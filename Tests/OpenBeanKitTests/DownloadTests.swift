// SPDX-License-Identifier: Apache-2.0

import Darwin
@testable import OpenBeanKit
import XCTest

/// 假的传输通道：收到请求后，在自己的队列上把设备的包一个个送进来
final class FakeChannel: TransferChannel, @unchecked Sendable {
    private let q = DispatchQueue(label: "fake.channel")
    var onPacket: ((Packet) -> Void)?
    private var connected = true
    var isConnected: Bool { connected }
    private(set) var requests = 0

    func sync<T>(_ body: () throws -> T) rethrows -> T { try q.sync(execute: body) }

    /// 模拟设备发 `count` 个包（`make(i)` 现做，不预先攒在内存里）；`disconnectAfter` 个之后断开
    func play(count: Int, disconnectAfter: Int? = nil, make: @escaping (Int) -> Packet) {
        requests += 1
        q.async {
            for i in 0..<count {
                if let d = disconnectAfter, i >= d { self.connected = false; return }
                self.onPacket?(make(i))
            }
        }
    }
}

final class DownloadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("openbean-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ id: UInt32 = 1_794_000_000, slices n: Int) -> RecordingFile {
        RecordingFile(id: id, endTime: nil, durationMs: UInt32(n * 20))
    }

    /// 跑一次下载：`packets` 是设备按顺序发的包
    private func download(_ dev: FakeDevice, file f: RecordingFile, packets: [Packet], disconnectAfter: Int? = nil,
                          spool: FrameSpool? = nil, idle: Double = 0.3) async throws -> (DownloadResult, FrameSpool) {
        let ch = FakeChannel()
        let sp = try spool ?? FrameSpool(url: dir.appendingPathComponent("download.part"), keepExisting: false)
        let r = try await Downloader.run(channel: ch, crypto: dev.crypto, file: f, spool: sp, idle: idle, tick: 0.02,
                                         doneGrace: 0.1,
                                         request: { ch.play(count: packets.count, disconnectAfter: disconnectAfter) { packets[$0] } },
                                         progress: { _ in })
        return (r, sp)
    }

    private func oggFrames(_ url: URL) throws -> Int {
        // 数 Ogg 页里的包：用 LocalAudio 解码时长也行，这里直接按 granule 算
        let b = [UInt8](try Data(contentsOf: url))
        var i = 0, granule: UInt64 = 0
        while i + 27 <= b.count {
            granule = (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[i + 6 + $1]) << (8 * UInt64($1)) }
            let segs = Int(b[i + 26])
            let body = (0..<segs).reduce(0) { $0 + Int(b[i + 27 + $1]) }
            i += 27 + segs + body
        }
        return Int(granule / OggOpus.samplesPerFrame)
    }

    func testNormalDownloadIsCompleteAndMatchesInMemoryMux() async throws {
        let dev = try FakeDevice()
        let f = file(slices: 200)
        let (r, sp) = try await download(dev, file: f, packets: try dev.packets(fileId: f.id, slices: 200))
        XCTAssertEqual(r.stop, .done)
        XCTAssertEqual(r.check.verdict, .complete)
        XCTAssertEqual(r.received.ranges, [0...199])
        XCTAssertEqual(r.newFrames, 200)
        let out = dir.appendingPathComponent("audio.ogg")
        let w = try sp.writeOgg(to: out, first: r.check.firstSeq, count: r.check.expectedFrames)
        XCTAssertEqual(w.frames, 200)
        XCTAssertEqual(w.filled, 0)
        // 和原来的内存路径（拼起来再 mux）逐字节相同
        let raw = (0..<200).flatMap { FakeDevice.plain(seq: UInt32($0)) }
        XCTAssertEqual([UInt8](try Data(contentsOf: out)), OggOpus.mux(frames: OggOpus.frames(from: raw)))
    }

    func testDisconnectMidwayKeepsPartialAndNextAttemptAddsToIt() async throws {
        let dev = try FakeDevice()
        let f = file(slices: 300)
        let packets = try dev.packets(fileId: f.id, slices: 300, perPacket: 10)
        let url = dir.appendingPathComponent("download.part")
        // 头 + 12 个分片包之后断开
        var (r, sp) = try await download(dev, file: f, packets: packets, disconnectAfter: 13,
                                         spool: try FrameSpool(url: url, keepExisting: false))
        XCTAssertEqual(r.stop, .disconnected)
        XCTAssertTrue(r.stop.isInterruption)
        XCTAssertEqual(r.received.ranges, [0...119])
        guard case .incomplete = r.check.verdict else { return XCTFail("\(r.check.verdict)") }
        XCTAssertEqual(r.check.expectedFrames, 300)
        sp.close()

        // 重新打开留下的临时文件（像 App 重启后那样），再从头请求一次：已有的不重写，只记新的
        let again = try FrameSpool(url: url, keepExisting: true)
        XCTAssertEqual(again.received.ranges, [0...119])
        (r, sp) = try await download(dev, file: f, packets: packets, spool: again)
        XCTAssertEqual(r.check.verdict, .complete)
        XCTAssertEqual(r.newFrames, 180)
        let out = dir.appendingPathComponent("audio.ogg")
        let w = try sp.writeOgg(to: out, first: 0, count: 300)
        XCTAssertEqual(w.frames, 300)
        XCTAssertEqual(try oggFrames(out), 300)
    }

    func testOutOfOrderAndSmallGapIsUsableAndGapIsFilled() async throws {
        let dev = try FakeDevice()
        let f = file(slices: 400)
        var packets = [try dev.head(fileId: f.id, slices: 400)]
        // 倒着发每 10 片一包，第 137 片丢了
        for start in stride(from: 390, through: 0, by: -10) {
            packets.append(try dev.slices((start..<start + 10).map(UInt32.init).filter { $0 != 137 }))
        }
        packets.append(FakeDevice.done(fileId: f.id))
        let (r, sp) = try await download(dev, file: f, packets: packets)
        XCTAssertEqual(r.check.verdict, .completeWithGaps(missing: 1))
        XCTAssertFalse(sp.inOrder)
        let out = dir.appendingPathComponent("audio.ogg")
        let w = try sp.writeOgg(to: out, first: 0, count: 400)
        XCTAssertEqual(w.frames, 400)
        XCTAssertEqual(w.filled, 1)
        XCTAssertEqual(try oggFrames(out), 400)
    }

    func testManyMissingIsIncomplete() async throws {
        let dev = try FakeDevice()
        let f = file(slices: 2000)
        var packets = [try dev.head(fileId: f.id, slices: 2000)]
        for start in stride(from: 0, to: 2000, by: 10) where !(500..<700).contains(start) {
            packets.append(try dev.slices((start..<start + 10).map(UInt32.init)))
        }
        packets.append(FakeDevice.done(fileId: f.id))
        let (r, _) = try await download(dev, file: f, packets: packets)
        XCTAssertEqual(r.stop, .done)
        guard case let .incomplete(why) = r.check.verdict else { return XCTFail("\(r.check.verdict)") }
        XCTAssertTrue(why.contains("缺 200 片"), why)
        XCTAssertEqual(r.received.ranges, [0...499, 700...1999])
    }

    func testWrongFileHeadIsRejectedAndNothingWritten() async throws {
        let dev = try FakeDevice()
        let f = file(slices: 100)
        // 设备回了另一个文件的头和数据（社区笔记：录音中请求历史文件时见过）
        let packets = try dev.packets(fileId: f.id + 77, slices: 100)
        let (r, sp) = try await download(dev, file: f, packets: packets)
        XCTAssertEqual(r.stop, .wrongFile)
        guard case let .rejected(why) = r.check.verdict else { return XCTFail("\(r.check.verdict)") }
        XCTAssertTrue(why.contains("别的文件"), why)
        XCTAssertEqual(sp.count, 0)
    }

    func testDeviceErrorInHeadStopsAtOnce() async throws {
        let dev = try FakeDevice()
        let f = file(slices: 100)
        let (r, _) = try await download(dev, file: f, packets: [try dev.head(fileId: f.id, slices: 100, error: 1)], idle: 5)
        XCTAssertEqual(r.stop, .deviceError)
        guard case .rejected = r.check.verdict else { return XCTFail("\(r.check.verdict)") }
    }

    func testMissingDonePacket() async throws {
        let dev = try FakeDevice()
        let f = file(slices: 100)
        // 全收到了，只是没有结束包：等一会儿后按「收够了」停，数据完整
        let (r, _) = try await download(dev, file: f, packets: try dev.packets(fileId: f.id, slices: 100, done: false))
        XCTAssertEqual(r.stop, .reachedExpected)
        XCTAssertEqual(r.check.verdict, .complete)
        // 收了一半、没结束包、设备不再发：按「没有新数据」停，不完整
        let half = Array(try dev.packets(fileId: f.id, slices: 100, done: false).prefix(18))
        let (r2, _) = try await download(dev, file: f, packets: half)
        XCTAssertEqual(r2.stop, .idle)
        guard case .incomplete = r2.check.verdict else { return XCTFail("\(r2.check.verdict)") }
    }

    func testCancelStops() async throws {
        let dev = try FakeDevice()
        let f = file(slices: 100)
        let ch = FakeChannel()
        let sp = try FrameSpool(url: dir.appendingPathComponent("p"), keepExisting: false)
        let r = try await Downloader.run(channel: ch, crypto: dev.crypto, file: f, spool: sp, idle: 5, tick: 0.02,
                                         request: { ch.play(count: 1) { _ in try! dev.head(fileId: f.id, slices: 100) } },
                                         shouldCancel: { true }, progress: { _ in })
        XCTAssertEqual(r.stop, .cancelled)
        XCTAssertTrue(r.stop.isInterruption)
    }

    /// 超大文件不在内存里攒：12 万片（约 19 MB 音频，40 分钟）下完，内存增长远小于音频大小
    func testLargeDownloadDoesNotAccumulateInMemory() async throws {
        let dev = try FakeDevice()
        let n = 120_000, per = 10
        let f = file(slices: n)
        let head = try dev.head(fileId: f.id, slices: n)
        let ch = FakeChannel()
        let sp = try FrameSpool(url: dir.appendingPathComponent("big.part"), keepExisting: false)
        let before = footprint()
        var peak = before
        let r = try await Downloader.run(channel: ch, crypto: dev.crypto, file: f, spool: sp, idle: 2, tick: 0.05,
                                         request: {
                                             ch.play(count: n / per + 2) { i in
                                                 if i == 0 { return head }
                                                 if i == n / per + 1 { return FakeDevice.done(fileId: f.id) }
                                                 let s = (i - 1) * per
                                                 return try! dev.slices((s..<s + per).map(UInt32.init))
                                             }
                                         },
                                         progress: { _ in peak = max(peak, self.footprint()) })
        XCTAssertEqual(r.check.verdict, .complete)
        XCTAssertEqual(sp.received.ranges.count, 1)
        let size = try FileManager.default.attributesOfItem(atPath: sp.url.path)[.size] as? Int
        XCTAssertEqual(size, n * FrameSpool.recordSize)
        let audio = n * 160
        let grew = max(peak, footprint()) - before
        XCTAssertLessThan(grew, audio / 2, "内存增长 \(grew / 1024) KB，音频 \(audio / 1024) KB")
        // 收尾成 Ogg 也是流式的
        let out = dir.appendingPathComponent("big.ogg")
        let w = try sp.writeOgg(to: out, first: 0, count: n)
        XCTAssertEqual(w.frames, n)
        XCTAssertLessThan(footprint() - before, audio / 2)
    }

    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
