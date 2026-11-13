// SPDX-License-Identifier: Apache-2.0

import Charts
import OpenBeanKit
import Observation
import SwiftUI

// MARK: - 导航

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case overview, library, dictation, recorder, settings
    var id: String { rawValue }
    /// 侧栏上半部分的内容页（⌘1–⌘4）；设置单独放在下面（⌘,）
    static let pages: [MainSection] = [.overview, .library, .dictation, .recorder]
    var title: LocalizedStringKey {
        switch self {
        case .overview: return "Overview"
        case .library: return "Library"
        case .dictation: return "Voice typing"
        case .recorder: return "Recorder"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .library: return "list.bullet"
        case .dictation: return "keyboard"
        case .recorder: return "mic"
        case .settings: return "gearshape"
        }
    }
}

@MainActor @Observable
final class Navigator {
    var section: MainSection = .overview
    var settingsTab: SettingsTab = .voice
    /// 刚从别处跳过来的录音：那一行亮一下，提示「你在这」
    var flash: UInt32?

    func show(recording id: UInt32, in library: LibraryStore) {
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
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: nav.section)
        // 再窄工具栏就放不下设置页的四个标签，会收进 » 菜单
        .frame(minWidth: 960, minHeight: 600)
        .background { shortcuts }
        .task { await model.library.refreshDeviceList() }
        .onAppear { NSApp.activate() }
    }

    @ViewBuilder private func page(_ s: MainSection) -> some View {
        switch s {
        case .overview: OverviewView(model: model)
        case .library: LibraryPage(model: model)
        case .dictation: DictationHistoryView(log: model.log, settings: model.settings)
        case .recorder:
            DeviceView(device: model.device, dictation: model.dictation)
                .navigationTitle("Recorder")
        case .settings: SettingsPage(model: model)
        }
    }

    /// ⌘1–⌘4 切页面，⌃⌘S 收起/展开侧栏（菜单栏 App 没有菜单，用隐藏按钮接快捷键）
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(MainSection.pages.enumerated()), id: \.offset) { i, s in
                Button("") { model.nav.section = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { model.nav.section = .settings }
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

struct NavSidebar: View {
    let model: AppModel
    @Binding var section: MainSection

    var body: some View {
        List(selection: Binding<MainSection?>(get: { section }, set: { if let s = $0 { section = s } })) {
            ForEach(MainSection.pages) { s in
                Label { Text(s.title) } icon: {
                    if s == .recorder { BeanSymbol() } else { Image(systemName: s.icon) }
                }
                    .badge(badge(s))
                    .tag(s)
            }
            Section {
                Label(MainSection.settings.title, systemImage: MainSection.settings.icon)
                    .tag(MainSection.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DeviceFooter(device: model.device, library: model.library) { section = .recorder }
        }
    }

    private func badge(_ s: MainSection) -> Int {
        switch s {
        case .library: return model.library.recordings.filter { !$0.isDictation }.count
        case .dictation: return model.log.entries.count
        default: return 0
        }
    }
}

/// 侧栏底部：录音豆状态 + 同步进度。点名字去「录音豆」页。
struct DeviceFooter: View {
    let device: DeviceController
    let library: LibraryStore
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.horizontal, -12)
            Button(action: open) {
                HStack(spacing: 8) {
                    Circle().fill(device.isReady ? Color.accentColor : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
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
            SyncStatus(device: device, library: library, compact: true)
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
            case .syncing: return String(localized: "Syncing") + (b.isEmpty ? "" : " · \(b)")
            case .idle: return b.isEmpty ? String(localized: "Connected") : String(localized: "Connected · \(b)")
            }
        case .connecting: return String(localized: "Connecting…")
        case .idle, .searching: return String(localized: "Searching…")
        case .failed: return String(localized: "Not connected")
        }
    }
}

/// 同步进度 / 同步按钮（侧栏底部和概览共用）
struct SyncStatus: View {
    let device: DeviceController
    let library: LibraryStore
    var compact = false

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
            if !device.isReady {
                // 没连上时不放一个点不动的同步按钮：说清楚新录音还在录音豆上、连上后才能同步
                if pending > 0 {
                    Text("\(pending) new recordings are on the recorder. Sync them once it connects.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(compact ? .leading : .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: compact ? .infinity : 220, alignment: compact ? .leading : .trailing)
                }
            } else if compact {
                if pending > 0 {
                    Button { Task { await library.syncAll() } } label: {
                        Label("Sync \(pending) new", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(!device.isReady || device.activity != .idle)
                    .help(estimate ?? "")
                }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button { Task { await library.syncAll() } } label: {
                        Text(pending > 0 ? "Sync \(pending) new" : "Sync")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.isReady || device.activity != .idle)
                    if let estimate { Text(estimate).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var pending: Int { library.recordings.filter { $0.onDevice && !$0.downloaded && !$0.isDictation }.count }

    /// 「蓝牙约需 12 分钟」；没有要下的就没有
    private var estimate: String? {
        library.pendingSyncSeconds.map { String(localized: "About \(Self.phrase($0)) over Bluetooth") }
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

// MARK: - 录音库：列表 + 详情

struct LibraryPage: View {
    let model: AppModel
    @State private var query = ""

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
        .navigationTitle("Library")
        .onAppear {
            // 第一次进来默认选最近一条
            if library.selection == nil { library.selection = library.visible.first?.id }
        }
    }

    private var emptyLibrary: some View {
        let device = model.device
        return ContentUnavailableView {
            Label("No recordings yet", systemImage: "waveform")
        } description: {
            Text(device.isReady
                 ? "Recordings you make on the recorder show up here after you sync them to this Mac."
                 : "Take the recorder out of its case to connect. Its recordings show up here after you sync them.")
        } actions: {
            if device.isReady {
                Button("Sync") { Task { await model.library.syncAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(device.activity != .idle)
            }
        }
    }

    private var columns: some View {
        let library = model.library
        return HStack(spacing: 0) {
            RecordingList(library: library, nav: model.nav,
                          selection: Binding(get: { library.selection }, set: { library.selection = $0 }),
                          query: $query)
                .frame(width: 300)
            Divider()
            Group {
                if let id = library.selection, let r = library.recordings.first(where: { $0.id == id }) {
                    RecordingDetail(recording: r, library: library, device: model.device).id(id)
                } else {
                    LibraryHome(device: model.device, settings: model.settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 概览

struct OverviewView: View {
    let model: AppModel
    @State private var period: Period = .week
    @Environment(\.colorScheme) private var scheme

    enum Period: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self { case .week: "This week"; case .month: "This month"; case .all: "All time" }
        }
        var interval: DateInterval? {
            switch self {
            case .week: Calendar.current.dateInterval(of: .weekOfYear, for: Date())
            case .month: Calendar.current.dateInterval(of: .month, for: Date())
            case .all: nil
            }
        }
    }

    private var library: LibraryStore { model.library }
    private var device: DeviceController { model.device }
    private var recordings: [Recording] { library.recordings.filter { !$0.isDictation } }

    var body: some View {
        // 窗口够高时撑满：图表和最近录音吃掉剩余高度；太矮时整页滚动
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            if recordings.isEmpty && model.log.entries.isEmpty {
                // 还什么都没有：不摆一排 0 和空图表，告诉人从哪开始
                gettingStarted.frame(maxHeight: .infinity, alignment: .top)
            } else {
                tiles
                HStack(alignment: .top, spacing: 12) {
                    ActivityChart(recordings: recordings, log: model.log)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    recent.frame(minWidth: 260, maxWidth: 380, maxHeight: .infinity)
                }
                .frame(minHeight: 280, maxHeight: .infinity)
            }
            statusStrip
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // 录音豆
    private var hero: some View {
        let info = device.info
        let onDevice = library.recordings.filter { $0.onDevice && !$0.isDictation }
        let pending = onDevice.filter { !$0.downloaded }.count
        // 两行：上面是设备和同步，下面三个数平分宽度，窗口窄时也不会挤出去
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                BeanBadge(size: 44, color: device.isReady ? .accentColor : .white.opacity(0.15))
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.deviceName).font(.headline)
                    Text(heroStatus(info)).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 12)
                SyncStatus(device: device, library: library).fixedSize()
            }
            if let info {
                let used = Double(Int(info.totalKB) - Int(info.freeKB)), total = Double(max(info.totalKB, 1))
                let battery = device.battery ?? info.micBattery ?? 0
                HStack(alignment: .top, spacing: 24) {
                    HeroMetric(title: "Battery", value: Text("\(battery)%"), progress: Double(battery) / 100)
                    HeroMetric(title: "Storage", value: Text(bytes(used)), progress: used / total,
                               note: Text("of \(bytes(total))"))
                    HeroMetric(title: "On the recorder", value: Text("\(onDevice.count)"),
                               note: pending > 0 ? Text("\(pending) not synced") : Text("All synced"))
                }
            } else {
                if case .failed = device.state, let p = device.problem {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.callout.weight(.semibold))
                        Text(p.advice).font(.callout).foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    Text(device.isReady ? "Reading the recorder…" : "Take the recorder out of its case to connect.")
                        .font(.callout).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(0.07) : Color(red: 0.106, green: 0.114, blue: 0.129)))
    }

    private func heroStatus(_ info: DeviceInfo?) -> String {
        var s = DeviceFooter.status(device, library)
        if let f = info?.firmware, !f.isEmpty { s += " · " + String(localized: "Firmware \(f)") }
        return s
    }

    // 四个数
    private var tiles: some View {
        let inPeriod = recordings.filter { period.interval?.contains($0.start) ?? true }
        let secs = inPeriod.reduce(0) { $0 + $1.duration }
        let done = inPeriod.filter(\.transcribed).reduce(0) { $0 + $1.duration }
        let typed = model.log.entries(in: period.interval)
        let local = recordings.filter(\.downloaded).count
        return Grid(horizontalSpacing: 12) {
            GridRow {
                StatTile(title: "Recordings", value: Text("\(recordings.count)"),
                         note: Text("\(local) on this Mac"))
                StatTile(title: "Times recorded", value: Text("\(inPeriod.count)"), note: Text(period.title))
                StatTile(title: "Recorded", value: Text(hours(secs)),
                         note: Text("\(hours(done)) transcribed"))
                StatTile(title: "Voice typing",
                         value: Text("\(typed.reduce(0) { $0 + $1.characters }) characters"),
                         note: Text("\(typed.count) times"))
            }
        }
    }

    // 最近录音
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent recordings").font(.headline)
                Spacer()
                Button("See all") { model.nav.section = .library }.buttonStyle(.link)
            }
            .padding(.bottom, 6)
            let list = Array(recordings.sorted { $0.start > $1.start }.prefix(20))
            if list.isEmpty {
                Text("No recordings yet").foregroundStyle(.secondary).padding(.vertical, 8)
            }
            // 卡片多高就放几条整行（不露半行），其余去「查看全部」
            GeometryReader { geo in
            let n = max(1, min(list.count, Int((geo.size.height + 1) / (Self.recentRow + 1))))
            VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.prefix(n).enumerated()), id: \.element.id) { i, r in
                Button { model.nav.show(recording: r.id, in: library) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title?.isEmpty == false ? r.title! : RelativeDate.name(r.start)).font(.callout.weight(.medium)).lineLimit(1)
                            Text(recentStatus(r)).font(.caption).foregroundStyle(library.transcribing[r.id] != nil ? Color.accentColor : .secondary)
                        }
                        Spacer()
                        Text(LibraryStore.clock(r.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(height: Self.recentRow)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < n - 1 { Divider() }
            }
            }
            }
            .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    /// 最近录音一行的高度（两行字加上下留白）
    private static let recentRow: CGFloat = 46

    // 第一次用：三步入门
    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Getting started").font(.headline)
            step(done: device.isReady, number: 1, title: "Connect your recorder",
                 detail: "Take it out of its case. OpenBean finds it over Bluetooth.")
            step(done: !model.log.entries.isEmpty, number: 2, title: "Try voice typing",
                 detail: "Press the recorder's button, speak, then press it again. The text goes where your cursor is.")
            step(done: !recordings.isEmpty, number: 3, title: "Sync your first recording",
                 detail: "Recordings made on the recorder come to this Mac and are transcribed here.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private func step(done: Bool, number: Int, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
        }
    }

    private func recentStatus(_ r: Recording) -> String {
        if let p = library.transcribing[r.id] { return String(localized: "Transcribing \(Int(p * 100))%") }
        if !r.downloaded { return String(localized: "On your recorder") }
        return r.transcribed ? String(localized: "Transcribed") : String(localized: "Not transcribed")
    }

    // 语音输入当前怎么配置
    private var statusStrip: some View {
        let s = model.settings
        return HStack(spacing: 20) {
            Text("Voice typing").fontWeight(.semibold)
            Label(s.buttonDictates ? "Button: voice typing" : "Button: record only", systemImage: "button.programmable")
            Label(s.hotkeyLabel, systemImage: "command")
            Label(model.models.state == .ready ? "SenseVoice on this Mac" : "Speech models not downloaded", systemImage: "waveform")
            Label(s.polishEnabled ? "LLM clean-up on" : "LLM clean-up off", systemImage: "sparkles")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private func hours(_ s: Double) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = s >= 3600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(s).formatted(.units(allowed: units, width: .abbreviated))
    }

    private func bytes(_ kb: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb * 1024), countStyle: .file)
    }
}

private struct HeroMetric: View {
    let title: LocalizedStringKey
    let value: Text
    var progress: Double?
    var note: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.6))
            value.font(.title2.weight(.semibold).monospacedDigit())
            if let progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(Color.accentColor).controlSize(.small)
            }
            if let note {
                note.font(.caption).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: Text
    let note: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            value.font(.system(size: 24, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            note.font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

/// 最近 14 天：录音分钟数或语音输入字数（单位不同，不画在一起）
private struct ActivityChart: View {
    let recordings: [Recording]
    let log: DictationLog
    @State private var metric: Metric = .recorded

    enum Metric: String, CaseIterable, Identifiable {
        case recorded, typed
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .recorded ? "Minutes recorded" : "Characters typed" }
    }

    struct Day: Identifiable { let date: Date; let value: Double; var id: Date { date } }

    private var days: [Day] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: today)!
            let v: Double
            switch metric {
            case .recorded:
                v = recordings.filter { cal.isDate($0.start, inSameDayAs: d) }.reduce(0) { $0 + $1.duration } / 60
            case .typed:
                v = Double(log.entries.filter { cal.isDate($0.date, inSameDayAs: d) }.reduce(0) { $0 + $1.characters })
            }
            return Day(date: d, value: v)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last 14 days").font(.headline)
                Spacer()
                Picker("Show", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            Chart(days) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Value", d.value))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) {
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() } }
            .frame(minHeight: 160, idealHeight: 200, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: metric)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

// MARK: - 语音输入记录

struct DictationHistoryView: View {
    let log: DictationLog
    let settings: Settings
    @State private var confirmClear = false

    var body: some View {
        List {
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
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .disabled(log.entries.isEmpty)
            }
        }
        .confirmationDialog("Clear all voice typing history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { log.clear() }
        } message: {
            Text("This removes the text kept on this Mac. It does not change anything you already typed.")
        }
    }

    private var sections: [(title: String, items: [DictationEntry])] {
        let cal = Calendar.current
        var order: [String] = []
        var groups: [String: [DictationEntry]] = [:]
        for e in log.entries {
            let key: String
            if cal.isDateInToday(e.date) { key = String(localized: "Today") }
            else if cal.isDateInYesterday(e.date) { key = String(localized: "Yesterday") }
            else { key = e.date.formatted(date: .abbreviated, time: .omitted) }
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
