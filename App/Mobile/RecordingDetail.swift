// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

/// 一条录音：信息、摘要卡片、重点标记、按段落的转写（点句子从那里播，正在播的那句标亮并跟着滚动），底部是播放器
struct RecordingDetail: View {
    let library: LibraryStore
    let id: UInt32
    /// 从搜索点进来：转写里标出这个词，并滚到第一处
    var query = ""

    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var follow = true
    @State private var scrolledToHit = false
    @Environment(\.dismiss) private var dismiss

    private var playback: Playback { Playback.shared }
    private var recording: Recording? { library.recordings.first { $0.id == id && !$0.isDictation } }
    private var heart: Bool { library.settings.mode.callsDeviceHeartBean }

    var body: some View {
        if let r = recording {
            content(r)
        } else {
            ContentUnavailableView("Recording deleted", systemImage: "trash", description: Text("This recording is no longer on this iPhone."))
        }
    }

    private func content(_ r: Recording) -> some View {
        let segs = r.transcribed ? library.transcript(r.id) : []
        let marks = r.downloaded ? library.marks(r.id) : []
        let active = playback.id == r.id
        let current = active && (playback.playing || playback.time > 0) ? Self.segment(at: playback.time, in: segs) : nil
        let sections = TranscriptLayout(segs, conversations: r.transcribed ? library.conversations.conversations(r.id) : [])
        return ScrollViewReader { proxy in
            List {
                header(r)
                SummaryCard(library: library, recording: r)
                if !marks.isEmpty { marksSection(r, marks: marks, segs: segs) }
                transcriptSection(r, segs: segs, sections: sections, marks: marks, current: current)
            }
            .listStyle(.insetGrouped)
            .environment(\.openURL, OpenURLAction { url in handle(url, segs: segs) })
            .onChange(of: current.flatMap { sections.paragraph(containing: $0) }) { _, p in
                guard follow, playback.playing, let p else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(ParagraphID(index: p), anchor: .center) }
            }
            .task(id: r.id) {
                scrollToHit(segs: segs, sections: sections, proxy: proxy)
            }
            .safeAreaInset(edge: .bottom) {
                if Playback.hasAudio(r) {
                    PlayerBar(recording: r, marks: marks, follow: $follow)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }
            }
        }
        .navigationTitle(library.listTitle(r))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(r) }
        .onAppear {
            if Playback.hasAudio(r) { playback.open(r, library: library) }
            demoPlay(r)
        }
        .alert("Rename recording", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                library.rename(r.id, to: t)
                if let r = recording { playback.retitle(r) }
            }
        } message: {
            Text("Leave it empty to show the date and time.")
        }
        .confirmationDialog("Delete this recording from this iPhone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                playback.forget([r.id])
                library.deleteLocal(r.id)
                dismiss()
            }
        } message: {
            Text(DeleteText.message([r], heart: heart))
        }
    }

    // MARK: 头部

    private func header(_ r: Recording) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(library.listTitle(r)).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("\(r.start.formatted(date: .complete, time: .shortened)) · \(LibraryStore.clock(r.duration))")
                    .font(.subheadline).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    SourceBadge(source: r.recordingSource)
                    StatusBadge(library: library, recording: r, heart: heart)
                    if r.audioRemoved { Chip(text: Text("Transcript only"), icon: "waveform.slash") }
                }
            }
            .padding(.vertical, 4)
            if r.audioRemoved, let at = r.audioDeletedAt {
                Label {
                    Text("Audio removed on \(at.formatted(date: .abbreviated, time: .omitted)) under Heart mode's audio retention. The transcript and summary are kept.")
                } icon: {
                    Image(systemName: "waveform.slash")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            if !r.downloaded {
                Label(DeviceWord.pick(heart, "This recording is still on your Heart bean.", "This recording is still on your recorder."),
                      systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Button("Download over Bluetooth") { Task { await library.syncAll(ids: [r.id]) } }
                    .disabled(Flavor.isFake || !library.recorderIdle)
                Text("About \(SyncStatusText.minutes(library.downloadSeconds(r))) over Bluetooth.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 重点标记

    private func marksSection(_ r: Recording, marks: [Double], segs: [TranscriptSegment]) -> some View {
        Section {
            ForEach(marks, id: \.self) { m in
                Button {
                    if Playback.hasAudio(r) { playback.open(r, library: library); playback.play(from: max(m - 3, 0)) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "flag.fill").foregroundStyle(.orange)
                        Text(LibraryStore.clock(m)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        if let i = MarkPlacement.line(for: m, spans: segs.map { ($0.start, $0.end) }) {
                            Text(segs[i].text).lineLimit(2).foregroundStyle(.primary)
                        }
                    }
                }
                .disabled(!Playback.hasAudio(r))
            }
        } header: {
            Text("Marks")
        } footer: {
            Text(DeviceWord.pick(heart, "Moments you marked on the Heart bean while recording. Tap one to play from a few seconds before it.",
                                 "Moments you marked on the recorder while recording. Tap one to play from a few seconds before it."))
        }
    }

    // MARK: 转写

    @ViewBuilder
    private func transcriptSection(_ r: Recording, segs: [TranscriptSegment], sections: TranscriptLayout,
                                   marks: [Double], current: Int?) -> some View {
        Section {
            if let p = library.transcribing[r.id] {
                ProgressView(value: p) { Text("Transcribing on this iPhone…") }
            } else if r.transcribed {
                if segs.isEmpty { Text("No speech found.").foregroundStyle(.secondary) }
                let byLine = MarkPlacement.byLine(marks, spans: segs.map { ($0.start, $0.end) })
                ForEach(Array(sections.paragraphs.enumerated()), id: \.offset) { k, range in
                    VStack(alignment: .leading, spacing: 8) {
                        if let c = sections.heading(before: k) { ConversationTitle(conversation: c) }
                        ParagraphText(segments: Array(segs[range]), first: range.lowerBound,
                                      current: current.flatMap { range.contains($0) ? $0 : nil },
                                      marks: byLine.filter { range.contains($0.key) }, query: query,
                                      wearer: library.speakers.showsMarks)
                            .equatable()
                    }
                    .id(ParagraphID(index: k))
                }
            } else if r.downloaded, !r.audioRemoved {
                Text("Not transcribed yet.").foregroundStyle(.secondary)
                Button("Transcribe now") { transcribe(r) }
            } else if r.audioRemoved {
                Text("No transcript, and the audio was removed.").foregroundStyle(.secondary)
            } else {
                Text("Sync the recording to transcribe it.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Transcript")
        } footer: {
            if r.transcribed, !segs.isEmpty, Playback.hasAudio(r) { Text("Tap a sentence to play from there.") }
        }
    }

    private func transcribe(_ r: Recording) {
        if Flavor.isFake { DemoLibrary.fakeTranscribe(r.id, library: library); return }
        Task { await library.transcribe(r.id) }
    }

    /// 点了转写里的链接：openbean-seek://<句子下标>，openbean-mark://<百分之一秒>
    private func handle(_ url: URL, segs: [TranscriptSegment]) -> OpenURLAction.Result {
        guard let r = recording, Playback.hasAudio(r) else { return .handled }
        playback.open(r, library: library)
        if url.scheme == "openbean-seek", let i = Int(url.host() ?? ""), segs.indices.contains(i) {
            follow = true
            playback.play(from: segs[i].start)
        } else if url.scheme == "openbean-mark", let c = Int(url.host() ?? "") {
            playback.play(from: max(Double(c) / 100 - 3, 0))
        }
        return .handled
    }

    private func scrollToHit(segs: [TranscriptSegment], sections: TranscriptLayout, proxy: ScrollViewProxy) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !scrolledToHit, !q.isEmpty,
              let i = segs.firstIndex(where: { $0.text.localizedCaseInsensitiveContains(q) }),
              let p = sections.paragraph(containing: i) else { return }
        scrolledToHit = true
        follow = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { proxy.scrollTo(ParagraphID(index: p), anchor: .center) }
        }
    }

    /// 时间 t 落在哪一句（最后一句开始时间不晚于 t 的）
    static func segment(at t: Double, in segs: [TranscriptSegment]) -> Int? {
        var lo = 0, hi = segs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segs[mid].start <= t + 0.05 { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private func toolbar(_ r: Recording) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename", systemImage: "pencil") {
                    newTitle = r.title ?? ""
                    renaming = true
                }
                if library.notes.canSummarize(r) {
                    Button(library.notes.summary(r.id) == nil ? "Summarise" : "Summarise again", systemImage: "sparkles") {
                        library.notes.summarize(r.id)
                    }
                    .disabled(library.notes.summarizing[r.id] != nil)
                }
                if r.downloaded, !r.audioRemoved, r.transcribed {
                    Button("Transcribe again", systemImage: "text.bubble") { transcribe(r) }
                        .disabled(library.transcribing[r.id] != nil)
                }
                Section("Share") {
                    let name = library.exportName(r)
                    ShareLink(item: MarkdownExport(name: name, text: library.markdown(r.id)),
                              preview: SharePreview(Text(verbatim: "\(name).md"))) {
                        Label("Transcript (Markdown)", systemImage: "doc.richtext")
                    }
                    .disabled(!r.transcribed)
                    ShareLink(item: PlainTextExport(name: name, text: library.plainText(r.id)),
                              preview: SharePreview(Text(verbatim: "\(name).txt"))) {
                        Label("Transcript (plain text)", systemImage: "doc.plaintext")
                    }
                    .disabled(!r.transcribed)
                    if Playback.hasAudio(r) {
                        ShareLink(item: AudioExport(name: name, url: library.audioURL(r.id)),
                                  preview: SharePreview(Text(verbatim: "\(name).ogg"))) {
                            Label("Audio (Ogg Opus)", systemImage: "waveform")
                        }
                    }
                }
                Section {
                    Button("Delete from this iPhone", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    /// 演示数据截图用：启动参数 -playAt <秒> 让详情页一打开就在那里播
    private func demoPlay(_ r: Recording) {
        guard Flavor.isFake, Playback.hasAudio(r), !playback.playing,
              let t = UserDefaults.standard.string(forKey: "playAt").flatMap(Double.init) else { return }
        if let rate = UserDefaults.standard.string(forKey: "playRate").flatMap(Float.init) { playback.rate = rate }
        playback.play(from: t)
    }
}

struct ParagraphID: Hashable { let index: Int }

/// 段落和对话段小标题：对话段对得上转写就按段分节（和 Mac 版的 TranscriptSections 同样的规则）
struct TranscriptLayout {
    let paragraphs: [Range<Int>]
    private let starts: [Int: Conversation]

    init(_ segs: [TranscriptSegment], conversations: [Conversation]) {
        let valid = conversations.count > 1
            && conversations.first?.from == 0 && conversations.last?.to == segs.count
            && zip(conversations, conversations.dropFirst()).allSatisfy { $0.to == $1.from && $0.from < $0.to }
        guard valid else {
            paragraphs = TranscriptParagraphs.group(segs)
            starts = [:]
            return
        }
        var paras: [Range<Int>] = [], starts: [Int: Conversation] = [:]
        for c in conversations {
            starts[paras.count] = c
            paras += TranscriptParagraphs.group(Array(segs[c.from..<c.to])).map { ($0.lowerBound + c.from)..<($0.upperBound + c.from) }
        }
        paragraphs = paras
        self.starts = starts
    }

    func heading(before paragraph: Int) -> Conversation? { starts[paragraph] }

    func paragraph(containing segment: Int) -> Int? {
        var lo = 0, hi = paragraphs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if paragraphs[mid].upperBound <= segment { lo = mid + 1 } else { hi = mid }
        }
        return lo < paragraphs.count && paragraphs[lo].contains(segment) ? lo : nil
    }
}

struct ConversationTitle: View {
    let conversation: Conversation
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let t = conversation.summary?.title, !t.isEmpty {
                Text(t).font(.headline)
            }
            Text("\(conversation.clockRange) · \(LibraryStore.clock(conversation.duration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 一段转写：前面是这段第一句的时间，后面是连在一起的句子。每句是一个链接，点了从那句播；正在播的那句标亮
struct ParagraphText: View, Equatable {
    let segments: [TranscriptSegment]
    let first: Int
    let current: Int?
    let marks: [Int: [Double]]
    let query: String
    /// 「认出我的声音」开着：佩戴者说的句子前面放一个小圆点（WearerMark）
    var wearer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LibraryStore.clock(segments.first?.start ?? 0))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(attributed)
                .lineSpacing(4)
                .tint(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (k, seg) in segments.enumerated() {
            if k > 0 { out += AttributedString(TranscriptParagraphs.joiner(after: segments[k - 1].text, before: seg.text)) }
            for m in marks[first + k] ?? [] {
                var flag = AttributedString("⚑\u{2009}")
                flag.link = URL(string: "openbean-mark://\(Int((m * 100).rounded()))")
                flag.foregroundColor = .orange
                out += flag
            }
            if wearer, seg.isWearer == true { out += WearerMark.prefix }
            var piece = Highlight.text(seg.text, query)
            piece.link = URL(string: "openbean-seek://\(first + k)")
            if first + k == current {
                piece.foregroundColor = .accentColor
                piece.backgroundColor = Color.accentColor.opacity(0.16)
            }
            out += piece
        }
        return out
    }
}

/// 详情页底部的播放器（玻璃底板）：进度条（上面标着重点标记）、时间、倍速、后退 15 秒、播放 / 暂停、前进 15 秒
struct PlayerBar: View {
    let recording: Recording
    let marks: [Double]
    @Binding var follow: Bool
    @State private var scrub: Double?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var playback: Playback { Playback.shared }
    private var active: Bool { playback.id == recording.id }

    var body: some View {
        let duration = max(active ? playback.duration : recording.duration, 0.1)
        let time = scrub ?? (active ? playback.time : 0)
        VStack(spacing: 6) {
            Slider(value: Binding(get: { time }, set: { scrub = $0 }), in: 0...duration) { editing in
                if !editing, let s = scrub { playback.seek(s); scrub = nil }
            }
            .accessibilityLabel("Position")
            .accessibilityValue(Text("\(LibraryStore.clock(time)) of \(LibraryStore.clock(duration))"))
            .overlay {
                MarkTicks(marks: marks, duration: duration)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            HStack {
                Text(LibraryStore.clock(time))
                Spacer()
                Text("-" + LibraryStore.clock(max(duration - time, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var controls: some View {
        HStack {
            Menu {
                Picker("Speed", selection: Binding(get: { playback.rate }, set: { playback.rate = $0 })) {
                    ForEach(Playback.rates, id: \.self) { Text(Self.rateText($0)).tag($0) }
                }
            } label: {
                Text(Self.rateText(playback.rate))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Playback speed")
            .accessibilityValue(Self.rateText(playback.rate))
            Spacer()
            Button { playback.skip(by: -Playback.skip) } label: {
                Image(systemName: "gobackward.15").font(.title2).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Back 15 seconds")
            Spacer()
            Button { playback.toggle() } label: {
                Image(systemName: active && playback.playing ? "pause.fill" : "play.fill")
                    .font(.title).frame(minWidth: 52, minHeight: 52)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(active && playback.playing ? "Pause" : "Play")
            Spacer()
            Button { playback.skip(by: Playback.skip) } label: {
                Image(systemName: "goforward.15").font(.title2).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Forward 15 seconds")
            Spacer()
            Button { follow.toggle() } label: {
                Image(systemName: follow ? "text.line.first.and.arrowtriangle.forward" : "text.alignleft")
                    .font(.title3).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(follow ? "Stop following playback" : "Follow playback in the transcript")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(!active)
    }

    static func rateText(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r)
    }
}

/// 进度条上的重点标记：橙色小竖线
struct MarkTicks: View {
    let marks: [Double]
    let duration: Double
    var body: some View {
        GeometryReader { g in
            // Slider 两头各有约半个滑块宽的空白
            let inset: CGFloat = 12, w = max(g.size.width - inset * 2, 1)
            ForEach(marks, id: \.self) { m in
                Capsule().fill(.orange)
                    .frame(width: 3, height: 14)
                    .position(x: inset + w * CGFloat(min(m / duration, 1)), y: g.size.height / 2 - 11)
            }
        }
    }
}

/// 「大约 N 分钟」（Mac 版的 SyncStatus.phrase 在 Mac 目标里）
enum SyncStatusText {
    static func minutes(_ s: Double) -> String {
        let m = max(Int((s / 60).rounded()), 1)
        return m < 60 ? String(localized: "\(m) min") : String(localized: "\(m / 60) h \(m % 60) min")
    }
}
