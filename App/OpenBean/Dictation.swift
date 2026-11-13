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
    /// 个人词表纠正（不需要大模型），每次听写开始时按词表重建
    private var glossary = GlossaryCorrector(terms: [])
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
                // 小声说话时 VAD 会当成静音：给切句的音频加一个边听边估的增益（音量正常时为 0，不影响识别）
                r.adaptiveGain = AdaptiveGain()
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
    /// 一次语音输入结束；带着这次用的设备文件和「它是不是 App 新建的」证据，录音库据此决定删不删
    var onFinished: (DictationDeletePolicy.Evidence?) -> Void = { _ in }
    /// 录音库正在删上一次语音输入的设备文件：这时开始新的语音输入，录音豆可能续写那个正要删的文件
    var cleanupRunning: () -> Bool = { false }
    /// 一次输入结束（有文字时），用于语音输入记录
    var onEntry: (DictationEntry) -> Void = { _ in }
    private var targetApp: String?
    /// 本次听写从哪一刻开始（电量日志算时长用）
    private var startedAt: Date?
    private var currentFile: UInt32 = 0
    /// 正在进行的「只录音」：开始时刻和文件号
    private var recordOnly: (since: Date, fileId: UInt32)?
    /// 这次语音输入是 App 发的开始命令：发命令的时刻，和发之前录音豆在不在录（nil = 没读到）
    private var appStart: (at: Date, recordingBefore: Bool?)?
    /// App 发开始命令之后收到的新文件通知（1A/06）里的文件号
    private var notifiedNew: Set<UInt32> = []

    // MARK: 启动

    /// 开始命令回包后先等新文件通知（1A/06）多久，再退回「按上次的文件号开始」。
    /// 真机：紧接上一次的录音 1A/06 在回包后 90–180 ms 到；隔久了的第一次约 1 秒（那种情况等不到，走兜底）
    static let notifyWait: TimeInterval = 0.4
    /// 第一次用（不知道上一个文件号）时，回包后最多等通知多久，再去读文件列表
    static let firstUseNotifyWait: TimeInterval = 1.2

    /// 和文件号无关的准备工作（识别器、焦点、词表、润色服务），发开始命令的同时做；文件号到了只剩开流
    private struct Prepared {
        var transcriber: LiveTranscriber?
        var transcriberError: String?
        var targetApp: String?
        var words: [String] = []
        var polisher: Polisher?
        /// 各步耗时，写进启动分段日志
        var steps: [String] = []
    }
    private var preparing: Task<Prepared, Never>?

    /// 启动分段：从按下（或收到按键开始的通知）到可以说话，每一步在第几毫秒
    private struct StartTrace {
        let t0 = Date()
        var marks: [String] = []
        /// 最终走的路径：通知 / 猜上次的文件 / 文件列表 / 按键
        var path = "?"
        var ms: Double { Date().timeIntervalSince(t0) * 1000 }
        mutating func mark(_ name: String) { marks.append(String(format: "%@ %.0f", name, ms)) }
    }
    private var trace: StartTrace?

    private func startPreparing() {
        guard preparing == nil else { return }
        let polishURL = settings.polishEnabled ? URL(string: settings.polishEndpoint) : nil
        let key = settings.polishAPIKey, model = settings.polishModel
        let focus = settings.typeIntoApp && Typist.trusted
        preparing = Task { @MainActor in
            var p = Prepared()
            // 最慢的是识别器（SpeechAnalyzer 准备），先让它跑起来，其余的和它并行
            async let made = Self.makeTranscriber()
            var t = Date()
            func step(_ name: String) {
                p.steps.append(String(format: "%@ %.0f", name, Date().timeIntervalSince(t) * 1000))
                t = Date()
            }
            p.targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
            // 先问一次焦点：顺便让 Electron 类应用把辅助功能打开，到真正打字时就能分清输入框和画布
            if focus { _ = Typist.focus() }
            step("焦点")
            // 每次开始都重读词表，改了词表下一次就生效
            p.words = AppPaths.readGlossary()
            step("词表")
            // 本机服务先探一下（1 秒），没开就不润色；云端不探，免得拖慢开始，请求失败时那句原样输出
            if let url = polishURL {
                let usable = Polisher.isLocal(url) ? await Polisher.isUp(url) : true
                if usable {
                    // 润色只拿词条本身，误听别名不给（免得大模型把别名当成要用的词）
                    p.polisher = Polisher(endpoint: url, apiKey: key, model: model,
                                          glossary: GlossaryCorrector.canonicalTerms(p.words))
                }
                step("润色服务")
            }
            let r = await made
            p.transcriber = r.transcriber
            p.transcriberError = r.error
            p.steps.append(String(format: "识别器 %.0f", r.ms))
            return p
        }
    }

    private static func makeTranscriber() async -> (transcriber: LiveTranscriber?, error: String?, ms: Double) {
        let t0 = Date()
        do {
            let t = try await LiveTranscriber(locale: Locale(identifier: "zh_CN"), engine: .dictation) { Log.write($0) }
            return (t, nil, Date().timeIntervalSince(t0) * 1000)
        } catch {
            return (nil, "\(error)", Date().timeIntervalSince(t0) * 1000)
        }
    }

    /// 准备好了却没用上（开始失败）：把识别器关掉
    private func discardPreparing() {
        guard let p = preparing else { return }
        preparing = nil
        Task { @MainActor in await p.value.transcriber?.finish() }
    }

    /// 写启动分段日志（可以说话时、或开始失败时各一次）
    private func finishTrace(ok: Bool) {
        guard let t = trace else { return }
        trace = nil
        Log.write("启动分段（ms）：" + (t.marks + ["路径=\(t.path)", ok ? String(format: "可以说话 %.0f", t.ms) : "没开始"]).joined(separator: "，"))
        if ok { Log.write(String(format: "语音输入启动用了 %.0f ms", t.ms)) }
    }

    // MARK: 设备事件

    func handle(_ e: DeviceEvent) {
        Log.write("设备事件：\(e)")
        switch e {
        case let .recordingStarted(fileId):
            // 只录音：按键设成「只录音」，或者设备页手动开始录音。
            // App 自己发的开始（快捷键、菜单）不算，即使按键设成了「只录音」
            if ignoreNextStart || (!settings.buttonDictates && appStart == nil) {
                ignoreNextStart = false
                Log.write("只录音，不听写 file=\(fileId)")
                recordOnly = (Date(), fileId)
                return
            }
            // 记下来：这是「这个文件是这次新建的」的证据（删设备文件时要用）
            if appStart != nil { notifiedNew.insert(fileId) }
            trace?.mark("1A/06")
            // 没等到通知、已经按文件列表里最新的一条开始了，结果通知晚到、说的是另一个新文件：换过去
            if phase != .idle, guessedFile, fileId != currentFile {
                switchFile(to: fileId, why: "新录音的通知到了")
                return
            }
            if phase == .idle, trace != nil { trace?.path = "通知" }
            Task { await begin(fileId: fileId) }
        case .recordingStopped:
            if let r = recordOnly, phase == .idle {
                recordOnly = nil
                let secs = Int(Date().timeIntervalSince(r.since).rounded())
                Log.write("battery event=record seconds=\(secs) recorder=\(DeviceController.field(device.battery)) file=\(r.fileId)")
                return
            }
            Task { await end() }
        default:
            break
        }
    }

    /// 对这条录音开实时流，音频解码后喂给识别
    @discardableResult
    private func openStream(fileId: UInt32) -> Bool {
        guard let session = device.session, let decoder else { return false }
        do {
            stream = try session.startRealtime(fileId: fileId) { [weak self] _, frame in
                guard let pcm = try? decoder.decode(frame) else { return }
                DispatchQueue.main.async { self?.feed(pcm) }
            }
            return true
        } catch {
            lastError = "\(error)"
            Log.write("开实时流失败 file=\(fileId)：\(error)")
            return false
        }
    }

    /// 猜错了文件：换到真正在录的那一条
    private func switchFile(to fileId: UInt32, why: String) {
        guessedFile = false
        Log.write("\(why)，换到 file=\(fileId)")
        trace?.mark("换文件")
        stream?.stop()
        currentFile = fileId
        onStarted(fileId)
        openStream(fileId: fileId)
    }

    /// 这次听写收到过音频没有
    private var gotAudio = false

    /// 这次听写的文件号是猜的（没等到设备通知，取了文件列表里最新的一条）
    private var guessedFile = false

    /// 这次是 App 发的暂停（不是按录音豆按键停的）：暂停只是暂停，结束时还要发「结束录音」让录音豆收尾文件。
    /// 按键停止设备自己会收尾，不用发
    private var pausedByApp = false

    /// 菜单里的开始/停止：让设备开始或暂停录音，后续由设备事件驱动
    func toggle() async {
        guard let s = device.session else { Log.write("语音输入没开始：录音豆没连上"); return }
        let starting = phase == .idle
        // 开始没成功（没进入听写）就不留「App 发过开始命令」的记录，免得之后按键开始的听写被当成 App 开始的；
        // 准备好的识别器也关掉
        defer {
            if starting, phase == .idle {
                appStart = nil; notifiedNew = []
                discardPreparing()
                finishTrace(ok: false)
            }
        }
        do {
            if phase == .idle {
                // 和文件号无关的准备（识别器等）现在就开始，和下面的查状态、开始命令、等通知并行
                trace = StartTrace()
                startPreparing()
                // 上一次语音输入的设备文件还在删：等它删完再开始（最多 5 秒），免得录音豆续写那个文件、然后被删掉
                for _ in 0..<50 where cleanupRunning() { try? await Task.sleep(nanoseconds: 100_000_000) }
                if cleanupRunning() { Log.write("语音输入没开始：还在删上一次的设备文件"); return }
                // 录音豆其实已经在录、App 却不知道（App 重启时错过了开始事件）：这时再发「开始」设备不理，
                // 语音输入就一直起不来。按键是「语音输入」时这段录音没人要，先停掉再开始；
                // 按键是「只录音」时可能是正在录的会议，不动它
                let info = recordOnly == nil ? try? await s.deviceInfo() : nil
                trace?.mark("查状态")
                if let info, info.recording == true {
                    guard settings.buttonDictates else {
                        Log.write("语音输入没开始：录音豆正在录音（只录音模式），先按录音豆按键停止")
                        lastError = String(localized: "The recorder is recording. Stop it first.")
                        return
                    }
                    Log.write("录音豆上有一段 App 不知道的录音，先停掉再开始语音输入")
                    try await s.pauseRecording()
                    // 暂停后再结束（真机测过的顺序），这样下面的「开始」会新建文件，而不是续写那段录音
                    do { try await s.stopRecording() } catch { Log.write("结束那段录音失败：\(error)") }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
                guessedFile = false
                // 读不到状态（info 为 nil）或在录，都记下来；只有确定没在录，结束后才可能删设备文件
                appStart = (Date(), info?.recording)
                notifiedNew = []
                try await s.startRecording()
                trace?.mark("开始回包")
                let replied = Date()
                // 设备新建录音文件时会报文件号（1A/06）：紧接上一次时回包后 0.1–0.2 秒到，隔久了的第一次约 1 秒；
                // 续写上一个文件时根本不报。现在每次结束都会发「结束录音」，正常情况下总是新建文件、总有 1A/06。
                // 先短等通知：到了 handle 会直接用它开始（phase 变成 starting），不走猜的路径
                while phase == .idle, Date().timeIntervalSince(replied) < Self.notifyWait {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                if phase != .idle { return }
                trace?.mark("没等到通知")
                // 兜底（结束命令失败、或别处只暂停没结束时会续写，就没有通知）：手里有上一次的文件号就先按它开始，
                // 通知晚到、发现是新文件再换过去（见 handle）
                if currentFile != 0 {
                    guessedFile = true
                    let guess = currentFile
                    trace?.path = "猜上次的文件"
                    await begin(fileId: guess)
                    // 保险：1.5 秒还没收到任何音频，说明猜错了又没等到通知，去文件列表里找最新的
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard let self, self.guessedFile, self.phase != .idle, self.currentFile == guess, !self.gotAudio,
                              let newest = try? await s.listFiles().first?.id, newest != guess,
                              self.guessedFile, self.phase != .idle, self.currentFile == guess else { return }
                        self.switchFile(to: newest, why: "一直没有音频")
                    }
                    return
                }
                // 第一次用、不知道上一个文件：再等一会儿通知，等不到就读文件列表
                while phase == .idle, Date().timeIntervalSince(replied) < Self.firstUseNotifyWait {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                if phase == .idle {
                    trace?.mark("等通知超时")
                    guard let id = try await s.listFiles().first?.id else {
                        Log.write("语音输入没开始：录音豆没报新录音，文件列表也是空的")
                        return
                    }
                    Log.write("录音豆没报新录音，按文件列表里最新的一条开始 file=\(id)")
                    guessedFile = true
                    trace?.path = "文件列表"
                    await begin(fileId: id)
                }
            } else {
                pausedByApp = true
                do { try await s.pauseRecording() } catch { pausedByApp = false; throw error }
            }
        } catch {
            lastError = "\(error)"
            Log.write("语音输入\(phase == .idle ? "开始" : "停止")失败：\(error)")
        }
    }

    // MARK: 开始

    private func begin(fileId: UInt32) async {
        guard phase == .idle, let session = device.session, let decoder else {
            Log.write("没有开始听写：phase=\(phase) 已连接=\(device.session != nil) 解码器=\(decoder != nil)")
            return
        }
        // 按录音豆按键开始的：前面没有 toggle，准备工作从这里才开始
        if trace == nil { trace = StartTrace(path: "按键") }
        startPreparing()
        let prep = preparing!
        preparing = nil
        phase = .starting
        finalText = ""; volatileText = ""; lastError = nil
        level = 0; noiseFloor = -60; listeningSince = nil; typedCount = 0; polishing = 0; deliveredByClipboard = false
        text = TwoPassText(); segments = []; lastEnd = nil; chain = nil; early = []
        typing = settings.typeIntoApp && Typist.trusted
        if settings.typeIntoApp, !Typist.trusted { Log.write("没有辅助功能权限，只显示不打字") }
        let r = recognizer
        svQueue.async { r?.reset() }
        gotAudio = false
        pausedByApp = false
        Log.write("开始听写 file=\(fileId)")
        startedAt = Date()
        currentFile = fileId
        recordOnly = nil   // 听写开始就不再是「只录音」，免得下次停止时多记一条时长
        onStarted(fileId)
        await device.beginDictation()
        trace?.mark("占连接")

        // 先开流，识别器准备好之前的音频先攒着
        guard openStream(fileId: fileId) else {
            phase = .idle; device.endDictation()
            Task { @MainActor in await prep.value.transcriber?.finish() }
            finishTrace(ok: false)
            return
        }
        trace?.mark("开流")

        let p = await prep.value
        trace?.marks.append("准备（" + p.steps.joined(separator: "，") + "）")
        trace?.mark("准备好")
        targetApp = p.targetApp
        glossary = GlossaryCorrector(terms: p.words)
        polisher = p.polisher
        guard let t = p.transcriber else {
            lastError = "识别器：\(p.transcriberError ?? "?")"
            finishTrace(ok: false)
            return
        }
        // 等准备的时候已经结束了（很快又按了一下）：这个识别器用不上
        guard phase == .starting else {
            Task { @MainActor in await t.finish() }
            finishTrace(ok: false)
            return
        }
        t.onUpdate = { [weak self] u in self?.appleUpdate(u) }
        t.onPCM = { [weak self] buf, _ in self?.toSenseVoice(buf) }
        transcriber = t
        for b in early { t.append(b) }
        early = []
        phase = .listening
        listeningSince = Date()
        if settings.readySound { NSSound(named: "Tink")?.play() }
        finishTrace(ok: true)
    }

    private func feed(_ pcm: AVAudioPCMBuffer) {
        gotAudio = true
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
            let recognized = text.commit(text: s.text, end: s.end + 0.1)
            volatileText = text.pendingText
            guard recognized.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            // 先按个人词表纠正专有名词，再交给可选的润色
            let (raw, fixes) = glossary.correct(recognized)
            let gap = lastEnd.map { s.start - $0 }
            let newPara = gap.map { $0 >= settings.paragraphGap } ?? false
            lastEnd = s.end
            let idx = segments.count
            segments.append(Segment(raw: Self.trimTail(raw), polished: nil, newParagraph: newPara, gap: gap))
            rebuild()
            Log.write(String(format: "定稿 [%.2f–%.2f s，%.0f ms]%@ %@", s.start, s.end, s.decodeMs, newPara ? " ¶" : "", recognized))
            for f in fixes { Log.write("词表纠正：\(f.original) → \(f.replacement)") }
            let prev = chain, polisher = self.polisher
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
                // 焦点不在能输入的地方（比如点在画布、列表上）：按键打出去也没处落，改成结束时拷到剪贴板
                if self.typing {
                    let f = Typist.focus()
                    if f.kind == .notEditable {
                        self.typing = false
                        Log.write("焦点不在输入框（\(f.role)），改为拷到剪贴板")
                    }
                }
                if self.typing {
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
        let (rest, fallback, gain): ([SentenceRecognizer.Sentence], Bool, Float) = await withCheckedContinuation { c in
            svQueue.async {
                let s = r?.flush() ?? []
                c.resume(returning: (s, r?.usedFallback ?? false, r?.adaptiveGain?.gainDb ?? 0))
            }
        }
        if fallback { Log.write("这次没切出句子，整段直接识别") }
        if gain > 0 { Log.write(String(format: "切句增益（结束时）%.1f dB", gain)) }
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
        if let t = startedAt {
            let secs = Int(Date().timeIntervalSince(t).rounded())
            Log.write("battery event=dictation seconds=\(secs) recorder=\(DeviceController.field(device.battery)) file=\(currentFile)")
        }
        startedAt = nil
        let evidence = currentFile == 0 ? nil : DictationDeletePolicy.Evidence(
            fileId: currentFile, startedByApp: appStart != nil, recordingBeforeStart: appStart?.recordingBefore,
            notifiedNew: notifiedNew, startedAt: appStart?.at ?? Date())
        appStart = nil
        notifiedNew = []
        // App 发的暂停只是暂停、文件还开着：文字已经交付，再发「结束录音」让录音豆收尾（暂停 → 结束，真机测过的顺序）。
        // 收尾后下次开始会新建文件，这次的文件也才删得掉。等到 1A/0A（最多 3 秒）再往下走，免得和删除抢。失败只写日志
        if pausedByApp, let s = device.session {
            do {
                let done = try await s.stopRecording()
                Log.write("已结束录音 file=\(currentFile)" + (done.map { $0 == currentFile ? "（收到 1A/0A）" : "（1A/0A 说的是 \($0)）" } ?? "（没等到 1A/0A）"))
            } catch {
                Log.write("结束录音失败 file=\(currentFile)：\(error)")
            }
        }
        pausedByApp = false
        if !finalText.isEmpty, settings.keepHistory {
            let since = listeningSince ?? Date()
            onEntry(DictationEntry(date: since, duration: Date().timeIntervalSince(since), text: finalText,
                                   app: targetApp, viaClipboard: deliveredByClipboard))
        }
        device.endDictation()
        phase = .idle
        onFinished(evidence)
    }
}
