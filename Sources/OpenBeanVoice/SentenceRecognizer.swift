// SPDX-License-Identifier: Apache-2.0

import CSherpaOnnx
import Foundation

/// 第二遍识别（进程内）：Silero VAD 按停顿切句，每句交给 SenseVoice 定稿。
/// 输入 16 kHz 单声道 Float 采样；不是线程安全的，调用方保证串行。
///
/// 小声说话：Silero VAD 会把很轻的人声当成静音，整段什么也切不出来。两道补救（见 AudioLevel.swift）：
/// - 给 VAD 的音频先乘增益：整个文件可用时调用方测完设 `vadGainDb`；实时听写设 `adaptiveGain`，边听边估；
///   增益只影响切句，SenseVoice 识别的仍是原始音频；
/// - `flush()` 时这次一句也没切出来、音频不超过 60 秒、又不是纯静音：整段直接识别一次（`usedFallback`）。
public final class SentenceRecognizer {
    public struct Sentence: Sendable {
        /// 在输入音频时间轴上的起止（秒）
        public let start: Double
        public let end: Double
        public let text: String
        public let decodeMs: Double
    }

    public static let sampleRate = 16000
    private let recognizer: OpaquePointer
    private var vad: OpaquePointer
    private let window = 512
    private let vadPath: String
    private let minSilence: Float
    private var pending: [Float] = []
    // 保留最近 60 秒原始音频：VAD 给的片段起点偏晚，会吞掉句首的字，解码时前后各补一点
    private var history: [Float] = []
    private var historyStart = 0
    private let pre = 16000 * 3 / 10, post = 16000 / 10

    /// 固定增益（dB），只给 VAD：整个文件可用时由调用方先测量再设（AudioLevel.Stats.gain）
    public var vadGainDb: Float = 0
    /// 流式自动增益，只给 VAD：实时听写用；nil 表示不用。设了它就不看 vadGainDb
    public var adaptiveGain: AdaptiveGain?
    /// 一句也没切出来时，flush 整段直接识别（见类注释）
    public var fallbackWhenEmpty = true
    /// 这次（reset 以来）是不是走了整段识别
    public private(set) var usedFallback = false
    /// 这次（reset 以来）送进来的采样数、切出来的句数
    private var fed = 0
    private var emitted = 0

    /// - Parameters:
    ///   - modelsDir: 含 `sensevoice/model.int8.onnx`、`sensevoice/tokens.txt`、`vad/silero_vad.onnx`
    ///   - minSilence: 停顿多久算一句结束（秒）
    public init(modelsDir: URL, minSilence: Float = 0.5, threads: Int32 = 4) throws {
        let sv = modelsDir.appendingPathComponent("sensevoice")
        let vadPath = modelsDir.appendingPathComponent("vad/silero_vad.onnx").path
        for p in [sv.appendingPathComponent("model.int8.onnx").path, sv.appendingPathComponent("tokens.txt").path, vadPath]
        where !FileManager.default.fileExists(atPath: p) {
            throw VoiceError.missingModel(p)
        }

        // C 结构体里的字符串指针只需在 Create 调用期间有效
        let r: OpaquePointer? = sv.appendingPathComponent("model.int8.onnx").path.withCString { model in
            sv.appendingPathComponent("tokens.txt").path.withCString { tokens in
                "zh".withCString { lang in
                    "greedy_search".withCString { method in
                        "cpu".withCString { provider in
                            var c = SherpaOnnxOfflineRecognizerConfig()
                            c.feat_config.sample_rate = 16000
                            c.feat_config.feature_dim = 80
                            c.model_config.sense_voice.model = model
                            c.model_config.sense_voice.language = lang
                            c.model_config.sense_voice.use_itn = 1
                            c.model_config.tokens = tokens
                            c.model_config.num_threads = threads
                            c.model_config.provider = provider
                            c.decoding_method = method
                            return SherpaOnnxCreateOfflineRecognizer(&c)
                        }
                    }
                }
            }
        }
        guard let r else { throw VoiceError.initFailed("SenseVoice") }
        recognizer = r

        self.vadPath = vadPath
        self.minSilence = minSilence
        guard let v = Self.makeVAD(path: vadPath, minSilence: minSilence) else {
            SherpaOnnxDestroyOfflineRecognizer(r)
            throw VoiceError.initFailed("Silero VAD")
        }
        vad = v
    }

    private static func makeVAD(path: String, minSilence: Float) -> OpaquePointer? {
        path.withCString { p in
            "cpu".withCString { provider in
                var vc = SherpaOnnxVadModelConfig()
                vc.silero_vad.model = p
                vc.silero_vad.threshold = 0.5
                vc.silero_vad.min_silence_duration = minSilence
                vc.silero_vad.min_speech_duration = 0.2
                vc.silero_vad.window_size = 512
                vc.silero_vad.max_speech_duration = 15
                vc.sample_rate = 16000
                vc.num_threads = 1
                vc.provider = provider
                return SherpaOnnxCreateVoiceActivityDetector(&vc, 60)
            }
        }
    }

    /// 开始新的一次听写：时间轴从 0 重新算（SenseVoice 模型不用重新加载）
    public func reset() {
        if let v = Self.makeVAD(path: vadPath, minSilence: minSilence) {
            SherpaOnnxDestroyVoiceActivityDetector(vad)
            vad = v
        }
        pending.removeAll()
        history.removeAll()
        historyStart = 0
        adaptiveGain?.reset()
        fed = 0
        emitted = 0
        usedFallback = false
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// 送一段音频，返回这段音频里完成的句子
    public func accept(_ samples: [Float]) -> [Sentence] {
        pending += samples
        history += samples
        fed += samples.count
        if history.count > 60 * 16000 {
            let cut = history.count - 60 * 16000
            history.removeFirst(cut)
            historyStart += cut
        }
        var used = 0
        while pending.count - used >= window {
            toVAD(pending[used..<(used + window)])
            used += window
        }
        pending.removeFirst(used)
        return drain()
    }

    /// 一个窗口送进 VAD：按当前增益放大（限幅在 ±1），增益为 0 时原样送
    private func toVAD(_ w: ArraySlice<Float>) {
        var g: Float = 0
        if adaptiveGain != nil {
            g = adaptiveGain!.next(AudioLevel.db(w))
        } else if vadGainDb > 0 {
            g = AudioLevel.frameGain(vadGainDb, frameDb: AudioLevel.db(w))
        }
        if g == 0 {
            w.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count)) }
        } else {
            let k = AudioLevel.linear(g)
            let boosted = w.map { min(max($0 * k, -1), 1) }
            boosted.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count)) }
        }
    }

    /// 输入结束：把最后一句也吐出来
    public func flush() -> [Sentence] {
        if !pending.isEmpty {
            toVAD(pending[...])
            pending.removeAll()
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        let out = drain()
        if out.isEmpty, emitted == 0, fallbackWhenEmpty, let s = wholeClip() { return [s] }
        return out
    }

    /// 最后一招：一句也没切出来时整段识别。只在整段都还在 history 里（≤ 60 秒）、
    /// 长度至少 0.3 秒、而且最响的地方比底噪高出 `fallbackMinRange` dB（不是纯静音或平稳底噪）时才做
    private func wholeClip() -> Sentence? {
        guard fed == history.count, fed >= 16000 * 3 / 10 else { return nil }
        let levels = AudioLevel.frameLevels(history)
        guard AudioLevel.percentile(levels, 0.98) - AudioLevel.percentile(levels, 0.10) >= Self.fallbackMinRange else { return nil }
        let t0 = Date()
        let text = recognize(history)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        usedFallback = true
        emitted += 1
        return Sentence(start: 0, end: Double(fed) / 16000, text: text, decodeMs: Date().timeIntervalSince(t0) * 1000)
    }

    /// 整段识别要求的动态范围（dB）
    static let fallbackMinRange: Float = 12

    /// 单独识别一段完整音频（不经过 VAD）
    public func recognize(_ samples: [Float]) -> String {
        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let res = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(res) }
        return res.pointee.text.map { String(cString: $0) } ?? ""
    }

    private func drain() -> [Sentence] {
        var out: [Sentence] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            let start = Int(seg.pointee.start), n = Int(seg.pointee.n)
            SherpaOnnxDestroySpeechSegment(seg)
            SherpaOnnxVoiceActivityDetectorPop(vad)
            let a = max(start - pre, historyStart), b = min(start + n + post, historyStart + history.count)
            guard b > a else { continue }
            let t0 = Date()
            let text = recognize(Array(history[(a - historyStart)..<(b - historyStart)]))
            out.append(Sentence(start: Double(start) / 16000, end: Double(start + n) / 16000,
                                text: text, decodeMs: Date().timeIntervalSince(t0) * 1000))
            if text.contains(where: { $0.isLetter || $0.isNumber }) { emitted += 1 }
        }
        return out
    }
}

public enum VoiceError: Error, CustomStringConvertible {
    case missingModel(String)
    case initFailed(String)

    public var description: String {
        switch self {
        case let .missingModel(p): return "缺少模型文件 \(p)，先运行 Scripts/fetch-deps.sh"
        case let .initFailed(w): return "\(w) 初始化失败"
        }
    }
}
