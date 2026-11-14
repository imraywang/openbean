// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

/// 心力模式：开关、这次同步的四步进度、今天的日记和对话段（只读）。数据都是共用的（DiaryService、ConversationStore、SyncProgress）
struct HeartTab: View {
    let model: MobileModel
    @State private var day = Date()

    private var settings: Settings { model.settings }
    private var library: LibraryStore { model.library }
    private var boundary: DayBoundary { library.dayBoundary }
    private var dayStart: Date { boundary.day(of: day) }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                Section {
                    Toggle("Heart mode", isOn: $settings.heartMode)
                } footer: {
                    Text("Wear the recorder all day. When it goes back in its case, OpenBean syncs, transcribes, splits the day into conversations and writes the day's diary and to-dos.")
                }
                if settings.heartMode, let run = library.progress.run {
                    Section("Sync") {
                        ForEach(run.steps, id: \.step) { p in
                            LabeledContent(SyncRunText.title(p.step), value: SyncRunText.status(p))
                        }
                    }
                }
                DiarySections(day: library.notes.diary.day(dayStart))
                ConversationSections(items: conversations)
            }
            .navigationTitle(dayTitle)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { day = boundary.day(dayStart, offsetBy: -1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous day")
                    Button { day = boundary.day(dayStart, offsetBy: 1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next day")
                        .disabled(isToday)
                }
            }
        }
    }

    private var isToday: Bool { dayStart >= boundary.day(of: Date()) }

    private var dayTitle: String {
        isToday ? String(localized: "Today") : dayStart.formatted(.dateTime.month().day().weekday())
    }

    /// 这一天的对话段（按开始时间），来自各条录音的 segments.json
    private var conversations: [(Recording, Conversation)] {
        _ = library.conversations.revision
        let interval = boundary.interval(of: dayStart)
        var out: [(Recording, Conversation)] = []
        for r in library.recordings where r.transcribed && !r.isDictation {
            for c in library.conversations.conversations(r.id) where interval.contains(c.wallStart) {
                out.append((r, c))
            }
        }
        return out.sorted { $0.1.wallStart < $1.1.wallStart }
    }
}

private struct DiarySections: View {
    let day: DayFile?

    var body: some View {
        if let diary = day?.diary {
            if let o = diary.overview, !o.isEmpty {
                Section("Diary") { Text(o) }
            }
            if !diary.decisions.isEmpty {
                Section("Decided") {
                    ForEach(diary.decisions, id: \.self) { Text($0.text) }
                }
            }
            if !diary.todos.isEmpty {
                Section("To-dos") {
                    ForEach(diary.todos, id: \.self) { t in
                        Label { Text(t.text) + Text(verbatim: t.owner.map { "  · \($0)" } ?? "").foregroundStyle(.secondary) }
                            icon: { Image(systemName: "circle") }
                    }
                }
            }
            if !diary.people.isEmpty {
                Section("People") {
                    Text(diary.people.map(\.name).joined(separator: "、"))
                }
            }
        } else {
            Section("Diary") {
                Text(day == nil ? "No diary for this day yet." : "Too little was said this day for a diary.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConversationSections: View {
    let items: [(Recording, Conversation)]

    var body: some View {
        Section("Conversations") {
            if items.isEmpty {
                Text("No conversations.").foregroundStyle(.secondary)
            }
            ForEach(items, id: \.1.id) { r, c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.clockRange).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if let k = c.kind { Text(k).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(c.summary?.title ?? r.displayTitle).font(.headline)
                    if let s = c.summary?.summary { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
