// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanKit
import XCTest

final class DeleteTests: XCTestCase {
    func testEncodeDeleteFile() {
        // 08 EE 00 00 00 | 1A 10 | 长度 0x0E（14 字节，含校验）| fileId u32 LE | 校验
        let f = Cmd.deleteFile(id: 0x6AF5_7626)
        XCTAssertEqual(f, [0x08, 0xEE, 0x00, 0x00, 0x00, 0x1A, 0x10, 0x0E, 0x00, 0x26, 0x76, 0xF5, 0x6A, 0x29])
        XCTAssertEqual(f.last, Frame.checksum(f[0..<13]))
        // fileId 的编码和 1A/07 里的一样
        let t = Cmd.transferFile(id: 0x6AF5_7626, realtime: false)
        XCTAssertEqual(Array(f[9..<13]), Array(t[13..<17]))
    }

    func testDeleteAckMatchesTransportId() {
        var a = FrameAssembler()
        let ok = a.feed(hex("09FF0000011A100B00003E")).first
        XCTAssertEqual(ok?.type, 0x1A)
        XCTAssertEqual(ok?.id, Rx.deleteFile)
        XCTAssertEqual(ok?.isSuccess, true)
        XCTAssertTrue(ok.map(Rx.isTransport) ?? false)
    }

    private func check(onRecorder: Bool = true, downloaded: Bool = true, local: Double? = 60, expected: Double = 60,
                       recording: Bool? = false, busy: Bool = false) -> DeletePolicy.Refusal? {
        DeletePolicy.check(onRecorder: onRecorder, downloaded: downloaded, localSeconds: local,
                           expectedSeconds: expected, recorderRecording: recording, busy: busy)
    }

    func testPolicyAllowsCompleteDownload() {
        XCTAssertNil(check())
        XCTAssertNil(check(local: 59.2, expected: 60))          // 1 秒内
        XCTAssertNil(check(local: 7130, expected: 7200))        // 1% 内
        XCTAssertNil(check(local: 1.06, expected: 1.06))
    }

    func testPolicyRefusals() {
        XCTAssertEqual(check(busy: true), .busy)
        XCTAssertEqual(check(recording: true), .recording)
        XCTAssertEqual(check(recording: nil), .recording)       // 读不到录音状态也不删
        XCTAssertEqual(check(onRecorder: false), .notOnRecorder)
        XCTAssertEqual(check(downloaded: false), .notDownloaded)
        XCTAssertEqual(check(local: nil), .localAudioMissing)
        XCTAssertEqual(check(local: 0), .localAudioMissing)
        XCTAssertEqual(check(expected: 0), .emptyRecording)
        XCTAssertEqual(check(local: 57, expected: 60), .durationMismatch(local: 57, expected: 60))
        XCTAssertEqual(check(local: 7000, expected: 7200), .durationMismatch(local: 7000, expected: 7200))
        XCTAssertEqual(check(local: 75, expected: 60), .durationMismatch(local: 75, expected: 60))
        // 忙的时候先报忙
        XCTAssertEqual(check(downloaded: false, busy: true), .busy)
    }

    func testVerifyAfterDelete() throws {
        func f(_ id: UInt32) -> RecordingFile { RecordingFile(id: id, endTime: nil, durationMs: 1000) }
        let before = [f(3), f(2), f(1)]
        XCTAssertNoThrow(try DeleteError.verify(deleted: 2, before: before, after: [f(3), f(1)]))
        // 期间新录的一条多出来没关系
        XCTAssertNoThrow(try DeleteError.verify(deleted: 2, before: before, after: [f(4), f(3), f(1)]))
        XCTAssertThrowsError(try DeleteError.verify(deleted: 2, before: before, after: before)) {
            guard case DeleteError.stillPresent(2) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try DeleteError.verify(deleted: 2, before: before, after: [f(3)])) {
            guard case let DeleteError.othersMissing(ids) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(ids, [1])
        }
    }

    func testDecodedSecondsOfMuxedFile() throws {
        // 100 个只有 TOC 字节的 20 ms 帧（解码器当作静音/丢包补偿）→ 2 秒
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openbean-delete-test-\(UUID()).ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(OggOpus.mux(frames: Array(repeating: [0xBC], count: 100))).write(to: url)
        let s = try XCTUnwrap(LocalAudio.decodedSeconds(url))
        XCTAssertEqual(s, 2.0, accuracy: 0.05)
    }

    func testDecodedSecondsOfMissingFile() {
        XCTAssertNil(LocalAudio.decodedSeconds(URL(fileURLWithPath: "/nonexistent/audio.ogg")))
    }
}
