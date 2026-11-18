// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OpenBeanLibrary
import OpenBeanVoice

/// 「认出我的声音」：标出转写里哪些句子是佩戴者说的（规则在 OpenBeanVoice 的 SpeakerID / Voiceprint / SpeakerPass）。
///
/// - 默认关，用户在心力模式设置里自己打开；声纹模型（28 MB）打开时才下载，没有模型就等于关着。
/// - 声纹存在 App 数据文件夹的 voiceprint.json（`AppPaths.support`，和 Library 文件夹平级，不在录音库里）：
///   MCP 服务只读 Library，笔记、导出、日记都不碰它；iOS 上不进 iCloud 备份。日志只记条数和用时。
/// - 每句的结果写在 transcript.json（wearerShare / wearerScore / isWearer）；每条录音扫没扫、结果如何记在 index.json 的 speakerScan。
/// - 新转写：转写时顺手算窗口（复用转写解码好的采样），转写完、切段之前判定。
/// - 补算：已经转写过、还没按当前声纹判定过的录音，重新解码音频算一遍（学习中也扫：长的心力模式录音能交候选）。
///   本机音频已经按保留设置删掉的录音记为 noAudio，不再管。
/// - 「忘掉我的声音」：删声纹文件、清掉所有句子的标签和扫描记录，并把开关关上。
@MainActor @Observable
final class SpeakerIdentity {
    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored weak var models: ModelStore?
    private let d = Flavor.defaults
    static let enabledKey = "recognizeMyVoice"

    /// 用户的开关
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            d.set(enabled, forKey: Self.enabledKey)
            Log.write(enabled ? "认出我的声音：打开" : "认出我的声音：关闭")
            if enabled { start() } else { stopBackfill() }
        }
    }
    private(set) var voiceprint: Voiceprint?
    /// 补算进度（只在补算时有值）
    private(set) var backfillProgress: (done: Int, total: Int)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 这次启动里补算失败过的录音（读不了音频之类），不反复重试
    @ObservationIgnored private var failed: Set<UInt32> = []

    static var fileURL: URL { AppPaths.support.appendingPathComponent("voiceprint.json") }

    init() {
        enabled = Flavor.defaults.bool(forKey: Self.enabledKey)
        voiceprint = Self.load()
    }

    var modelReady: Bool { FileManager.default.fileExists(atPath: AppPaths.models.appendingPathComponent(SpeakerEmbedder.modelPath).path) }
    /// 开着、模型也在：转写和补算才做
    var active: Bool { enabled && modelReady && !Flavor.isFake }
    /// 界面上显示标记：开着就显示（模型没了也显示已有的结果）
    var showsMarks: Bool { enabled }

    private static func load() -> Voiceprint? {
        guard let v = Voiceprint.read(fileURL) else { return nil }
        guard v.model == SpeakerEmbedder.modelName else {
            Log.write("认出我的声音：声纹是另一个模型算的，作废重学")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return v
    }

    private func save() {
        guard let v = voiceprint else { return }
        do {
            try v.write(Self.fileURL)
            #if os(iOS)
            // 生物特征数据：不进 iCloud 备份；后台同步时要能读，用「首次解锁后」的数据保护
            var u = Self.fileURL
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? u.setResourceValues(rv)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: u.path)
            #endif
        } catch {
            Log.write("认出我的声音：写声纹文件失败：\(error.localizedDescription)")
        }
    }

    /// App 启动、开关打开、模型下好之后
    func start() {
        guard enabled, !Flavor.isFake else { return }
        if !modelReady {
            Task { [weak self] in
                guard let self, let models = self.models else { return }
                await models.downloadSpeaker(wifiOnly: self.library?.settings.modelWifiOnly ?? false)
                if self.modelReady { self.startBackfill() }
            }
            return
        }
        startBackfill()
    }

    // MARK: 新转写

    /// 转写这条时要不要顺手算窗口
    func wantsWindows(_ r: Recording) -> Bool { active && !r.isDictation }

    /// 后台线程用：建扫描器（加载模型约 0.1 秒）；失败返回 nil，转写照常
    nonisolated static func makeScanner(models: URL) -> SpeakerScanner? {
        do { return try SpeakerScanner(modelsDir: models) } catch {
            Log.write("认出我的声音：声纹模型加载失败：\(error)")
            return nil
        }
    }

    /// 一条录音的窗口算完（主线程）：交候选、判定每句，必要时写声纹文件。关掉了（或忘掉了）返回 nil，句子不动
    func finish(_ r: Recording, windows: SpeakerWindows, candidate: SpeakerID.Candidate?,
                segments: inout [TranscriptSegment], seconds: Double) -> SpeakerScan? {
        guard active, let library else { return nil }
        var v = voiceprint ?? Voiceprint(dim: windows.dim)
        let wasReady = v.isReady
        let rec = SpeakerPass.Recording(id: r.id, day: library.dayBoundary.day(of: r.start),
                                        enrols: SpeakerPass.Recording.enrols(heart: r.recordingSource == .heart, duration: r.duration))
        let result = SpeakerPass.run(windows: windows, candidate: candidate, recording: rec, voiceprint: &v, segments: &segments)
        if result.voiceprintChanged || voiceprint == nil {
            voiceprint = v
            save()
        }
        let s = result.scan
        Log.write(String(format: "认出我的声音 %u：%d 窗口，%@，%@，%d 句中 %d 句为本人，用时 %.1f 秒",
                         r.id, windows.count, candidate.map { "主声音 \($0.windows) 窗口" } ?? "没有明显的主声音",
                         Self.describe(result), s.lines ?? 0, s.wearerLines ?? 0, seconds))
        if !wasReady, v.isReady {
            Log.write("认出我的声音：声纹已确认（\(v.recordings) 段录音、\(v.sampleCount) 个窗口），开始补算已有的录音")
            startBackfill()
        }
        return s
    }

    private static func describe(_ r: SpeakerPass.Result) -> String {
        switch r.event {
        case .stored?: return "交了候选（学习中）"
        case .confirmed?: return "声纹确认"
        case .agrees?: return "主声音是本人，慢更新"
        case .differs?: return "主声音不是本人，不更新"
        case nil: return r.scan.outcome == .learning ? "学习中（这段不登记）" : (r.worn == .notWorn ? "录音豆没戴" : "按声纹判定")
        }
    }

    // MARK: 补算

    /// 还要扫的录音（新的在前）
    private func targets() -> [Recording] {
        guard let library else { return [] }
        return library.recordings.filter {
            $0.transcribed && !$0.isDictation && library.transcribing[$0.id] == nil && !failed.contains($0.id)
                && SpeakerScan.needsScan($0.speakerScan, current: voiceprint)
        }
    }

    func startBackfill() {
        guard active, task == nil, !targets().isEmpty else { return }
        task = Task { [weak self] in
            await self?.runBackfill()
            self?.task = nil
            self?.backfillProgress = nil
        }
    }

    private func stopBackfill() {
        task?.cancel()
        task = nil
        backfillProgress = nil
    }

    private func runBackfill() async {
        let t0 = Date()
        var scanned = 0, noAudio = 0, hours = 0.0
        let models = AppPaths.models
        backfillProgress = (0, targets().count)
        while !Task.isCancelled, active, let library, let r = targets().first {
            let total = (backfillProgress?.done ?? 0) + targets().count
            backfillProgress = (backfillProgress?.done ?? 0, total)
            let audio = library.audioURL(r.id)
            guard !r.audioRemoved, FileManager.default.fileExists(atPath: audio.path) else {
                library.storeSpeakerResult(r.id, segments: nil, scan: SpeakerScan(outcome: .noAudio))
                noAudio += 1
                backfillProgress = ((backfillProgress?.done ?? 0) + 1, total)
                continue
            }
            let segs = library.transcript(r.id)
            let times = segs.map { ($0.start, $0.end) }
            let t1 = Date()
            let computed: (SpeakerWindows, SpeakerID.Candidate?)? = await Task.detached(priority: .utility) {
                guard let scanner = Self.makeScanner(models: models) else { return nil }
                var slicer = SentenceAudioSlicer(times: times)
                do {
                    try AudioFile16k.read(audio) { chunk, _ in
                        guard !Task.isCancelled else { throw CancellationError() }
                        slicer.feed(chunk) { scanner.add(sentence: $0, samples: $1) }
                    }
                } catch {
                    if !(error is CancellationError) { Log.write("认出我的声音：补算 \(r.id) 读音频失败：\(error.localizedDescription)") }
                    return nil
                }
                slicer.finish { scanner.add(sentence: $0, samples: $1) }
                return (scanner.windows, SpeakerID.loudCandidate(scanner.windows))
            }.value
            guard !Task.isCancelled, active else { break }
            guard let (windows, candidate) = computed else { failed.insert(r.id); continue }
            // 算的时候转写变了（重新转写了）：下一轮再来
            var current = library.transcript(r.id)
            guard current.count == segs.count, zip(current, segs).allSatisfy({ $0.start == $1.start && $0.end == $1.end }),
                  let fresh = library.recordings.first(where: { $0.id == r.id }) else { continue }
            if let scan = finish(fresh, windows: windows, candidate: candidate, segments: &current, seconds: Date().timeIntervalSince(t1)) {
                library.storeSpeakerResult(r.id, segments: current, scan: scan)
            }
            scanned += 1
            hours += r.duration / 3600
            backfillProgress = ((backfillProgress?.done ?? 0) + 1, total)
        }
        if scanned + noAudio > 0 {
            Log.write(String(format: "认出我的声音：补算 %d 条录音（%.1f 小时），%d 条本机音频已删、没法算，用时 %.0f 秒",
                             scanned, hours, noAudio, Date().timeIntervalSince(t0)))
        }
    }

    // MARK: 忘掉

    /// 删掉声纹、清掉所有句子的标签和扫描记录，并关上开关
    func forget() {
        stopBackfill()
        enabled = false
        try? FileManager.default.removeItem(at: Self.fileURL)
        voiceprint = nil
        failed = []
        guard let library else { return }
        let ids = library.recordings.map(\.id)
        let urls = ids.map { library.transcriptURL($0) }
        Task { [weak self] in
            let changed = await Task.detached(priority: .userInitiated) { () -> [Int] in
                var out: [Int] = []
                for (k, url) in urls.enumerated() {
                    guard let d = try? Data(contentsOf: url),
                          var segs = try? JSONDecoder().decode([TranscriptSegment].self, from: d),
                          segs.contains(where: { $0.isWearer != nil || $0.wearerShare != nil }) else { continue }
                    for i in segs.indices { segs[i].clearWearer() }
                    if let e = try? JSONEncoder().encode(segs), (try? e.write(to: url, options: .atomic)) != nil { out.append(k) }
                }
                return out
            }.value
            guard let library = self?.library else { return }
            library.clearSpeakerScans(changed.map { ids[$0] })
            Log.write("认出我的声音：已忘掉声纹，清掉了 \(changed.count) 条录音的标签")
        }
    }

    // MARK: 状态（设置页显示）

    enum Status: Equatable {
        case off
        case needsModel
        case downloadingModel(Double)
        case modelFailed(String)
        /// 学习中：已经有几段候选、来自几天
        case learning(candidates: Int, days: Int)
        case ready(since: Date, recordings: Int)
    }

    var status: Status {
        guard enabled else { return .off }
        if !modelReady {
            switch models?.speaker {
            case let .downloading(p)?: return .downloadingModel(p)
            case let .failed(e)?: return .modelFailed(e)
            default: return .needsModel
            }
        }
        guard let v = voiceprint, v.isReady, let since = v.confirmedAt else {
            let p = voiceprint?.pending ?? []
            return .learning(candidates: p.count, days: Set(p.map(\.day)).count)
        }
        return .ready(since: since, recordings: v.recordings)
    }
}
