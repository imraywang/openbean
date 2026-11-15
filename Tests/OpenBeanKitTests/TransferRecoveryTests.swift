// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanKit
import XCTest

/// iOS 后台下载被打断以后的处理（真机日志 2026-11-15：挂起被当成 Mac 睡眠、新请求时录音豆还在发旧数据、err=4 删了临时文件）
final class TransferRecoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("openbean-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let f = RecordingFile(id: 1_778_656_172, endTime: nil, durationMs: 300 * 20)

    /// spool 里先有 0…119
    private func spoolWithPrefix() throws -> FrameSpool {
        let url = dir.appendingPathComponent("download.part")
        let old = try FrameSpool(url: url, keepExisting: false)
        for q in 0..<120 { old.put(seq: UInt32(q), frame: FakeDevice.plain(seq: UInt32(q))) }
        old.close()
        return try FrameSpool(url: url, keepExisting: true)
    }

    /// 录音豆还在发上一次请求的数据：不管请求什么，回来的都是从 `from` 起的片（文件头照常，或 err=4）
    private func staleStream(_ dev: FakeDevice, _ ch: FakeChannel, from: Int, error: UInt8 = 0,
                             requests: DownloadTests.Box<[UInt32]>) -> (UInt32) async throws -> Void {
        { offset in
            requests.value.append(offset)
            var packets = [try dev.head(fileId: self.f.id, slices: 300, error: error)]
            for start in stride(from: from, to: 300, by: 10) { packets.append(try dev.slices((start..<min(start + 10, 300)).map(UInt32.init))) }
            ch.play(count: packets.count) { packets[$0] }
        }
    }

    // MARK: 片号对不上

    func testBackgroundSafeMismatchKeepsPrefixAndDoesNotAskFromStart() async throws {
        let dev = try FakeDevice()
        let sp = try spoolWithPrefix()
        let ch = FakeChannel()
        let reqs = DownloadTests.Box<[UInt32]>([])
        var logs: [String] = []
        let r = try await Downloader.runResuming(channel: ch, crypto: dev.crypto, file: f, spool: sp, idle: 0.3, tick: 0.02,
                                                 doneGrace: 0.1, behavior: .backgroundSafe,
                                                 request: staleStream(dev, ch, from: 180, requests: reqs),
                                                 log: { logs.append($0) }, progress: { _ in })
        XCTAssertEqual(reqs.value, [120 * 166], "不马上从 0 再要（录音豆还在发，只会得到 err=4）")
        XCTAssertEqual(r.stop, .resumeMismatch)
        XCTAssertEqual(r.newFrames, 0)
        XCTAssertEqual(sp.received.ranges, [0...119], "已经连续收好的前缀不丢")
        XCTAssertTrue(TransferRecovery.keepsPartial(stop: r.stop, verdict: r.check.verdict))
        XCTAssertTrue(TransferRecovery.needsQuiet(r.stop))
    }

    func testStandardBehaviourStillFallsBackToStart() async throws {
        // Mac 不变：续传首片不对就马上从 0 再要
        let dev = try FakeDevice()
        let sp = try spoolWithPrefix()
        let ch = FakeChannel()
        let reqs = DownloadTests.Box<[UInt32]>([])
        _ = try await Downloader.runResuming(channel: ch, crypto: dev.crypto, file: f, spool: sp, idle: 0.3, tick: 0.02,
                                             doneGrace: 0.1, request: staleStream(dev, ch, from: 180, requests: reqs),
                                             progress: { _ in })
        XCTAssertEqual(reqs.value, [120 * 166, 0])
    }

    func testStrictStartIgnoresTheOldStreamOnAFromStartRequest() async throws {
        let dev = try FakeDevice()
        let sp = try FrameSpool(url: dir.appendingPathComponent("download.part"), keepExisting: false)
        let ch = FakeChannel()
        let reqs = DownloadTests.Box<[UInt32]>([])
        let r = try await Downloader.runResuming(channel: ch, crypto: dev.crypto, file: f, spool: sp, idle: 0.3, tick: 0.02,
                                                 doneGrace: 0.1, behavior: .backgroundSafe,
                                                 request: staleStream(dev, ch, from: 200, requests: reqs), progress: { _ in })
        XCTAssertEqual(r.stop, .resumeMismatch)
        XCTAssertEqual(sp.count, 0, "从头请求时回来的不是第 0 片：上一次的数据，一片不写")
    }

    // MARK: err=4

    func testDeviceBusyHeadWritesNothingAndKeepsThePartial() async throws {
        let dev = try FakeDevice()
        let sp = try spoolWithPrefix()
        let ch = FakeChannel()
        let reqs = DownloadTests.Box<[UInt32]>([])
        // 从头请求（标准行为，不查第一片）：设备回 err=4 的头，后面紧跟着上一次请求的片
        let r = try await Downloader.run(channel: ch, crypto: dev.crypto, file: f, spool: sp, idle: 0.3, tick: 0.02,
                                         request: { try await self.staleStream(dev, ch, from: 200, error: 4, requests: reqs)(0) },
                                         progress: { _ in })
        XCTAssertEqual(r.stop, .deviceError)
        XCTAssertEqual(r.newFrames, 0, "err=4 后面的片一片不写（真机日志里别的文件的片曾写进了这个文件）")
        XCTAssertEqual(sp.received.ranges, [0...119])
        guard case .rejected = r.check.verdict else { return XCTFail("\(r.check.verdict)") }
        XCTAssertTrue(TransferRecovery.keepsPartial(stop: r.stop, verdict: r.check.verdict), "设备忙不算数据坏了")
    }

    // MARK: 挂起

    func testSuspendableDownloadDoesNotStopOnAClockGap() async throws {
        let dev = try FakeDevice()
        // 没有结束包：下载循环要多检查几次才会停（收够以后等 doneGrace）
        let packets = try dev.packets(fileId: f.id, slices: 300, perPacket: 10, done: false)
        func run(_ b: DownloadBehavior) async throws -> DownloadResult {
            let ch = FakeChannel()
            let sp = try FrameSpool(url: dir.appendingPathComponent("\(UUID().uuidString).part"), keepExisting: false)
            // clockJump 设得极小：每一次检查都算「隔了很久」
            return try await Downloader.run(channel: ch, crypto: dev.crypto, file: f, spool: sp, idle: 0.5, tick: 0.02,
                                            clockJump: 0.000_1, doneGrace: 0.1, behavior: b,
                                            request: { ch.play(count: packets.count) { packets[$0] } }, progress: { _ in })
        }
        let mac = try await run(.standard)
        XCTAssertEqual(mac.stop, .clockJump, "Mac 不变：隔太久按睡眠停")
        let phone = try await run(.backgroundSafe)
        XCTAssertEqual(phone.stop, .reachedExpected, "iOS：被挂起不是断开，接着收")
        XCTAssertEqual(phone.check.verdict, .complete)
    }

    func testSuspensionThreshold() {
        XCTAssertFalse(DownloadBehavior.wasSuspended(gap: 0.6, tick: 0.5))
        XCTAssertTrue(DownloadBehavior.wasSuspended(gap: 2.5, tick: 0.5))
        XCTAssertTrue(DownloadBehavior.wasSuspended(gap: 170, tick: 0.5))
    }

    // MARK: 等录音豆安静

    func testQuietDeviceProceedsAfterOneWindow() {
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: nil, listened: 1, sinceRelink: nil), .wait, "刚连上：先听一会儿")
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: nil, listened: StreamQuiet.quietWindow, sinceRelink: nil), .proceed)
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: 600, listened: 3.5, sinceRelink: nil), .proceed, "很久以前收到过：不算在发")
    }

    func testStreamingDeviceWaitsThenRelinksOnce() {
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: 0.1, listened: 4, sinceRelink: nil), .wait)
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: 0.1, listened: StreamQuiet.relinkAfter, sinceRelink: nil), .relink)
        // 刚为这事断开过（重连后还在发：断开没让它停）：不再断，等它发完
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: 0.1, listened: StreamQuiet.relinkAfter, sinceRelink: 30), .wait)
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: 0.1, listened: 600, sinceRelink: 30), .wait)
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: 4, listened: 600, sinceRelink: 30), .proceed, "发完了")
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: 0.1, listened: StreamQuiet.maxWait, sinceRelink: 30), .giveUp)
        // 冷却过了可以再断一次
        XCTAssertEqual(StreamQuiet.next(sinceLastStray: 0.1, listened: 9, sinceRelink: StreamQuiet.relinkCooldown + 1), .relink)
    }

    func testOnlyBadDataDeletesThePartial() {
        let bad = DownloadCheck.Verdict.rejected("解出来的不像 Opus")
        XCTAssertFalse(TransferRecovery.keepsPartial(stop: .done, verdict: bad))
        XCTAssertFalse(TransferRecovery.keepsPartial(stop: .reachedExpected, verdict: bad))
        for stop: DownloadStop in [.deviceError, .wrongFile, .resumeMismatch, .disconnected, .clockJump, .cancelled, .idle] {
            XCTAssertTrue(TransferRecovery.keepsPartial(stop: stop, verdict: .rejected("x")), "\(stop)")
        }
        XCTAssertTrue(TransferRecovery.keepsPartial(stop: .done, verdict: .incomplete("x")))
        XCTAssertFalse(TransferRecovery.needsQuiet(.done))
        XCTAssertFalse(TransferRecovery.needsQuiet(.disconnected), "断开了录音豆自己就停了")
    }
}
