// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

/// 本机录音库：列表 → 详情（播放、转写、摘要）。语音输入片段不在这里（iOS 版没有语音输入）
struct RecordingsTab: View {
    let library: LibraryStore
    @State private var query = ""

    private var items: [Recording] {
        library.recordings.filter { library.includes($0, in: .all) && library.matches($0, query: query) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { r in
                    NavigationLink(value: r.id) { RecordingRowView(library: library, recording: r) }
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No recordings yet" : "No results",
                                           systemImage: "waveform",
                                           description: Text(query.isEmpty ? "Recordings synced from the recorder show up here." : ""))
                }
            }
            .searchable(text: $query)
            .navigationTitle("Recordings")
            .navigationDestination(for: UInt32.self) { id in
                RecordingDetailView(library: library, id: id)
            }
        }
    }
}

struct RecordingRowView: View {
    let library: LibraryStore
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.displayTitle).font(.body).lineLimit(1)
            HStack(spacing: 6) {
                // 没有标题时标题就是日期，这里不再重复
                if recording.title?.isEmpty == false {
                    Text(recording.start.formatted(date: .abbreviated, time: .shortened))
                }
                Text(LibraryStore.clock(recording.duration)).monospacedDigit()
                Spacer()
                if let p = library.transcribing[recording.id] {
                    ProgressView(value: p).frame(width: 40)
                } else if !recording.downloaded {
                    Image(systemName: "arrow.down.circle").accessibilityLabel("On recorder")
                } else if !recording.transcribed {
                    Image(systemName: "text.bubble").accessibilityLabel("Not transcribed")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let s = library.snippet(recording.id) {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct RecordingDetailView: View {
    let library: LibraryStore
    let id: UInt32
    @State private var player = PlayerModel()

    private var recording: Recording? { library.recordings.first { $0.id == id } }
    private var notes: NoteService { library.notes }

    var body: some View {
        if let r = recording {
            List {
                Section {
                    LabeledContent("Recorded", value: r.start.formatted(date: .long, time: .shortened))
                    LabeledContent("Length", value: LibraryStore.clock(r.duration))
                    if r.audioRemoved { Text("The audio was removed after transcription (Heart mode setting).").foregroundStyle(.secondary) }
                }
                if r.downloaded, !r.audioRemoved { playerSection }
                summarySection(r)
                transcriptSection(r)
            }
            .navigationTitle(r.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { load(r) }
            .onDisappear { player.stop() }
        } else {
            ContentUnavailableView("Recording not found", systemImage: "questionmark")
        }
    }

    private func load(_ r: Recording) {
        let url = library.audioURL(r.id)
        if FileManager.default.fileExists(atPath: url.path) { player.load(url) } else { player.demoDuration(r.duration) }
    }

    private var playerSection: some View {
        Section {
            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.playing ? "Pause" : "Play")
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 0.1))
                    HStack {
                        Text(LibraryStore.clock(player.time))
                        Spacer()
                        Text(LibraryStore.clock(player.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ r: Recording) -> some View {
        Section("Summary") {
            if let s = notes.summary(r.id) {
                Text(s.summary)
                ForEach(s.actionItems, id: \.self) { item in
                    Button { notes.setDone(r.id, item, !notes.isDone(r.id, item)) } label: {
                        Label(item, systemImage: notes.isDone(r.id, item) ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            if let p = notes.summarizing[r.id] {
                ProgressView(value: p) { Text("Summarising…") }
            } else if notes.canSummarize(r) {
                Button(notes.summary(r.id) == nil ? "Summarise" : "Summarise again") { notes.summarize(r.id) }
            } else if notes.summary(r.id) == nil {
                Text("Transcribe the recording first.").foregroundStyle(.secondary)
            }
            if let e = notes.errors[r.id] { Text(e).foregroundStyle(.red).font(.caption) }
        }
    }

    @ViewBuilder
    private func transcriptSection(_ r: Recording) -> some View {
        Section("Transcript") {
            if let p = library.transcribing[r.id] {
                ProgressView(value: p) { Text("Transcribing…") }
            } else if r.transcribed {
                let segs = library.transcript(r.id)
                if segs.isEmpty { Text("No speech found.").foregroundStyle(.secondary) }
                ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                    Button { player.play(from: seg.start) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(LibraryStore.clock(seg.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(seg.text).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else if r.downloaded, !r.audioRemoved {
                Button("Transcribe") { Task { await library.transcribe(r.id) } }
            } else {
                Text("Sync the recording to transcribe it.").foregroundStyle(.secondary)
            }
        }
    }
}
