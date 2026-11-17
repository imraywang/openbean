// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 边转写边算窗口：每句的采样交进来，切成 1.5 秒窗口，记下响度和声纹向量，采样本身不留。
/// 一段录音只留窗口（每个约 0.8 KB），几个小时的录音也就几十 MB 以内；整段 PCM 从不放在内存里。
public final class SpeakerScanner {
    private let embedder: SpeakerEmbedder
    public private(set) var windows: SpeakerWindows
    /// 花在算向量上的时间（秒，挂钟）
    public private(set) var seconds: Double = 0

    public init(embedder: SpeakerEmbedder) {
        self.embedder = embedder
        windows = SpeakerWindows(dim: embedder.dim)
    }

    public convenience init(modelsDir: URL) throws {
        try self.init(embedder: SpeakerEmbedder(modelsDir: modelsDir))
    }

    /// 一句的采样（16 kHz，就是这句的起止，不含前后补的）
    public func add(sentence: Int, samples: UnsafeBufferPointer<Float>) {
        let t0 = Date()
        let rate = Double(SentenceRecognizer.sampleRate)
        for w in SpeakerID.windows(duration: Double(samples.count) / rate) {
            let a = max(0, Int(w.start * rate)), b = min(samples.count, Int(w.end * rate))
            guard b > a else { continue }
            let slice = UnsafeBufferPointer(rebasing: samples[a..<b])
            guard let v = embedder.embed(slice) else { continue }
            windows.append(sentence: sentence, rmsDb: SpeakerMath.rmsDb(slice), vector: v)
        }
        seconds += Date().timeIntervalSince(t0)
    }

    public func add(sentence: Int, samples: ArraySlice<Float>) {
        samples.withUnsafeBufferPointer { add(sentence: sentence, samples: $0) }
    }
}

/// 补算已经转写过的录音：音频按块流式读进来，按转写里每句的起止切出采样交给 body。
/// 只留还没交出去的句子需要的那一段，不留整段音频。句子要按开始时间排好
public struct SentenceAudioSlicer {
    private let spans: [(start: Int, end: Int)]
    private var next = 0
    private var buffer: [Float] = []
    /// buffer[0] 在整段音频里的位置（采样）
    private var bufferStart = 0

    public init(times: [(start: Double, end: Double)], sampleRate: Int = SentenceRecognizer.sampleRate) {
        spans = times.map { (Int(($0.start * Double(sampleRate)).rounded()), Int(($0.end * Double(sampleRate)).rounded())) }
    }

    /// 送一块音频；凑齐了的句子（下标、采样）交给 body
    public mutating func feed(_ chunk: [Float], _ body: (Int, ArraySlice<Float>) throws -> Void) rethrows {
        buffer += chunk
        try emit(final: false, body)
    }

    /// 音频读完：剩下的句子能切多少切多少
    public mutating func finish(_ body: (Int, ArraySlice<Float>) throws -> Void) rethrows {
        try emit(final: true, body)
    }

    private mutating func emit(final: Bool, _ body: (Int, ArraySlice<Float>) throws -> Void) rethrows {
        let bufferEnd = bufferStart + buffer.count
        while next < spans.count {
            let s = spans[next]
            guard final || s.end <= bufferEnd else { break }
            let a = max(s.start, bufferStart), b = min(s.end, bufferEnd)
            if b > a { try body(next, buffer[(a - bufferStart)..<(b - bufferStart)]) }
            next += 1
        }
        // 丢掉以后用不到的：下一句开始之前的都不要了
        let keepFrom = next < spans.count ? min(spans[next].start, bufferEnd) : bufferEnd
        let drop = keepFrom - bufferStart
        if drop > 0 {
            let d = min(drop, buffer.count)
            buffer.removeFirst(d)
            bufferStart += d
        }
    }
}
