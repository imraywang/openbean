// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OpenBeanLibrary
import OpenBeanVoice

/// 每日日记：段摘要（写回 segments.json）→ 当天日记（Library/days/<日期>/day.json）→ 日记笔记（笔记文件夹/日记/<日期>.md）。
///
/// - 只在设置「每天写一篇日记」开着时做；切段（ConversationStore）不管开关、不花钱，照常做。
/// - 所有大模型调用排在 NoteService 的队列里，和整条录音的摘要一个一个来。
/// - 增量：段摘要只给还没有的段写（转写改了只有文字变了的段会丢掉旧摘要）；一天的输入（段的指纹和段摘要）
///   没变就不重算日记，所以过去的日子不会反复调用大模型。什么时候算：一条录音转写完 / 重新摘要 / 词表改了字之后，
///   算它涉及的那几天；App 启动和打开开关时算今天和昨天；「今天」页可以手动算某一天。
/// - 失败（服务没开、超时、回复不可用）：已经写好的段摘要留着（每段是完整的），当天日记不写半成品，写日志，下次再试。
@MainActor @Observable
final class DiaryService {
    @ObservationIgnored weak var notes: NoteService?
    @ObservationIgnored private let settings: Settings
    /// 日文件变了就加 1
    private(set) var revision = 0
    /// 正在写日记的天（yyyy-MM-dd）
    private(set) var working: Set<String> = []
    @ObservationIgnored private var cache: [String: DayFile] = [:]
    @ObservationIgnored private var missing: Set<String> = []

    init(settings: Settings) {
        self.settings = settings
    }

    private var library: LibraryStore? { notes?.library }
    var boundary: DayBoundary { DayBoundary(startHour: settings.dayStartHour) }
    func key(_ day: Date) -> String { DayFile.key(day, calendar: boundary.calendar) }

    // MARK: 读

    /// 某一天（DayBoundary.day(of:) 给的那天 0 点）的日文件。「一天从几点开始」改过之后写的旧文件不算
    func day(_ day: Date) -> DayFile? {
        _ = revision
        let k = key(day)
        let f: DayFile?
        if let c = cache[k] { f = c } else if missing.contains(k) { f = nil } else {
            f = DayFile.read(DayFile.url(library: AppPaths.library, date: k))
            if let f { cache[k] = f } else { missing.insert(k) }
        }
        guard let f, f.dayStartHour == settings.dayStartHour else { return nil }
        return f
    }

    // MARK: 段摘要

    /// 给这条录音还没有段摘要的段写段摘要（force：全部重写）。全部写完返回 true；服务不可用或出错返回 false（写日志）
    @discardableResult
    func summarizeConversations(_ id: UInt32, force: Bool) async -> Bool {
        do { try await summarize(id, force: force); return true } catch {
            Log.write("段摘要 \(id) 没写完：\(error)，下次再试")
            return false
        }
    }

    private func summarize(_ id: UInt32, force: Bool) async throws {
        guard let library, let notes, let r = library.recordings.first(where: { $0.id == id }), r.transcribed, !r.isDictation else { return }
        let todo = library.conversations.conversations(id).filter { force || $0.kind == nil }
        guard !todo.isEmpty else { return }
        guard let service = notes.service else { throw URLError(.badURL) }
        guard await service.check() == .ok else { throw URLError(.cannotConnectToHost) }
        let segs = library.transcript(id)
        let summarizer = ConversationSummarizer(await notes.summarizer(service))
        let t0 = Date()
        var calls = 0, dropped = 0
        let spans = segs.map { (start: $0.start, end: $0.end) }
        for c in todo where c.to <= segs.count {
            // 用户在这段里做了重点标记的句子：送给模型的转写里注明（下标相对这段）
            // 录音豆在录时用语音输入说的句子（Conversation.voiceTyping）不送给模型
            let spoken = c.spokenLines
            guard !spoken.isEmpty else { continue }
            let markedLines = Set(c.marks.compactMap { MarkPlacement.line(for: $0, spans: spans) })
            let marked = Set(spoken.enumerated().filter { markedLines.contains($0.element) }.map(\.offset))
            let res = try await summarizer.summarize(spoken.map { TimedLine(start: segs[$0].start, text: segs[$0].text) }, marked: marked)
            calls += res.calls
            dropped += res.droppedNames
            library.conversations.setSummary(id, index: c.index, hash: c.hash, kind: res.kind, summary: res.summary,
                                             model: settings.polishModel)
        }
        Log.write(String(format: "段摘要 %u：%d 段，%d 次调用，%.0f 秒，丢掉转写里找不到的名字 %d 个",
                         id, todo.count, calls, Date().timeIntervalSince(t0), dropped))
    }

    /// 开着日记时整条录音的摘要：以段摘要为准。一段直接用；多段时用合并提示词合成一份（一次调用）
    func recordingSummary(_ id: UInt32, force: Bool) async throws -> RecordingSummary {
        try await summarize(id, force: force)
        guard let library, let notes, let service = notes.service else { throw URLError(.badURL) }
        let parts = library.conversations.conversations(id).compactMap(\.summary)
            .map { RecordingSummary(title: $0.title, summary: $0.summary, keyPoints: $0.keyPoints, actionItems: $0.todos) }
        guard !parts.isEmpty else { throw Summarizer.Failure.tooShort }
        let sample = String(library.transcript(id).map(\.text).joined().prefix(4000))
        return try await notes.summarizer(service).merge(parts, languageSample: sample).0
    }

    // MARK: 日

    /// 这条录音涉及的那几天（按段归天，再加上以前的日文件里引用过它的天）重算日记。
    /// 返回汇总的结果（心力模式页的四步条用）：哪天服务不通就算服务不通，哪天没写成就算没写成
    @discardableResult
    func refreshDays(touching id: UInt32) async -> SyncRun.DiaryResult {
        guard settings.mode.writesDiary, let library else { return .written }
        var keys = Set(DayAssignment.days(of: library.conversations.conversations(id), boundary: boundary).keys)
        keys.formUnion(daysReferencing(id))
        var results: [SyncRun.DiaryResult] = []
        for k in keys.sorted() { results.append(await refreshDay(k)) }
        if results.contains(.serviceUnavailable) { return .serviceUnavailable }
        if results.contains(.failed) { return .failed }
        return .written
    }

    /// 没写成时分清是服务不通还是别的原因
    private func failure() async -> SyncRun.DiaryResult {
        await notes?.serviceReachable() == true ? .failed : .serviceUnavailable
    }

    /// 启动、打开开关时：今天和昨天（排进队列；先等切段补算跑完）
    func catchUp() {
        guard settings.mode.writesDiary, let notes, let library else { return }
        let today = boundary.day(of: Date())
        let keys = [key(boundary.day(today, offsetBy: -1)), key(today)]
        notes.enqueue { [weak self] in
            await library.conversations.waitForBackfill()
            for k in keys { await self?.refreshDay(k) }
        }
    }

    /// 「今天」页手动：重算某一天（排进队列）
    func requestDay(_ day: Date) {
        let k = key(day)
        notes?.enqueue { [weak self] in await self?.refreshDay(k, force: true) }
    }

    /// 删了某条录音的本机副本：引用过它的那几天重算
    func recordingRemoved(_ id: UInt32) {
        guard settings.mode.writesDiary else { return }
        let keys = daysReferencing(id)
        guard !keys.isEmpty else { return }
        notes?.enqueue { [weak self] in for k in keys.sorted() { await self?.refreshDay(k) } }
    }

    private func daysReferencing(_ id: UInt32) -> Set<String> {
        let dir = AppPaths.library.appendingPathComponent("days")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { name in
            let f = cache[name] ?? DayFile.read(DayFile.url(library: AppPaths.library, date: name))
            return f?.conversations.contains { $0.ref.recording == id } ?? false
        })
    }

    /// 当天的段：开始时刻落在这一天里的（录音最早可以从前一天开始）
    private func gather(_ interval: DateInterval) -> [(Recording, Conversation)] {
        guard let library else { return [] }
        var out: [(Recording, Conversation)] = []
        for r in library.recordings where r.transcribed && !r.isDictation
            && r.start < interval.end && r.start >= interval.start.addingTimeInterval(-86_400) {
            for c in library.conversations.conversations(r.id) where c.wallStart >= interval.start && c.wallStart < interval.end {
                out.append((r, c))
            }
        }
        return out.sorted { $0.1.wallStart < $1.1.wallStart }
    }

    /// 重算某一天的日记。返回 .written 也包括「输入没变，不用重写」和「这天已经没有录音」
    @discardableResult
    func refreshDay(_ key: String, force: Bool = false) async -> SyncRun.DiaryResult {
        guard settings.mode.writesDiary, let library, let notes, let day0 = DayFile.day(key, calendar: boundary.calendar) else { return .written }
        let url = DayFile.url(library: AppPaths.library, date: key)
        var included = gather(boundary.interval(of: day0))
        guard !included.isEmpty else {
            // 这天的录音都删了：日文件跟着去掉（知识库里的日记笔记不动）
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                Log.write("日记 \(key)：已经没有录音，去掉日文件")
            }
            cache[key] = nil
            missing.insert(key)
            revision += 1
            return .written
        }
        // 先把段摘要补齐；没补齐就不写（不写半成品）
        for id in Set(included.filter { $0.1.kind == nil }.map(\.0.id)).sorted() {
            guard await summarizeConversations(id, force: false) else {
                Log.write("日记 \(key)：段摘要没写完，下次再试")
                return await failure()
            }
        }
        included = gather(boundary.interval(of: day0))
        let sig = DayFile.signature(included.map { r, c in
            let s = (try? JSONEncoder().encode(c.summary)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return "\(r.id)#\(c.index)|\(c.hash)|\(c.kind ?? "")|\(s)|marks=\(c.marks)"
        } + ["diary-v1", "start=\(settings.dayStartHour)", "tz=\(TimeZone.current.identifier)"])
        if !force, let old = DayFile.read(url), old.version == DayFile.currentVersion, old.signature == sig {
            if notes.notesFolder != nil, noteRecord(key) == nil { writeNote(old) }
            return .written
        }
        guard let service = notes.service, await service.check() == .ok else {
            Log.write("日记 \(key)：服务不可用，下次再试")
            return .serviceUnavailable
        }
        working.insert(key)
        defer { working.remove(key) }
        let t0 = Date()
        // 当天的重点标记：每个标记的时刻、所在的段和前后的原话（代码摘，不经大模型）
        let marks = Dictionary(grouping: included, by: { $0.0.id }).flatMap { id, items -> [DiaryMark] in
            let t = library.transcript(id)
            return DiaryMark.collect(recording: id, recordingStart: items[0].0.start, conversations: items.map(\.1),
                                     spans: t.map { ($0.start, $0.end) }, texts: t.map(\.text))
        }.sorted { $0.wall < $1.wall }
        let inputs = included.map { r, c in
            DiaryWriter.Input(ref: ConversationRef(recording: r.id, index: c.index), wallStart: c.wallStart, wallEnd: c.wallEnd,
                              kind: c.kind, summary: c.summary,
                              chars: library.transcript(r.id)[c.lines.clamped(to: 0..<library.transcript(r.id).count)].reduce(0) { $0 + $1.text.count },
                              marks: marks.filter { $0.ref.recording == r.id && $0.ref.index == c.index }.map { $0.quote.joined(separator: " ") }
                                  .filter { !$0.isEmpty })
        }
        let sample = String(included.flatMap { r, c in
            let t = library.transcript(r.id)
            return t[c.lines.clamped(to: 0..<t.count)].map(\.text)
        }.joined().prefix(4000))
        let out: DiaryWriter.Output
        do {
            out = try await DiaryWriter(await notes.summarizer(service)).write(inputs, languageSample: sample)
        } catch {
            Log.write("日记 \(key) 没写成：\(error)，下次再试")
            return await failure()
        }
        let secs = Date().timeIntervalSince(t0)
        let day = DayFile(date: key, timeZone: TimeZone.current.identifier, dayStartHour: settings.dayStartHour, signature: sig,
                          status: out.status,
                          conversations: included.map { r, c in
                              DayConversation(ref: ConversationRef(recording: r.id, index: c.index), wallStart: c.wallStart,
                                              wallEnd: c.wallEnd, wallApprox: c.wallApprox, kind: c.kind,
                                              title: c.summary?.title, summary: c.summary?.summary)
                          },
                          diary: out.diary, model: settings.polishModel, createdAt: Date(),
                          stats: DayStats(calls: out.calls, seconds: secs, dropped: out.dropped), marks: marks)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try day.encoded().write(to: url, options: .atomic)
        } catch {
            Log.write("写日文件失败 \(key)：\(error)")
            return .failed
        }
        cache[key] = day
        missing.remove(key)
        revision += 1
        Log.write(String(format: "已写日记 %@：%d 段，%@，%d 次调用，%.0f 秒，丢掉出处对不上的 %d 条、重复的 %d 条、不认的负责人 %d 个",
                         key, included.count, out.status.rawValue, out.calls, secs, out.dropped, out.duplicates, out.droppedOwners))
        writeNote(day)
        return .written
    }

    // MARK: 日记笔记

    private func noteRecordURL(_ key: String) -> URL { DayFile.folder(library: AppPaths.library, date: key).appendingPathComponent("note.json") }

    private func noteRecord(_ key: String) -> NoteRecord? {
        guard let d = try? Data(contentsOf: noteRecordURL(key)) else { return nil }
        return try? JSONDecoder().decode(NoteRecord.self, from: d)
    }

    /// 日记笔记所在的文件夹：设置里的相对路径（规则见 DiaryNote.folder）；不合规时用默认的子文件夹
    var noteFolder: URL? {
        guard let dir = notes?.notesFolder else { return nil }
        return DiaryNote.folder(settings.diaryFolder, notesFolder: dir, defaultName: String(localized: "Diary"))
            ?? DiaryNote.folder("", notesFolder: dir, defaultName: String(localized: "Diary"))
    }

    /// 设置里填的日记文件夹不合规（跑到笔记文件夹的上一级以外、绝对路径等）
    var diaryFolderInvalid: Bool {
        guard let dir = notes?.notesFolder else { return false }
        return DiaryNote.folder(settings.diaryFolder, notesFolder: dir, defaultName: "Diary") == nil
    }

    /// 日记笔记的小节标题，跟着 App 的语言
    static var labels: DiaryNote.Labels {
        DiaryNote.Labels(overview: String(localized: "Overview of the day"), decisions: String(localized: "Decided"),
                         todos: String(localized: "To-dos"), peopleAndThings: String(localized: "People and things mentioned"),
                         people: String(localized: "People"), things: String(localized: "Things"),
                         conversations: String(localized: "Conversations"), transcript: String(localized: "Transcript"),
                         media: String(localized: "media"), marks: String(localized: "Marked moments"))
    }

    /// 写（或重写）某天的日记笔记。规则同逐条笔记：没被改过就原地覆盖；用户改过就不动它，另写一份
    func writeNote(_ day: DayFile) {
        guard settings.mode.writesDiary, let notes, let folder = noteFolder else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var target: URL?
        if let rec = noteRecord(day.date) {
            let old = URL(fileURLWithPath: rec.path)
            if old.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path, fm.fileExists(atPath: old.path) {
                let mod = (try? fm.attributesOfItem(atPath: old.path)[.modificationDate] as? Date) ?? .distantPast
                if NoteRules.existing(edited: NoteRules.edited(modified: mod, writtenAt: rec.writtenAt), mode: .auto) == .newFile { Log.write("日记笔记被改过，另写一份：\(old.lastPathComponent)") } else { target = old }
            }
        }
        if target == nil {
            var name = "\(day.date).md", n = 2
            while fm.fileExists(atPath: folder.appendingPathComponent(name).path) { name = "\(day.date)-\(n).md"; n += 1 }
            target = folder.appendingPathComponent(name)
        }
        guard let url = target else { return }
        var links: [ConversationRef: String] = [:]
        for c in day.conversations {
            links[c.ref] = notes.noteURL(c.ref.recording).map { DiaryNote.relativeLink(from: folder, to: $0) } ?? "openbean://open/\(c.ref.recording)"
        }
        let ids = Array(Set(day.conversations.map(\.ref.recording))).sorted()
        let spoken = day.conversations.reduce(0.0) { $0 + max($1.wallEnd.timeIntervalSince($1.wallStart), 0) }
        let frozen = links
        let text = DiaryNote.render(.init(day: day, recordedSeconds: spoken, recordings: ids, labels: Self.labels) {
            frozen[$0] ?? "openbean://open/\($0.recording)"
        })
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.write("写日记笔记失败 \(day.date)：\(error)")
            return
        }
        let mod = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        if let d = try? JSONEncoder().encode(NoteRecord(path: url.path, writtenAt: mod)) { try? d.write(to: noteRecordURL(day.date), options: .atomic) }
        Log.write("已写日记笔记 \(day.date)：\(url.lastPathComponent)")
    }
}
