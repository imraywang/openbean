// SPDX-License-Identifier: Apache-2.0

import AVFoundation
@testable import OpenBeanVoice
import XCTest

/// 电平归一化：纯计算的部分用合成信号测；识别部分要本机模型和中文语音「婷婷」，缺了就跳过。
final class AudioLevelTests: XCTestCase {
    /// 指定 RMS（dBFS）的正弦波，模拟说话；noise 是同样方式的「底噪」
    private func tone(_ db: Float, seconds: Double, freq: Float = 220) -> [Float] {
        let amp = AudioLevel.linear(db) * Float(2).squareRoot()
        return (0..<Int(seconds * 16000)).map { amp * sin(2 * .pi * freq * Float($0) / 16000) }
    }

    private func noise(_ db: Float, seconds: Double) -> [Float] {
        var g = SystemRandomNumberGenerator()
        let amp = AudioLevel.linear(db) * Float(3).squareRoot()   // 均匀分布的 RMS 是幅度 / √3
        return (0..<Int(seconds * 16000)).map { _ in Float.random(in: -amp...amp, using: &g) }
    }

    func testDb() {
        XCTAssertEqual(AudioLevel.db(tone(-20, seconds: 1)), -20, accuracy: 0.1)
        XCTAssertEqual(AudioLevel.db([Float](repeating: 0, count: 512)), -120)
        XCTAssertEqual(AudioLevel.frameLevels([Float](repeating: 0.1, count: 512 * 3 + 100)).count, 3)
    }

    func testGainRule() {
        XCTAssertEqual(AudioLevel.gain(speech: -25, noise: -80), 0)          // 正常音量：不动
        XCTAssertEqual(AudioLevel.gain(speech: -34, noise: -80), 0)          // 不低于 -36：不动
        XCTAssertEqual(AudioLevel.gain(speech: -37, noise: -80), 7)          // 偏轻：抬到 -30
        XCTAssertEqual(AudioLevel.gain(speech: -50, noise: -85), 20)
        XCTAssertEqual(AudioLevel.gain(speech: -75, noise: -100), 30)        // 封顶 30 dB
        XCTAssertEqual(AudioLevel.gain(speech: -50, noise: -65), 10)         // 底噪不超过 -55
        XCTAssertEqual(AudioLevel.gain(speech: -50, noise: -57), 0)          // 底噪太高，增益不到 3 dB 就不动
        // 逐帧：不把任何一帧抬过 target
        XCTAssertEqual(AudioLevel.frameGain(20, frameDb: -50), 20)
        XCTAssertEqual(AudioLevel.frameGain(20, frameDb: -40), 10)
        XCTAssertEqual(AudioLevel.frameGain(20, frameDb: -20), 0)
        XCTAssertEqual(AudioLevel.frameGain(0, frameDb: -90), 0)
    }

    func testStatsResistOneClick() {
        // 一段 -50 dB 的轻声 + 一下满幅的咔哒：按峰值归一化会一点都不放大，按第 95 百分位不受影响
        var s = noise(-85, seconds: 1) + tone(-50, seconds: 3) + noise(-85, seconds: 1)
        for i in 16000..<16100 { s[i] = i % 2 == 0 ? 1 : -1 }
        let st = AudioLevel.stats(s)
        XCTAssertEqual(st.speech, -50, accuracy: 1)
        XCTAssertEqual(st.noise, -85, accuracy: 2)
        XCTAssertEqual(st.gain, 20, accuracy: 1)
        XCTAssertEqual(AudioLevel.stats(tone(-20, seconds: 2)).gain, 0)
    }

    func testPureNoiseNotBlownUp() {
        // 只有底噪：说话音量 ≈ 底噪，放大受 noiseCeiling 限制
        XCTAssertEqual(AudioLevel.stats(noise(-50, seconds: 2)).gain, 0)
        XCTAssertLessThanOrEqual(AudioLevel.stats(noise(-90, seconds: 2)).gain + -90, AudioLevel.noiseCeiling + 1)
    }

    func testAdaptiveGain() {
        func run(_ s: [Float]) -> [Float] {
            var a = AdaptiveGain()
            return stride(from: 0, to: s.count - 511, by: 512).map { a.next(AudioLevel.db(s[$0..<($0 + 512)])) }
        }
        // 正常音量：开口前的静音、说话、中间停顿，增益全是 0（结果和以前一样）
        let loud = run(noise(-80, seconds: 2) + tone(-22, seconds: 3) + noise(-80, seconds: 5) + tone(-25, seconds: 2))
        XCTAssertEqual(loud.max(), 0)
        // 只有底噪：不放大
        XCTAssertEqual(run(noise(-80, seconds: 5)).max(), 0)
        // 小声：0.3 秒热身后开始抬，一秒内到位，抬到约 -30
        let quiet = run(noise(-85, seconds: 0.3) + tone(-50, seconds: 4))
        XCTAssertEqual(quiet[0], 0)
        XCTAssertEqual(quiet[Int(1.5 * 16000 / 512)], 20, accuracy: 1)
        // 小声之后突然大声：增益立刻降下来
        var a = AdaptiveGain()
        for db in AudioLevel.frameLevels(noise(-85, seconds: 0.5) + tone(-50, seconds: 2)) { _ = a.next(db) }
        XCTAssertGreaterThan(a.gainDb, 10)
        XCTAssertEqual(a.next(-20), 0)
        a.reset()
        XCTAssertEqual(a.gainDb, 0)
    }

    // MARK: 识别（要模型）

    static let models = SentenceRecognizerTests.models

    private func ttsSamples(_ text: String) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: Self.models.appendingPathComponent("sensevoice/model.int8.onnx").path) else {
            throw XCTSkip("没有模型")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ob-tts-quiet.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Tingting", "--data-format=LEF32@16000", "-o", url.path, text]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("没有中文语音") }
        return try AudioFile16k.samples(url)
    }

    /// 把音频衰减 by dB，前后各加 0.5 秒，全程叠一层 -88 dB 的底噪（像录音豆离嘴远时的录音）。
    /// TTS 的声音很干净，要压到 -55 dB 左右 VAD 才会整段漏掉（真人录音 -50 dB 上下就会）
    private func attenuate(_ s: [Float], by db: Float) -> [Float] {
        let k = AudioLevel.linear(-db)
        let pad = [Float](repeating: 0, count: 8000)
        let speech = pad + s.map { $0 * k } + pad
        return zip(speech, noise(-88, seconds: Double(speech.count) / 16000 + 0.1)).map { $0 + $1 }
    }

    private func run(_ r: SentenceRecognizer, _ s: [Float], chunk: Int = 1600) -> String {
        r.reset()
        var got: [SentenceRecognizer.Sentence] = []
        for i in stride(from: 0, to: s.count, by: chunk) { got += r.accept(Array(s[i..<min(i + chunk, s.count)])) }
        got += r.flush()
        return got.map(\.text).joined()
    }

    func testQuietSpeechIsRecognised() throws {
        let speech = try ttsSamples("请帮我把这份报告发给张经理，顺便抄送财务部门。")
        let quiet = attenuate(speech, by: 55)
        let r = try SentenceRecognizer(modelsDir: Self.models)

        // 旧行为（不加增益、不整段识别）：VAD 当成静音
        r.fallbackWhenEmpty = false
        let old = run(r, quiet)
        print("不处理：", old)
        XCTAssertFalse(old.contains("张经理"), old)

        // 整个文件可用：先测再定增益
        r.vadGainDb = AudioLevel.stats(quiet).gain
        XCTAssertGreaterThan(r.vadGainDb, 15)
        let file = run(r, quiet)
        XCTAssertTrue(file.contains("张经理"), file)
        XCTAssertFalse(r.usedFallback)

        // 实时：流式增益
        r.vadGainDb = 0
        r.adaptiveGain = AdaptiveGain()
        let live = run(r, quiet)
        XCTAssertTrue(live.contains("张经理"), live)
    }

    func testLoudSpeechUnchanged() throws {
        let speech = try ttsSamples("这个周末天气不错，我打算带孩子去公园放风筝。")
        let r = try SentenceRecognizer(modelsDir: Self.models)
        let before = run(r, speech)
        r.adaptiveGain = AdaptiveGain()
        r.vadGainDb = AudioLevel.stats(speech).gain
        XCTAssertEqual(r.vadGainDb, 0)
        XCTAssertEqual(run(r, speech), before)
        XCTAssertEqual(r.adaptiveGain?.gainDb, 0)
    }

    func testFallbackWhenNothingSegmented() throws {
        let speech = try ttsSamples("今天下午三点开会。")
        let quiet = attenuate(speech, by: 60)
        let r = try SentenceRecognizer(modelsDir: Self.models)
        // 不加增益，只靠最后一招：一句也没切出来时整段识别
        let text = run(r, quiet)
        XCTAssertTrue(r.usedFallback)
        XCTAssertTrue(text.contains("开会"), text)
        r.fallbackWhenEmpty = false
        XCTAssertEqual(run(r, quiet), "")
        r.fallbackWhenEmpty = true
        // 纯静音和平稳底噪：不整段识别，什么都不出
        XCTAssertEqual(run(r, [Float](repeating: 0, count: 32000)), "")
        XCTAssertFalse(r.usedFallback)
        XCTAssertEqual(run(r, noise(-70, seconds: 2)), "")
        XCTAssertFalse(r.usedFallback)
    }

    /// 本机有评测语音（作者的私有数据，不在仓库里）时：拿一条真实录音衰减 30 dB，归一化后结果应和原音量时基本一样
    func testRealClipAttenuated() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENBEAN_EVAL_DIR"]
            ?? NSHomeDirectory() + "/projects/openbean-eval/typeless")
        guard let list = try? String(contentsOf: dir.appendingPathComponent("files.txt"), encoding: .utf8) else {
            throw XCTSkip("没有评测数据")
        }
        guard FileManager.default.fileExists(atPath: Self.models.appendingPathComponent("sensevoice/model.int8.onnx").path) else {
            throw XCTSkip("没有模型")
        }
        let r = try SentenceRecognizer(modelsDir: Self.models)
        // 找一条 3–15 秒、音量正常的录音
        for path in list.split(separator: "\n").prefix(200) {
            guard let s = try? AudioFile16k.samples(URL(fileURLWithPath: String(path))),
                  (48000...240_000).contains(s.count), AudioLevel.stats(s).speech > -40 else { continue }
            r.vadGainDb = AudioLevel.stats(s).gain
            let reference = run(r, s)
            guard reference.count >= 8 else { continue }
            let quiet = s.map { $0 * AudioLevel.linear(-30) }
            r.vadGainDb = AudioLevel.stats(quiet).gain
            let got = run(r, quiet)
            let sim = Self.similarity(reference, got)
            print(String(format: "%@：相似度 %.2f（增益 %.1f dB）", (String(path) as NSString).lastPathComponent, sim, r.vadGainDb))
            XCTAssertGreaterThan(sim, 0.8)
            return
        }
        throw XCTSkip("评测数据里没找到合适的录音")
    }

    /// 按字的相似度：2 × 最长公共子序列 / 总长
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var dp = [Int](repeating: 0, count: y.count + 1)
        for i in 0..<x.count {
            var prev = 0
            for j in 0..<y.count {
                let t = dp[j + 1]
                dp[j + 1] = x[i] == y[j] ? prev + 1 : max(dp[j + 1], dp[j])
                prev = t
            }
        }
        return 2 * Double(dp[y.count]) / Double(x.count + y.count)
    }
}
