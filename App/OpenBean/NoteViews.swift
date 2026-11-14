// SPDX-License-Identifier: Apache-2.0

import AppKit
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

// MARK: - 界面

/// 详情页标题下面的摘要：摘要做导语，接着是能勾选的待办和要点（按文档排，不再放在灰底卡片里）
struct SummaryCard: View {
    let recording: Recording
    let notes: NoteService

    var body: some View {
        let progress = notes.summarizing[recording.id]
        let s = notes.summary(recording.id)
        let error = notes.errors[recording.id]
        if progress != nil || s != nil || error != nil {
            VStack(alignment: .leading, spacing: 16) {
                if let progress {
                    HStack(spacing: 10) {
                        // 0 = 还在队列里等（前面有别的摘要或日记在写），轮到了才有进度
                        if progress > 0 {
                            ProgressView(value: progress).frame(width: 120)
                            Text("Summarising…").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Waiting for other summaries to finish…").foregroundStyle(.secondary)
                        }
                    }
                }
                if let s {
                    Text(s.summary)
                        .font(.system(size: 17)).lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !s.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Action items").font(.headline)
                            ForEach(Array(s.actionItems.enumerated()), id: \.offset) { _, t in
                                TodoRow(text: t, done: Binding(get: { notes.isDone(recording.id, t) },
                                                               set: { notes.setDone(recording.id, t, $0) }))
                            }
                        }
                    }
                    if !s.keyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Key points").font(.headline)
                            ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, t in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verbatim: "•").foregroundStyle(.secondary)
                                    Text(t).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}

/// 一条能勾选的待办（详情页和「今天」共用）。勾掉的划线变灰，状态存在本机
struct TodoRow: View {
    let text: String
    @Binding var done: Bool
    var source: String? = nil

    var body: some View {
        Toggle(isOn: $done) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let source { Text(verbatim: "— \(source)").foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(Text(text))
        .accessibilityValue(Text(done ? "Done" : "Not done"))
    }
}

/// 详情页工具栏的「摘要」按钮（摘要进行中显示进度）
struct SummariseButton: View {
    let recording: Recording
    let notes: NoteService

    var body: some View {
        if let p = notes.summarizing[recording.id] {
            if p > 0 {
                ProgressView(value: p) { Text("Summarising…") }.frame(width: 140)
            } else {
                Text("Queued…").foregroundStyle(.secondary).help("Waiting for other summaries to finish…")
            }
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

/// 设置页里的「摘要」「每日日记」「笔记」几组
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
                Text("Title, summary, key points and action items, written by the LLM service set up in Voice typing → Clean-up. Skipped when the service is not running.")
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
            // 每日日记现在是心力模式的一部分（0.5 以前是这里的一个开关）
            LabeledContent {
                Button(DeviceWord.pick(settings.mode.heartMode, "Heart mode settings…", "Go to Heart mode")) { AppModel.shared.nav.open(.heart) }
            } label: {
                Text(settings.mode.writesDiary ? "Heart mode is on: a diary is written for each day"
                                               : "A diary for each day is part of Heart mode")
                Text("Diary folder, day start and what happens after sync are set in Heart mode.")
            }
        } header: {
            Text("Daily diary")
        }

        Section {
            Toggle(isOn: $settings.notesEnabled) {
                Text("Save a note for each recording to a folder")
                if settings.mode.heartMode {
                    Text("In Heart mode only the diary is written, unless “Also write a note for each recording” is on in Heart mode.")
                } else {
                    Text("One Markdown file per recording with the summary and the transcript, for example in an Obsidian vault. Audio stays in the library.")
                }
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
