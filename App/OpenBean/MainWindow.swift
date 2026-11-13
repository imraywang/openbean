// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import OpenBeanLibrary
import Observation
import SwiftUI

// MARK: - 导航

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case today, library, dictation, recorder
    var id: String { rawValue }
    /// 侧栏里的页面（⌘1–⌘4）。设置在独立的设置窗口里（⌘,）
    static let pages: [MainSection] = [.today, .library, .dictation, .recorder]
    /// 链接里的名字：0.4 以前的「概览」现在是「今天」
    init?(link: String) {
        if link == "overview" { self = .today; return }
        self.init(rawValue: link)
    }
    var title: LocalizedStringKey {
        switch self {
        case .today: return "Today"
        case .library: return "Library"
        case .dictation: return "Voice typing"
        case .recorder: return "Recorder"
        }
    }
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .library: return "list.bullet"
        case .dictation: return "keyboard"
        case .recorder: return "mic"
        }
    }
}

@MainActor @Observable
final class Navigator {
    var section: MainSection = .today
    /// 「今天」页看的是哪一天（那个日历日的 0 点）；nil = 今天（跟着时间走，过了凌晨 4 点自动换天）
    var day: Date?
    var settingsTab: SettingsTab = .voice
    /// 刚从别处跳过来的录音：那一行亮一下，提示「你在这」
    var flash: UInt32?

    func show(recording id: UInt32, in library: LibraryStore) {
        // 当前筛选里看不到这条就回到「全部」
        if let r = library.recordings.first(where: { $0.id == id }), !library.includes(r, in: library.filter) { library.filter = .all }
        library.selection = id
        section = .library
        flash = id
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeOut(duration: 0.6)) { if self.flash == id { self.flash = nil } }
        }
    }
}

// MARK: - 主窗口：侧栏导航 + 页面（同级页面原地淡入淡出，不横向推入）

struct MainView: View {
    let model: AppModel
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var nav = model.nav
        NavigationSplitView(columnVisibility: $columns) {
            NavSidebar(model: model, section: $nav.section)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            page(nav.section)
                .id(nav.section)
                .transition(.opacity)
                // 整个窗口只有这一个同步入口：每一页的工具栏右边都是它
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SyncToolbarButton(device: model.device, library: model.library)
                    }
                    // macOS 26.1 起可以加 .visibilityPriority(.high)，部署目标是 26.0，先不用
                }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: nav.section)
        .frame(minWidth: 960, minHeight: 600)
        .background { shortcuts }
        .task { await model.library.refreshDeviceList() }
        .onAppear { NSApp.activate() }
    }

    @ViewBuilder private func page(_ s: MainSection) -> some View {
        switch s {
        case .today: TodayView(model: model)
        case .library: LibraryPage(model: model)
        case .dictation: DictationHistoryView(log: model.log, settings: model.settings, library: model.library)
        case .recorder:
            DeviceView(device: model.device, dictation: model.dictation, library: model.library)
                .navigationTitle("Recorder")
        }
    }

    /// ⌘1–⌘4 切页面，⌃⌘S 收起/展开侧栏（菜单栏 App 没有菜单，用隐藏按钮接快捷键）
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(MainSection.pages.enumerated()), id: \.offset) { i, s in
                Button("") { model.nav.section = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { model.openSettings?() }
                .keyboardShortcut(",", modifiers: .command)
            Button("") {
                withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// 侧栏里的一项：一个页面，或「录音」下面的一个筛选
enum SidebarTag: Hashable {
    case page(MainSection)
    case filter(LibraryStore.Filter)
}

struct NavSidebar: View {
    let model: AppModel
    @Binding var section: MainSection
    @State private var libraryExpanded = true

    private var library: LibraryStore { model.library }

    private var selection: Binding<SidebarTag?> {
        Binding(get: {
            section == .library && library.filter != .all ? .filter(library.filter) : .page(section)
        }, set: { tag in
            switch tag {
            case let .page(s): if s == .library { library.filter = .all }; section = s
            case let .filter(f): library.filter = f; section = .library
            case nil: break
            }
        })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(MainSection.pages) { s in
                if s == .library {
                    DisclosureGroup(isExpanded: $libraryExpanded) {
                        ForEach(LibraryStore.Filter.actionable) { f in
                            Label(f.label, systemImage: f.icon)
                                .badge(library.count(f))
                                .tag(SidebarTag.filter(f))
                        }
                    } label: {
                        Label(s.title, systemImage: s.icon).tag(SidebarTag.page(s))
                    }
                } else {
                    Label { Text(s.title) } icon: {
                        if s == .recorder { BeanSymbol() } else { Image(systemName: s.icon) }
                    }
                    .tag(SidebarTag.page(s))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DeviceFooter(device: model.device, library: model.library) { section = .recorder }
        }
        // 「有待办」要看每条的摘要：在后台读进缓存，不在主线程上逐条读盘
        .task(id: library.recordings.count) { library.notes.preload(library.recordings.filter { $0.transcribed && !$0.isDictation }.map(\.id)) }
    }
}

/// 侧栏底部：只放录音豆状态（不放按钮；同步在工具栏）。点它去「录音豆」页。
struct DeviceFooter: View {
    let device: DeviceController
    let library: LibraryStore
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.horizontal, -12)
            Button(action: open) {
                HStack(spacing: 8) {
                    Circle().fill(device.isReady ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.deviceName).font(.callout.weight(.medium)).lineLimit(1)
                        Text(DeviceFooter.status(device, library)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show recorder details")
            .accessibilityLabel(Text("\(device.deviceName), \(DeviceFooter.status(device, library))"))
            .accessibilityHint(Text("Show recorder details"))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    static func status(_ device: DeviceController, _ library: LibraryStore) -> String {
        switch device.state {
        case .ready:
            let b = device.battery.map { "\($0)%" } ?? ""
            switch device.activity {
            case .dictating: return String(localized: "Listening") + (b.isEmpty ? "" : " · \(b)")
            case .syncing:
                if case let .downloading(_, done, total, _, _) = library.sync {
                    return String(localized: "Syncing \(done + 1) of \(total)")
                }
                return String(localized: "Syncing") + (b.isEmpty ? "" : " · \(b)")
            case .idle: return b.isEmpty ? String(localized: "Connected") : String(localized: "Connected · \(b)")
            }
        case .connecting: return String(localized: "Connecting…")
        case .idle, .searching: return String(localized: "Searching…")
        case .failed: return String(localized: "Not connected")
        }
    }
}

/// 同步进度的说明（录音豆页的一节）。空闲时什么都不画：同步按钮只在工具栏里
struct SyncStatus: View {
    let device: DeviceController
    let library: LibraryStore

    var body: some View {
        switch library.sync {
        case let .downloading(_, done, total, f, _):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: f).controlSize(.small)
                if let left = library.syncSecondsLeft {
                    Text("Downloading \(done + 1) of \(total) — about \(Self.phrase(left)) left").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Downloading \(done + 1) of \(total)…").font(.caption2).foregroundStyle(.secondary)
                }
                WifiSuggestion(device: device, library: library)
            }
        case let .wifi(msg):
            Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        case .listing:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking the recorder…").font(.caption2).foregroundStyle(.secondary) }
        case .paused:
            Text("Sync paused for dictation").font(.caption2).foregroundStyle(.secondary)
        case let .failed(e):
            Text("Sync failed: \(e)").font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .idle:
            EmptyView()
        }
    }

    /// 时长的说法：不到 1 分钟 / 12 分钟 / 1 小时 35 分钟
    static func phrase(_ seconds: Double) -> String {
        switch SyncEstimate.display(seconds) {
        case .underMinute: return String(localized: "less than a minute")
        case let .minutes(m): return String(localized: "\(m) min")
        case let .hours(h, m): return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
        }
    }
}

/// 工具栏里的同步按钮：整个主窗口唯一的同步入口。
/// 空闲时是「同步 N 条新录音」（没有新的就只是图标）；下载中是进度环加「第 2 / 5 条 · 约 12 分钟」，点开看详情；
/// 没连上时变灰，悬停说明原因；失败时变成「重试」。
struct SyncToolbarButton: View {
    let device: DeviceController
    let library: LibraryStore
    @State private var showDetail = false

    private var pending: Int { library.recordings.filter { $0.onDevice && !$0.downloaded && !$0.isDictation }.count }

    var body: some View {
        switch library.sync {
        case let .downloading(_, done, total, f, _):
            Button { showDetail.toggle() } label: {
                HStack(spacing: 6) {
                    ProgressView(value: f).progressViewStyle(.circular).controlSize(.small)
                    Text(progressLine(done: done, total: total)).monospacedDigit()
                }
            }
            .help("Syncing recordings from the recorder")
            .accessibilityLabel(Text("Syncing: \(progressLine(done: done, total: total))"))
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                SyncStatus(device: device, library: library)
                    .frame(width: 260).padding(14)
            }
        case .listing:
            Label { Text("Checking…") } icon: { ProgressView().controlSize(.small) }
                .labelStyle(.titleAndIcon)
                .help("Checking the recorder…")
        case let .wifi(msg):
            Label(msg, systemImage: "wifi").labelStyle(.titleAndIcon).lineLimit(1).frame(maxWidth: 220)
        case .paused:
            Label("Sync paused", systemImage: "pause.circle")
                .labelStyle(.titleAndIcon)
                .help("Sync paused for dictation")
        case let .failed(e):
            Button { Task { await library.syncAll() } } label: {
                Label("Retry sync", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!device.isReady || device.activity != .idle)
            .help(String(localized: "Sync failed: \(e)"))
        case .idle:
            Button { Task { await library.syncAll() } } label: {
                if pending > 0 {
                    Label("Sync \(pending) new", systemImage: "arrow.triangle.2.circlepath").labelStyle(.titleAndIcon)
                } else {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(!device.isReady || device.activity != .idle)
            .help(idleHelp)
        }
    }

    /// 「第 2 / 5 条 · 约 12 分钟」
    private func progressLine(done: Int, total: Int) -> String {
        let n = String(localized: "\(done + 1) of \(total)")
        guard let left = library.syncSecondsLeft else { return n }
        return n + " · " + SyncStatus.phrase(left)
    }

    private var idleHelp: String {
        if !device.isReady {
            return pending > 0
                ? String(localized: "\(pending) new recordings are on the recorder. Sync them once it connects.")
                : String(localized: "The recorder isn't connected")
        }
        if device.activity == .dictating { return String(localized: "Voice typing is using the recorder") }
        if let s = library.pendingSyncSeconds { return String(localized: "About \(SyncStatus.phrase(s)) over Bluetooth") }
        return String(localized: "Check the recorder for new recordings")
    }
}

// MARK: - 录音库：列表 + 详情

struct LibraryPage: View {
    let model: AppModel
    @State private var query = ""
    @SceneStorage("libraryListHidden") private var listHidden = false

    var body: some View {
        let library = model.library
        Group {
            // 一条录音都没有：整页一个空状态（不再左边「没有录音」、右边「选择一条录音」）
            if library.recordings.allSatisfy(\.isDictation) {
                emptyLibrary
            } else {
                columns
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search titles and transcripts")
        #if DEMO || DEBUG
        .onChange(of: DemoState.shared.query, initial: true) { _, q in query = q }
        #endif
        .navigationTitle(library.filter.label)
        .onAppear {
            // 第一次进来默认选最近一条
            if library.selection == nil { library.selection = library.visible.first?.id }
        }
        // 换了筛选，选中的那条不在里面了：选新列表的第一条
        .onChange(of: library.filter) {
            if let id = library.selection, library.visible.contains(where: { $0.id == id }) { return }
            library.selection = library.visible.first?.id
        }
    }

    private var emptyLibrary: some View {
        let device = model.device
        return ContentUnavailableView {
            Label("No recordings yet", systemImage: "waveform")
        } description: {
            Text(device.isReady
                 ? "Recordings you make on the recorder show up here after you sync them to this Mac with Sync in the toolbar."
                 : "Take the recorder out of its case to connect. Its recordings show up here after you sync them.")
        }
    }

    private var columns: some View {
        let library = model.library
        // 列表栏可以拖宽（NSSplitView），也可以收起（工具栏按钮、⌥⌘L）
        return HSplitView {
            if !listHidden {
                RecordingList(library: library, nav: model.nav,
                              selection: Binding(get: { library.selection }, set: { library.selection = $0 }),
                              query: $query)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 480)
            }
            Group {
                if let id = library.selection, let r = library.recordings.first(where: { $0.id == id }) {
                    RecordingDetail(recording: r, library: library, device: model.device).id(id)
                } else if library.visible.isEmpty {
                    // 筛选是空的：列表那边已经说明了，这边不再叫人「选择一条录音」
                    Color.clear
                } else {
                    LibraryHome(device: model.device, settings: model.settings)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation { listHidden.toggle() } } label: {
                    Label(listHidden ? "Show list" : "Hide list", systemImage: "list.bullet.rectangle")
                }
                .help(listHidden ? "Show list" : "Hide list")
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
    }
}

// MARK: - 语音输入记录

struct DictationHistoryView: View {
    let log: DictationLog
    let settings: Settings
    let library: LibraryStore
    @State private var confirmClear = false
    /// 清理以前留在录音豆上的语音输入文件：确认框里列的条目，和删完的结果
    @State private var leftover: [Recording] = []
    @State private var confirmLeftover = false
    @State private var leftoverResult: String?

    var body: some View {
        List {
            // 原来概览里的「语音输入」统计：本周几次、多少字
            if !log.entries.isEmpty {
                let week = log.entries(in: Calendar.current.dateInterval(of: .weekOfYear, for: Date()))
                Text("This week: \(week.count) times · \(week.reduce(0) { $0 + $1.characters }) characters")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if !settings.keepHistory {
                Label("History is off. Turn it on in Settings to keep new voice typing here.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { e in
                        DictationRow(entry: e)
                            .contextMenu {
                                Button("Copy") { copy(e.text) }
                                Divider()
                                Button("Delete", role: .destructive) { log.delete(e.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if log.entries.isEmpty {
                ContentUnavailableView {
                    Label("No voice typing yet", systemImage: "keyboard")
                } description: {
                    Text("Press the recorder's button and speak. What you say is kept here, on this Mac.")
                }
            }
        }
        .navigationTitle("Voice typing")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // 以前留在录音豆上的语音输入文件（原来在录音库的「语音输入片段」筛选里）
                    Button("Delete voice-typing files from recorder…") {
                        Task {
                            // 先读一遍设备列表，确认框里的条数和时长用最新的
                            await library.refreshDeviceList()
                            leftover = library.leftoverDictationFiles
                            confirmLeftover = !leftover.isEmpty
                        }
                    }
                    .disabled(library.leftoverDictationFiles.isEmpty || !library.recorderIdle)
                    Divider()
                    Button("Clear history…", role: .destructive) { confirmClear = true }
                        .disabled(log.entries.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        .confirmationDialog(leftoverTitle, isPresented: $confirmLeftover) {
            Button("Delete from recorder", role: .destructive) {
                let ids = leftover.map(\.id)
                Task {
                    let r = await library.deleteLeftoverDictation(ids)
                    leftoverResult = String(localized: "Deleted \(r.deleted), failed \(r.failed).")
                }
            }
        } message: {
            Text("These files were never downloaded to this Mac. Some may have been continued by later voice typing, so they can be longer than one dictation. This cannot be undone.")
        }
        .alert("Voice-typing files", isPresented: Binding(
            get: { leftoverResult != nil }, set: { if !$0 { leftoverResult = nil } }
        )) {
            Button("OK") { leftoverResult = nil }
        } message: {
            Text(leftoverResult ?? "")
        }
        .confirmationDialog("Clear all voice typing history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { log.clear() }
        } message: {
            Text("This removes the text kept on this Mac. It does not change anything you already typed.")
        }
    }

    private var leftoverTitle: String {
        let total = leftover.reduce(0) { $0 + $1.duration }
        return String(localized: "Delete \(leftover.count) voice-typing files (\(LibraryStore.clock(total)) in total) from the recorder?")
    }

    /// 按天分组，和「今天」页同一个分天函数（一天从凌晨 4 点算）：凌晨 1 点的语音输入算前一天
    private var sections: [(title: String, items: [DictationEntry])] {
        let b = DayBoundary(startHour: settings.dayStartHour)
        let today = b.day(of: Date()), yesterday = b.day(today, offsetBy: -1)
        var order: [String] = []
        var groups: [String: [DictationEntry]] = [:]
        for e in log.entries {
            let day = b.day(of: e.date)
            let key: String
            if day == today { key = String(localized: "Today") }
            else if day == yesterday { key = String(localized: "Yesterday") }
            else { key = day.formatted(date: .abbreviated, time: .omitted) }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        return order.map { ($0, groups[$0]!) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct DictationRow: View {
    let entry: DictationEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                if let app = entry.app { Text("→ \(app)") }
                if entry.viaClipboard { Image(systemName: "doc.on.clipboard").help("Copied to the clipboard") }
                Spacer()
                Text("\(entry.characters) characters · \(LibraryStore.clock(entry.duration))").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(entry.text).lineLimit(4).textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
