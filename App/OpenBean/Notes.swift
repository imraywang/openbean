// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation
import OpenBeanVoice
import SwiftUI

/// 存在录音文件夹里的摘要（summary.json）
struct StoredSummary: Codable, Sendable {
    var summary: RecordingSummary
    var createdAt: Date
    var model: String
    /// 摘要自动填进去的标题；用户没改过标题时，重新摘要会换成新标题
    var appliedTitle: String?
}

/// 这条录音写到知识库里的笔记（note.json）：路径和写入后的修改时间
struct NoteRecord: Codable {
    var path: String
    var writtenAt: Date
}

/// 录音摘要 + 知识库笔记。
/// 任务排成一队依次执行，免得同时下载的几条录音一起压到本机模型上。
///
/// 覆盖规则：记下每条笔记写入后的修改时间。之后再写（重新摘要、自动写入、补写）时，
/// 文件没被改过就原地覆盖；文件被用户改过（修改时间晚于记录 2 秒以上）就不动它，另写一份新文件
/// （同名规则加 -HHmm），并改为记住新文件。手动「保存笔记」遇到改过的文件会先问：替换还是另存。
@MainActor @Observable
final class NoteService {
    /// 正在摘要的录音 → 进度（0…1）
    private(set) var summarizing: [UInt32: Double] = [:]
    /// 手动摘要失败的原因（自动摘要失败只写日志）
    private(set) var errors: [UInt32: String] = [:]
    /// 补写笔记的进度
    private(set) var backfill: (done: Int, total: Int)?
    /// 摘要变了就加一，界面靠它刷新（缓存本身不参与观察，免得在界面刷新时改状态）
    private(set) var revision = 0
    @ObservationIgnored private var summaries: [UInt32: StoredSummary] = [:]
    /// 没有摘要的录音（免得每次刷新都去读磁盘）
    @ObservationIgnored private var noSummary: Set<UInt32> = []

    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private var queue: Task<Void, Never>?

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: 存取

    private func summaryURL(_ id: UInt32) -> URL? { library?.folder(id).appendingPathComponent("summary.json") }
    private func noteRecordURL(_ id: UInt32) -> URL? { library?.folder(id).appendingPathComponent("note.json") }

    func summary(_ id: UInt32) -> RecordingSummary? {
        _ = revision
        return stored(id)?.summary
    }

    private func stored(_ id: UInt32) -> StoredSummary? {
        if let s = summaries[id] { return s }
        if noSummary.contains(id) { return nil }
        guard let url = summaryURL(id), let d = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(StoredSummary.self, from: d) else { noSummary.insert(id); return nil }
        summaries[id] = s
        return s
    }

    /// 只看缓存，不读盘（侧栏数字、「今天」这类一次要看很多条的地方用；配合 preload）
    func cachedSummary(_ id: UInt32) -> RecordingSummary? {
        _ = revision
        return summaries[id]?.summary
    }

    /// 在后台把这些录音的 summary.json 读进缓存，读完刷新一次界面。已经在缓存里（或确定没有）的跳过
    func preload(_ ids: [UInt32]) {
        let todo = ids.filter { summaries[$0] == nil && !noSummary.contains($0) && !preloading.contains($0) }
        guard !todo.isEmpty else { return }
        preloading.formUnion(todo)
        let root = AppPaths.library
        Task.detached(priority: .utility) {
            var found: [UInt32: StoredSummary] = [:]
            for id in todo {
                let url = root.appendingPathComponent(String(id)).appendingPathComponent("summary.json")
                if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(StoredSummary.self, from: d) { found[id] = s }
            }
            await MainActor.run {
                for id in todo {
                    self.preloading.remove(id)
                    // 读盘期间刚生成的新摘要优先
                    if self.summaries[id] == nil {
                        if let s = found[id] { self.summaries[id] = s } else { self.noSummary.insert(id) }
                    }
                }
                self.revision += 1
            }
        }
    }
    @ObservationIgnored private var preloading: Set<UInt32> = []

    private func noteRecord(_ id: UInt32) -> NoteRecord? {
        guard let url = noteRecordURL(id), let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NoteRecord.self, from: d)
    }

    /// 删除本机副本时调用（summary.json / note.json 跟着录音文件夹一起删了；知识库里的笔记不动）
    func forget(_ id: UInt32) {
        summaries[id] = nil
        noSummary.remove(id)
        errors[id] = nil
        revision += 1
    }

    var notesFolder: URL? {
        let p = settings.notesFolder
        guard !p.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    private var service: LLMService? {
        URL(string: settings.polishEndpoint).map { LLMService(endpoint: $0, apiKey: settings.polishAPIKey, model: settings.polishModel) }
    }

    func canSummarize(_ r: Recording) -> Bool {
        !r.isDictation && r.transcribed && !(library?.transcript(r.id).isEmpty ?? true)
    }

    // MARK: 队列

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let prev = queue
        queue = Task { @MainActor in
            await prev?.value
            await job()
        }
    }

    /// 转写完成后：按设置自动摘要、写笔记（语音输入片段不处理）
    func afterTranscription(_ id: UInt32) {
        guard let r = library?.recordings.first(where: { $0.id == id }), !r.isDictation else { return }
        guard settings.summarizeRecordings || settings.notesEnabled else { return }
        enqueue { [weak self] in
            guard let self else { return }
            if self.settings.summarizeRecordings { await self.runSummary(id, manual: false) }
            if self.settings.notesEnabled { _ = self.writeNote(id, mode: .auto) }
        }
    }

    /// 转写文字变了（词表回填）：写过的笔记、用户没改过就重写；没写过、或改过的都不动。不重新摘要
    func transcriptChanged(_ id: UInt32) {
        guard noteRecord(id) != nil else { return }
        enqueue { [weak self] in _ = self?.writeNote(id, mode: .refresh) }
    }

    /// 「摘要」/「重新摘要」；写过笔记（或开着自动笔记）就顺手更新笔记
    func summarize(_ id: UInt32) {
        guard summarizing[id] == nil else { return }
        summarizing[id] = 0
        errors[id] = nil
        enqueue { [weak self] in
            guard let self else { return }
            await self.runSummary(id, manual: true)
            if self.settings.notesEnabled || self.noteRecord(id) != nil { _ = self.writeNote(id, mode: .auto) }
        }
    }

    // MARK: 摘要

    private func runSummary(_ id: UInt32, manual: Bool) async {
        defer { summarizing[id] = nil }
        guard let library, let r = library.recordings.first(where: { $0.id == id }), canSummarize(r) else { return }
        let lines = library.transcript(id).map { TimedLine(start: $0.start, text: $0.text) }
        guard let service else { fail(id, manual, String(localized: "The server address in Clean-up is not valid.")); return }
        let status = await service.check()
        guard status == .ok else {
            if manual {
                fail(id, manual, status == .unauthorized ? String(localized: "The LLM service rejected the API key.")
                                                         : String(localized: "The LLM service is not reachable. Check Settings → Clean-up."))
            } else {
                Log.write("跳过摘要 \(id)：服务不可用（\(status)）")
            }
            return
        }
        summarizing[id] = 0.02
        let t0 = Date()
        do {
            let s = try await Summarizer(service: service, glossary: AppPaths.readGlossary()).summarize(lines) { p in
                Task { @MainActor [weak self] in
                    if self?.summarizing[id] != nil { self?.summarizing[id] = max(p, 0.02) }
                }
            }
            let old = stored(id)
            var stored = StoredSummary(summary: s, createdAt: Date(), model: settings.polishModel, appliedTitle: old?.appliedTitle)
            // 没有用户自己起的标题（或者标题就是上次摘要给的）时，用生成的标题
            if !s.title.isEmpty, r.title?.isEmpty ?? true || r.title == old?.appliedTitle {
                library.rename(id, to: s.title)
                stored.appliedTitle = s.title
            }
            summaries[id] = stored
            noSummary.remove(id)
            revision += 1
            if let url = summaryURL(id), let d = try? JSONEncoder().encode(stored) { try? d.write(to: url, options: .atomic) }
            errors[id] = nil
            Log.write("已摘要 \(id)：\(lines.count) 句，\(Int(Date().timeIntervalSince(t0))) 秒")
        } catch Summarizer.Failure.tooShort {
            Log.write("跳过摘要 \(id)：转写太短")
            if manual { errors[id] = String(localized: "This recording is too short to summarise.") }
        } catch {
            Log.write("摘要失败 \(id)：\(error)")
            if manual {
                fail(id, manual, error is Summarizer.Failure
                     ? String(localized: "The model's reply could not be used. Try again or use a larger model.")
                     : String(localized: "The LLM service did not answer: \(error.localizedDescription)"))
            }
        }
    }

    private func fail(_ id: UInt32, _ manual: Bool, _ message: String) {
        if manual { errors[id] = message }
        Log.write("摘要 \(id)：\(message)")
    }

    // MARK: 笔记

    enum WriteMode {
        /// 自动：改过的文件不动，另写一份
        case auto
        /// 手动保存：改过的文件先返回 .edited 让界面问
        case ask
        /// 替换（用户确认过）
        case replace
        /// 另存一份新文件
        case newFile
        /// 刷新：只重写 OpenBean 写过、用户没改过的那份；改过或找不到就不写
        case refresh
    }

    enum WriteResult {
        case written(URL)
        /// 用户改过这份笔记（只在 .ask 时返回）
        case edited(URL)
        case skipped(String)
    }

    /// 写（或重写）这条录音的笔记，规则见类型说明
    @discardableResult
    func writeNote(_ id: UInt32, mode: WriteMode) -> WriteResult {
        guard let dir = notesFolder else { return .skipped(String(localized: "Choose a notes folder in Settings → Library.")) }
        guard let library, let r = library.recordings.first(where: { $0.id == id }), !r.isDictation, r.transcribed else {
            return .skipped(String(localized: "Not transcribed yet."))
        }
        let segs = library.transcript(id)
        guard !segs.isEmpty else { return .skipped(String(localized: "No speech found.")) }
        let fm = FileManager.default

        var target: URL?
        if let rec = noteRecord(id) {
            let old = URL(fileURLWithPath: rec.path)
            // 只认当前笔记文件夹里还在的那份；换了文件夹就在新文件夹里另写
            if old.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path,
               fm.fileExists(atPath: old.path) {
                let mod = (try? fm.attributesOfItem(atPath: old.path)[.modificationDate] as? Date) ?? .distantPast
                let edited = mod.timeIntervalSince(rec.writtenAt) > 2
                switch (edited, mode) {
                case (false, .newFile), (true, .auto), (true, .newFile): target = nil
                case (true, .ask): return .edited(old)
                case (true, .refresh): return .skipped("edited")
                default: target = old
                }
                if edited, mode == .auto { Log.write("笔记被改过，另写一份：\(old.lastPathComponent)") }
            }
        }
        // 笔记没被改过、录音后来有了标题（摘要给的或用户起的）：文件名跟着改成「日期-标题」
        if let old = target, let title = r.title, !title.isEmpty {
            let name = NoteTemplate.fileName(title: title, start: r.start) {
                $0 != old.lastPathComponent && fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            let renamed = dir.appendingPathComponent(name)
            if name != old.lastPathComponent, (try? fm.moveItem(at: old, to: renamed)) != nil {
                Log.write("笔记改名 \(id)：\(old.lastPathComponent) → \(name)")
                target = renamed
            }
        }
        if target == nil, mode == .refresh { return .skipped("no note") }
        if target == nil {
            let name = NoteTemplate.fileName(title: r.title, start: r.start) { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            target = dir.appendingPathComponent(name)
        }
        guard let url = target else { return .skipped("") }

        let values = NoteTemplate.Values(title: r.displayTitle, start: r.start, duration: r.duration, recordingID: id,
                                         summary: summary(id), lines: segs.map { TimedLine(start: $0.start, text: $0.text) })
        let text = NoteTemplate.render(AppPaths.readNoteTemplate(), values)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.write("写笔记失败 \(id)：\(error)")
            return .skipped(error.localizedDescription)
        }
        let mod = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        if let rurl = noteRecordURL(id), let d = try? JSONEncoder().encode(NoteRecord(path: url.path, writtenAt: mod)) {
            try? d.write(to: rurl, options: .atomic)
        }
        Log.write("已写笔记 \(id)：\(url.lastPathComponent)")
        return .written(url)
    }

    /// 已写过的笔记文件（在当前笔记文件夹里且还在）
    func noteURL(_ id: UInt32) -> URL? {
        guard let dir = notesFolder, let rec = noteRecord(id) else { return nil }
        let u = URL(fileURLWithPath: rec.path)
        guard u.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// 给已经转写好、还没有笔记的录音补写笔记；开着自动摘要时先给没有摘要的补摘要（已有摘要的不重做）
    func backfillNotes() {
        guard backfill == nil, notesFolder != nil, let library else { return }
        let ids = library.recordings.filter { canSummarize($0) && noteURL($0.id) == nil }.map(\.id)
        guard !ids.isEmpty else { backfill = (0, 0); clearBackfillSoon(); return }
        backfill = (0, ids.count)
        enqueue { [weak self] in
            guard let self else { return }
            for (n, id) in ids.enumerated() {
                if self.settings.summarizeRecordings, self.summary(id) == nil {
                    self.summarizing[id] = 0
                    await self.runSummary(id, manual: false)
                }
                self.writeNote(id, mode: .auto)
                self.backfill = (n + 1, ids.count)
            }
            Log.write("补写笔记 \(ids.count) 条")
            self.clearBackfillSoon()
        }
    }

    private func clearBackfillSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.backfill = nil
        }
    }

    /// 选笔记文件夹（App 没有沙盒，直接存路径）
    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for recording notes, for example a folder in your Obsidian vault.")
        if let dir = notesFolder { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        settings.notesFolder = url.path
        return true
    }
}

// MARK: - 界面

/// 详情页转写上方的摘要卡片
struct SummaryCard: View {
    let recording: Recording
    let notes: NoteService

    var body: some View {
        let progress = notes.summarizing[recording.id]
        let s = notes.summary(recording.id)
        let error = notes.errors[recording.id]
        if progress != nil || s != nil || error != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let progress {
                    HStack(spacing: 10) {
                        ProgressView(value: progress).frame(width: 120)
                        Text("Summarising…").foregroundStyle(.secondary)
                    }
                }
                if let s {
                    Text(s.summary).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                    if !s.keyPoints.isEmpty {
                        section("Key points", items: s.keyPoints, symbol: "circle.fill", size: 5)
                    }
                    if !s.actionItems.isEmpty {
                        section("Action items", items: s.actionItems, symbol: "square", size: 11)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            }
            .padding(16)
            .frame(maxWidth: 700, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            .padding(.bottom, 8)
        }
    }

    private func section(_ title: LocalizedStringKey, items: [String], symbol: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.secondary)
                    Text(t).textSelection(.enabled)
                }
            }
        }
    }
}

/// 详情页工具栏的「摘要」按钮（摘要进行中显示进度）
struct SummariseButton: View {
    let recording: Recording
    let notes: NoteService

    var body: some View {
        if let p = notes.summarizing[recording.id] {
            ProgressView(value: p) { Text("Summarising…") }.frame(width: 140)
        } else {
            let again = notes.summary(recording.id) != nil
            Button { notes.summarize(recording.id) } label: {
                Label(again ? "Summarise again" : "Summarise", systemImage: "sparkles")
            }
            .help(again ? "Summarise again" : "Summarise")
            .disabled(!notes.canSummarize(recording))
        }
    }
}

/// 「保存笔记」：没选文件夹先选；笔记被改过时问替换还是另存
struct SaveNoteModifier: ViewModifier {
    let recording: Recording
    let notes: NoteService
    @Binding var request: Bool
    @State private var edited: URL?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, now in
                guard now else { return }
                request = false
                save(.ask)
            }
            .confirmationDialog("This note was edited after OpenBean wrote it.", isPresented: Binding(
                get: { edited != nil }, set: { if !$0 { edited = nil } })) {
                Button("Replace with a new version", role: .destructive) { save(.replace) }
                Button("Save as a new note") { save(.newFile) }
            } message: {
                Text(edited?.lastPathComponent ?? "")
            }
    }

    private func save(_ mode: NoteService.WriteMode) {
        edited = nil
        if notes.notesFolder == nil, !notes.chooseFolder() { return }
        switch notes.writeNote(recording.id, mode: mode) {
        case let .written(url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case let .edited(url): edited = url
        case let .skipped(why): if !why.isEmpty { NSSound.beep(); Log.write("没写笔记 \(recording.id)：\(why)") }
        }
    }
}

/// 设置 → 录音库里的「摘要」和「笔记」两组
struct NoteSettingsSections: View {
    @Bindable var settings: Settings
    let notes: NoteService

    private var cloudHost: String? {
        guard let u = URL(string: settings.polishEndpoint), !LLMService.isLocal(u) else { return nil }
        return u.host
    }

    var body: some View {
        Section {
            Toggle(isOn: $settings.summarizeRecordings) {
                Text("Summarise recordings after transcription")
                Text("Title, summary, key points and action items, written by the LLM service set up in Clean-up. Skipped when the service is not running.")
            }
            if settings.summarizeRecordings, let cloudHost {
                Label {
                    Text("Transcripts are sent to \(cloudHost) for summaries.")
                } icon: {
                    Image(systemName: "icloud").foregroundStyle(.orange)
                }
                .font(.callout)
            }
        } header: {
            Text("Summaries")
        }

        Section {
            Toggle(isOn: $settings.notesEnabled) {
                Text("Save a note for each recording to a folder")
                Text("One Markdown file per recording with the summary and the transcript, for example in an Obsidian vault. Audio stays in the library.")
            }
            LabeledContent("Notes folder") {
                HStack(spacing: 8) {
                    Text(settings.notesFolder.isEmpty ? String(localized: "Not chosen") : (settings.notesFolder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { notes.chooseFolder() }
                    Button("Show in Finder") { if let d = notes.notesFolder { NSWorkspace.shared.open(d) } }
                        .disabled(notes.notesFolder == nil)
                }
            }
            HStack(spacing: 16) {
                Button("Edit note template…") {
                    AppPaths.ensureNoteTemplate()
                    NSWorkspace.shared.open(AppPaths.noteTemplate)
                }
                .buttonStyle(.link)
                Spacer()
                if let b = notes.backfill {
                    if b.total == 0 {
                        Text("All transcribed recordings have notes").foregroundStyle(.secondary)
                    } else if b.done < b.total {
                        ProgressView(value: Double(b.done), total: Double(b.total)).frame(width: 100)
                        Text("\(b.done) of \(b.total)").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text("\(b.total) notes saved").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Save notes for existing recordings") { notes.backfillNotes() }
                        .disabled(notes.notesFolder == nil)
                }
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("Notes are named date-title.md. A note you have edited is never overwritten: OpenBean writes a new one next to it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
