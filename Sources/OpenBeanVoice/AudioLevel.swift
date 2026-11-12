// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// 音量测量和电平归一化：小声说话时 Silero VAD 会把整段当成静音，切句前先把音量抬上来。
///
/// 只放大不缩小；音量正常的音频增益为 0，结果和以前完全一样。
/// 增益只给 VAD 看（判断哪里有人说话），送去 SenseVoice 识别的仍是原始音频。
public enum AudioLevel {
    /// 测量用的帧长：和 VAD 窗口一样 512 个采样（16 kHz 下 32 ms）
    public static let frame = 512
    /// 把说话的音量抬到这个水平（帧 RMS，dBFS）
    public static let target: Float = -30
    /// 说话音量已经不低于这个值就不动（dBFS）
    public static let quietBelow: Float = -36
    /// 最多放大多少（dB）：再往上抬只会把底噪也抬成「说话」
    public static let maxGain: Float = 30
    /// 放大后底噪不能超过这个值（dBFS）
    public static let noiseCeiling: Float = -55
    /// 算出来的增益不到这个值就当 0（dB），免得为一点点差别改变结果
    public static let minGain: Float = 3

    /// 一段采样的 RMS（dBFS），全零时给 -120
    public static func db<C: Collection>(_ s: C) -> Float where C.Element == Float {
        guard !s.isEmpty else { return -120 }
        var sum: Float = 0
        for x in s { sum += x * x }
        return 10 * log10(max(sum / Float(s.count), 1e-12))
    }

    /// 逐帧 RMS（dBFS）；不足一帧的尾巴丢掉
    public static func frameLevels(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count - frame + 1, by: frame).map { db(samples[$0..<($0 + frame)]) }
    }

    /// 第 p 百分位（0…1），最近秩
    public static func percentile(_ v: [Float], _ p: Float) -> Float {
        guard !v.isEmpty else { return -120 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((Float(s.count - 1) * p).rounded())))]
    }

    /// 由说话音量和底噪算增益（dB）：抬到 target，不超过 maxGain，底噪不超过 noiseCeiling；
    /// 说话音量本来就够（≥ quietBelow）或增益太小（< minGain）都返回 0
    public static func gain(speech: Float, noise: Float) -> Float {
        guard speech < quietBelow else { return 0 }
        let g = min(target - speech, maxGain, noiseCeiling - noise)
        return g >= minGain ? g : 0
    }

    /// 整段音频的统计：说话音量取帧 RMS 的第 95 百分位（一声咔哒只占一两帧，顶不动它；峰值就会被顶住），
    /// 底噪取第 10 百分位
    public struct Stats: Sendable {
        public let speech: Float
        public let noise: Float
        public let frames: Int
        public var gain: Float { AudioLevel.gain(speech: speech, noise: noise) }

        public init(frameLevels v: [Float]) {
            speech = AudioLevel.percentile(v, 0.95)
            noise = AudioLevel.percentile(v, 0.10)
            frames = v.count
        }
    }

    /// 整个文件（已经全部可用）：先测再定一个固定增益
    public static func stats(_ samples: [Float]) -> Stats { Stats(frameLevels: frameLevels(samples)) }

    public static func linear(_ db: Float) -> Float { pow(10, db / 20) }

    /// 某一帧实际用的增益：不把任何一帧抬到 target 以上，本来就不轻的帧（≥ target）不放大。
    /// 这样小声录音里突然大声的地方、实时听写里开口第一帧的大声，都和不加增益时一样
    public static func frameGain(_ gain: Float, frameDb: Float) -> Float {
        gain > 0 ? min(gain, max(0, target - frameDb)) : 0
    }
}

/// 流式的自动增益（实时听写用，没有后文可看）。
///
/// 每 512 个采样一帧，记最近几秒每帧的 RMS：
/// - 说话音量 = 最近 `window` 秒里第二响的帧（一声咔哒顶不动）；底噪 = 最近 `window` 秒里最静的帧附近；
/// - 增益按 `AudioLevel.gain` 算，变大时每帧最多加 `rise` dB（慢慢抬），变小时立刻降（大声说话马上不放大）；
/// - 开头还没听够 `warmup` 秒时增益为 0；
/// - 只在最近确实听到了「比底噪高出 `minRange` dB 的轻声」时才放大：纯静音、平稳底噪不放大；
/// - 最近 `holdLoud` 秒里有过正常音量的帧（≥ quietBelow）就不放大：正常说话中间的停顿不会被抬起来。
/// 这样音量正常的听写和以前基本一样（开口前、停顿里的底噪都不放大）。
public struct AdaptiveGain: Sendable {
    public var window: Double = 4
    public var warmup: Double = 0.3
    public var minRange: Float = 15
    public var holdLoud: Double = 8
    /// 增益每帧最多上升多少 dB（32 ms 一帧，3 dB/帧 ≈ 0.3 秒升满 30 dB）
    public var rise: Float = 3

    private var levels: [Float] = []
    private var seen = 0
    private var lastLoud: Int?
    public private(set) var gainDb: Float = 0

    public init() {}

    private var capacity: Int { max(2, Int(window * 16000 / Double(AudioLevel.frame))) }

    /// 送入一帧的 RMS（dBFS），返回这一帧该用的增益（dB，已按 AudioLevel.frameGain 限过）
    public mutating func next(_ db: Float) -> Float {
        levels.append(db)
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        seen += 1
        if db >= AudioLevel.quietBelow { lastLoud = seen }
        guard Double(seen * AudioLevel.frame) / 16000 >= warmup else { return 0 }
        let sorted = levels.sorted()
        let speech = sorted[max(0, sorted.count - 2)]
        let noise = sorted[min(sorted.count - 1, sorted.count / 10)]
        let recentLoud = lastLoud.map { Double((seen - $0) * AudioLevel.frame) / 16000 < holdLoud } ?? false
        let want = recentLoud || speech - noise < minRange ? 0 : AudioLevel.gain(speech: speech, noise: noise)
        gainDb = want < gainDb ? want : min(want, gainDb + rise)
        return AudioLevel.frameGain(gainDb, frameDb: db)
    }

    public mutating func reset() { levels.removeAll(); seen = 0; lastLoud = nil; gainDb = 0 }
}

/// 读音频文件，转成 16 kHz 单声道 Float，分块交给 body（第二个参数是读到的进度 0…1）
public enum AudioFile16k {
    public static func read(_ url: URL, chunk: AVAudioFrameCount = 48000,
                            _ body: ([Float], Double) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { throw VoiceError.initFailed("converter") }
        let total = max(Double(file.length), 1)
        var done = false
        while !done, file.framePosition < file.length {
            let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
            // Ogg Opus 的 length 是估算值，读到末尾时 AVAudioFile 会抛 eofErr（-39），当作读完
            do {
                try file.read(into: inBuf, frameCount: chunk)
            } catch let e as NSError where e.domain == NSOSStatusErrorDomain && e.code == -39 {
                done = true
            }
            if inBuf.frameLength == 0 { break }
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / file.processingFormat.sampleRate) + 64
            let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)!
            var fed = false
            conv.convert(to: outBuf, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return inBuf
            }
            try body(Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))),
                     min(Double(file.framePosition) / total, 1))
        }
    }

    /// 整个文件读进内存（短文件、测试用）
    public static func samples(_ url: URL) throws -> [Float] {
        var out: [Float] = []
        try read(url) { s, _ in out += s }
        return out
    }

    /// 只测音量不留采样：长录音先走一遍，定下整段的增益
    public static func stats(_ url: URL) throws -> AudioLevel.Stats {
        var levels: [Float] = []
        var carry: [Float] = []
        try read(url) { s, _ in
            carry += s
            let n = carry.count / AudioLevel.frame * AudioLevel.frame
            levels += AudioLevel.frameLevels(Array(carry[0..<n]))
            carry.removeFirst(n)
        }
        return AudioLevel.Stats(frameLevels: levels)
    }
}
