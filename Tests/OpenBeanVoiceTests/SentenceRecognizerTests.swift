// SPDX-License-Identifier: Apache-2.0

import AVFoundation
@testable import OpenBeanVoice
import XCTest

/// 需要本机模型（Scripts/fetch-deps.sh）和中文语音「婷婷」；缺了就跳过。
final class SentenceRecognizerTests: XCTestCase {
    static let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("openbean/models")

    /// 用系统 TTS 现场合成两句话，中间停 1 秒，按 100 ms 一块喂进去
    func testTwoSentencesFromSpeech() throws {
        guard FileManager.default.fileExists(atPath: Self.models.appendingPathComponent("sensevoice/model.int8.onnx").path) else {
            throw XCTSkip("没有模型")
        }
        let dir = FileManager.default.temporaryDirectory
        var samples: [Float] = []
        for (i, text) in ["请帮我把这份报告发给张经理，顺便抄送财务部门。", "这个周末天气不错，我打算带孩子去公园放风筝。"].enumerated() {
            let url = dir.appendingPathComponent("ob-tts-\(i).wav")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", "Tingting", "--data-format=LEF32@16000", "-o", url.path, text]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw XCTSkip("没有中文语音") }
            let f = try AVAudioFile(forReading: url)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: buf)
            samples += Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            samples += [Float](repeating: 0, count: 16000)
        }

        let r = try SentenceRecognizer(modelsDir: Self.models)
        var got: [SentenceRecognizer.Sentence] = []
        for start in stride(from: 0, to: samples.count, by: 1600) {
            got += r.accept(Array(samples[start..<min(start + 1600, samples.count)]))
        }
        got += r.flush()
        let text = got.map(\.text).joined()
        print(got.map { String(format: "[%.2f–%.2f s, %.0f ms] %@", $0.start, $0.end, $0.decodeMs, $0.text) }.joined(separator: "\n"))
        XCTAssertEqual(got.count, 2)
        XCTAssertTrue(text.contains("张经理"), text)
        XCTAssertTrue(text.contains("放风筝"), text)
    }
}
