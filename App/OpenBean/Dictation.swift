// SPDX-License-Identifier: Apache-2.0

import AppKit
import AVFoundation
import Foundation
import Observation
import OpenBeanKit
import OpenBeanVoice

/// 一次听写：录音豆开始录音 → 实时流 → Apple 灰字 + SenseVoice 每句定稿 → 可选润色 → 打字。
@MainActor @Observable
final class Dictation {
    enum Phase: Equatable { case idle, starting, listening, finishing }

    private(set) var phase: Phase = .idle
    private(set) var finalText = ""
    private(set) var volatileText = ""
    private(set) var lastError: String?
    private(set) var recognizerReady = false
    /// 实时音量 0…1（悬浮条的声波用）
    private(set) var level: Float = 0
    /// 开始听的时刻（计时用）
    private(set) var listeningSince: Date?
    /// 本次已打进光标处的字数
    private(set) var typedCount = 0
    /// 正在润色的句数
    private(set) var polishing = 0
    /// 本次结束时的结果：打进了 App，还是拷贝到了剪贴板
    private(set) var deliveredByClipboard = false

    private let device: DeviceController
    private let settings: Settings
    private let decoder: OpusDecoder?
    private let svQueue = DispatchQueue(label: "openbean.sensevoice")
    nonisolated(unsafe) private var recognizer: SentenceRecognizer?

    // 本次听写的状态
    private var stream: RealtimeStream?
    private var transcriber: LiveTranscriber?
    private var early: [AVAudioPCMBuffer] = []
    private var text = TwoPassText()
    private var segments: [Segment] = []

    struct Segment {
        var raw: String
        var polished: String?
        var newParagraph: Bool
        /// 和上一句之间停了多久（秒）
        var gap: Double?
    }

    /// 两句之间停顿短于「切句停顿 + 0.3 秒」用逗号，否则用句号
    private var commaGap: Double { settings.sentencePause + 0.3 }
    private static let strong: Set<Character> = ["？", "！", "?", "!"]

    /// 去掉句末的句号/逗号（问号、感叹号保留）：句末标点等下一句来了再定
    static func trimTail(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let l = t.last, "。，,.．、;；".contains(l) { t.removeLast() }
        return t
    }

    /// 放在第 i 句前面的连接标点
    static func joiner(prev: String, gap: Double?, commaGap: Double) -> String {
        guard let last = prev.last, !strong.contains(last) else { return "" }
        return (gap ?? 99) < commaGap ? "，" : "。"
    }
    private var lastEnd: Double?
    private var chain: Task<Void, Never>?
    private var polisher: Polisher?
    private var typing = false

    init(device: DeviceController, settings: Settings) {
        self.device = device
        self.settings = settings
        decoder = try? OpusDecoder()
        loadRecognizer()
    }

    /// 加载 SenseVoice（启动时、以及引导里下载完模型之后）
    func loadRecognizer() {
        let models = AppPaths.models
        let pause = Float(settings.sentencePause)
        svQueue.async { [weak self] in
            do {
                let r = try SentenceRecognizer(modelsDir: models, minSilence: pause)
                DispatchQueue.main.async {
                    self?.recognizer = r
                    self?.recognizerReady = true
                    self?.lastError = nil
                }
            } catch {
                DispatchQueue.main.async { self?.lastError = "\(error)" }
            }
        }
    }

    /// 本次听写对应的设备录音（开始时通知录音库）
    var onStarted: (UInt32) -> Void = { _ in }
    /// 设备页「开始录音」：下一次开始录音事件不触发听写
    var ignoreNextStart = false
    var onFinished: () -> Void = {}
    /// 一次输入结束（有文字时），用于语音输入记录
    var onEntry: (DictationEntry) -> Void = { _ in }
    private var targetApp: String?

    // MARK: 设备事件

    func handle(_ e: DeviceEvent) {
        Log.write("设备事件：\(e)")
        switch e {
        case let .recordingStarted(fileId):
            // 只录音：按键设成「只录音」，或者设备页手动开始录音
            if ignoreNextStart || !settings.buttonDictates {
                ignoreNextStart = false
                Log.write("只录音，不听写 file=\(fileId)")
                return
            }
            Task { await begin(fileId: fileId) }
        case .recordingStopped:
            Task { await end() }
        default:
            break
        }
    }

    /// 菜单里的开始/停止：让设备开始或暂停录音，后续由设备事件驱动
    func toggle() async {
        guard let s = device.session else { return }
        do {
            if phase == .idle { try await s.startRecording() } else { try await s.pauseRecording() }
        } catch { lastError = "\(error)" }
    }

    // MARK: 开始

    private func begin(fileId: UInt32) async {
        guard phase == .idle, let session = device.session, let decoder else {
            Log.write("没有开始听写：phase=\(phase) 已连接=\(device.session != nil) 解码器=\(decoder != nil)")
            return
        }
        phase = .starting
        finalText = ""; volatileText = ""; lastError = nil
        level = 0; noiseFloor = -60; listeningSince = nil; typedCount = 0; polishing = 0; deliveredByClipboard = false
        text = TwoPassText(); segments = []; lastEnd = nil; chain = nil; early = []
        typing = settings.typeIntoApp && Typist.trusted
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        if settings.typeIntoApp, !Typist.trusted { Log.write("没有辅助功能权限，只显示不打字") }
        let r = recognizer
        svQueue.async { r?.reset() }
        Log.write("开始听写 file=\(fileId)")
        onStarted(fileId)
        await device.beginDictation()

        // 先开流，识别器准备好之前的音频先攒着
        do {
            stream = try session.startRealtime(fileId: fileId) { [weak self] _, frame in
                guard let pcm = try? decoder.decode(frame) else { return }
                DispatchQueue.main.async { self?.feed(pcm) }
            }
        } catch {
            lastError = "\(error)"; phase = .idle; device.endDictation(); return
        }

        polisher = nil
        if settings.polishEnabled, let url = URL(string: settings.polishEndpoint), await Polisher.isUp(url) {
            polisher = Polisher(endpoint: url, model: settings.polishModel, glossary: AppPaths.readGlossary())
        }

        do {
            let t = try await LiveTranscriber(locale: Locale(identifier: "zh_CN"), engine: .dictation) { Log.write($0) }
            t.onUpdate = { [weak self] u in self?.appleUpdate(u) }
            t.onPCM = { [weak self] buf, _ in self?.toSenseVoice(buf) }
            transcriber = t
            for b in early { t.append(b) }
            early = []
            if phase == .starting {
                phase = .listening
                listeningSince = Date()
                if settings.readySound { NSSound(named: "Tink")?.play() }
            }
        } catch {
            lastError = "识别器：\(error)"
        }
    }

    private func feed(_ pcm: AVAudioPCMBuffer) {
        updateLevel(pcm)
        if let t = transcriber { t.append(pcm) } else if phase == .starting { early.append(pcm) }
    }

    /// 底噪估计（分贝）：静音时跟随，说话时缓慢上升
    private var noiseFloor: Float = -60

    /// 音量：RMS 换成分贝，减去自动估计的底噪，只有明显高于底噪的声音才让声波起伏；上升快、回落慢
    private func updateLevel(_ pcm: AVAudioPCMBuffer) {
        guard let p = pcm.floatChannelData, pcm.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(pcm.frameLength) { sum += p[0][i] * p[0][i] }
        let db = 10 * log10(max(sum / Float(pcm.frameLength), 1e-9))
        noiseFloor = db < noiseFloor ? db : noiseFloor + 0.05   // 每帧 20 ms，约 2.5 dB/秒
        let target = pow(min(max((db - noiseFloor - 4) / 28, 0), 1), 0.7)
        level = target > level ? target : level * 0.8 + target * 0.2
    }

    // MARK: 两遍识别

    private func appleUpdate(_ u: LiveTranscriber.Update) {
        text.apple(isFinal: u.isFinal, runs: u.runs, text: u.text, audioStart: u.audioStart, audioEnd: u.audioEnd)
        volatileText = text.pendingText
    }

    private func toSenseVoice(_ buf: AVAudioPCMBuffer) {
        guard let p = buf.int16ChannelData else { return }
        let samples = (0..<Int(buf.frameLength)).map { Float(p[0][$0]) / 32768 }
        let r = recognizer
        svQueue.async { [weak self] in
            guard let out = r?.accept(samples), !out.isEmpty else { return }
            DispatchQueue.main.async { self?.sentences(out) }
        }
    }

    private func sentences(_ list: [SentenceRecognizer.Sentence]) {
        for s in list {
            let raw = text.commit(text: s.text, end: s.end + 0.1)
            volatileText = text.pendingText
            guard raw.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let gap = lastEnd.map { s.start - $0 }
            let newPara = gap.map { $0 >= settings.paragraphGap } ?? false
            lastEnd = s.end
            let idx = segments.count
            segments.append(Segment(raw: Self.trimTail(raw), polished: nil, newParagraph: newPara, gap: gap))
            rebuild()
            Log.write(String(format: "定稿 [%.2f–%.2f s，%.0f ms]%@ %@", s.start, s.end, s.decodeMs, newPara ? " ¶" : "", raw))
            let prev = chain, polisher = self.polisher, typing = self.typing
            chain = Task { @MainActor [weak self] in
                await prev?.value
                var final = raw
                if let polisher {
                    self?.polishing += 1
                    let r = await polisher.polish(raw)
                    self?.polishing -= 1
                    final = r.text
                    Log.write(String(format: "润色 %.0f ms%@ %@", r.ms, r.fellBack ? "（退回原文）" : "", r.text))
                }
                guard let self else { return }
                final = Self.trimTail(final)
                self.segments[idx].polished = final
                self.rebuild()
                if typing {
                    if idx > 0 {
                        let prev = self.segments[idx - 1]
                        Typist.type(Self.joiner(prev: prev.polished ?? prev.raw, gap: gap, commaGap: self.commaGap))
                    }
                    if newPara { Typist.newline() }
                    Typist.type(final)
                    self.typedCount += final.count
                }
            }
        }
    }

    private func rebuild() {
        var out = ""
        for (i, s) in segments.enumerated() {
            if i > 0 {
                let p = segments[i - 1]
                out += Self.joiner(prev: p.polished ?? p.raw, gap: s.gap, commaGap: commaGap)
                if s.newParagraph { out += "\n\n" }
            }
            out += s.polished ?? s.raw
        }
        finalText = out
    }

    // MARK: 结束

    private func end() async {
        guard phase == .starting || phase == .listening else { return }
        phase = .finishing
        // 设备停止后还会有零星几帧在路上
        try? await Task.sleep(nanoseconds: 400_000_000)
        stream?.stop()
        stream = nil
        await transcriber?.finish()
        transcriber = nil
        let r = recognizer
        let rest: [SentenceRecognizer.Sentence] = await withCheckedContinuation { c in
            svQueue.async { c.resume(returning: r?.flush() ?? []) }
        }
        sentences(rest)
        await chain?.value
        // 补上最后一句的句末标点
        if let last = segments.last {
            let tail = Self.joiner(prev: last.polished ?? last.raw, gap: nil, commaGap: commaGap)
            if !tail.isEmpty {
                finalText += tail
                if typing { Typist.type(tail); typedCount += 1 }
            }
        }
        volatileText = ""
        level = 0
        // 没有打进 App（关了打字或没权限）时，把全文放进剪贴板，免得白说
        if !typing, !finalText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)
            deliveredByClipboard = true
        }
        Log.write("结束听写：\(finalText)")
        if !finalText.isEmpty, settings.keepHistory {
            let since = listeningSince ?? Date()
            onEntry(DictationEntry(date: since, duration: Date().timeIntervalSince(since), text: finalText,
                                   app: targetApp, viaClipboard: deliveredByClipboard))
        }
        device.endDictation()
        phase = .idle
        onFinished()
    }
}
