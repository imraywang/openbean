// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import OpenBeanLibrary
import SwiftUI

// MARK: - 一天的内容（只读：现有的录音、缓存里的摘要和待办勾选状态、语音输入记录）

/// 「今天」页上的一块：一条录音，或者（切成了多段的录音）其中一段对话。顶上另有当天的日记（TodayDiarySection）
enum TodayBlock: Identifiable {
    case recording(Recording)
    case conversation(Recording, Conversation)

    var id: String {
        switch self {
        case let .recording(r): return "r\(r.id)"
        case let .conversation(r, c): return "c\(r.id)#\(c.index)"
        }
    }

    var start: Date {
        switch self {
        case let .recording(r): return r.start
        case let .conversation(_, c): return c.wallStart
        }
    }
}

/// 某一天要显示的东西
@MainActor
struct DayDigest {
    let day: Date
    /// 这天的录音（不含语音输入片段），按开始时间先后。只有一段对话的录音按开始时刻归天；
    /// 切成多段的录音按段的开始时刻归天（跨过一天分界的长录音两天都有），每段一块
    let recordings: [Recording]
    let blocks: [TodayBlock]
    let dictation: [DictationEntry]

    init(day: Date, boundary: DayBoundary, library: LibraryStore, log: DictationLog) {
        self.day = day
        let interval = boundary.interval(of: day)
        var recs: [Recording] = [], blocks: [TodayBlock] = []
        // 录音最早可以从前一天开始（段落在这一天里）
        for r in library.recordings where !r.isDictation && r.start < interval.end && r.start >= interval.start.addingTimeInterval(-86_400) {
            let convs = r.transcribed ? library.conversations.conversations(r.id) : []
            if convs.count > 1 {
                let mine = convs.filter { boundary.day(of: $0.wallStart) == day }
                if !mine.isEmpty { recs.append(r); blocks += mine.map { .conversation(r, $0) } }
            } else if boundary.day(of: r.start) == day {
                recs.append(r)
                blocks.append(.recording(r))
            }
        }
        recordings = recs.sorted { $0.start < $1.start }
        self.blocks = blocks.sorted { $0.start < $1.start }
        dictation = log.entries.filter { boundary.day(of: $0.date) == day }.sorted { $0.date < $1.date }
    }

    var untranscribed: [Recording] { recordings.filter { $0.downloaded && !$0.transcribed } }

    /// 往前最近一个有录音的日子（没有录音的一天里给链接用）
    static func previousDay(before day: Date, boundary: DayBoundary, library: LibraryStore) -> Date? {
        library.recordings.lazy.filter { !$0.isDictation }.map { boundary.day(of: $0.start) }.filter { $0 < day }.max()
    }
}

// MARK: - 页面

/// 「今天」：心力模式页开着时的内容（HeartPage），心力模式下打开 OpenBean 就落在这一页。这一页只在心力模式里出现，设备都叫「心力豆」。
/// 今天录了什么、每段在说什么、要做什么、还有什么没处理；可以前后翻天。
/// 一天从凌晨 4 点算（设置里可改），和以后的每日日记共用 OpenBeanLibrary 的 DayBoundary。
struct TodayView: View {
    let model: AppModel
    @State private var showPicker = false
    @State private var dictationExpanded = false

    private var library: LibraryStore { model.library }
    private var boundary: DayBoundary { DayBoundary(startHour: model.settings.dayStartHour) }

    var body: some View {
        let today = boundary.day(of: Date())
        let day = model.nav.day.map { min($0, today) } ?? today
        let digest = DayDigest(day: day, boundary: boundary, library: library, log: model.log)
        let firstRun = library.recordings.allSatisfy(\.isDictation) && model.log.entries.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header(day: day, today: today)
                // 设备状态和同步进度是「现在」的事：只在看今天时显示
                if day == today {
                    HeartSyncStrip(progress: library.progress) { model.nav.open(.voiceTyping(cleanUp: true)) }
                    TodayDeviceLine(device: model.device, library: library) { model.nav.section = .recorder }
                }
                if firstRun {
                    GettingStarted(model: model)
                } else if digest.recordings.isEmpty {
                    emptyDay(day: day, today: today)
                } else {
                    attention(digest)
                    TodayDiarySection(model: model, day: day, digest: digest)
                    todos(digest)
                    timeline(digest)
                }
                if !digest.dictation.isEmpty { dictationRow(digest.dictation) }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title(day: day, today: today))
        .toolbar { toolbar(day: day, today: today) }
        // 这天各条录音的摘要和待办状态在后台读进缓存（不在主线程上逐条读盘）
        .task(id: digest.recordings.map(\.id)) {
            library.notes.preload(digest.recordings.filter(\.transcribed).map(\.id))
        }
    }

    // MARK: 标题和翻天

    private func title(day: Date, today: Date) -> String {
        if day == today { return String(localized: "Today") }
        if day == boundary.day(today, offsetBy: -1) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.month().day().weekday(.wide))
    }

    private func header(day: Date, today: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(verbatim: day.formatted(.dateTime.year().month().day().weekday(.wide)) + " · "
                     + String(localized: "starts at \(startLabel)"))
                    .font(.callout).foregroundStyle(.secondary)
                HeartOnBadge()
            }
            Text(title(day: day, today: today))
                .font(.system(size: 28, weight: .bold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var startLabel: String {
        Calendar.current.date(bySettingHour: boundary.startHour, minute: 0, second: 0, of: Date())!
            .formatted(date: .omitted, time: .shortened)
    }

    @ToolbarContentBuilder private func toolbar(day: Date, today: Date) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { go(boundary.day(day, offsetBy: -1), today: today) } label: {
                Label("Previous day", systemImage: "chevron.left")
            }
            .help("Previous day (⌘←)")
            .keyboardShortcut(.leftArrow, modifiers: .command)
            Button { go(boundary.day(day, offsetBy: 1), today: today) } label: {
                Label("Next day", systemImage: "chevron.right")
            }
            .help("Next day (⌘→)")
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(day >= today)
        }
        ToolbarItemGroup(placement: .navigation) {
            Button("Today") { model.nav.day = nil }
                .disabled(day == today)
                .keyboardShortcut("t", modifiers: .command)
                .help("Go to today (⌘T)")
            Button { showPicker = true } label: {
                Label("Choose a day", systemImage: "calendar")
            }
            .help("Choose a day")
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                DatePicker("Day", selection: Binding(get: { day }, set: { go(Calendar.current.startOfDay(for: $0), today: today); showPicker = false }),
                           in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(12)
            }
        }
    }

    private func go(_ day: Date, today: Date) {
        model.nav.day = day >= today ? nil : day
    }

    // MARK: 块

    /// 要处理的事：这天还没转写的录音（录音豆上的新录音在设备那一行）
    @ViewBuilder private func attention(_ d: DayDigest) -> some View {
        let n = d.untranscribed.count
        if n > 0 {
            TodayCallout(icon: "text.bubble", tint: .orange) {
                Text("\(n) recordings from this day aren't transcribed yet")
            } action: {
                Button("Show") { model.nav.section = .library; library.filter = .untranscribed }
            }
        }
    }

    /// 这天所有录音的待办汇总，能勾选；标出来自哪条录音（有段摘要的多段录音：来自哪段对话）
    @ViewBuilder private func todos(_ d: DayDigest) -> some View {
        let items = TodayTodos.items(d, library: library)
        if !items.isEmpty {
            let done = items.filter { library.notes.isDone($0.0.id, $0.1) }.count
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("To-dos").font(.headline)
                    Text("\(done) of \(items.count) done").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    let (r, t, source) = it
                    TodoRow(text: t, done: Binding(get: { library.notes.isDone(r.id, t) },
                                                   set: { library.notes.setDone(r.id, t, $0) }),
                            source: source)
                }
            }
        }
    }

    private func timeline(_ d: DayDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Timeline").font(.headline)
                Text(summaryLine(d)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(d.blocks) { b in
                    switch b {
                    case let .recording(r):
                        TodayRecordingBlock(recording: r, library: library) { model.nav.show(recording: r.id, in: library) }
                    case let .conversation(r, c):
                        TodayConversationBlock(recording: r, conversation: c) { model.nav.show(recording: r.id, in: library) }
                    }
                }
            }
        }
    }

    /// 「5 条 · 1 小时 3 分钟」
    private func summaryLine(_ d: DayDigest) -> String {
        let secs = d.recordings.reduce(0) { $0 + $1.duration }
        let units: Set<Duration.UnitsFormatStyle.Unit> = secs >= 3600 ? [.hours, .minutes] : [.minutes]
        return String(localized: "\(d.recordings.count) recordings · \(Duration.seconds(secs).formatted(.units(allowed: units, width: .wide)))")
    }

    /// 语音输入折叠成一行，展开才看每条
    private func dictationRow(_ entries: [DictationEntry]) -> some View {
        let chars = entries.reduce(0) { $0 + $1.characters }
        return DisclosureGroup(isExpanded: $dictationExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entries) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(e.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let app = e.app { Text("→ \(app)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label { Text("Voice typing \(entries.count) times · \(chars) characters") } icon: { Image(systemName: "keyboard") }
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 没有录音的一天

    private func emptyDay(day: Date, today: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(day == today ? "No recordings yet today" : "No recordings on this day").font(.title3.weight(.semibold))
            Text("Recordings from the Heart bean show up here by day after you sync them.")
                .foregroundStyle(.secondary)
            if let prev = DayDigest.previousDay(before: day, boundary: boundary, library: library) {
                Button {
                    model.nav.day = prev
                } label: {
                    Label { Text("Previous day with recordings: \(prev.formatted(.dateTime.month().day().weekday(.wide)))") }
                        icon: { Image(systemName: "chevron.left") }
                }
                .buttonStyle(.link)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 24)
    }
}

// MARK: - 一条录音一块

/// 时间线上的一条录音：时间、时长、标题、摘要的导语（没有就是转写的第一句或状态）、还有几条没勾的待办。点了去录音库看这一条
struct TodayRecordingBlock: View {
    let recording: Recording
    let library: LibraryStore
    let open: () -> Void

    var body: some View {
        let s = library.notes.cachedSummary(recording.id)
        let open = library.notes.openTodos(recording.id).count
        Button(action: self.open) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(recording.start.formatted(date: .omitted, time: .shortened)).font(.callout.monospacedDigit())
                    Text(LibraryStore.clock(recording.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let until = endsNextDay {
                        Text(until).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                .frame(width: 80, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    // 没有标题的录音：左边已经写了时间，这里不再重复日期
                    Text(recording.title?.isEmpty == false ? recording.title! : String(localized: "Untitled recording"))
                        .font(.headline).multilineTextAlignment(.leading)
                    if let lead = s?.summary {
                        Text(lead).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(status).foregroundStyle(library.transcribing[recording.id] != nil ? Color.accentColor : .secondary)
                            .lineLimit(2)
                    }
                    if open > 0 {
                        Label { Text("\(open) open to-dos") } icon: { Image(systemName: "checklist") }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 2) }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in Library")
        .accessibilityHint(Text("Open in Library"))
    }

    /// 跨午夜的录音：「到次日 1:20」
    private var endsNextDay: String? {
        let end = recording.start.addingTimeInterval(recording.duration)
        guard !Calendar.current.isDate(end, inSameDayAs: recording.start) else { return nil }
        return String(localized: "until \(end.formatted(date: .omitted, time: .shortened)) next day")
    }

    private var status: String {
        if let p = library.transcribing[recording.id] { return String(localized: "Transcribing \(Int(p * 100))%") }
        if !recording.downloaded { return String(localized: "Still on the Heart bean. It's transcribed after you sync it.") }
        if !recording.transcribed { return String(localized: "Not transcribed") }
        return library.snippet(recording.id) ?? String(localized: "No speech")
    }
}

// MARK: - 设备一行

/// 「今天」顶上的设备一行（心力模式里，叫心力豆）：平时很淡（名字 · 电量）；有事（没连上、电量低、录音豆上有新录音、正在同步）才变成提示
struct TodayDeviceLine: View {
    let device: DeviceController
    let library: LibraryStore
    let openRecorder: () -> Void

    private var pending: [Recording] { library.recordings.filter { $0.onDevice && !$0.downloaded && !$0.isDictation } }

    var body: some View {
        if case let .downloading(_, done, total, f, _) = library.sync {
            TodayCallout(icon: "arrow.triangle.2.circlepath", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 6) {
                    if let left = library.syncSecondsLeft {
                        Text("Syncing \(done + 1) of \(total) — about \(SyncStatus.phrase(left)) left")
                    } else {
                        Text("Syncing \(done + 1) of \(total)")
                    }
                    ProgressView(value: f).controlSize(.small)
                    WifiSuggestion(device: device, library: library)
                }
            } action: { EmptyView() }
        } else if !device.isReady {
            let p = device.problem
            TodayCallout(icon: p?.symbol ?? "antenna.radiowaves.left.and.right.slash", tint: .orange) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p?.title ?? String(localized: "The Heart bean isn't connected")).fontWeight(.medium)
                    Text(p?.advice ?? String(localized: "Take the Heart bean out of its case to connect."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !pending.isEmpty {
                        Text("\(pending.count) new recordings are on the Heart bean. Sync them once it connects.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } action: {
                Button("Heart bean details", action: openRecorder)
            }
        } else if !pending.isEmpty {
            TodayCallout(icon: "arrow.down.circle", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pending.count) new recordings on the Heart bean").fontWeight(.medium)
                    if let s = library.pendingSyncSeconds {
                        Text("About \(SyncStatus.phrase(s)) over Bluetooth. Use Sync in the toolbar.").foregroundStyle(.secondary)
                    }
                    WifiSuggestion(device: device, library: library)
                }
            } action: { EmptyView() }
        } else if let b = device.battery, b <= 20 {
            TodayCallout(icon: "battery.25percent", tint: .orange) {
                Text("\(device.deviceName) battery is low (\(b)%). Put it back in its case to charge.")
            } action: { Button("Heart bean details", action: openRecorder) }
        } else {
            // 没事：很淡的一行
            Button(action: openRecorder) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(device.battery.map { "\(device.deviceName) · \($0)%" } ?? device.deviceName)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show Heart bean details")
        }
    }
}

/// 「今天」里带图标、说明和按钮的提示
struct TodayCallout<Content: View, Action: View>: View {
    let icon: String
    let tint: Color
    @ViewBuilder var content: Content
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 24)
            content.frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 第一次用

/// 还没有录音、也没用过语音输入时：三步入门（原来在概览里）
struct GettingStarted: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Getting started").font(.headline)
            step(done: model.device.isReady, number: 1, title: "Connect your Heart bean",
                 detail: "Take it out of its case. OpenBean finds it over Bluetooth.")
            step(done: !model.log.entries.isEmpty, number: 2, title: "Try voice typing",
                 detail: "Press the Heart bean's button, speak, then press it again. The text goes where your cursor is.")
            step(done: !model.library.recordings.allSatisfy(\.isDictation), number: 3, title: "Sync your first recording",
                 detail: "Recordings made on the Heart bean come to this Mac and are transcribed here.")
        }
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
}
