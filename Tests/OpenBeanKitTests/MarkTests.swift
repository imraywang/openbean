// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanKit
import XCTest

/// 重点标记：1A/08 单元的 flags（01 标记、02 第一片、04 最后一片），下载时记进 spool 的标记文件
final class MarkTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("openbean-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testFlagsAreParsed() throws {
        let dev = try FakeDevice()
        let p = try dev.slices([0, 1661, 1662, 5143], flags: [0: 0x02, 1661: 0x01, 5143: 0x04 | 0x01])
        let s = parseSlices(frame: p.raw)
        XCTAssertEqual(s.map(\.seq), [0, 1661, 1662, 5143])
        XCTAssertEqual(s.map(\.flags), [0x02, 0x01, 0x00, 0x05])
        XCTAssertEqual(s.map(\.isMark), [false, true, false, true])
        XCTAssertTrue(s[0].flags & SliceFlags.first != 0)
        XCTAssertTrue(s[3].flags & SliceFlags.last != 0)
        // 标记时刻 = seq × 20 ms（实测三个标记 33.22 / 68.02 / 102.88 秒）
        XCTAssertEqual(SliceFlags.seconds(seq: 1661), 33.22)
        XCTAssertEqual(SliceFlags.seconds(seq: 3401), 68.02)
        XCTAssertEqual(SliceFlags.seconds(seq: 5144), 102.88)
        XCTAssertEqual(SliceFlags.seconds(seq: 150, firstSeq: 100), 1.0)
    }

    func testSpoolKeepsMarksOnceAcrossReopen() throws {
        let url = dir.appendingPathComponent("download.part")
        let sp = try FrameSpool(url: url, keepExisting: false)
        sp.put(seq: 0, frame: FakeDevice.plain(seq: 0), flags: 0x02)
        sp.put(seq: 10, frame: FakeDevice.plain(seq: 10), flags: 0x01)
        sp.put(seq: 10, frame: FakeDevice.plain(seq: 10), flags: 0x01) // 重复的片：不重复记
        XCTAssertEqual(sp.marks, [10])
        sp.close()
        let again = try FrameSpool(url: url, keepExisting: true)
        XCTAssertEqual(again.marks, [10])
        // 收过的片再收到一次、这次带标记（旧的临时文件没有标记文件时从头重下补回来）
        XCTAssertFalse(again.put(seq: 0, frame: FakeDevice.plain(seq: 0), flags: 0x01))
        again.put(seq: 30, frame: FakeDevice.plain(seq: 30), flags: 0x01)
        XCTAssertEqual(again.marks, [0, 10, 30])
        again.close()
        XCTAssertEqual(try FrameSpool(url: url, keepExisting: true).marks, [0, 10, 30])
        // 不保留时清空
        let fresh = try FrameSpool(url: url, keepExisting: false)
        XCTAssertEqual(fresh.marks, [])
        fresh.put(seq: 5, frame: FakeDevice.plain(seq: 5), flags: 0x01)
        fresh.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.marksURL.path))
    }

    /// 断开 → 续传：两次各收到一个标记，拼起来两个都在；再从头重下一遍也不重复
    func testMarksSurviveResumeWithoutDuplicates() async throws {
        let dev = try FakeDevice()
        let n = 300
        let f = RecordingFile(id: 1_794_000_000, endTime: nil, durationMs: UInt32(n * 20))
        let flags: [UInt32: UInt8] = [0: 0x02, 50: 0x01, 200: 0x01, UInt32(n - 1): 0x04]
        func packets(from: Int) throws -> [Packet] {
            var out = [try dev.head(fileId: f.id, slices: n)]
            for s in stride(from: from, to: n, by: 10) {
                out.append(try dev.slices((s..<min(s + 10, n)).map(UInt32.init), flags: flags))
            }
            out.append(FakeDevice.done(fileId: f.id))
            return out
        }
        let url = dir.appendingPathComponent("download.part")
        // 第一次：头 + 12 包（0…119）之后断开
        let ch1 = FakeChannel()
        let first = try packets(from: 0)
        let sp1 = try FrameSpool(url: url, keepExisting: false)
        let r1 = try await Downloader.runResuming(channel: ch1, crypto: dev.crypto, file: f, spool: sp1, idle: 0.3, tick: 0.02,
                                                  doneGrace: 0.1,
                                                  request: { _ in ch1.play(count: first.count, disconnectAfter: 13) { first[$0] } },
                                                  progress: { _ in })
        XCTAssertEqual(r1.stop, .disconnected)
        XCTAssertEqual(sp1.marks, [50])
        sp1.close()
        // 第二次：续传
        let sp2 = try FrameSpool(url: url, keepExisting: true)
        let ch2 = FakeChannel()
        var offsets: [UInt32] = []
        let r2 = try await Downloader.runResuming(channel: ch2, crypto: dev.crypto, file: f, spool: sp2, idle: 0.3, tick: 0.02,
                                                  doneGrace: 0.1,
                                                  request: { off in
                                                      offsets.append(off)
                                                      let p = try packets(from: Int(off / 166))
                                                      ch2.play(count: p.count) { p[$0] }
                                                  }, progress: { _ in })
        XCTAssertEqual(offsets, [120 * 166])
        XCTAssertEqual(r2.check.verdict, .complete)
        XCTAssertEqual(sp2.marks, [50, 200])
        // 再从头收一遍：标记不重复
        let ch3 = FakeChannel()
        let all = try packets(from: 0)
        _ = try await Downloader.run(channel: ch3, crypto: dev.crypto, file: f, spool: sp2, idle: 0.3, tick: 0.02, doneGrace: 0.1,
                                     request: { ch3.play(count: all.count) { all[$0] } }, progress: { _ in })
        XCTAssertEqual(sp2.marks, [50, 200])
        XCTAssertEqual(sp2.marks.map { SliceFlags.seconds(seq: $0) }, [1.0, 4.0])
    }
}
