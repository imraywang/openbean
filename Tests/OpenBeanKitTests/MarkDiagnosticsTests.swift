// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanKit
import XCTest

/// 重点标记实验的解析和记录（A1），以及续航统计的设备文件日志（A3）
final class MarkDiagnosticsTests: XCTestCase {
    func testParseSlicesKeepsFlags() throws {
        let dev = try FakeDevice()
        let p = try dev.slices([10, 11, 12], flags: [11: 0x01])
        let s = parseSlices(frame: p.raw)
        XCTAssertEqual(s.map(\.seq), [10, 11, 12])
        XCTAssertEqual(s.map(\.flags), [0, 1, 0])
    }

    func testMarkFramesAndFlagsAreRecordedWithoutChangingAudio() throws {
        let dev = try FakeDevice()
        func run(diagnostics: TransferDiagnostics?) throws -> Transfer {
            let st = TransferState(fileId: 5)
            st.diagnostics = diagnostics
            var packets = try dev.packets(fileId: 5, slices: 12, perPacket: 3, done: false)
            // 第 6–8 片换成 1A/12，第 10 片的 flags 置 2
            packets[3] = try dev.slices([6, 7, 8], id: Rx.fileSliceMark)
            packets[4] = try dev.slices([9, 10, 11], flags: [10: 0x02])
            packets.append(FakeDevice.done(fileId: 5))
            for p in packets { D3200Session.handle(p, st, dev.crypto) }
            return D3200Session.makeTransfer(st, started: Date())
        }
        let plain = try run(diagnostics: nil)
        let t = try run(diagnostics: TransferDiagnostics())
        // 音频输出和不开排查时一样，1A/12 的片照常进音频
        XCTAssertEqual(t.audio, plain.audio)
        XCTAssertEqual(t.audio, (0..<12).flatMap { FakeDevice.plain(seq: UInt32($0)) })
        XCTAssertNil(plain.diagnostics)

        let d = try XCTUnwrap(t.diagnostics)
        XCTAssertEqual(d.sliceFrames[Rx.fileSlice], 3)
        XCTAssertEqual(d.sliceFrames[Rx.fileSliceMark], 1)
        XCTAssertEqual(d.markFrames.count, 1)
        XCTAssertEqual(d.markFrames[0].packetIndex, 2)
        XCTAssertEqual(d.markFrames[0].seqs, [6, 7, 8])
        XCTAssertEqual(d.markFrames[0].unitRemainder, 0)
        XCTAssertEqual(d.flaggedTotal, 1)
        XCTAssertEqual(d.flaggedUnits.first?.seq, 10)
        XCTAssertEqual(d.flaggedUnits.first?.flags, 2)
        XCTAssertEqual(d.flagCounts[0], 11)
        XCTAssertEqual(TransferDiagnostics.seconds(seq: 10, firstSeq: 0), 0.2, accuracy: 1e-9)
        XCTAssertEqual(t.heads.count, 1)
        XCTAssertTrue(d.cipher.isEmpty)
    }

    /// 1A/12 如果布局不同（比如前面多 4 个字节），长度余数会暴露出来
    func testOddLayoutIsVisible() throws {
        let p = FakeDevice.frame(id: Rx.fileSliceMark, payload: [1, 2, 3, 4] + u32le(9) + [0] + [UInt8](repeating: 0, count: 160) + [0])
        var d = TransferDiagnostics()
        d.note(frame: p, slices: parseSlices(frame: p.raw), packetIndex: 0, elapsed: 0)
        XCTAssertEqual(d.oddFrames, 1)
        XCTAssertEqual(d.markFrames.first?.unitRemainder, 4)
    }

    func testKeepCipherForResumeExperiment() throws {
        let dev = try FakeDevice()
        let st = TransferState(fileId: 5)
        st.diagnostics = TransferDiagnostics(keepCipher: true)
        for p in try dev.packets(fileId: 5, slices: 4) { D3200Session.handle(p, st, dev.crypto) }
        let t = D3200Session.makeTransfer(st, started: Date())
        XCTAssertEqual(t.diagnostics?.cipher[3], try dev.cipher(seq: 3))
    }

    func testDeviceFileLogOnlyNewOrGrownFiles() {
        let files = [
            RecordingFile(id: 1_794_000_000, endTime: 1_794_000_600, durationMs: 600_000),
            RecordingFile(id: 1_794_100_000, endTime: nil, durationMs: 28_800_000),
            RecordingFile(id: 1_794_200_000, endTime: 1_794_200_010, durationMs: 0),
        ]
        XCTAssertEqual(DeviceFileLog.lines(known: [1_794_000_000: 600_000, 1_794_100_000: 28_800_000], files: files, recorder: 40), [])
        let lines = DeviceFileLog.lines(known: [1_794_000_000: 600_000, 1_794_100_000: 20_000_000], files: files, recorder: 40)
        XCTAssertEqual(lines, [
            "battery event=device-file file=1794100000 start=1794100000 end=? seconds=28800.0 recorder=40",
            "battery event=device-files count=3 seconds=29400.0 recorder=40",
        ])
        XCTAssertEqual(DeviceFileLog.lines(known: [:], files: Array(files.prefix(1)), recorder: nil).first,
                       "battery event=device-file file=1794000000 start=1794000000 end=1794000600 seconds=600.0 recorder=?")
    }
}
