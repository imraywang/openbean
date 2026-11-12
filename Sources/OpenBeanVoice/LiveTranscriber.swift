// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import OpenBeanKit
import Speech

/// 带音频时间的一段文字（字或词）
public struct TimedText: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// Apple 设备端流式识别（macOS 26 SpeechAnalyzer）。喂任意格式的 PCM，回调中间结果和最终结果。
@available(macOS 26.0, iOS 26.0, *)
@MainActor
public final class LiveTranscriber {
    public enum Engine: String { case speech, speechSlow = "speech-slow", dictation }

    public struct Update {
        public let text: String
        public let isFinal: Bool
        public let at: Date
        /// 这段文字对应的音频区间（以送进识别器的音频为时间轴）
        public let audioStart: Double
        public let audioEnd: Double
        /// 这段文字最后一块音频送进识别器之后，过了多久出结果（识别器自身延迟）
        public let lag: Double?
        /// 按字（或词）拆开的文字和对应音频时间
        public let runs: [Run]
    }

    public typealias Run = TimedText

    public private(set) var finalized: [String] = []
    public private(set) var volatile = ""
    public var onUpdate: (Update) -> Void = { _ in }
    /// 送进识别器的同一份音频（已转成识别器格式），给第二遍识别用
    public var onPCM: ((AVAudioPCMBuffer, Double) -> Void)?
    /// 攒够这么长再送给识别器（秒）
    public var chunkSeconds: Double = 0.1
    private var pending: AVAudioPCMBuffer?

    private let module: any SpeechModule
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converters: [String: AVAudioConverter] = [:]
    private var framesIn: Int64 = 0
    /// (音频时间轴上的秒数, 送进去的时刻)，用来把结果映射回墙钟时间
    private var marks: [(audio: Double, at: Date)] = []
    private var resultsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    public private(set) var failure: String?

    public var text: String { finalized.joined() + volatile }

    public static func installedStatus(locale: Locale) async -> String {
        let s = await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
        let d = await DictationTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
        return "SpeechTranscriber 已装=\(s)，DictationTranscriber 已装=\(d)"
    }

    /// `unbounded`：转写文件时一次性灌入，不能限制排队长度
    public init(locale: Locale, engine: Engine, unbounded: Bool = false, log: @escaping (String) -> Void) async throws {
        let module: any SpeechModule
        switch engine {
        case .speech, .speechSlow:
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw LinkError.missing("SpeechTranscriber 不支持 \(locale.identifier)")
            }
            // fastResults：牺牲一点准确率换响应速度；不开时识别器每约 11.5 秒音频才处理一批
            module = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                       reportingOptions: engine == .speech ? [.volatileResults, .fastResults] : [.volatileResults],
                                       attributeOptions: [.audioTimeRange])
        case .dictation:
            guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw LinkError.missing("DictationTranscriber 不支持 \(locale.identifier)")
            }
            module = DictationTranscriber(locale: loc, contentHints: [], transcriptionOptions: [.punctuation],
                                          reportingOptions: [.volatileResults, .frequentFinalization],
                                          attributeOptions: [.audioTimeRange])
        }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            log("下载 \(locale.identifier) 识别模型（只需一次）…")
            let t0 = Date()
            try await req.downloadAndInstall()
            log(String(format: "  模型已装好，用时 %.0f 秒", Date().timeIntervalSince(t0)))
        }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw LinkError.missing("识别器音频格式")
        }
        log("识别器：\(engine.rawValue)，输入格式 \(Int(fmt.sampleRate)) Hz \(fmt.commonFormat == .pcmFormatInt16 ? "Int16" : "Float32")")
        self.module = module
        self.format = fmt
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: unbounded ? .unbounded : .bufferingOldest(200))
        continuation = cont
        analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: fmt)

        resultsTask = Task { @MainActor [weak self] in
            do {
                if let m = module as? SpeechTranscriber {
                    for try await r in m.results { self?.receive(r.text, r.range, r.isFinal) }
                } else if let m = module as? DictationTranscriber {
                    for try await r in m.results { self?.receive(r.text, r.range, r.isFinal) }
                }
            } catch { self?.failure = "\(error)" }
        }
        let analyzer = self.analyzer
        analysisTask = Task { @MainActor [weak self] in
            do { try await analyzer.start(inputSequence: stream) } catch { self?.failure = "\(error)" }
        }
    }

    private func receive(_ attributed: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) {
        let text = String(attributed.characters)
        var runs: [Run] = []
        for run in attributed.runs {
            guard let r = run.audioTimeRange else { continue }
            runs.append(Run(text: String(attributed[run.range].characters),
                            start: r.start.seconds, end: CMTimeRangeGetEnd(r).seconds))
        }
        if isFinal { finalized.append(text); volatile = "" } else { volatile = text }
        let end = CMTimeRangeGetEnd(range).seconds
        let now = Date()
        let fedAt = marks.first { $0.audio >= end }?.at
        onUpdate(Update(text: text, isFinal: isFinal, at: now,
                        audioStart: range.start.seconds, audioEnd: end,
                        lag: fedAt.map { now.timeIntervalSince($0) }, runs: runs))
    }

    /// 送一块音频（任意采样率/格式，内部转换）。
    public func append(_ buffer: AVAudioPCMBuffer) {
        let key = "\(buffer.format.sampleRate)-\(buffer.format.commonFormat.rawValue)-\(buffer.format.channelCount)"
        let conv: AVAudioConverter
        if let c = converters[key] { conv = c } else {
            guard let c = AVAudioConverter(from: buffer.format, to: format) else { return }
            converters[key] = c
            conv = c
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0 else { return }
        // 攒批
        let want = AVAudioFrameCount(chunkSeconds * format.sampleRate)
        if pending == nil { pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(want, out.frameLength) * 2) }
        guard let p = pending else { return }
        if p.frameLength + out.frameLength > p.frameCapacity { flush() ; pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(want, out.frameLength) * 2) }
        let q = pending!
        let bpf = Int(format.streamDescription.pointee.mBytesPerFrame)
        let dst = q.audioBufferList.pointee.mBuffers.mData!.advanced(by: Int(q.frameLength) * bpf)
        dst.copyMemory(from: out.audioBufferList.pointee.mBuffers.mData!, byteCount: Int(out.frameLength) * bpf)
        q.frameLength += out.frameLength
        if q.frameLength >= want { flush() }
    }

    private func flush() {
        guard let q = pending, q.frameLength > 0 else { return }
        pending = nil
        let t = CMTime(value: framesIn, timescale: CMTimeScale(format.sampleRate))
        onPCM?(q, Double(framesIn) / format.sampleRate)
        framesIn += Int64(q.frameLength)
        marks.append((Double(framesIn) / format.sampleRate, Date()))
        continuation.yield(AnalyzerInput(buffer: q, bufferStartTime: t))
    }

    /// 已送入的音频时长（秒）
    public var audioSeconds: Double { Double(framesIn) / format.sampleRate }

    public func finish() async {
        flush()
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
    }
}
