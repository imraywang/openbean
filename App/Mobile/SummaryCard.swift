// SPDX-License-Identifier: Apache-2.0

import OpenBeanVoice
import SwiftUI

/// 摘要卡片：标题、摘要、要点、待办（可勾选）。没有摘要时可以手动生成；排队中、生成中、失败各有说法
struct SummaryCard: View {
    let library: LibraryStore
    let recording: Recording

    private var notes: NoteService { library.notes }
    private var id: UInt32 { recording.id }

    var body: some View {
        let summary = notes.summary(id)
        Section {
            if let s = summary {
                VStack(alignment: .leading, spacing: 8) {
                    if !s.title.isEmpty { Text(s.title).font(.headline) }
                    Text(s.summary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                if !s.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key points").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(s.keyPoints, id: \.self) { p in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "•").foregroundStyle(.secondary)
                                Text(p).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if !s.actionItems.isEmpty {
                    ForEach(s.actionItems, id: \.self) { item in
                        let done = notes.isDone(id, item)
                        Button { notes.setDone(id, item, !done) } label: {
                            Label {
                                Text(item).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(done ? Color.accentColor : .secondary)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(done ? Text("Done") : Text("Not done"))
                        .accessibilityHint("Double-tap to toggle")
                    }
                }
            }
            state(summary)
        } header: {
            HStack {
                Text("Summary")
                Spacer()
                if summary != nil, let a = summary?.actionItems, !a.isEmpty {
                    let open = a.filter { !notes.isDone(id, $0) }.count
                    Text(open == 0 ? String(localized: "All done") : String(localized: "\(open) to do"))
                }
            }
        }
    }

    @ViewBuilder
    private func state(_ summary: RecordingSummary?) -> some View {
        if let p = notes.summarizing[id] {
            if p <= 0 {
                // summarize() 先记 0；排到了、连上大模型服务后才往上走（前面可能还有别的摘要、日记在跑）
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Queued")
                        Text("Starts after any summaries or diary updates ahead of it, once the LLM service answers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock")
                }
            } else {
                ProgressView(value: p) {
                    Label("Writing the summary…", systemImage: "sparkles")
                }
            }
        } else if let e = notes.errors[id] {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(e).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Button("Try again") { notes.summarize(id) }
            }
        } else if summary == nil {
            if notes.canSummarize(recording) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No summary yet. Summaries use the LLM service set in Settings; the transcript is sent to it.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Generate summary", systemImage: "sparkles") { notes.summarize(id) }
                }
            } else if recording.transcribed {
                Text("Nothing to summarise: no speech was found.").foregroundStyle(.secondary)
            } else {
                Text("A summary can be written once the recording is transcribed.").foregroundStyle(.secondary)
            }
        }
    }
}
