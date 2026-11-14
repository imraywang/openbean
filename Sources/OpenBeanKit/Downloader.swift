// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 传输通道：蓝牙（`Link`）和 Wi‑Fi（`WifiExport`）收到的帧格式相同，下载循环只需要这三样。
/// 测试里用假的通道模拟设备（正常、断开、乱序、错的文件头……）。
public protocol TransferChannel: AnyObject {
    /// 在通道自己的队列上执行（`onPacket` 的回调也在这个队列上）
    func sync<T>(_ body: () throws -> T) rethrows -> T
    /// 每收到一帧回调；只在 `sync` 里改
    var onPacket: ((Packet) -> Void)? { get set }
    /// 还连着；只在 `sync` 里读
    var isConnected: Bool { get }
}

public struct DownloadProgress: Sendable {
    /// spool 里一共有的字节（解密后，包括之前几次留下的）
    public let received: Int
    /// 应有的字节（文件头 size 换算；没收到头时按列表时长）
    public let expected: Int
    /// 这一次新收到的字节（算速度用）
    public let thisAttempt: Int
    public let elapsed: Double
}

/// 下载循环为什么停下
public enum DownloadStop: Equatable, Sendable {
    case done              // 收到结束包 1A/0A
    case reachedExpected   // 收够了文件头说的大小（等了一会儿没等到结束包）
    case idle              // 一段时间没有新数据
    case disconnected      // 连接断了
    case clockJump         // 两次检查之间过了很久：Mac 睡过（合盖），连接多半已断
    case cancelled         // 调用方要停（让给语音输入、退出）
    case wrongFile         // 文件头是别的文件
    case deviceError       // 文件头报错（err ≠ 0，例如正在录音时请求历史文件）
    case writeFailed       // 写盘出错
    case resumeMismatch    // 续传回来的第一片不是期望的那片（这次的数据一片没写）

    public var label: String {
        switch self {
        case .done: return "收到结束包"
        case .reachedExpected: return "收够了"
        case .idle: return "没有新数据"
        case .disconnected: return "连接断开"
        case .clockJump: return "Mac 睡眠"
        case .cancelled: return "被取消"
        case .wrongFile: return "文件头不对"
        case .deviceError: return "设备报错"
        case .writeFailed: return "写盘失败"
        case .resumeMismatch: return "续传首片不对"
        }
    }

    /// 是连接 / 睡眠这类外因（重连后马上可以再试），不是数据本身的问题
    public var isInterruption: Bool { self == .disconnected || self == .clockJump || self == .cancelled }
}

public struct DownloadResult: Sendable {
    public let fileId: UInt32
    public let head: FileHead?
    public let offset: UInt32
    /// 这次请求从哪一片起（从头为 0）
    public let fromSeq: UInt32
    /// 这次收到的第一片（装上解密器之后）
    public let firstSliceSeq: UInt32?
    /// spool 里收到的全部 seq（包括之前几次留下的）
    public let received: SeqRanges
    /// 这一次新收到的片数
    public let newFrames: Int
    public let gotDone: Bool
    public let seconds: Double
    public let stop: DownloadStop
    public let check: DownloadCheck.Result
    public let tocConsistency: Double

    public var receivedBytes: Int { received.count * OggOpus.frameSize }
    public var bytesThisAttempt: Int { newFrames * OggOpus.frameSize }
    /// 日志用的一句话
    public var summary: String {
        "\(ResumePlan.label(fromSeq: fromSeq))；停止原因：\(stop.label)；本次新收 \(bytesThisAttempt / 1024) KB、\(Int(seconds)) 秒；"
            + "累计 \(received.count) / \(check.expectedFrames) 片（\(received.summary)）；结束包 \(gotDone ? "有" : "没有")"
    }
}

extension FileHead: @unchecked Sendable {}

/// 下载一个文件到 `FrameSpool`：发请求 → 每 `tick` 秒看一次进度 → 收完 / 断开 / 睡眠 / 取消 / 出错时停 →
/// 判断完整性。和 `D3200Session.pull` 的区别：不在内存里攒，校验文件头，认得断开和睡眠。
public enum Downloader {
    public static func run(channel: TransferChannel, crypto: SessionCrypto, file: RecordingFile, spool: FrameSpool,
                           offset: UInt32 = 0, fromSeq: UInt32 = 0, idle: Double = 20, tick: Double = 0.5, clockJump: Double = 15,
                           doneGrace: Double = 2,
                           request: () async throws -> Void,
                           shouldCancel: () async -> Bool = { false },
                           progress: (DownloadProgress) async -> Void) async throws -> DownloadResult {
        let st = TransferState(fileId: file.id)
        st.spool = spool
        st.requestedOffset = offset
        if fromSeq > 0 { st.expectFirstSeq = fromSeq }
        let started = Date()
        channel.sync { channel.onPacket = { p in D3200Session.handle(p, st, crypto) } }
        var stop: DownloadStop = .idle
        do {
            try await request()
        } catch {
            channel.sync { channel.onPacket = nil }
            spool.flush()
            throw error
        }
        var lastTick = Date()
        var reachedAt: Date?
        while true {
            try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            let now = Date()
            let gap = now.timeIntervalSince(lastTick)
            lastTick = now
            let s = channel.sync {
                (frames: spool.count, new: st.newFrames, done: st.done, quiet: now.timeIntervalSince(st.lastActivity),
                 head: st.head, wrong: st.wrongHead != nil, connected: channel.isConnected,
                 writeFailed: spool.writeError != nil, mismatch: st.resumeMismatch)
            }
            let listFrames = file.audioBytes / OggOpus.frameSize
            let expectedFrames = s.head.map { DownloadCheck.headFrames($0, fromSeq: fromSeq, listFrames: listFrames) } ?? listFrames
            await progress(DownloadProgress(received: s.frames * OggOpus.frameSize, expected: expectedFrames * OggOpus.frameSize,
                                            thisAttempt: s.new * OggOpus.frameSize, elapsed: now.timeIntervalSince(started)))
            if s.wrong { stop = .wrongFile; break }
            if s.mismatch { stop = .resumeMismatch; break }
            if let h = s.head, h.errorCode != 0 { stop = .deviceError; break }
            if s.writeFailed { stop = .writeFailed; break }
            if s.done { stop = .done; break }
            if gap > clockJump { stop = .clockJump; break }
            if !s.connected { stop = .disconnected; break }
            if expectedFrames > 0, s.frames >= expectedFrames {
                // 收够了，再等一会儿结束包
                if reachedAt == nil { reachedAt = now }
                if now.timeIntervalSince(reachedAt!) >= doneGrace { stop = .reachedExpected; break }
                continue
            }
            if s.quiet > idle { stop = .idle; break }
            if await shouldCancel() { stop = .cancelled; break }
        }
        let snapshot = channel.sync {
            channel.onPacket = nil
            return (head: st.head, decrypted: st.decryptor != nil, done: st.done, new: st.newFrames, wrong: st.wrongHead,
                    first: st.firstSliceSeq)
        }
        spool.flush()
        let head = snapshot.wrong ?? snapshot.head
        let check = DownloadCheck.evaluate(requestedId: file.id, head: head, decrypted: snapshot.decrypted || snapshot.wrong != nil,
                                           received: spool.received, gotDone: snapshot.done,
                                           listFrames: file.audioBytes / OggOpus.frameSize, tocConsistency: spool.tocConsistency,
                                           resumedFrom: fromSeq)
        return DownloadResult(fileId: file.id, head: head, offset: offset, fromSeq: fromSeq, firstSliceSeq: snapshot.first,
                              received: spool.received, newFrames: snapshot.new,
                              gotDone: snapshot.done, seconds: Date().timeIntervalSince(started), stop: stop, check: check,
                              tocConsistency: spool.tocConsistency)
    }
}

extension Downloader {
    /// 带断点续传的下载：spool 里从第 0 片起已经连续有 k 片时，offset = k × 166、从第 k 片接着要（见 `ResumePlan`）。
    /// 续传回来的第一片不是第 k 片时，这次收的丢掉，再从头请求一次（已有的片不重写）。
    /// `request(offset)` 发 1A/07；`log` 记「续传，从第 N 片」/「从头」和回退。
    public static func runResuming(channel: TransferChannel, crypto: SessionCrypto, file: RecordingFile, spool: FrameSpool,
                                   support: ResumeSupport = .current, idle: Double = 20, tick: Double = 0.5,
                                   clockJump: Double = 15, doneGrace: Double = 2,
                                   request: (UInt32) async throws -> Void,
                                   log: (String) -> Void = { _ in },
                                   shouldCancel: () async -> Bool = { false },
                                   progress: (DownloadProgress) async -> Void) async throws -> DownloadResult {
        let plan = ResumePlan.next(received: spool.received, total: file.audioBytes / OggOpus.frameSize, support: support)
        log("\(file.id)：\(ResumePlan.label(fromSeq: plan.fromSeq))（offset \(plan.offset)）")
        func attempt(offset: UInt32, fromSeq: UInt32) async throws -> DownloadResult {
            try await run(channel: channel, crypto: crypto, file: file, spool: spool, offset: offset, fromSeq: fromSeq,
                          idle: idle, tick: tick, clockJump: clockJump, doneGrace: doneGrace,
                          request: { try await request(offset) }, shouldCancel: shouldCancel, progress: progress)
        }
        let first = try await attempt(offset: plan.offset, fromSeq: plan.fromSeq)
        guard first.stop == .resumeMismatch else {
            if plan.fromSeq > 0, let got = first.firstSliceSeq, got != plan.fromSeq {
                log("\(file.id)：设备没从第 \(plan.fromSeq) 片续，从第 \(got) 片发起，当作从头收")
            }
            return first
        }
        log("\(file.id)：续传回来的第一片是 \(first.firstSliceSeq.map(String.init) ?? "?")，不是 \(plan.fromSeq)；丢掉这次，从头下载")
        return try await attempt(offset: 0, fromSeq: 0)
    }
}

extension D3200Session {
    /// App 同步用的下载（蓝牙）：边收边写进 `spool`，校验文件头，认得断开和 Mac 睡眠。
    /// spool 里有上次没下完的连续前缀时带 offset 续传（见 `Downloader.runResuming`）。
    public func download(_ file: RecordingFile, spool: FrameSpool, idle: Double = 20,
                         log: (String) -> Void = { _ in },
                         shouldCancel: () async -> Bool = { false },
                         progress: (DownloadProgress) async -> Void) async throws -> DownloadResult {
        let link = self.link
        return try await Downloader.runResuming(channel: link, crypto: crypto, file: file, spool: spool, idle: idle,
                                                request: { offset in
                                                    try link.send(Cmd.transferFile(id: file.id, offset: offset, realtime: false))
                                                },
                                                log: log, shouldCancel: shouldCancel, progress: progress)
    }
}
