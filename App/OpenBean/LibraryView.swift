// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Observation
import SwiftUI

struct LibraryView: View {
    @Bindable var library: LibraryStore
    let device: DeviceController
    @State private var selection: UInt32?
    @State private var query = ""
    @State private var confirmWifi = false

    private var items: [Recording] { library.visible.filter { library.matches($0, query: query) } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                SyncBanner(library: library, device: device)
                List(items, selection: $selection) { r in
                    RecordingRow(recording: r, transcribing: library.transcribing[r.id])
                        .tag(r.id)
                        .contextMenu { rowMenu(r) }
                }
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "No recordings yet" : "No matches",
                                               systemImage: "waveform",
                                               description: Text(query.isEmpty ? "Press Sync to download recordings from your recorder." : ""))
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320)

            Group {
                if let id = selection, let r = library.recordings.first(where: { $0.id == id }) {
                    RecordingDetail(recording: r, library: library, device: device)
                        .id(id)
                } else {
                    ContentUnavailableView("Select a recording", systemImage: "music.note.list")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, prompt: "Search titles and transcripts")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $library.showDictation) { Label("Show dictation clips", systemImage: "keyboard") }
                    .help("Recordings created by voice typing")
                Button {
                    Task { await library.syncAll() }
                } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!device.isReady || device.activity != .idle)
                    .help("Download new recordings over Bluetooth")
            }
        }
        .task { await library.refreshDeviceList() }
    }

    @ViewBuilder private func rowMenu(_ r: Recording) -> some View {
        if r.onDevice && !r.downloaded {
            Button("Download") { Task { await library.syncAll(ids: [r.id]) } }
        }
        if r.downloaded {
            Button(r.transcribed ? "Transcribe again" : "Transcribe") { Task { await library.transcribe(r.id) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(r.id)]) }
            Divider()
            Button("Delete local copy", role: .destructive) { library.deleteLocal(r.id) }
        }
    }
}

struct SyncBanner: View {
    let library: LibraryStore
    let device: DeviceController

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                if case let .downloading(_, _, _, f, _) = library.sync {
                    ProgressView(value: f).frame(width: 60)
                } else if case .listing = library.sync {
                    ProgressView().controlSize(.small)
                } else if case .wifi = library.sync {
                    ProgressView().controlSize(.small)
                }
                Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var text: String? {
        switch library.sync {
        case .idle:
            switch device.state {
            case .ready: return nil
            case .failed: return String(localized: "Recorder not connected.")
            default: return String(localized: "Connecting to your recorder…")
            }
        case .listing: return String(localized: "Reading the list of recordings…")
        case let .downloading(_, done, total, f, kbps):
            return String(localized: "Downloading \(done + 1) of \(total) over Bluetooth — \(Int(f * 100))%, \(Int(kbps)) KB/s")
        case let .wifi(msg): return msg
        case .paused: return String(localized: "Sync paused for dictation; it resumes afterwards.")
        case let .failed(e): return String(localized: "Sync failed: \(e)")
        }
    }
}

struct RecordingRow: View {
    let recording: Recording
    let transcribing: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.displayTitle).font(.body).lineLimit(1)
            HStack(spacing: 6) {
                Text(LibraryStore.clock(recording.duration)).monospacedDigit()
                if recording.isDictation { Badge(text: String(localized: "Dictation"), color: .purple) }
                if let p = transcribing {
                    Badge(text: String(localized: "Transcribing \(Int(p * 100))%"), color: .orange)
                } else if recording.transcribed {
                    Badge(text: String(localized: "Transcript"), color: .green)
                }
                if !recording.downloaded { Badge(text: String(localized: "On recorder"), color: .blue) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - 详情

struct RecordingDetail: View {
    let recording: Recording
    let library: LibraryStore
    let device: DeviceController
    @State private var title = ""
    @State private var player = PlayerModel()
    @State private var confirmWifi = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Title", text: $title, prompt: Text(recording.displayTitle))
                .textFieldStyle(.plain).font(.title2.weight(.semibold))
                .onSubmit { library.rename(recording.id, to: title) }
            Text("\(recording.start.formatted(date: .long, time: .shortened)) · \(LibraryStore.clock(recording.duration))")
                .foregroundStyle(.secondary)

            if recording.downloaded {
                PlayerBar(player: player)
                actions
                Divider()
                transcript
            } else {
                notDownloaded
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            title = recording.title ?? ""
            if recording.downloaded { player.load(library.audioURL(recording.id)) }
        }
        .onChange(of: recording.downloaded) { _, now in if now { player.load(library.audioURL(recording.id)) } }
        .onDisappear { player.stop() }
        .confirmationDialog("Download over Wi‑Fi?", isPresented: $confirmWifi) {
            Button("Download over Wi‑Fi") { Task { await library.syncViaWifi(ids: [recording.id]) } }
        } message: {
            Text("About 100× faster than Bluetooth. Your Mac joins the recorder's own Wi‑Fi and is offline for about a minute, then reconnects to your usual network.")
        }
    }

    private var actions: some View {
        HStack {
            if let p = library.transcribing[recording.id] {
                ProgressView(value: p) { Text("Transcribing…") }.frame(width: 180)
            } else {
                Button(recording.transcribed ? "Transcribe again" : "Transcribe") {
                    Task { await library.transcribe(recording.id) }
                }
            }
            Spacer()
            Menu("Export") {
                Button("Transcript as Markdown…") { library.exportMarkdown(recording.id) }.disabled(!recording.transcribed)
                Button("Copy transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(library.transcript(recording.id).map(\.text).joined(separator: "\n"), forType: .string)
                }.disabled(!recording.transcribed)
                Button("Audio (Ogg Opus)…") { library.exportAudio(recording.id) }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(recording.id)]) }
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var transcript: some View {
        let segs = library.transcript(recording.id)
        if segs.isEmpty {
            Text(recording.transcribed ? "No speech found." : "Not transcribed yet. Transcription runs on this Mac and takes about a minute per two hours of audio.")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                List(Array(segs.enumerated()), id: \.offset) { i, s in
                    let current = player.time >= s.start && player.time < s.end + 0.3 && player.playing
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(LibraryStore.clock(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                        Text(s.text).textSelection(.enabled)
                            .foregroundStyle(current ? Color.accentColor : .primary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(from: s.start) }
                    .id(i)
                }
                .listStyle(.inset)
                .onChange(of: player.time) { _, t in
                    if player.playing, let i = segs.firstIndex(where: { t >= $0.start && t < $0.end + 0.3 }) {
                        withAnimation { proxy.scrollTo(i, anchor: .center) }
                    }
                }
            }
        }
    }

    private var notDownloaded: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This recording is still on your recorder.").foregroundStyle(.secondary)
            let estimate = recording.duration / 1.9
            HStack {
                Button("Download over Bluetooth") { Task { await library.syncAll(ids: [recording.id]) } }
                    .disabled(!device.isReady || device.activity != .idle)
                Text("about \(LibraryStore.clock(estimate))").font(.caption).foregroundStyle(.secondary)
            }
            if recording.duration > 600 {
                Button("Download over Wi‑Fi (faster)…") { confirmWifi = true }
                    .disabled(!device.isReady || device.activity != .idle)
            }
            Spacer()
        }
    }
}

// MARK: - 播放

@MainActor @Observable
final class PlayerModel {
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    private(set) var playing = false
    private(set) var duration: Double = 0
    var time: Double = 0

    func load(_ url: URL) {
        audio = try? AVAudioPlayer(contentsOf: url)
        audio?.prepareToPlay()
        duration = audio?.duration ?? 0
    }

    func toggle() { playing ? pause() : play(from: nil) }

    func play(from t: Double?) {
        guard let a = audio else { return }
        if let t { a.currentTime = t; time = t }
        a.play()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let a = self.audio else { return }
                self.time = a.currentTime
                if !a.isPlaying { self.playing = false; self.timer?.invalidate() }
            }
        }
    }

    func pause() { audio?.pause(); playing = false; timer?.invalidate() }
    func seek(_ t: Double) { audio?.currentTime = t; time = t }
    func stop() { audio?.stop(); playing = false; timer?.invalidate() }
}

struct PlayerBar: View {
    @Bindable var player: PlayerModel
    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.title)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            Text(LibraryStore.clock(player.time)).monospacedDigit().font(.caption)
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
            Text(LibraryStore.clock(player.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
        }
    }
}
