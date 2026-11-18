// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

// MARK: - 心力模式页（App 打开默认落在这里）
//
// 关着：「心力模式已关闭」和「设置心力模式…」（走引导，看完最后一步才打开）。
// 开着：某一天的内容（HeartDayView）：今天的同步四步、日记概述、定了的事、待办、提到的人、对话段；左右翻天，能回到今天。
// 右上角齿轮是心力模式设置。数据都是共用的（DiaryService、ConversationStore、SyncProgress），和 Mac 版同一套。
//
// 演示数据截图用的启动参数（只在 -demo 下生效）：-heartOff YES、-heartIntro <页 0–3>、-heartDaysBack <往前几天，如 1>、
// -heartSync expanded|running、-heartOpen segment|settings

struct HeartTab: View {
    let model: MobileModel
    @State private var path = NavigationPath()
    @State private var showIntro = false
    @State private var introStep = 0
    @State private var demoApplied = false

    private var settings: Settings { model.settings }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if settings.heartMode {
                    HeartDayView(model: model, path: $path)
                } else {
                    HeartOffView { introStep = 0; showIntro = true }
                        .navigationTitle("Heart mode")
                }
            }
            .navigationDestination(for: ConversationKey.self) { key in
                ConversationDetailView(library: model.library, key: key)
            }
            .navigationDestination(for: HeartRoute.self) { r in
                switch r {
                case .settings: HeartSettingsView(model: model)
                }
            }
        }
        .sheet(isPresented: $showIntro) {
            HeartIntroSheet(model: model, step: introStep)
        }
        .onChange(of: settings.heartMode) { _, now in
            Log.write(now ? "打开心力模式" : "关闭心力模式")
            if now { model.library.notes.diary.catchUp() } else { path = NavigationPath() }
        }
        .onAppear { applyDemoArguments() }
    }

    /// 演示数据截图：按启动参数摆好页面（只做一次）
    private func applyDemoArguments() {
        guard Flavor.isDemo, !demoApplied else { return }
        demoApplied = true
        let d = UserDefaults.standard
        if d.bool(forKey: "heartOff") { settings.heartMode = false }
        if d.object(forKey: "heartIntro") != nil {
            introStep = d.integer(forKey: "heartIntro")
            showIntro = true
        }
        if let s = d.string(forKey: "heartSync") {
            DemoHeartRun.apply(s, to: model.library.progress)
        }
        switch d.string(forKey: "heartOpen") {
        case "settings": path.append(HeartRoute.settings)
        case "segment":
            if let k = HeartDayView.conversations(model.library, day: model.library.dayBoundary.day(of: Date())).dropFirst().first?.key {
                path.append(k)
            }
        default: break
        }
    }
}

enum HeartRoute: Hashable { case settings }

/// 一段对话：哪条录音的第几段
struct ConversationKey: Hashable {
    var recording: UInt32
    var index: Int
}

/// 某一天里的一段对话
struct DayItem: Identifiable {
    var key: ConversationKey
    var recording: Recording
    var conversation: Conversation
    var id: ConversationKey { key }
}

// MARK: - 关着

struct HeartOffView: View {
    let setUp: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Heart mode is off", systemImage: "heart")
        } description: {
            Text("Wear your Heart bean all day. When it goes back in its case, OpenBean syncs it — even with your iPhone in your pocket — and sorts the day into conversations, a diary and to-dos.")
        } actions: {
            Button("Set up Heart mode…", action: setUp)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - 某一天

struct HeartDayView: View {
    let model: MobileModel
    @Binding var path: NavigationPath
    /// nil = 今天（跨过一天的分界时自动跟着变）
    @State private var picked: Date?
    @State private var todos = DayTodoState()
    @Bindable private var router = MobileRouter.shared

    private var library: LibraryStore { model.library }
    private var settings: Settings { model.settings }
    private var boundary: DayBoundary { library.dayBoundary }
    private var today: Date { boundary.day(of: Date()) }
    private var day: Date { picked.map { min($0, today) } ?? today }
    private var isToday: Bool { day >= today }
    private var heart: Bool { settings.mode.callsDeviceHeartBean }

    var body: some View {
        let file = library.notes.diary.day(day)
        let convs = Self.conversations(library, day: day)
        let waiting = untranscribed
        let onDevice = isToday ? library.recordings.filter { $0.onDevice && !$0.downloaded && !$0.isDictation } : []
        let empty = convs.isEmpty && file?.diary == nil && waiting.isEmpty
        List {
            Section {
                EmptyView()
            } header: {
                Text(verbatim: day.formatted(.dateTime.year().month().day().weekday(.wide)) + " · "
                     + String(localized: "starts at \(startLabel)"))
                    .textCase(nil)
            }
            if isToday {
                HeartSyncSection(model: model, onDevice: onDevice.count)
            }
            if !waiting.isEmpty {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(waiting.count) recordings from this day aren't transcribed yet")
                            if library.transcribing.isEmpty {
                                Button("Transcribe now") { transcribe(waiting) }
                            } else {
                                Text("Transcribing…").foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    } icon: { Image(systemName: "text.bubble").foregroundStyle(.orange) }
                }
            }
            if empty {
                emptySection
            } else {
                DiarySections(model: model, day: day, file: file, conversations: convs, todos: $todos)
                conversationSection(convs)
            }
        }
        .navigationTitle(title)
        .toolbar { toolbar }
        .simultaneousGesture(swipe)
        .refreshable { await model.device.refreshInfo() }
        .task(id: library.notes.diary.key(day)) { todos = TodoFile.read(library.notes.diary.key(day)) }
        .onChange(of: router.todayRequests) { _, _ in picked = nil; path = NavigationPath() }
        .onAppear {
            let back = UserDefaults.standard.integer(forKey: "heartDaysBack")
            if Flavor.isDemo, picked == nil, back > 0 { picked = boundary.day(today, offsetBy: -back) }
        }
    }

    // MARK: 标题和翻天

    private var title: String {
        if isToday { return String(localized: "Today") }
        if day == boundary.day(today, offsetBy: -1) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.month().day().weekday())
    }

    private var startLabel: String {
        Calendar.current.date(bySettingHour: boundary.startHour, minute: 0, second: 0, of: Date())!
            .formatted(date: .omitted, time: .shortened)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { go(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous day")
            Button { go(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next day")
                .disabled(isToday)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !isToday {
                Button("Today") { withAnimation { picked = nil } }
            }
            NavigationLink(value: HeartRoute.settings) { Image(systemName: "gearshape") }
                .accessibilityLabel("Heart mode settings")
        }
    }

    private func go(_ offset: Int) {
        let d = boundary.day(day, offsetBy: offset)
        withAnimation(.easeOut(duration: 0.2)) { picked = d >= today ? nil : d }
    }

    /// 左右划翻天（横向为主的划动才算，不和上下滚动抢）
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { v in
            let dx = v.translation.width, dy = v.translation.height
            guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
            if dx > 0 { go(-1) } else if !isToday { go(1) }
        }
    }

    // MARK: 内容

    /// 这一天的对话段（按开始时间）：切成多段的录音按段归天（跨过分界的长录音两天都有）
    static func conversations(_ library: LibraryStore, day: Date) -> [DayItem] {
        _ = library.conversations.revision
        let b = library.dayBoundary
        let interval = b.interval(of: day)
        var out: [DayItem] = []
        for r in library.recordings where r.transcribed && !r.isDictation && r.start < interval.end
            && r.start >= interval.start.addingTimeInterval(-86_400) {
            for c in library.conversations.conversations(r.id) where b.day(of: c.wallStart) == day {
                out.append(DayItem(key: ConversationKey(recording: r.id, index: c.index), recording: r, conversation: c))
            }
        }
        return out.sorted { $0.conversation.wallStart < $1.conversation.wallStart }
    }

    /// 这天下载了、还没转写的录音
    private var untranscribed: [Recording] {
        library.recordings.filter { $0.downloaded && !$0.transcribed && !$0.isDictation && boundary.day(of: $0.start) == day }
    }

    private func transcribe(_ rs: [Recording]) {
        Task { for r in rs.sorted(by: { $0.start < $1.start }) { await library.transcribe(r.id) } }
    }

    private func conversationSection(_ items: [DayItem]) -> some View {
        Section {
            ForEach(items) { item in
                NavigationLink(value: item.key) {
                    ConversationRow(library: library, recording: item.recording, conversation: item.conversation)
                }
            }
        } header: {
            HStack {
                Text("Conversations")
                Spacer()
                Text(verbatim: summaryLine(items.map(\.conversation))).textCase(nil).monospacedDigit()
            }
        }
    }

    /// 「5 段 · 1 小时 3 分钟」
    private func summaryLine(_ cs: [Conversation]) -> String {
        let secs = cs.reduce(0) { $0 + $1.duration }
        let units: Set<Duration.UnitsFormatStyle.Unit> = secs >= 3600 ? [.hours, .minutes] : [.minutes]
        return String(localized: "\(cs.count) conversations · \(Duration.seconds(max(secs, 60)).formatted(.units(allowed: units, width: .abbreviated)))")
    }

    @ViewBuilder private var emptySection: some View {
        Section {
            ContentUnavailableView {
                Label(isToday ? "No recordings yet today" : "No recordings on this day", systemImage: "calendar")
            } description: {
                Text(heart ? "Recordings from the Heart bean show up here by day after they're synced."
                     : "Recordings from the recorder show up here by day after they're synced.")
            } actions: {
                if let prev = previousDayWithRecordings {
                    Button {
                        withAnimation { picked = prev }
                    } label: {
                        Text("Previous day with recordings: \(prev.formatted(.dateTime.month().day().weekday(.wide)))")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private var previousDayWithRecordings: Date? {
        library.recordings.lazy.filter { !$0.isDictation }.map { boundary.day(of: $0.start) }.filter { $0 < day }.max()
    }
}

// MARK: - 对话段一行

struct ConversationRow: View {
    let library: LibraryStore
    let recording: Recording
    let conversation: Conversation

    var body: some View {
        let s = conversation.summary
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: (conversation.wallApprox ? "~" : "") + conversation.wallStart.formatted(date: .omitted, time: .shortened)
                     + "–" + conversation.wallEnd.formatted(date: .omitted, time: .shortened))
                Text(verbatim: "·")
                Text(verbatim: LibraryStore.clock(conversation.duration))
                if let n = s?.todos.count, n > 0 {
                    Label { Text("\(n) to-dos") } icon: { Image(systemName: "checklist") }
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(verbatim: Self.title(conversation, library: library, recording: recording))
                .font(.headline).lineLimit(2)
            if let lead = s?.summary, !lead.isEmpty {
                Text(lead).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            } else if conversation.kind == "fragment" {
                Text("A few words").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    /// 段的标题；还没有段摘要时用这段的第一句
    static func title(_ c: Conversation, library: LibraryStore, recording r: Recording) -> String {
        if let t = c.summary?.title, !t.isEmpty { return t }
        // 读的时候显示的那份（干净版里整句是语气词的跳过）
        let shown = library.readingLines(r.id)
        if let i = c.spokenLines.first(where: { $0 < shown.count && !shown[$0].isEmpty }) { return shown[i] }
        return String(localized: "Conversation")
    }
}

// MARK: - 演示数据的同步四步

enum DemoHeartRun {
    @MainActor static func apply(_ name: String, to p: SyncProgress) {
        var r = SyncRun(ids: [1, 2, 3], options: SyncRun.Options(), now: Date().addingTimeInterval(-900))
        for id: UInt32 in [1, 2, 3] { r.recordDownloaded(id) }
        r.downloadEnded()
        switch name {
        case "running":
            r.recordTranscribed(1, ok: true); r.recordTranscribed(2, ok: true)
            r.recordDiary(1, .written)
        default:
            for id: UInt32 in [1, 2, 3] { r.recordTranscribed(id, ok: true); r.recordDiary(id, .written) }
            r.recordCleanUp(1, .deleted); r.recordCleanUp(2, .deleted); r.recordCleanUp(3, .deleted)
            _ = r.markFinishedIfSettled(now: Date().addingTimeInterval(-600))
        }
        p.demoSet(r, expanded: name == "expanded")
    }
}
