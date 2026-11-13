// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct Transfer {
    public let fileId: UInt32
    public let audio: [UInt8]       // 解密后的裸 Opus 帧串
    public let head: FileHead?
    public let decrypted: Bool
    public let decryptError: String?
    public let slices: Int
    public let firstSeq: UInt32?
    public let lastSeq: UInt32?
    public let missingSeqs: Int
    public let gotDone: Bool
    public let seconds: Double      // 传输耗时
    /// 每个 seq 第一次到达的时间；按 seq 排序后与 audio 里的帧一一对应。
    public let arrivals: [(seq: UInt32, at: Date)]
    /// 每个通知包到达的时间和其中的帧数。
    public let packets: [(at: Date, frames: Int)]
    public let newFileAt: Date?
    /// 这次收到的所有 1A/07 文件头（按到达顺序；正常只有一个）
    public let heads: [FileHead]
    /// 请求里的 offset（1A/07 的「已传字节数」字段）
    public let requestedOffset: UInt32
    /// 排查记录（只在请求时打开）
    public let diagnostics: TransferDiagnostics?

    /// 解密正确时，Opus 帧的 TOC 字节（第一个字节）几乎全一样；解错了会是随机值。
    public var tocConsistency: Double {
        let tocs = stride(from: 0, to: audio.count, by: OggOpus.frameSize).map { audio[$0] }
        guard let top = Dictionary(grouping: tocs, by: { $0 }).values.map(\.count).max(), !tocs.isEmpty else { return 0 }
        return Double(top) / Double(tocs.count)
    }

    public var dominantTOC: UInt8? {
        let tocs = stride(from: 0, to: audio.count, by: OggOpus.frameSize).map { audio[$0] }
        return Dictionary(grouping: tocs, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}

/// 收文件分片时的状态，只在 BLE 队列上改。
final class TransferState {
    var fileId: UInt32
    var head: FileHead?
    var decryptor: FileDecryptor?
    var decryptError: String?
    var chunks: [UInt32: [UInt8]] = [:]
    var slices = 0
    var done = false
    var lastActivity = Date()
    var newFileIds: [UInt32] = []
    // 延迟分析用
    var arrivals: [UInt32: Date] = [:]
    var packets: [(at: Date, frames: Int)] = []
    var newFileAt: Date?
    var heads: [FileHead] = []
    var requestedOffset: UInt32 = 0
    var diagnostics: TransferDiagnostics?
    let created = Date()
    /// 收到的分片包个数（1A/08 和 1A/12 一起数）
    var sliceFrames = 0
    /// 每个新帧（解密后）到达时在 BLE 队列上回调
    var onFrame: ((UInt32, [UInt8]) -> Void)?

    init(fileId: UInt32) { self.fileId = fileId }
    var bytes: Int { chunks.count * OggOpus.frameSize }
}

public final class D3200Session {
    public let link: Link
    public let crypto = SessionCrypto()

    public init(link: Link) { self.link = link }

    public func deviceInfo() async throws -> DeviceInfo? {
        let p = try await link.request(Cmd.getDeviceInfo(), label: "设备信息") { $0.type == 0x01 && $0.id == 0x01 }
        return DeviceInfo(frame: p.raw)
    }

    public func syncTime() async throws {
        _ = try await link.request(Cmd.syncTime(), label: "同步时间") { $0.type == 0x01 && $0.id == 0xA6 }
    }

    /// ECDH 握手，成功后才能解密文件。
    public func handshake() async throws {
        let p = try await link.request(Cmd.encryptHandshake(publicKey: crypto.publicKey), timeout: 12,
                                       label: "ECDH 握手") { $0.type == 0x2E && $0.id == 0x01 }
        guard p.raw.count >= 106 else {
            throw LinkError.missing("握手回包太短（\(p.raw.count) 字节）：\(p.raw.hex)")
        }
        try crypto.complete(devicePublicKey: Array(p.raw[9..<74]), deviceShared: Array(p.raw[74..<106]))
    }

    public func listFiles() async throws -> [RecordingFile] {
        var all: [UInt32: RecordingFile] = [:]
        for page in 0..<50 {
            let p = try await link.request(Cmd.listFiles(page: page), label: "文件列表第 \(page + 1) 页") {
                Rx.isTransport($0) && $0.id == Rx.fileList
            }
            let list = FileListPage(payload: Array(p.payload), withEndTime: p.type == 0x1B)
            list.files.forEach { all[$0.id] = $0 }
            if list.declaredCount < 10 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return all.values.sorted { $0.id > $1.id }
    }

    func installTransfer(_ st: TransferState) { install(st) }

    private func install(_ st: TransferState) {
        let crypto = self.crypto
        link.onPacket = { p in Self.handle(p, st, crypto) }
    }

    /// BLE 和 Wi‑Fi 两条通道收到的传输帧格式相同，共用这段处理。
    static func handle(_ p: Packet, _ st: TransferState, _ crypto: SessionCrypto) {
        guard Rx.isTransport(p) else { return }
        switch p.id {
        case Rx.recordStatus where p.payload.count >= 4:
            let id = readU32(Array(p.payload), 0)
            if id > 0 { st.newFileIds.append(id); if st.newFileAt == nil { st.newFileAt = Date() } }
        case Rx.fileHead:
            st.lastActivity = Date()
            guard let head = FileHead(frame: p.raw) else { return }
            st.heads.append(head)
            st.head = head
            do { st.decryptor = try crypto.fileDecryptor(for: head) } catch {
                st.decryptError = "\(error)"
            }
        case Rx.fileSlice, Rx.fileSliceMark:
            let now = Date()
            st.lastActivity = now
            let slices = parseSlices(frame: p.raw)
            st.packets.append((now, slices.count))
            st.diagnostics?.note(frame: p, slices: slices, packetIndex: st.sliceFrames,
                                 elapsed: now.timeIntervalSince(st.created))
            st.sliceFrames += 1
            for s in slices {
                let isNew = st.arrivals[s.seq] == nil
                if isNew { st.arrivals[s.seq] = now }
                st.slices += 1
                let plain: [UInt8]
                if let d = st.decryptor, let p = try? d.decrypt(seq: s.seq, data: s.data) { plain = p } else { plain = s.data }
                st.chunks[s.seq] = plain
                if isNew, st.decryptor != nil { st.onFrame?(s.seq, plain) }
            }
        case Rx.fileDone:
            st.lastActivity = Date()
            st.done = true
        default: break
        }
    }

    static func makeTransfer(_ st: TransferState, started: Date) -> Transfer {
        let seqs = st.chunks.keys.sorted()
        let audio = seqs.flatMap { st.chunks[$0]! }
        let missing = seqs.isEmpty ? 0 : Int(seqs.last! - seqs.first!) + 1 - seqs.count
        return Transfer(fileId: st.fileId, audio: audio, head: st.head, decrypted: st.decryptor != nil,
                        decryptError: st.decryptError, slices: st.slices, firstSeq: seqs.first,
                        lastSeq: seqs.last, missingSeqs: missing, gotDone: st.done,
                        seconds: Date().timeIntervalSince(started),
                        arrivals: seqs.compactMap { q in st.arrivals[q].map { (q, $0) } },
                        packets: st.packets, newFileAt: st.newFileAt, heads: st.heads,
                        requestedOffset: st.requestedOffset, diagnostics: st.diagnostics)
    }

    private func finish(_ st: TransferState, started: Date) -> Transfer {
        link.sync {
            link.onPacket = nil
            return Self.makeTransfer(st, started: started)
        }
    }

    /// 离线拉一个文件（BLE 通道）。`idle` 是多久没有新数据就放弃，不是总时长上限。
    /// `offset` 原样放进 1A/07 请求（设备认不认、单位是什么还没实测，见 `pull --resume-test`）。
    /// `diagnostics` 不为 nil 时记下 1A/12、flags 和文件头（排查用）。
    public func pull(_ file: RecordingFile, offset: UInt32 = 0, idle: Double = 20, maxSeconds: Double? = nil,
                     diagnostics: TransferDiagnostics? = nil,
                     shouldCancel: () async -> Bool = { false },
                     progress: (Int, Int, Double) async -> Void) async throws -> Transfer {
        let st = TransferState(fileId: file.id)
        st.requestedOffset = offset
        st.diagnostics = diagnostics
        let started = Date()
        link.sync { install(st) }
        try link.send(Cmd.transferFile(id: file.id, offset: offset, realtime: false))
        while true {
            try await Task.sleep(nanoseconds: 500_000_000)
            // 文件头里的 size 是线上字节（每片 166），换算成解密后字节（每片 160）
            let (bytes, done, quiet, expected) = link.sync {
                (st.bytes, st.done, Date().timeIntervalSince(st.lastActivity),
                 st.head.map { Int($0.size) / 166 * 160 } ?? file.audioBytes)
            }
            await progress(bytes, expected, Date().timeIntervalSince(started))
            if done || (expected > 0 && bytes >= expected) { break }
            if quiet > idle { break }
            if let maxSeconds, Date().timeIntervalSince(started) >= maxSeconds { break }
            if await shouldCancel() { break }
        }
        return finish(st, started: started)
    }

    /// 不再收的传输：设备可能还在发（我们没有「停止传输」的命令）。只数不存，
    /// 直到 `quiet` 秒没有传输帧或满 `maxSeconds` 秒。返回期间收到的分片数和有没有 1A/0A。
    public func drain(quiet: Double = 3, maxSeconds: Double = 120) async -> (slices: Int, gotDone: Bool, seconds: Double) {
        final class Counter { var slices = 0; var done = false; var last = Date() }
        let c = Counter()
        let started = Date()
        link.sync {
            link.onPacket = { p in
                guard Rx.isTransport(p) else { return }
                c.last = Date()
                if p.id == Rx.fileSlice || p.id == Rx.fileSliceMark { c.slices += parseSlices(frame: p.raw).count }
                if p.id == Rx.fileDone { c.done = true }
            }
        }
        while Date().timeIntervalSince(started) < maxSeconds {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if link.sync({ Date().timeIntervalSince(c.last) }) >= quiet { break }
        }
        return link.sync {
            link.onPacket = nil
            return (c.slices, c.done, Date().timeIntervalSince(started))
        }
    }

    /// 开始录音 → 等设备报新文件 id → 用实时模式拉流 `seconds` 秒 → 暂停录音 → 结束录音（收尾文件）。
    /// `finish` 为 false 时只暂停、不结束（排查用：文件还开着，下次开始会续写）。
    public func live(seconds: Double, finish: Bool = true, diagnostics: TransferDiagnostics? = nil,
                     onFrame: ((UInt32, [UInt8]) -> Void)? = nil,
                     shouldStop: @escaping () -> Bool = { false },
                     progress: (Int, Double) -> Void) async throws -> Transfer {
        let st = TransferState(fileId: 0)
        st.onFrame = onFrame
        st.diagnostics = diagnostics
        link.sync { install(st) }
        let rec = try await link.request(Cmd.startRecord(), label: "开始录音") { $0.type == 0x18 && $0.id == 0x82 }
        FileHandle.standardError.write(Data("  · 开始录音回包 st=\(String(format: "%02X", rec.status)) payload=\(rec.payload.hex)\n".utf8))

        // 等 1A06 告诉我们新文件 id
        var fileId: UInt32?
        for _ in 0..<40 {
            fileId = link.sync { st.newFileIds.last }
            if fileId != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if fileId == nil {
            FileHandle.standardError.write(Data("  · 10 秒内没收到 1A06，改从文件列表里取最新的一条\n".utf8))
            link.sync { link.onPacket = nil }
            fileId = try await listFiles().first?.id
            link.sync { install(st) }
        }
        guard let fileId else { throw LinkError.missing("录音文件 id") }
        link.sync { st.fileId = fileId }
        FileHandle.standardError.write(Data("  · 实时文件 id=\(fileId)\n".utf8))

        let started = Date()
        try link.send(Cmd.transferFile(id: fileId, realtime: true))
        while Date().timeIntervalSince(started) < seconds, !shouldStop() {
            try await Task.sleep(nanoseconds: 200_000_000)
            progress(link.sync { st.bytes }, Date().timeIntervalSince(started))
        }
        _ = try? await link.request(Cmd.pauseRecord(), label: "暂停录音") { $0.type == 0x18 && $0.id == 0x82 }
        try await Task.sleep(nanoseconds: 3_000_000_000) // 收尾巴
        let t = self.finish(st, started: started)
        if finish {
            do {
                let id = try await stopRecording()
                FileHandle.standardError.write(Data("  · 已结束录音\(id.map { "，1A/0A 文件 id=\($0)" } ?? "（没等到 1A/0A）")\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("  · 结束录音失败：\(error)\n".utf8))
            }
        }
        return t
    }
}

// MARK: - 设备事件与实时流（给常驻应用用）

public enum DeviceEvent: Sendable {
    /// 开始录音（含按录音豆按键）。`fileId` 是新录音文件
    case recordingStarted(fileId: UInt32)
    /// 停止录音（含按键）
    case recordingStopped
    case charging(recorder: Bool, chargingCase: Bool)
    case battery(recorder: Int?, chargingCase: Int?)
}

extension DeviceEvent {
    /// 把设备主动发来的帧翻译成事件；不认识的返回 nil
    public init?(packet p: Packet) {
        let b = Array(p.payload)
        switch (p.type, p.id) {
        case (0x1A, 0x06) where b.count >= 4:
            let id = readU32(b, 0)
            guard id > 0 else { return nil }
            self = .recordingStarted(fileId: id)
        // 按键停止推送 payload 首字节 00；我们自己发暂停命令的回包首字节 02
        case (0x18, 0x82) where b.first == 0x00 || b.first == 0x02:
            self = .recordingStopped
        case (0x01, 0x04) where b.count >= 2:
            self = .charging(recorder: b[0] == 1, chargingCase: b[1] == 1)
        case (0x01, 0x03) where b.count >= 2:
            self = .battery(recorder: DeviceInfo.battery(b[0]), chargingCase: DeviceInfo.battery(b[1]))
        default:
            return nil
        }
    }
}

/// 一路实时流。`stop()` 只停止接收，不会让设备停止录音。
public final class RealtimeStream: @unchecked Sendable {
    fileprivate let state: TransferState
    fileprivate let started = Date()
    fileprivate weak var session: D3200Session?
    public let fileId: UInt32

    fileprivate init(fileId: UInt32, state: TransferState, session: D3200Session) {
        self.fileId = fileId
        self.state = state
        self.session = session
    }

    public var bytes: Int { session?.link.sync { state.bytes } ?? 0 }

    @discardableResult
    public func stop() -> Transfer? { session?.finishRealtime(self) }
}

extension D3200Session {
    /// 订阅设备事件（回调在 BLE 队列上）
    public func observeEvents(_ handler: @escaping (DeviceEvent) -> Void) {
        link.sync { link.onEvent = { p in if let e = DeviceEvent(packet: p) { handler(e) } } }
    }

    public func startRecording() async throws {
        _ = try await link.request(Cmd.startRecord(), label: "开始录音") { $0.type == 0x18 && $0.id == 0x82 }
    }

    public func pauseRecording() async throws {
        _ = try await link.request(Cmd.pauseRecord(), label: "暂停录音") { $0.type == 0x18 && $0.id == 0x82 }
    }

    /// 结束录音并收尾文件（18/82 载荷 00）。真机实测的顺序是先 `pauseRecording()` 再调它；
    /// 不先暂停、录音中直接发还没测过。等到 18/82 回包后，再最多等 `fileDoneTimeout` 秒的 1A/0A
    /// （传输结束通知，载荷字节 5–8 是文件 id），返回其中的文件 id；没等到返回 nil，不算失败。
    @discardableResult
    public func stopRecording(fileDoneTimeout: Double = 3) async throws -> UInt32? {
        let done = link.latch { Rx.isTransport($0) && $0.id == Rx.fileDone }
        do {
            _ = try await link.request(Cmd.stopRecord(), label: "结束录音") { $0.type == 0x18 && $0.id == 0x82 }
        } catch {
            _ = await link.value(of: done, timeout: 0)
            throw error
        }
        guard let p = await link.value(of: done, timeout: fileDoneTimeout) else { return nil }
        return Self.fileDoneId(p)
    }

    /// 1A/0A 里的文件 id（真机：`00 30 1B 00 00 | EE C2 F6 6A`，前 5 字节含义未记录）
    static func fileDoneId(_ p: Packet) -> UInt32? {
        let b = Array(p.payload)
        return b.count >= 9 ? readU32(b, 5) : nil
    }

    /// 对正在录的文件开实时流。`onFrame` 在 BLE 队列上收到每个解密后的 Opus 帧。
    public func startRealtime(fileId: UInt32, onFrame: @escaping (UInt32, [UInt8]) -> Void) throws -> RealtimeStream {
        let st = TransferState(fileId: fileId)
        st.onFrame = onFrame
        let stream = RealtimeStream(fileId: fileId, state: st, session: self)
        link.sync { installTransfer(st) }
        try link.send(Cmd.transferFile(id: fileId, realtime: true))
        return stream
    }

    fileprivate func finishRealtime(_ s: RealtimeStream) -> Transfer {
        link.sync {
            link.onPacket = nil
            return Self.makeTransfer(s.state, started: s.started)
        }
    }
}
