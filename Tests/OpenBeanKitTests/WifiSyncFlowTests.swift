// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanKit
import XCTest

/// 经 Wi‑Fi 同步的流程（不碰硬件）：步骤顺序、各处失败时的走向（离不离开热点、前面存下的还算不算）、
/// 中途停下时已收的片留在 spool 里且蓝牙按同一套规则续传；以及何时提示改用 Wi‑Fi、两种方式的预计时间
final class WifiSyncFlowTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("openbean-wifi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: 假的平台部分

    final class Journal: @unchecked Sendable {
        var events: [String] = []
        func add(_ s: String) { events.append(s) }
    }

    final class FakeJoiner: HotspotJoining {
        let journal: Journal
        var joinError: Error?
        init(_ j: Journal, joinError: Error? = nil) { journal = j; self.joinError = joinError }
        func join(ssid: String, password: String, device: SoftAPEndpoint) async throws {
            journal.add("join \(ssid) \(device)")
            if let joinError { throw joinError }
        }
        func leave(ssid: String, device: SoftAPEndpoint) async { journal.add("leave") }
    }

    final class FakeTransport: WifiTransport {
        let journal: Journal
        var connectError: Error?
        /// 每个文件停下的原因（没写的按 .done）
        var stops: [UInt32: DownloadStop] = [:]
        init(_ j: Journal) { journal = j }
        func open() async throws {
            journal.add("connect")
            if let connectError { throw connectError }
        }
        func fetch(_ file: RecordingFile, spool: FrameSpool, shouldCancel: @escaping () async -> Bool,
                   progress: @escaping (DownloadProgress) async -> Void) async throws -> DownloadResult {
            journal.add("download \(file.id)")
            await progress(DownloadProgress(received: 50, expected: 100, thisAttempt: 50, elapsed: 1))
            let stop = stops[file.id] ?? .done
            let ok = stop == .done
            return DownloadResult(fileId: file.id, head: nil, offset: 0, fromSeq: 0, firstSliceSeq: 0,
                                  received: SeqRanges(), newFrames: 10, gotDone: ok, seconds: 1, stop: stop,
                                  check: DownloadCheck.Result(verdict: ok ? .complete : .incomplete("test"), expectedFrames: 10,
                                                              firstSeq: 0, missing: ok ? 0 : 5),
                                  tocConsistency: 1)
        }
        func close() async { journal.add("close") }
    }

    private let ep = SoftAPEndpoint(ip: "192.168.43.1", port: 443)

    private func flow(_ j: Journal, joiner: FakeJoiner? = nil, transport: FakeTransport? = nil,
                      openError: Error? = nil) -> WifiSyncFlow {
        let t = transport ?? FakeTransport(j)
        var f = WifiSyncFlow(openHotspot: { [ep] in
            j.add("open")
            if let openError { throw openError }
            return ep
        }, joiner: joiner ?? FakeJoiner(j), makeTransport: { _ in t }, ssid: "WiFi-openbean", password: "1762900000000")
        f.sleep = { _ in }
        return f
    }

    private func files(_ ids: UInt32...) -> [RecordingFile] { ids.map { RecordingFile(id: $0, endTime: nil, durationMs: 200) } }

    private func run(_ f: WifiSyncFlow, files: [RecordingFile], cancelAfter: Int? = nil,
                     journal j: Journal) async -> (WifiSyncFlow.Report, [WifiSyncStep], [UInt32]) {
        var steps: [WifiSyncStep] = []
        var done: [UInt32] = []
        var checks = 0
        let report = await f.run(files: files, spool: { id in
            try FrameSpool(url: self.dir.appendingPathComponent("\(id).part"), keepExisting: true)
        }, shouldCancel: {
            checks += 1
            return cancelAfter.map { checks > $0 } ?? false
        }, step: { steps.append($0) }, fileDone: { id, _, _ in done.append(id) })
        return (report, steps, done)
    }

    // MARK: 状态走向

    func testHappyPathOrderAndSteps() async {
        let j = Journal()
        let (r, steps, done) = await run(flow(j), files: files(1, 2), journal: j)
        XCTAssertNil(r.failure)
        XCTAssertEqual(r.stage, .finished)
        XCTAssertTrue(r.joined)
        XCTAssertEqual(r.endpoint, ep)
        XCTAssertEqual(j.events, ["open", "join WiFi-openbean 192.168.43.1:443", "connect", "download 1", "download 2", "close", "leave"])
        XCTAssertEqual(done, [1, 2])
        XCTAssertEqual(steps.first, .openingHotspot)
        XCTAssertEqual(Array(steps.prefix(3)), [.openingHotspot, .joining, .connecting])
        XCTAssertTrue(steps.contains(.downloading(index: 1, count: 2, percent: 50)))
        XCTAssertEqual(steps.last, .leaving)
    }

    func testHotspotRequestFailsDoesNotJoinOrLeave() async {
        let j = Journal()
        let (r, steps, done) = await run(flow(j, openError: LinkError.timeout("Wi‑Fi")), files: files(1), journal: j)
        XCTAssertNotNil(r.failure)
        XCTAssertNil(r.endpoint)
        XCTAssertEqual(r.stage, .opening)
        XCTAssertEqual(j.events, ["open"])
        XCTAssertEqual(steps, [.openingHotspot])
        XCTAssertTrue(done.isEmpty)
    }

    func testUserDeniedJoinStillLeavesAndNeverConnects() async {
        let j = Journal()
        let (r, _, done) = await run(flow(j, joiner: FakeJoiner(j, joinError: WifiSyncError.userDenied)), files: files(1), journal: j)
        XCTAssertEqual(r.failure as? WifiSyncError, .userDenied)
        XCTAssertEqual(r.stage, .joining)
        XCTAssertFalse(r.joined)
        XCTAssertEqual(j.events, ["open", "join WiFi-openbean 192.168.43.1:443", "leave"])
        XCTAssertTrue(done.isEmpty)
    }

    func testNotOnHotspotIsAJoinFailure() async {
        let j = Journal()
        let (r, _, _) = await run(flow(j, joiner: FakeJoiner(j, joinError: WifiSyncError.notOnHotspot)), files: files(1), journal: j)
        XCTAssertEqual(r.failure as? WifiSyncError, .notOnHotspot)
        XCTAssertEqual(j.events.last, "leave")
    }

    func testWebSocketFailureLeavesHotspot() async {
        let j = Journal()
        let t = FakeTransport(j)
        t.connectError = LinkError.timeout("WebSocket")
        let (r, _, done) = await run(flow(j, transport: t), files: files(1), journal: j)
        XCTAssertNotNil(r.failure)
        XCTAssertEqual(r.stage, .connecting)
        XCTAssertTrue(r.joined)
        XCTAssertEqual(j.events, ["open", "join WiFi-openbean 192.168.43.1:443", "connect", "leave"])
        XCTAssertTrue(done.isEmpty)
    }

    /// Wi‑Fi 中途断了：这个文件的结果照样交出去（已收的留着），后面的不再请求，收尾、离开热点
    func testDropMidwayHandsOverPartialAndStops() async {
        let j = Journal()
        let t = FakeTransport(j)
        t.stops = [2: .disconnected]
        let (r, _, done) = await run(flow(j, transport: t), files: files(1, 2, 3), journal: j)
        XCTAssertEqual(r.failure as? WifiSyncError, .dropped)
        XCTAssertEqual(r.stage, .downloading)
        XCTAssertEqual(done, [1, 2])
        XCTAssertEqual(r.files.map(\.id), [1, 2])
        XCTAssertEqual(j.events, ["open", "join WiFi-openbean 192.168.43.1:443", "connect", "download 1", "download 2", "close", "leave"])
    }

    /// 一个文件没等到数据（idle）不算断：和拆分前一样接着下一个
    func testIdleFileContinuesWithNext() async {
        let j = Journal()
        let t = FakeTransport(j)
        t.stops = [1: .idle]
        let (r, _, done) = await run(flow(j, transport: t), files: files(1, 2), journal: j)
        XCTAssertNil(r.failure)
        XCTAssertEqual(done, [1, 2])
    }

    /// App 要停（iOS 切到后台）：停在下一个文件之前，离开热点
    func testCancelBetweenFilesStopsAndLeaves() async {
        let j = Journal()
        // 第 1 次检查在加入前，第 2 次在第一个文件前，第 3 次在第二个文件前
        let (r, _, done) = await run(flow(j), files: files(1, 2), cancelAfter: 2, journal: j)
        XCTAssertEqual(r.failure as? WifiSyncError, .cancelled)
        XCTAssertEqual(done, [1])
        XCTAssertEqual(j.events.suffix(2), ["close", "leave"])
    }

    func testCancelledDuringFileStopsAfterHandingItOver() async {
        let j = Journal()
        let t = FakeTransport(j)
        t.stops = [1: .cancelled]
        let (r, _, done) = await run(flow(j, transport: t), files: files(1, 2), journal: j)
        XCTAssertEqual(r.failure as? WifiSyncError, .cancelled)
        XCTAssertEqual(done, [1])
        XCTAssertFalse(j.events.contains("download 2"))
    }

    func testCancelBeforeJoiningDoesNotJoin() async {
        let j = Journal()
        let (r, _, _) = await run(flow(j), files: files(1), cancelAfter: 0, journal: j)
        XCTAssertEqual(r.failure as? WifiSyncError, .cancelled)
        XCTAssertFalse(r.joined)
        XCTAssertEqual(j.events, ["open", "leave"])
    }

    // MARK: 续传：Wi‑Fi 收了一半，蓝牙按同一套规则接着下

    func testWifiPartialIsResumedOverBluetoothFromContiguousPrefix() async throws {
        let dev = try FakeDevice()
        let f = RecordingFile(id: 1_794_000_000, endTime: nil, durationMs: 300 * 20)
        let url = dir.appendingPathComponent("download.part")
        // Wi‑Fi：从头请求（Wi‑Fi 一律 offset 0），收到 120 片后断开
        let wifi = FakeChannel()
        let packets = try dev.packets(fileId: f.id, slices: 300, perPacket: 10)
        var requested: [String] = []
        let sp = try FrameSpool(url: url, keepExisting: true)
        let r1 = try await Downloader.run(channel: wifi, crypto: dev.crypto, file: f, spool: sp, idle: 0.3, tick: 0.02, doneGrace: 0.1,
                                          request: {
                                              requested.append(Cmd.wifiFileRequestHex(id: f.id))
                                              wifi.play(count: packets.count, disconnectAfter: 13) { packets[$0] }
                                          }, progress: { _ in })
        XCTAssertEqual(r1.stop, .disconnected)
        XCTAssertEqual(r1.received.ranges, [0...119])
        XCTAssertTrue(TransferRecovery.keepsPartial(stop: r1.stop, verdict: r1.check.verdict))
        XCTAssertTrue(requested[0].hasPrefix("08ee0000001a071200" + "00000000"), "Wi‑Fi 请求的 offset 是 0")
        sp.close()

        // 蓝牙：重新打开临时文件，按连续前缀带 offset = 120 × 166 续传
        let bt = FakeChannel()
        var offsets: [UInt32] = []
        let again = try FrameSpool(url: url, keepExisting: true)
        let r2 = try await Downloader.runResuming(channel: bt, crypto: dev.crypto, file: f, spool: again,
                                                  idle: 0.3, tick: 0.02, doneGrace: 0.1,
                                                  request: { offset in
                                                      offsets.append(offset)
                                                      let from = Int(offset / 166)
                                                      var p = [try dev.head(fileId: f.id, slices: 300)]
                                                      for s in stride(from: from, to: 300, by: 10) {
                                                          p.append(try dev.slices((s..<min(s + 10, 300)).map(UInt32.init)))
                                                      }
                                                      p.append(FakeDevice.done(fileId: f.id))
                                                      bt.play(count: p.count) { p[$0] }
                                                  }, progress: { _ in })
        XCTAssertEqual(offsets, [120 * 166])
        XCTAssertEqual(r2.check.verdict, DownloadCheck.Verdict.complete)
        XCTAssertEqual(r2.newFrames, 180)
    }

    // MARK: 何时提示、预计时间

    func testEstimateBothWays() {
        // 1 小时录音 = 28.8 MB；蓝牙按 36 KB/s 加 2 秒开销，Wi‑Fi 按 1.5 MB/s 加 90 秒开销
        let e = WifiAdvice.estimate(durationsMs: [3_600_000], bluetoothBytesPerSecond: 36_000)
        XCTAssertEqual(e.bluetooth, 2 + 28_800_000 / 36_000, accuracy: 0.01)
        XCTAssertEqual(e.wifi, 90 + 28_800_000 / 1_500_000, accuracy: 0.01)
        // 多个文件：蓝牙每个文件都有开销，Wi‑Fi 只算一次
        let two = WifiAdvice.estimate(durationsMs: [1_800_000, 1_800_000], bluetoothBytesPerSecond: 36_000)
        XCTAssertEqual(two.bluetooth, e.bluetooth + 2, accuracy: 0.01)
        XCTAssertEqual(two.wifi, e.wifi, accuracy: 0.01)
        XCTAssertEqual(WifiAdvice.estimate(durationsMs: [], bluetoothBytesPerSecond: 36_000).bluetooth, 0)
    }

    func testSuggestThresholds() {
        // 不在下载 / 没有估计
        XCTAssertFalse(WifiAdvice.suggest(bluetoothSeconds: nil, wifiSeconds: 100))
        // 不到 10 分钟不提示
        XCTAssertFalse(WifiAdvice.suggest(bluetoothSeconds: 9 * 60, wifiSeconds: 95))
        XCTAssertTrue(WifiAdvice.suggest(bluetoothSeconds: 10 * 60, wifiSeconds: 95))
        // Wi‑Fi 省不了一半就不提示（固定开销大、录音少）
        XCTAssertFalse(WifiAdvice.suggest(bluetoothSeconds: 10 * 60, wifiSeconds: 6 * 60))
        // 典型：一条 3.9 小时的录音（约 112 MB），iPhone 蓝牙 36 KB/s
        let e = WifiAdvice.estimate(durationsMs: [3.9 * 3_600_000], bluetoothBytesPerSecond: 36_000)
        XCTAssertGreaterThan(e.bluetooth, 50 * 60)
        XCTAssertLessThan(e.wifi, 4 * 60)
        XCTAssertTrue(WifiAdvice.suggest(bluetoothSeconds: e.bluetooth, wifiSeconds: e.wifi))
        // Mac 的门槛不变
        XCTAssertEqual(SyncPolicy.suggestWifiAfter, 20 * 60)
        XCTAssertLessThan(WifiAdvice.suggestAfterIOS, SyncPolicy.suggestWifiAfter)
    }

    func testEndpointFromAck() {
        // 1A/05 回包：IP 倒序在 9–12，端口小端在 13–14
        let r: [UInt8] = [0x09, 0xFF, 0, 0, 0x01, 0x1A, 0x05, 0x10, 0x00, 0x01, 0x2B, 0xA8, 0xC0, 0xBB, 0x01, 0x00]
        XCTAssertEqual(SoftAPEndpoint(frame: r), SoftAPEndpoint(ip: "192.168.43.1", port: 443))
    }
}
