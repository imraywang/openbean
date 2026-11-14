// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

/// 本机录音库：按天分组的列表（搜索全文、按来源和状态筛选、下拉刷新、多选删除）→ 详情（RecordingDetail）。
/// 工具栏的「更多」里有存储和个人词表。语音输入片段不在这里（iOS 版没有语音输入）
struct RecordingsTab: View {
    let library: LibraryStore
    @State private var query = ""
    @State private var source = SourceFilter.all
    @State private var status = StatusFilter.all
    @State private var path = NavigationPath()
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<UInt32>()
    @State private var confirmDelete = false
    @State private var routed = false

    private var heart: Bool { library.settings.mode.callsDeviceHeartBean }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 筛选后的录音和搜索命中（没在搜索时命中是空的）
    private var results: [(recording: Recording, hit: SearchHit?)] {
        library.recordings.compactMap { r in
            guard library.includes(r, in: .all), source.includes(r), library.includes(r, status: status) else { return nil }
            guard searching else { return (r, nil) }
            guard let hit = library.search(r, query) else { return nil }
            return (r, hit)
        }
    }

    var body: some View {
        let results = results
        let hits = Dictionary(uniqueKeysWithValues: results.compactMap { e in e.hit.map { (e.recording.id, $0) } })
        NavigationStack(path: $path) {
            List(selection: $selection) {
                ForEach(library.daySections(results.map(\.recording)), id: \.day) { section in
                    Section {
                        ForEach(section.items) { r in
                            NavigationLink(value: LibraryRoute.recording(r.id)) {
                                RecordingRow(library: library, recording: r, hit: hits[r.id], query: query, heart: heart)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    selection = [r.id]
                                    confirmDelete = true
                                }
                            }
                        }
                    } header: {
                        Text(library.dayTitle(section.day))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .overlay { if results.isEmpty { emptyState } }
            .searchable(text: $query, prompt: Text("Titles, summaries and transcripts"))
            .refreshable { await refresh() }
            .navigationTitle("Recordings")
            .navigationSubtitle(subtitle(count: results.count))
            .toolbar { toolbar(results.map(\.recording.id)) }
            .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case let .recording(id): RecordingDetail(library: library, id: id, query: query)
                case .storage: StorageView(library: library)
                case .words: WordListView()
                }
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(deleteButton, role: .destructive) { deleteSelected() }
            } message: {
                Text(DeleteText.message(library.recordings.filter { selection.contains($0.id) }, heart: heart))
            }
            .onChange(of: confirmDelete) { _, shown in
                // 从左滑来的删除取消了：别把那条留在多选里
                if !shown, !editMode.isEditing { selection = [] }
            }
            .onChange(of: path) { _, _ in
                // 从详情回来时退出多选
                if editMode.isEditing, !path.isEmpty { editMode = .inactive }
            }
            .task {
                library.notes.preload(library.recordings.map(\.id))
                demoRoute()
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ ids: [UInt32]) -> some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == ids.count && !ids.isEmpty ? "Deselect all" : "Select all") {
                    selection = selection.count == ids.count ? [] : Set(ids)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", role: .confirm) { withAnimation { editMode = .inactive; selection = [] } }
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(selection.isEmpty ? String(localized: "Delete") : String(localized: "Delete \(selection.count)"), systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .tint(.red)
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Source", selection: $source) {
                        ForEach(SourceFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Status", selection: $status) {
                        ForEach(StatusFilter.allCases) { Label($0.label(heart: heart), systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease")
                        .symbolVariant(source != .all || status != .all ? .fill : .none)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select", systemImage: "checkmark.circle") { withAnimation { editMode = .active } }
                        .disabled(ids.isEmpty)
                    Divider()
                    NavigationLink(value: LibraryRoute.storage) { Label("Storage", systemImage: "internaldrive") }
                    NavigationLink(value: LibraryRoute.words) { Label("Personal word list", systemImage: "character.book.closed") }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    private func subtitle(count: Int) -> Text {
        var parts: [String] = []
        if source != .all { parts.append(source == .heart ? String(localized: "Heart mode") : String(localized: "Normal")) }
        if status != .all { parts.append(Self.statusName(status, heart: heart)) }
        parts.append(String(localized: "\(count) recordings"))
        return Text(parts.joined(separator: " · "))
    }

    private static func statusName(_ s: StatusFilter, heart: Bool) -> String {
        switch s {
        case .all: return ""
        case .onRecorder: return heart ? String(localized: "On Heart bean") : String(localized: "On recorder")
        case .untranscribed: return String(localized: "Waiting for transcript")
        case .summarized: return String(localized: "Summarised")
        case .marked: return String(localized: "Has marks")
        case .todos: return String(localized: "Has to-dos")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searching {
            ContentUnavailableView.search(text: query)
        } else if source != .all || status != .all {
            ContentUnavailableView {
                Label("Nothing matches these filters", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Try another source or status.")
            } actions: {
                Button("Show all recordings") { source = .all; status = .all }
            }
        } else {
            ContentUnavailableView {
                Label("No recordings yet", systemImage: "waveform")
            } description: {
                Text(DeviceWord.pick(heart, "Recordings synced from your Heart bean show up here. Pull down to check for new ones.",
                                     "Recordings synced from your recorder show up here. Pull down to check for new ones."))
            }
        }
    }

    private var deleteTitle: String {
        selection.count == 1 ? String(localized: "Delete this recording from this iPhone?")
                             : String(localized: "Delete \(selection.count) recordings from this iPhone?")
    }

    private var deleteButton: String {
        selection.count == 1 ? String(localized: "Delete") : String(localized: "Delete \(selection.count)")
    }

    private func deleteSelected() {
        let ids = selection
        Playback.shared.forget(ids)
        for id in ids { library.deleteLocal(id) }
        selection = []
        withAnimation { editMode = .inactive }
    }

    /// 下拉刷新：连着设备就重新读一遍设备上的文件列表（有新录音时自动同步会接着下载），摘要缓存也重新看一遍
    private func refresh() async {
        library.notes.preload(library.recordings.map(\.id))
        if !Flavor.isFake { await library.refreshDeviceList() }
    }

    /// 演示数据截图用：启动参数 -library select|delete|storage|words|search:<词>|filter:<状态>|title:<标题开头>|open:<第几条>[:<搜索词>]
    private func demoRoute() {
        guard Flavor.isFake, !routed else { return }
        routed = true
        DemoLibrary.prepare(library)
        guard let route = UserDefaults.standard.string(forKey: "library") else { return }
        let all = library.recordings.filter { library.includes($0, in: .all) }
        switch route {
        case "select", "delete":
            editMode = .active
            selection = Set(all.filter(\.downloaded).prefix(3).map(\.id))
            if route == "delete" { confirmDelete = true }
        case "storage": path.append(LibraryRoute.storage)
        case "words": path.append(LibraryRoute.words)
        case let s where s.hasPrefix("search:"): query = String(s.dropFirst(7))
        case let s where s.hasPrefix("filter:"): status = StatusFilter(rawValue: String(s.dropFirst(7))) ?? .all
        case let s where s.hasPrefix("title:"):
            if let r = all.first(where: { library.listTitle($0).hasPrefix(s.dropFirst(6)) }) { path.append(LibraryRoute.recording(r.id)) }
        case let s where s.hasPrefix("open:"):
            let rest = s.dropFirst(5).split(separator: ":")
            if let n = rest.first.flatMap({ Int($0) }), n < all.count {
                if rest.count > 1 { query = String(rest[1]) }
                path.append(LibraryRoute.recording(all[n].id))
            }
        default: break
        }
    }
}

enum LibraryRoute: Hashable {
    case recording(UInt32)
    case storage
    case words
}

/// 删除确认里的说明：设备上还有的、音频已经按保留期删掉的分开说
enum DeleteText {
    static func message(_ rs: [Recording], heart: Bool) -> String {
        var lines: [String] = []
        let onDevice = rs.filter { $0.onDevice && $0.downloaded }.count
        let noAudio = rs.filter(\.audioRemoved).count
        if rs.count == 1, let r = rs.first {
            if r.audioRemoved {
                lines.append(String(localized: "Its audio was already removed under Heart mode's audio retention; this deletes the transcript, summary and to-dos left on this iPhone."))
            } else {
                lines.append(String(localized: "This deletes the audio, transcript, summary and to-dos on this iPhone."))
            }
        } else {
            lines.append(String(localized: "This deletes their audio, transcripts, summaries and to-dos on this iPhone."))
            if noAudio > 0 { lines.append(String(localized: "\(noAudio) of them only have a transcript left: their audio was removed under Heart mode's audio retention.")) }
        }
        if onDevice > 0 {
            lines.append(heart ? String(localized: "Recordings still on the Heart bean stay there and download again on the next sync.")
                               : String(localized: "Recordings still on the recorder stay there and download again on the next sync."))
        }
        lines.append(String(localized: "This cannot be undone."))
        return lines.joined(separator: " ")
    }
}

struct RecordingRow: View {
    let library: LibraryStore
    let recording: Recording
    var hit: SearchHit?
    var query = ""
    let heart: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var playing: Bool { Playback.shared.id == recording.id && Playback.shared.playing }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if playing {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).symbolEffect(.variableColor.iterative)
                        .accessibilityLabel("Playing")
                }
                Text(searching ? Highlight.text(library.listTitle(recording), query) : AttributedString(library.listTitle(recording)))
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
            }
            meta
            if let hit, let text = hit.text {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let t = hit.start { Text(LibraryStore.clock(t)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                    Text(Highlight.text(Highlight.excerpt(text, around: query), query))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                if hit.count > 1 {
                    Text("\(hit.count) matches").font(.caption).foregroundStyle(.tertiary)
                }
            } else if !searching, let s = library.notes.cachedSummary(recording.id)?.summary {
                Text(s).font(.subheadline).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
            } else if !searching, let s = library.snippet(recording.id) {
                Text(s).font(.subheadline).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 时间 · 时长（没有标题时标题就是时间，这里只写时长），下面一排小标签：来源、状态、标记、待办。排不下就换行
    private var meta: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if recording.title?.isEmpty == false || library.notes.cachedSummary(recording.id) != nil {
                    Text(recording.start.formatted(date: .omitted, time: .shortened))
                    Text(verbatim: "·")
                }
                Text(LibraryStore.clock(recording.duration)).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                SourceBadge(source: recording.recordingSource)
                StatusBadge(library: library, recording: recording, heart: heart)
                let marks = recording.downloaded ? library.marks(recording.id).count : 0
                if marks > 0 {
                    Chip(text: Text("\(marks)"), icon: "flag.fill", color: .orange)
                        .accessibilityLabel(Text("\(marks) marks"))
                }
                if recording.audioRemoved {
                    Chip(text: Text("Transcript only"), icon: "waveform.slash", color: .secondary)
                }
                let todos = library.notes.openTodos(recording.id).count
                if todos > 0 {
                    Chip(text: Text("\(todos)"), icon: "checklist", color: .blue)
                        .accessibilityLabel(Text("\(todos) open to-dos"))
                }
            }
        }
    }
}

/// 一个小标签：图标加字，浅色底
struct Chip: View {
    let text: Text
    let icon: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).imageScale(.small)
            text
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 从左往右排，排不下换行（标签一排）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [], row = Row()
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            guard size.width > 0 else { continue }
            if !row.items.isEmpty, row.width + spacing + size.width > width { rows.append(row); row = Row() }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

struct SourceBadge: View {
    let source: RecordingSource
    var body: some View {
        if source == .heart {
            Chip(text: Text("Heart mode"), icon: "heart.fill", color: .pink)
        }
    }
}

struct StatusBadge: View {
    let library: LibraryStore
    let recording: Recording
    let heart: Bool

    var body: some View {
        switch library.status(recording) {
        case .onRecorder:
            Chip(text: Text(DeviceWord.pick(heart, "On Heart bean", "On recorder")), icon: "arrow.down.circle", color: .secondary)
        case let .transcribing(p):
            Chip(text: Text("Transcribing \(Int(p * 100))%"), icon: "waveform.badge.ellipsis", color: .blue)
        case .waiting:
            Chip(text: Text("Waiting for transcript"), icon: "text.bubble", color: .orange)
        case .transcribed:
            EmptyView()
        case .summarized:
            Chip(text: Text("Summarised"), icon: "sparkles", color: .purple)
        }
    }
}
