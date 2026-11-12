// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Observation
import SwiftUI

// MARK: - 录音列表：按日期分组（录音库页的中间一栏）

struct RecordingList: View {
    @Bindable var library: LibraryStore
    let nav: Navigator
    @Binding var selection: UInt32?
    @Binding var query: String

    private var items: [Recording] { library.visible.filter { library.matches($0, query: query) } }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { r in
                            RecordingRow(recording: r, snippet: library.snippet(r.id), transcribing: library.transcribing[r.id])
                                .tag(r.id)
                                .id(r.id)
                                // 从概览点进来的那条亮一下再退回选中色
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(nav.flash == r.id ? 0.45 : 0))
                                    .padding(.horizontal, -6).padding(.vertical, -3))
                                .contextMenu { RecordingMenu(recording: r, library: library) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onAppear { if let id = selection { proxy.scrollTo(id, anchor: .center) } }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "No recordings" : "No matches", systemImage: "waveform")
                } description: {
                    Text(query.isEmpty ? "Sync downloads recordings from your recorder." : "Try another word.")
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $library.filter) {
                        ForEach(LibraryStore.Filter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: library.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter recordings")
            }
        }
    }

    /// 今天 / 昨天 / 本周 / 按月
    private var sections: [(title: String, items: [Recording])] {
        let cal = Calendar.current
        var order: [String] = []
        var groups: [String: [Recording]] = [:]
        for r in items {
            let key: String
            if cal.isDateInToday(r.start) { key = String(localized: "Today") }
            else if cal.isDateInYesterday(r.start) { key = String(localized: "Yesterday") }
            else if let w = cal.dateInterval(of: .weekOfYear, for: Date()), w.contains(r.start) { key = String(localized: "This week") }
            else { key = r.start.formatted(.dateTime.year().month(.wide)) }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

struct RecordingRow: View {
    let recording: Recording
    let snippet: String?
    let transcribing: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(snippet == nil ? 1 : 2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(LibraryStore.clock(recording.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                status
            }
        }
        .padding(.vertical, 3)
    }

    private var title: String {
        if let t = recording.title, !t.isEmpty { return t }
        return recording.start.formatted(date: Calendar.current.isDateInToday(recording.start) || Calendar.current.isDateInYesterday(recording.start) ? .omitted : .abbreviated,
                                         time: .shortened)
    }

    private var subtitle: String {
        if let snippet { return snippet }
        if transcribing != nil { return String(localized: "Transcribing…") }
        if !recording.downloaded { return String(localized: "On your recorder") }
        if !recording.transcribed { return String(localized: "Not transcribed") }
        return String(localized: "No speech")
    }

    @ViewBuilder private var status: some View {
        if let p = transcribing {
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
        } else if !recording.downloaded {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).help("On your recorder")
        } else if recording.isDictation {
            Image(systemName: "keyboard").foregroundStyle(.secondary).help("Dictation clip")
        }
    }
}

struct RecordingMenu: View {
    let recording: Recording
    let library: LibraryStore
    var body: some View {
        if recording.onDevice && !recording.downloaded {
            Button("Download") { Task { await library.syncAll(ids: [recording.id]) } }
        }
        if recording.downloaded {
            Button(recording.transcribed ? "Transcribe again" : "Transcribe") { Task { await library.transcribe(recording.id) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(recording.id)]) }
            Divider()
            Button("Delete local copy", role: .destructive) { library.deleteLocal(recording.id) }
        }
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
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 14)
            if recording.downloaded {
                PlayerStrip(player: player, peaks: library.peaks(recording.id))
                    .padding(.horizontal, 28).padding(.bottom, 12)
                Divider()
                transcript
            } else {
                Divider()
                notDownloaded.padding(28)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar { toolbar }
        .onAppear {
            title = recording.title ?? ""
            if recording.downloaded { player.load(library.audioURL(recording.id)) }
        }
        .task(id: recording.downloaded) { await library.loadPeaks(recording.id) }
        .onChange(of: recording.downloaded) { _, now in if now { player.load(library.audioURL(recording.id)) } }
        .onDisappear { player.stop() }
        .confirmationDialog("Download over Wi‑Fi?", isPresented: $confirmWifi) {
            Button("Download over Wi‑Fi") { Task { await library.syncViaWifi(ids: [recording.id]) } }
        } message: {
            Text("About 100× faster than Bluetooth. Your Mac joins the recorder's own Wi‑Fi and is offline for about a minute, then reconnects to your usual network.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $title, prompt: Text(recording.displayTitle))
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .focused($titleFocused)
                .onSubmit { library.rename(recording.id, to: title) }
                .onChange(of: titleFocused) { _, f in if !f { library.rename(recording.id, to: title) } }
            // 没有自定义标题时，大标题已经是日期，这里只补星期和时长
            Text(recording.title?.isEmpty == false
                 ? "\(recording.start.formatted(date: .complete, time: .shortened)) · \(LibraryStore.clock(recording.duration))"
                 : "\(recording.start.formatted(.dateTime.weekday(.wide))) · \(LibraryStore.clock(recording.duration))")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if recording.downloaded {
                if let p = library.transcribing[recording.id] {
                    ProgressView(value: p) { Text("Transcribing…") }.frame(width: 140)
                } else {
                    Button { Task { await library.transcribe(recording.id) } } label: {
                        Label(recording.transcribed ? "Transcribe again" : "Transcribe", systemImage: "text.bubble")
                    }
                    .help(recording.transcribed ? "Transcribe again" : "Transcribe")
                }
                Menu {
                    Button("Copy transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(library.transcript(recording.id).map(\.text).joined(separator: "\n"), forType: .string)
                    }.disabled(!recording.transcribed)
                    Button("Transcript as Markdown…") { library.exportMarkdown(recording.id) }.disabled(!recording.transcribed)
                    Button("Audio (Ogg Opus)…") { library.exportAudio(recording.id) }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(recording.id)]) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export")
            }
        }
    }

    @ViewBuilder private var transcript: some View {
        let segs = library.transcript(recording.id)
        if segs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if library.transcribing[recording.id] != nil {
                    Text("Transcribing on this Mac…").foregroundStyle(.secondary)
                } else {
                    Text(recording.transcribed ? "No speech found." : "Not transcribed yet.").foregroundStyle(.secondary)
                    if !recording.transcribed {
                        Button("Transcribe now") { Task { await library.transcribe(recording.id) } }
                    }
                }
            }
            .padding(28)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                            let current = player.playing && player.time >= s.start && player.time < s.end + 0.3
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(LibraryStore.clock(s.start))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    .frame(width: 46, alignment: .trailing)
                                Text(s.text)
                                    .font(.system(size: 15))
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                    .foregroundStyle(current ? Color.accentColor : .primary)
                                    .frame(maxWidth: 640, alignment: .leading)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(from: s.start) }
                            .id(i)
                        }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 18)
                }
                .onChange(of: player.time) { _, t in
                    if player.playing, let i = segs.firstIndex(where: { t >= $0.start && t < $0.end + 0.3 }) {
                        withAnimation { proxy.scrollTo(i, anchor: .center) }
                    }
                }
            }
        }
    }

    private var notDownloaded: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("This recording is still on your recorder.", systemImage: "arrow.down.circle")
                .font(.headline)
            HStack(spacing: 10) {
                Button("Download over Bluetooth") { Task { await library.syncAll(ids: [recording.id]) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.isReady || device.activity != .idle)
                Text("about \(LibraryStore.clock(recording.duration / 1.9))").font(.caption).foregroundStyle(.secondary)
            }
            if recording.duration > 600 {
                Button("Download over Wi‑Fi (faster)…") { confirmWifi = true }
                    .disabled(!device.isReady || device.activity != .idle)
            }
        }
    }
}

/// 详情页右侧没选中录音时
struct LibraryHome: View {
    let device: DeviceController
    let settings: Settings
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Select a recording").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Label("Press the recorder's button to type with your voice", systemImage: "keyboard")
                Label("Shortcut: \(settings.hotkey.label)", systemImage: "command")
                Label("Sync brings recordings to this Mac and transcribes them", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
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

/// 播放条：播放键 + 波形（已播放部分着色，点哪里跳到哪里）+ 时间
struct PlayerStrip: View {
    @Bindable var player: PlayerModel
    let peaks: [Float]?

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause (Space)")

            WaveScrubber(peaks: peaks ?? [], progress: player.duration > 0 ? player.time / player.duration : 0) { f in
                player.seek(f * player.duration)
            }
            .frame(height: 40)

            Text("\(LibraryStore.clock(player.time)) / \(LibraryStore.clock(player.duration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 84, alignment: .trailing)
        }
    }
}

struct WaveScrubber: View {
    let peaks: [Float]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(Int(w / 3), 1)
            let bins = resample(n)
            ZStack(alignment: .leading) {
                bars(bins, w: w, h: h).foregroundStyle(Color.secondary.opacity(0.35))
                bars(bins, w: w, h: h).foregroundStyle(Color.accentColor)
                    .mask(alignment: .leading) { Rectangle().frame(width: w * progress) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(min(max(v.location.x / w, 0), 1)) })
        }
    }

    private func bars(_ bins: [Float], w: CGFloat, h: CGFloat) -> some View {
        Canvas { ctx, size in
            let step = size.width / CGFloat(max(bins.count, 1))
            for (i, v) in bins.enumerated() {
                let bh = max(2, CGFloat(v) * size.height)
                let r = CGRect(x: CGFloat(i) * step, y: (size.height - bh) / 2, width: max(step - 1, 1), height: bh)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .foreground)
            }
        }
    }

    private func resample(_ n: Int) -> [Float] {
        guard !peaks.isEmpty else { return Array(repeating: 0.08, count: n) }
        return (0..<n).map { i in
            let a = i * peaks.count / n, b = max(a + 1, (i + 1) * peaks.count / n)
            return peaks[a..<min(b, peaks.count)].max() ?? 0
        }
    }
}
