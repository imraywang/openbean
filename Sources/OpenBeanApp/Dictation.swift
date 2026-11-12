// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import Observation
import OpenBeanKit
import OpenBeanVoice

/// 一次听写：录音豆开始录音 → 实时流 → Apple 灰字 + SenseVoice 每句定稿 → 可选润色 → 打字。
@available(macOS 26.0, *)
@MainActor @Observable
final class Dictation {
    enum Phase: Equatable { case idle, starting, listening, finishing }

    private(set) var phase: Phase = .idle
    private(set) var finalText = ""
    private(set) var volatileText = ""
    private(set) var lastError: String?
    private(set) var recognizerReady = false

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
    private var segments: [(raw: String, polished: String?, newParagraph: Bool)] = []
    private var lastEnd: Double?
    private var chain: Task<Void, Never>?
    private var polisher: Polisher?
    private var typing = false

    init(device: DeviceController, settings: Settings) {
        self.device = device
        self.settings = settings
        decoder = try? OpusDecoder()
        let models = AppPaths.models
        svQueue.async { [weak self] in
            do {
                let r = try SentenceRecognizer(modelsDir: models)
                DispatchQueue.main.async {
                    self?.recognizer = r
                    self?.recognizerReady = true
                }
            } catch {
                DispatchQueue.main.async { self?.lastError = "\(error)" }
            }
        }
    }

    // MARK: 设备事件

    func handle(_ e: DeviceEvent) {
        switch e {
        case let .recordingStarted(fileId):
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
        guard phase == .idle, let session = device.session, let decoder else { return }
        phase = .starting
        finalText = ""; volatileText = ""; lastError = nil
        text = TwoPassText(); segments = []; lastEnd = nil; chain = nil; early = []
        typing = settings.typeIntoApp && Typist.trusted
        let r = recognizer
        svQueue.async { r?.reset() }
        Log.write("开始听写 file=\(fileId)")

        // 先开流，识别器准备好之前的音频先攒着
        do {
            stream = try session.startRealtime(fileId: fileId) { [weak self] _, frame in
                guard let pcm = try? decoder.decode(frame) else { return }
                DispatchQueue.main.async { self?.feed(pcm) }
            }
        } catch {
            lastError = "\(error)"; phase = .idle; return
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
            if phase == .starting { phase = .listening }
        } catch {
            lastError = "识别器：\(error)"
        }
    }

    private func feed(_ pcm: AVAudioPCMBuffer) {
        if let t = transcriber { t.append(pcm) } else if phase == .starting { early.append(pcm) }
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
            guard !raw.isEmpty else { continue }
            let newPara = lastEnd.map { s.start - $0 >= settings.paragraphGap } ?? false
            lastEnd = s.end
            let idx = segments.count
            segments.append((raw, nil, newPara))
            rebuild()
            Log.write(String(format: "定稿 [%.2f–%.2f s，%.0f ms]%@ %@", s.start, s.end, s.decodeMs, newPara ? " ¶" : "", raw))
            let prev = chain, polisher = self.polisher, typing = self.typing
            chain = Task { @MainActor [weak self] in
                await prev?.value
                var final = raw
                if let polisher {
                    let r = await polisher.polish(raw)
                    final = r.text
                    Log.write(String(format: "润色 %.0f ms%@ %@", r.ms, r.fellBack ? "（退回原文）" : "", r.text))
                }
                guard let self else { return }
                self.segments[idx].polished = final
                self.rebuild()
                if typing {
                    if newPara { Typist.newline() }
                    Typist.type(final)
                }
            }
        }
    }

    private func rebuild() {
        finalText = segments.enumerated().map { i, s in
            (s.newParagraph && i > 0 ? "\n\n" : "") + (s.polished ?? s.raw)
        }.joined()
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
        volatileText = ""
        Log.write("结束听写：\(finalText)")
        phase = .idle
    }
}
