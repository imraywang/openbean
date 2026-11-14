// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import OpenBeanVoice
import Observation
import OpenBeanLibrary
import SwiftUI

// MARK: - 录音列表：按日期分组（录音库页的中间一栏）

struct RecordingList: View {
    @Bindable var library: LibraryStore
    let nav: Navigator
    @Binding var selection: UInt32?
    @Binding var query: String
    @State private var confirmDelete: Recording?
    @State private var deleteError: String?

    private var items: [Recording] { library.visible.filter { library.matches($0, query: query) } }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { r in
                            RecordingRow(recording: r, snippet: library.snippet(r.id), transcribing: library.transcribing[r.id])
                                .tag(r.id)
                                .id(r.id)
                                // 从概览点进来的那条亮一下再退回选中色
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(nav.flash == r.id ? 0.45 : 0))
                                    .padding(.horizontal, -6).padding(.vertical, -3))
                                .contextMenu {
                                    RecordingMenu(recording: r, library: library) { confirmDelete = r }
                                }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onAppear { if let id = selection { proxy.scrollTo(id, anchor: .center) } }
        }
        .confirmationDialog("Delete this recording from the recorder?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { r in
            Button("Delete from recorder", role: .destructive) {
                Task { deleteError = await library.deleteFromRecorder([r.id]) }
            }
        } message: { _ in
            Text("This cannot be undone. The copy on this Mac is kept.")
        }
        .alert("Couldn't delete from the recorder", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .overlay {
            if items.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: library.filter.icon)
                    } description: {
                        Text(emptyDetail)
                    }
                }
            }
        }
        // 页脚：这一组录音一共多长（原来概览里的「录音时长」）
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !items.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    Text(footer).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .background(.bar)
            }
        }
    }

    private var footer: String {
        let secs = items.reduce(0) { $0 + $1.duration }
        let units: Set<Duration.UnitsFormatStyle.Unit> = secs >= 3600 ? [.hours, .minutes] : [.minutes]
        let total = Duration.seconds(secs).formatted(.units(allowed: units, width: .abbreviated))
        return String(localized: "\(items.count) recordings · \(total)")
    }

    private var emptyTitle: LocalizedStringKey {
        switch library.filter {
        case .all: return "No recordings"
        case .onRecorder: return "Everything is synced"
        case .untranscribed: return "Everything is transcribed"
        case .todos: return "No to-dos"
        }
    }

    private var emptyDetail: LocalizedStringKey {
        switch library.filter {
        case .all: return "Sync downloads recordings from your recorder."
        case .onRecorder: return "No recordings are waiting on the recorder."
        case .untranscribed: return "Every recording on this Mac has a transcript."
        case .todos: return "Summaries with action items show up here."
        }
    }

    /// 今天 / 昨天 / 本周 / 按月。和「今天」页同一个分天函数（一天从凌晨 4 点算）：凌晨 1 点的录音算前一天
    private var sections: [(title: String, items: [Recording])] {
        let cal = Calendar.current
        let b = library.dayBoundary
        let today = b.day(of: Date()), yesterday = b.day(today, offsetBy: -1)
        var order: [String] = []
        var groups: [String: [Recording]] = [:]
        for r in items {
            let day = b.day(of: r.start)
            let key: String
            if day == today { key = String(localized: "Today") }
            else if day == yesterday { key = String(localized: "Yesterday") }
            else if cal.isDate(day, equalTo: today, toGranularity: .weekOfYear) { key = String(localized: "This week") }
            else { key = day.formatted(.dateTime.year().month(.wide)) }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

/// 没有标题的录音怎么称呼（列表、概览共用）：今天只写时间；昨天写「昨天」加时间（列表里组标题已经写了就只写时间）；
/// 一周内写星期几加时间；今年写月日加时间；更早的才带年份
enum RelativeDate {
    static func name(_ d: Date, grouped: Bool = false, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return time }
        if cal.isDateInYesterday(d) { return grouped ? time : String(localized: "Yesterday \(time)") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 99
        if days < 7 { return d.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        if cal.isDate(d, equalTo: now, toGranularity: .year) { return d.formatted(.dateTime.month().day().hour().minute()) }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let snippet: String?
    let transcribing: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(snippet == nil ? 1 : 2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(LibraryStore.clock(recording.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                status
            }
        }
        .padding(.vertical, 3)
    }

    private var title: String {
        if let t = recording.title, !t.isEmpty { return t }
        // 列表按今天 / 昨天 / 本周 / 月分了组，组标题已经说了是哪天
        return RelativeDate.name(recording.start, grouped: true)
    }

    private var subtitle: String {
        if let snippet { return snippet }
        if transcribing != nil { return String(localized: "Transcribing…") }
        if !recording.downloaded { return String(localized: "On your recorder") }
        if !recording.transcribed { return String(localized: "Not transcribed") }
        return String(localized: "No speech")
    }

    @ViewBuilder private var status: some View {
        if let p = transcribing {
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
        } else if !recording.downloaded {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).help("On your recorder")
        } else if recording.isDictation {
            Image(systemName: "keyboard").foregroundStyle(.secondary).help("Dictation clip")
        }
    }
}

struct RecordingMenu: View {
    let recording: Recording
    let library: LibraryStore
    /// 「从录音豆删除…」：由列表弹确认框
    var deleteFromRecorder: (() -> Void)?
    var body: some View {
        if recording.onDevice && !recording.downloaded {
            Button("Download") { Task { await library.syncAll(ids: [recording.id]) } }
        }
        if recording.downloaded {
            Button(recording.transcribed ? "Transcribe again" : "Transcribe") { Task { await library.transcribe(recording.id) } }
            if library.notes.canSummarize(recording) {
                Button(library.notes.summary(recording.id) != nil ? "Summarise again" : "Summarise") { library.notes.summarize(recording.id) }
                    .disabled(library.notes.summarizing[recording.id] != nil)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(recording.id)]) }
            Divider()
            Button("Delete local copy", role: .destructive) { library.deleteLocal(recording.id) }
        }
        if let deleteFromRecorder, library.mayDeleteFromRecorder(recording) {
            Button("Delete from recorder…", role: .destructive) { deleteFromRecorder() }
                .disabled(!library.recorderIdle)
        }
    }
}

// MARK: - 详情

struct RecordingDetail: View {
    let recording: Recording
    let library: LibraryStore
    let device: DeviceController
    @State private var title = ""
    @State private var player = PlayerModel()
    @State private var confirmWifi = false
    @State private var saveNote = false
    @State private var editingTitle = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if recording.downloaded {
                document
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Divider()
                    notDownloaded
                    Spacer()
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar { toolbar }
        .onAppear {
            title = recording.title ?? ""
            if recording.downloaded { player.load(library.audioURL(recording.id)) }
            #if DEMO || DEBUG
            if Flavor.isFake {
                player.demoDuration(recording.duration) // 演示版、预览没有音频，时长按录音算
                if let t = DemoState.shared.playAt { player.demoPlaying(at: t) } // 看「正在播放」的高亮
            }
            #endif
        }
        .task(id: recording.downloaded) { await library.loadPeaks(recording.id) }
        .onChange(of: recording.downloaded) { _, now in if now { player.load(library.audioURL(recording.id)) } }
        .onDisappear { player.stop() }
        // 摘要可能给录音起了标题：没在编辑时跟着更新，免得把它改回空
        .onChange(of: recording.title) { _, t in if !editingTitle { title = t ?? "" } }
        .modifier(SaveNoteModifier(recording: recording, notes: library.notes, request: $saveNote))
        .confirmationDialog("Download over Wi‑Fi?", isPresented: $confirmWifi) {
            Button("Download over Wi‑Fi") { Task { await library.syncViaWifi(ids: [recording.id]) } }
        } message: {
            Text("About 100× faster than Bluetooth. Your Mac joins the recorder's own Wi‑Fi and is offline for about a minute, then reconnects to your usual network.")
        }
    }

    /// 按文档排：标题、摘要导语、待办、要点、全文（按停顿并成段落；有多段对话时按段分节）；播放条浮在底部
    private var document: some View {
        let segs = library.transcript(recording.id)
        let sections = TranscriptSections(segs, conversations: library.conversations.conversations(recording.id))
        let paras = sections.paragraphs
        // 重点标记归到句子上（先敲后说：落在两句之间的归后一句）
        let marks = MarkPlacement.byLine(library.marks(recording.id), spans: segs.map { ($0.start, $0.end) })
        let current = player.playing ? segs.firstIndex { player.time >= $0.start && player.time < $0.end + 0.3 } : nil
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    SummaryCard(recording: recording, notes: library.notes)
                    transcript(segs, sections: sections, marks: marks, current: current)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 20)
                .padding(.bottom, 96) // 给浮动播放条留位置
                .frame(maxWidth: .infinity)
            }
            .onChange(of: current) { _, i in
                guard let i, let p = paras.firstIndex(where: { $0.contains(i) }) else { return }
                withAnimation { proxy.scrollTo(p, anchor: .center) }
            }
        }
        // 点一句从那里播放：每句是一个 openbean-seek://<下标> 链接；标记记号是 openbean-mark://<百分之一秒>，从标记处播放
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "openbean-seek", let i = Int(url.host ?? ""), segs.indices.contains(i) {
                player.play(from: segs[i].start)
            } else if url.scheme == "openbean-mark", let c = Int(url.host ?? "") {
                player.play(from: Double(c) / 100)
            }
            return .handled
        })
        .overlay(alignment: .bottom) {
            PlayerStrip(player: player, peaks: library.peaks(recording.id))
                .padding(.leading, 8).padding(.trailing, 18).padding(.vertical, 8)
                // 玻璃染上窗口底色：转写文字从下面滚过时，波形和时间也看得清（系统设置里把玻璃调到最透时也一样）
                .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.92)), in: .capsule)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                .frame(maxWidth: 680)
                .padding(.horizontal, 32).padding(.bottom, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meta).font(.callout).foregroundStyle(.secondary)
            if editingTitle {
                TextField("Title", text: $title, prompt: Text(recording.displayTitle))
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onExitCommand { title = recording.title ?? ""; editingTitle = false }
                    .onChange(of: titleFocused) { _, f in if !f && editingTitle { commitTitle() } }
            } else {
                // 平时是文字：双击、回车或右键「重命名」才变成输入框
                Text(recording.displayTitle)
                    .font(.system(size: 26, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) { startEditing() }
                    .contextMenu { Button("Rename") { startEditing() } }
                    .help("Double-click to rename")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(named: Text("Rename")) { startEditing() }
            }
        }
        .background {
            Button("Rename") { startEditing() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(editingTitle)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    /// 「2026年11月13日 星期五 上午10:00 · 58:06 · 已转写」
    private var meta: String {
        // 没有自定义标题时，大标题已经是日期和时间，这里只补星期
        let when = recording.title?.isEmpty == false
            ? recording.start.formatted(date: .complete, time: .shortened)
            : recording.start.formatted(.dateTime.weekday(.wide))
        var parts = [when, LibraryStore.clock(recording.duration)]
        if library.transcribing[recording.id] != nil { parts.append(String(localized: "Transcribing…")) }
        else if !recording.downloaded { parts.append(String(localized: "On your recorder")) }
        else if !recording.transcribed { parts.append(String(localized: "Not transcribed")) }
        return parts.joined(separator: " · ")
    }

    private func startEditing() {
        title = recording.title ?? ""
        editingTitle = true
        DispatchQueue.main.async { titleFocused = true }
    }

    private func commitTitle() {
        library.rename(recording.id, to: title)
        editingTitle = false
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // 一组：这条录音的主操作（带文字）；另一组：共享（导出、拷贝、存笔记）
        ToolbarItemGroup(placement: .primaryAction) {
            if recording.downloaded {
                if recording.transcribed && !recording.isDictation {
                    SummariseButton(recording: recording, notes: library.notes)
                        .labelStyle(.titleAndIcon)
                }
                if let p = library.transcribing[recording.id] {
                    ProgressView(value: p) { Text("Transcribing…") }.frame(width: 140)
                } else {
                    Button { Task { await library.transcribe(recording.id) } } label: {
                        Label(recording.transcribed ? "Transcribe again" : "Transcribe", systemImage: "text.bubble")
                    }
                    .labelStyle(.titleAndIcon)
                    .help(recording.transcribed ? "Transcribe again" : "Transcribe")
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if recording.downloaded {
                Menu {
                    Button("Copy transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(library.transcript(recording.id).map(\.text).joined(separator: "\n"), forType: .string)
                    }.disabled(!recording.transcribed)
                    Divider()
                    Button("Export transcript as Markdown…") { library.exportMarkdown(recording.id) }.disabled(!recording.transcribed)
                    Button("Export audio (Ogg Opus)…") { library.exportAudio(recording.id) }
                    Button("Save note to folder") { saveNote = true }.disabled(!library.notes.canSummarize(recording))
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(recording.id)]) }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share or export")
            }
        }
    }

    @ViewBuilder private func transcript(_ segs: [TranscriptSegment], sections: TranscriptSections, marks: [Int: [Double]],
                                         current: Int?) -> some View {
        let paras = sections.paragraphs
        if segs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if library.transcribing[recording.id] != nil {
                    Text("Transcribing on this Mac…").foregroundStyle(.secondary)
                } else {
                    Text(recording.transcribed ? "No speech found." : "Not transcribed yet.").foregroundStyle(.secondary)
                    if !recording.transcribed {
                        Button("Transcribe now") { Task { await library.transcribe(recording.id) } }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transcript").font(.headline)
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(paras.indices, id: \.self) { p in
                        let r = paras[p]
                        VStack(alignment: .leading, spacing: 14) {
                            // 一段对话的第一个段落前放这段的小标题（只有一段对话时没有）
                            if let c = sections.heading(before: p) {
                                ConversationHeading(conversation: c).padding(.top, p == 0 ? 0 : 12)
                            }
                            TranscriptParagraph(segments: Array(segs[r]), first: r.lowerBound,
                                                current: current.flatMap { r.contains($0) ? $0 : nil },
                                                marks: marks.filter { r.contains($0.key) })
                                .equatable()
                        }
                        .id(p)
                    }
                }
            }
        }
    }

    private var notDownloaded: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("This recording is still on your recorder.", systemImage: "arrow.down.circle")
                .font(.headline)
            HStack(spacing: 10) {
                Button("Download over Bluetooth") { Task { await library.syncAll(ids: [recording.id]) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.isReady || device.activity != .idle)
                // 和侧栏、概览的「蓝牙约需 N 分钟」同一套算法和说法
                Text("About \(SyncStatus.phrase(library.downloadSeconds(recording))) over Bluetooth").font(.caption).foregroundStyle(.secondary)
            }
            if recording.duration > 600 {
                Button("Download over Wi‑Fi (faster)…") { confirmWifi = true }
                    .disabled(!device.isReady || device.activity != .idle)
            }
        }
    }
}

/// 全文怎么分：只有一段对话（或还没切段）时就是按停顿并成的段落；有多段时先按对话段分节，节内再并段落，
/// 段落不跨节。段的句子范围和转写对不上时（转写刚变、段还没重算）当作没有段
struct TranscriptSections {
    let paragraphs: [Range<Int>]
    /// 段落下标 → 从这个段落开始的对话段
    private let starts: [Int: Conversation]

    init(_ segs: [TranscriptSegment], conversations: [Conversation]) {
        let valid = conversations.count > 1
            && conversations.first?.from == 0 && conversations.last?.to == segs.count
            && zip(conversations, conversations.dropFirst()).allSatisfy { $0.to == $1.from && $0.from < $0.to }
        guard valid else {
            paragraphs = TranscriptParagraphs.group(segs)
            starts = [:]
            return
        }
        var paras: [Range<Int>] = [], starts: [Int: Conversation] = [:]
        for c in conversations {
            starts[paras.count] = c
            paras += TranscriptParagraphs.group(Array(segs[c.lines])).map { ($0.lowerBound + c.from)..<($0.upperBound + c.from) }
        }
        paragraphs = paras
        self.starts = starts
    }

    func heading(before paragraph: Int) -> Conversation? { starts[paragraph] }
}

/// 全文里一段对话的小标题：段摘要的标题（还没有时只有时间）、起止时刻和时长
struct ConversationHeading: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let t = conversation.summary?.title, !t.isEmpty {
                Text(t).font(.title3.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(conversation.clockRange).font(.title3.weight(.semibold).monospacedDigit())
                Text(LibraryStore.clock(conversation.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var detail: String { "\(conversation.clockRange) · \(LibraryStore.clock(conversation.duration))" }
}

/// 转写的一段：左边是这段第一句的时间，右边是连在一起的句子。每句是一个链接，点了从那句播放；正在播的那句标亮
struct TranscriptParagraph: View, Equatable {
    let segments: [TranscriptSegment]
    /// segments[0] 在整份转写里的下标
    let first: Int
    let current: Int?
    /// 重点标记：整份转写里的句子下标 → 落在这句的标记（秒）。这句前面放一个 ⚑，点了从标记处播放
    var marks: [Int: [Double]] = [:]

    static func == (a: Self, b: Self) -> Bool {
        a.first == b.first && a.current == b.current && a.segments == b.segments && a.marks == b.marks
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(LibraryStore.clock(segments.first?.start ?? 0))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
                .accessibilityHidden(true)
            Text(attributed)
                .font(.system(size: 15))
                .lineSpacing(5)
                .tint(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(marks.isEmpty ? Text("Click a sentence to play from there")
              : Text("Click a sentence to play from there. ⚑ is a moment you marked on the recorder; click it to play from the mark."))
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (k, seg) in segments.enumerated() {
            if k > 0 { out += AttributedString(TranscriptParagraphs.joiner(after: segments[k - 1].text, before: seg.text)) }
            for m in marks[first + k] ?? [] {
                var flag = AttributedString("⚑\u{2009}")
                flag.link = URL(string: "openbean-mark://\(Int((m * 100).rounded()))")
                flag.foregroundColor = .orange
                out += flag
            }
            // 显示用 text（过了词表的），不用 raw
            var piece = AttributedString(seg.text)
            piece.link = URL(string: "openbean-seek://\(first + k)")
            if first + k == current {
                piece.foregroundColor = .accentColor
                piece.backgroundColor = Color.accentColor.opacity(0.14)
            }
            out += piece
        }
        return out
    }
}

/// 详情页右侧没选中录音时
struct LibraryHome: View {
    let device: DeviceController
    let settings: Settings
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Select a recording").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Label("Press the recorder's button to type with your voice", systemImage: "keyboard")
                Label("Shortcut: \(settings.hotkeyLabel)", systemImage: "command")
                Label("Sync brings recordings to this Mac and transcribes them", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 播放

/// 播放：AVAudioEngine + 按帧定位。
/// 不用 AVAudioPlayer：它对 Ogg Opus 设 `currentTime` 后报的时间是对的，实际播出的却是别处的声音
/// （实测：跳到 20、60 秒仍从头播，跳到 1200 秒播的是 1087 秒处）。AVAudioFile 按帧读是准的。
@MainActor @Observable
final class PlayerModel {
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var timer: Timer?
    /// 这次排进去的那段从第几秒开始；播放位置 = base + 节点已播的时长
    @ObservationIgnored private var base: Double = 0
    /// 每次重新排段加一：旧段的结束回调据此认出自己已经过期
    @ObservationIgnored private var generation = 0
    private(set) var playing = false
    private(set) var duration: Double = 0
    var time: Double = 0

    init() { engine.attach(node) }

    func load(_ url: URL) {
        stop()
        file = try? AVAudioFile(forReading: url)
        time = 0
        guard let f = file else { duration = 0; return }
        duration = Double(f.length) / f.processingFormat.sampleRate
        engine.connect(node, to: engine.mainMixerNode, format: f.processingFormat)
    }

    #if DEMO || DEBUG
    func demoDuration(_ d: Double) { if file == nil { duration = d } }
    /// 假装正在播放到 t 秒（没有音频，不会走动）
    func demoPlaying(at t: Double) { time = t; playing = true }
    #endif

    func toggle() { playing ? pause() : play(from: nil) }

    func play(from t: Double?) {
        guard file != nil else { return }
        var start = min(max(t ?? time, 0), duration)
        if t == nil, start >= duration - 0.05 { start = 0 } // 播完了再按播放：从头
        guard schedule(from: start) else { return }
        if !engine.isRunning { engine.prepare(); guard (try? engine.start()) != nil else { return } }
        node.play()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        tick()
        generation += 1
        node.stop()
        playing = false
        timer?.invalidate()
    }

    func seek(_ t: Double) {
        let to = min(max(t, 0), duration)
        if playing { if schedule(from: to) { node.play() } } else { time = to }
    }

    func stop() {
        generation += 1
        node.stop()
        engine.stop()
        playing = false
        timer?.invalidate()
    }

    /// 从 start 秒起把文件剩下的部分排进节点（先清掉之前排的）
    private func schedule(from start: Double) -> Bool {
        guard let f = file else { return false }
        generation += 1
        let gen = generation
        node.stop()
        let sr = f.processingFormat.sampleRate
        let frame = min(AVAudioFramePosition(start * sr), f.length)
        base = Double(frame) / sr
        time = base
        let left = f.length - frame
        guard left > 0 else { return false }
        node.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(left), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.playing = false
                self.time = self.duration
                self.timer?.invalidate()
            }
        }
        return true
    }

    private func tick() {
        guard playing, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return }
        time = min(base + Double(pt.sampleTime) / pt.sampleRate, duration)
    }
}

/// 播放条：播放键 + 波形（已播放部分着色，点哪里跳到哪里）+ 时间
struct PlayerStrip: View {
    @Bindable var player: PlayerModel
    let peaks: [Float]?

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause (Space)")

            WaveScrubber(peaks: peaks ?? [], progress: player.duration > 0 ? player.time / player.duration : 0) { f in
                player.seek(f * player.duration)
            }
            .frame(height: 40)

            Text("\(LibraryStore.clock(player.time)) / \(LibraryStore.clock(player.duration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 84, alignment: .trailing)
        }
    }
}

struct WaveScrubber: View {
    let peaks: [Float]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(Int(w / 3), 1)
            let bins = resample(n)
            ZStack(alignment: .leading) {
                bars(bins, w: w, h: h).foregroundStyle(Color.secondary.opacity(0.35))
                bars(bins, w: w, h: h).foregroundStyle(Color.accentColor)
                    .mask(alignment: .leading) { Rectangle().frame(width: w * progress) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(min(max(v.location.x / w, 0), 1)) })
        }
    }

    private func bars(_ bins: [Float], w: CGFloat, h: CGFloat) -> some View {
        Canvas { ctx, size in
            let step = size.width / CGFloat(max(bins.count, 1))
            for (i, v) in bins.enumerated() {
                let bh = max(2, CGFloat(v) * size.height)
                let r = CGRect(x: CGFloat(i) * step, y: (size.height - bh) / 2, width: max(step - 1, 1), height: bh)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .foreground)
            }
        }
    }

    private func resample(_ n: Int) -> [Float] {
        guard !peaks.isEmpty else { return Array(repeating: 0.08, count: n) }
        return (0..<n).map { i in
            let a = i * peaks.count / n, b = max(a + 1, (i + 1) * peaks.count / n)
            return peaks[a..<min(b, peaks.count)].max() ?? 0
        }
    }
}
