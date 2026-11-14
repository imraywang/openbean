// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import SwiftUI

// 「今天」页里和对话段、每日日记有关的部分。放在单独的文件里，TodayView.swift 只多了几处调用。

// MARK: - 待办

enum TodayTodos {
    /// 这天的待办：(录音, 待办原文, 来源)。勾选状态按录音 + 原文记（沿用 todos.json），所以同一条只出现一次：
    /// - 多段录音、有段摘要：用落在这天的各段的待办，来源写段的时间和小标题；整条录音的待办（由段摘要合成）不再列；
    /// - 其他：整条录音摘要里的待办，来源写录音标题。
    @MainActor
    static func items(_ d: DayDigest, library: LibraryStore) -> [(Recording, String, String)] {
        var out: [(Recording, String, String)] = []
        var seen = Set<String>()
        var recordingDone = Set<UInt32>()
        for b in d.blocks {
            switch b {
            case let .recording(r):
                for t in library.notes.cachedSummary(r.id)?.actionItems ?? [] where seen.insert("\(r.id)|\(t)").inserted {
                    out.append((r, t, r.displayTitle))
                }
            case let .conversation(r, c):
                let segmented = library.conversations.conversations(r.id).contains { $0.summary != nil }
                if segmented {
                    let source = c.summary?.title.isEmpty == false ? c.summary!.title : c.clockRange
                    for t in c.summary?.todos ?? [] where seen.insert("\(r.id)|\(t)").inserted { out.append((r, t, source)) }
                } else if recordingDone.insert(r.id).inserted {
                    for t in library.notes.cachedSummary(r.id)?.actionItems ?? [] where seen.insert("\(r.id)|\(t)").inserted {
                        out.append((r, t, r.displayTitle))
                    }
                }
            }
        }
        return out
    }
}

// MARK: - 一段对话一块

/// 时间线上的一段对话（来自切成多段的录音）：时刻、时长、小标题、段摘要、几条待办。点了去录音库看这条录音
struct TodayConversationBlock: View {
    let recording: Recording
    let conversation: Conversation
    let open: () -> Void

    var body: some View {
        let s = conversation.summary
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text((conversation.wallApprox ? "~" : "") + conversation.wallStart.formatted(date: .omitted, time: .shortened))
                        .font(.callout.monospacedDigit())
                    Text(LibraryStore.clock(conversation.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(width: 80, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s?.title.isEmpty == false ? s!.title : conversation.clockRange)
                        .font(.headline).multilineTextAlignment(.leading)
                    if let lead = s?.summary, !lead.isEmpty {
                        Text(lead).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    } else if conversation.kind == "fragment" {
                        Text("A few words").foregroundStyle(.secondary)
                    }
                    // 来自哪条录音：多段录音的标题在这里提一下
                    HStack(spacing: 10) {
                        if recording.title?.isEmpty == false {
                            Label { Text(verbatim: recording.displayTitle) } icon: { Image(systemName: "waveform") }
                                .lineLimit(1)
                        }
                        if let n = s?.todos.count, n > 0 {
                            Label { Text("\(n) to-dos") } icon: { Image(systemName: "checklist") }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
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
}

// MARK: - 当天的日记

/// 「今天」顶上的日记：概述、定了的事（带出处时刻，点了去那条录音）、提到的人。
/// 没开「每天写一篇日记」、或这天还没有日记时什么都不显示（开着时给一个「写这天的日记」按钮）
struct TodayDiarySection: View {
    let model: AppModel
    let day: Date
    let digest: DayDigest

    private var diary: DiaryService { model.library.notes.diary }

    var body: some View {
        let file = diary.day(day)
        if let file, let d = file.diary {
            content(file, d)
        } else if model.settings.mode.writesDiary {
            if diary.working.contains(diary.key(day)) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing the diary for this day…").foregroundStyle(.secondary)
                }
            } else if file?.status == .brief {
                Text("Too little was said on this day for a diary; the conversations are listed below.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if digest.recordings.contains(where: \.transcribed) {
                Button("Write the diary for this day") { diary.requestDay(day) }
                    .buttonStyle(.link)
            }
        }
    }

    private func content(_ file: DayFile, _ d: Diary) -> some View {
        let byRef = Dictionary(file.conversations.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 14) {
            if let o = d.overview, !o.isEmpty {
                Text(o).font(.title3).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !d.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Decided").font(.headline)
                    ForEach(Array(d.decisions.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.seal").foregroundStyle(.secondary).font(.callout)
                            Text(item.text).fixedSize(horizontal: false, vertical: true)
                            refs(item.refs, byRef)
                        }
                    }
                }
            }
            if !d.people.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("People mentioned").font(.headline)
                    // 名字照转写写，不合并不同写法；后面是出现在哪几段
                    Text(d.people.map { p in
                        let times = p.refs.compactMap { byRef[$0].map(time) }.joined(separator: ", ")
                        return times.isEmpty ? p.name : "\(p.name) (\(times))"
                    }.joined(separator: " · "))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    private func time(_ c: DayConversation) -> String {
        (c.wallApprox ? "~" : "") + c.wallStart.formatted(date: .omitted, time: .shortened)
    }

    /// 出处：每个是一个时刻，点了去那条录音
    private func refs(_ refs: [ConversationRef], _ byRef: [ConversationRef: DayConversation]) -> some View {
        HStack(spacing: 4) {
            ForEach(refs, id: \.self) { r in
                if let c = byRef[r] {
                    Button(time(c)) { model.nav.show(recording: r.recording, in: model.library) }
                        .buttonStyle(.link).font(.caption.monospacedDigit())
                        .help("Open the conversation this comes from")
                }
            }
        }
    }
}
