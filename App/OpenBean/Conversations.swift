// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OpenBeanLibrary
import OpenBeanVoice

/// 每条录音按停顿切成的对话段（`<id>/segments.json`，格式和切段规则见 OpenBeanLibrary 的 ConversationFile、Segmenter）。
///
/// - 什么时候算：转写完成（含重新转写）和词表回填改了转写之后，立刻重算这一条（在写笔记之前，笔记要用段）；
///   App 启动后在后台把所有已转写的录音过一遍，文件缺了、过时了（转写比它新、规则或参数变了）才重算。
/// - 不用大模型、不花钱，跟「每天写一篇日记」开不开无关。语音输入片段不切。
/// - 删本机副本时文件跟着录音文件夹一起删，这里只丢缓存。
@MainActor @Observable
final class ConversationStore {
    @ObservationIgnored weak var library: LibraryStore?
    /// 界面读段时依赖它：哪条录音的段变了就加 1
    private(set) var revision = 0
    @ObservationIgnored private var cache: [UInt32: ConversationFile] = [:]
    @ObservationIgnored private var missing: Set<UInt32> = []
    /// 每条录音的段被重算 / 丢掉的次数：后台补算回来时据此判断结果是不是已经过时
    @ObservationIgnored private var generation: [UInt32: Int] = [:]
    @ObservationIgnored private var backfillTask: Task<Void, Never>?

    nonisolated static func url(_ id: UInt32) -> URL {
        AppPaths.library.appendingPathComponent(String(id)).appendingPathComponent("segments.json")
    }

    /// 这条录音的对话段（没算过、没转写时为空）
    func conversations(_ id: UInt32) -> [Conversation] {
        _ = revision
        if let f = cache[id] { return f.segments }
        if missing.contains(id) { return [] }
        if let f = ConversationFile.read(Self.url(id)) {
            cache[id] = f
            return f.segments
        }
        missing.insert(id)
        return []
    }

    /// 按当前转写重算这一条并写盘（转写完成、词表回填之后调用）。很快：几千句也只是一遍线性扫描加一次哈希
    func refresh(_ id: UInt32) {
        guard let library, let r = library.recordings.first(where: { $0.id == id }), !r.isDictation, r.transcribed else { return }
        let lines = library.transcript(id).map { ConversationFile.Line(start: $0.start, end: $0.end, text: $0.text) }
        let previous = cache[id] ?? ConversationFile.read(Self.url(id))
        let f = ConversationFile.build(lines, recordingStart: r.start,
                                       wallApprox: ConversationFile.likelyPaused(start: r.start, end: r.end, duration: r.duration),
                                       previous: previous, marks: library.marks(id))
        store(f, id)
        Log.write("切段 \(id)：\(f.segments.count) 段")
    }

    /// 写回一段的段摘要。等大模型的时候转写可能变了：段号和这段的指纹都还对得上才写，返回写没写
    @discardableResult
    func setSummary(_ id: UInt32, index: Int, hash: String, kind: String, summary: ConversationSummary?, model: String) -> Bool {
        guard var f = cache[id] ?? ConversationFile.read(Self.url(id)),
              let i = f.segments.firstIndex(where: { $0.index == index && $0.hash == hash }) else { return false }
        f.segments[i].kind = kind
        f.segments[i].summary = summary
        f.segments[i].summaryModel = model
        f.segments[i].summarizedAt = Date()
        store(f, id)
        return true
    }

    /// 等启动后的补算跑完（日记要用补算出来的段）
    func waitForBackfill() async { await backfillTask?.value }

    /// 删了本机副本
    func forget(_ id: UInt32) {
        cache[id] = nil
        missing.remove(id)
        generation[id, default: 0] += 1
        revision += 1
    }

    private func store(_ f: ConversationFile, _ id: UInt32) {
        do {
            try f.encoded().write(to: Self.url(id), options: .atomic)
        } catch {
            Log.write("写 segments.json 失败 \(id)：\(error)")
        }
        cache[id] = f
        missing.remove(id)
        generation[id, default: 0] += 1
        revision += 1
    }

    // MARK: 启动后补算

    /// 后台把已转写的录音过一遍：segments.json 缺了或过时了才重算。再调用一次会中断正在跑的那遍、重新开始
    func backfill() {
        let previous = backfillTask
        previous?.cancel()
        backfillTask = Task { [weak self] in
            await previous?.value
            await self?.runBackfill()
        }
    }

    private func runBackfill() async {
        guard let library else { return }
        let t0 = Date()
        let targets = library.recordings.filter { $0.transcribed && !$0.isDictation }
        var redone = 0
        for r in targets {
            if Task.isCancelled {
                Log.write("切段补算：中断，已重算 \(redone) 条")
                return
            }
            // 正在转写的这条，转写完会自己算
            if library.transcribing[r.id] != nil { continue }
            let gen = generation[r.id, default: 0]
            let id = r.id, start = r.start
            let approx = ConversationFile.likelyPaused(start: r.start, end: r.end, duration: r.duration)
            let result = await Task.detached(priority: .utility) {
                Self.rebuildIfStale(id: id, start: start, wallApprox: approx)
            }.value
            // 等的时候这条被重算或删掉了：以那次为准
            guard let f = result, generation[id, default: 0] == gen,
                  library.recordings.contains(where: { $0.id == id && $0.transcribed }) else { continue }
            store(f, id)
            redone += 1
        }
        Log.write(String(format: "切段补算：%d 条已转写的录音，重算 %d 条，用时 %.1f 秒",
                         targets.count, redone, Date().timeIntervalSince(t0)))
    }

    /// 过时了就返回要写的一份（不写盘），没过时返回 nil。
    /// 先只看文件：segments.json 比 transcript.json 新、规则和参数也一样，就不读转写
    nonisolated static func rebuildIfStale(id: UInt32, start: Date, wallApprox: Bool) -> ConversationFile? {
        let fm = FileManager.default
        let tURL = AppPaths.library.appendingPathComponent(String(id)).appendingPathComponent("transcript.json")
        let sURL = url(id)
        func mtime(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        guard let tTime = mtime(tURL) else { return nil }
        let old = ConversationFile.read(sURL)
        if let old, let sTime = mtime(sURL), sTime >= tTime, old.version == ConversationFile.currentVersion,
           old.segmenter == Segmenter.version, old.params == .standard {
            return nil
        }
        guard let d = try? Data(contentsOf: tURL), let segs = try? JSONDecoder().decode([TranscriptSegment].self, from: d) else { return nil }
        let lines = segs.map { ConversationFile.Line(start: $0.start, end: $0.end, text: $0.text) }
        // 内容没变、只是文件时间旧了（比如转写被原样重写）：原样再写一遍，下次启动就不用再读转写
        if let old, old.isCurrent(transcriptHash: ConversationFile.fingerprint(lines)) { return old }
        let marks = RecordingMarks.read(AppPaths.library.appendingPathComponent(String(id))
            .appendingPathComponent(RecordingMarks.fileName))?.marks ?? []
        return ConversationFile.build(lines, recordingStart: start, wallApprox: wallApprox, previous: old, marks: marks)
    }
}

extension Conversation {
    /// 「09:12–09:40」；时间只是近似时前面加「约」
    var clockRange: String {
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        let s = "\(wallStart.formatted(f))–\(wallEnd.formatted(f))"
        return wallApprox ? String(localized: "about \(s)") : s
    }
}
