// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import OpenBeanLibrary
import SwiftUI

// MARK: - 一段对话：小标题、时间、段摘要、这段的转写；点一句从那里播放
//
// 播放用共用的 PlayerModel（按帧定位）。本机音频按心力模式的保留期删掉以后只剩转写，播放按钮换成一句说明。

struct ConversationDetailView: View {
    let library: LibraryStore
    let key: ConversationKey
    @State private var player = PlayerModel()
    @State private var loaded = false

    private var recording: Recording? { library.recordings.first { $0.id == key.recording } }
    private var conversation: Conversation? {
        _ = library.conversations.revision
        return library.conversations.conversations(key.recording).first { $0.index == key.index }
    }

    var body: some View {
        if let r = recording, let c = conversation {
            content(r, c)
        } else {
            ContentUnavailableView("This conversation is no longer here", systemImage: "text.bubble")
        }
    }

    private func content(_ r: Recording, _ c: Conversation) -> some View {
        let lines = library.transcript(r.id)
        let range = c.lines.clamped(to: 0..<lines.count)
        let typed = Set(c.voiceTyping)
        let audio = hasAudio(r)
        return ScrollViewReader { proxy in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: (c.wallApprox ? "~" : "") + c.wallStart.formatted(date: .abbreviated, time: .shortened)
                             + "–" + c.wallEnd.formatted(date: .omitted, time: .shortened) + " · " + LibraryStore.clock(c.duration))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        if let s = c.summary?.summary, !s.isEmpty {
                            Text(s).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    if range.isEmpty {
                        Text("No transcript for this conversation.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(range), id: \.self) { i in
                        let line = lines[i]
                        Button {
                            play(from: line.start, r)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(verbatim: r.start.addingTimeInterval(line.start).formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                Text(library.speakers.showsMarks && line.isWearer == true ? WearerMark.prefix + AttributedString(line.text)
                                     : AttributedString(line.text))
                                    .foregroundStyle(typed.contains(i) ? .secondary : .primary)
                                    .fontWeight(isPlaying(line) ? .semibold : .regular)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(isPlaying(line) ? Color.accentColor.opacity(0.12) : nil)
                        .id(i)
                        .accessibilityHint(audio ? Text("Plays from here") : Text(verbatim: ""))
                    }
                } header: {
                    Text("Transcript")
                } footer: {
                    if !typed.isEmpty { Text("Greyed lines were voice typing and are left out of summaries.") }
                }
                if let s = c.summary, !s.keyPoints.isEmpty {
                    Section("Key points") {
                        ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in Text(p) }
                    }
                }
                if let s = c.summary, !s.todos.isEmpty {
                    Section("To-dos") {
                        ForEach(Array(s.todos.enumerated()), id: \.offset) { _, t in
                            Label(t, systemImage: "circle").labelStyle(BulletLabel())
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { playerBar(r, c, audio: audio) }
            .onChange(of: currentLine(range, lines)) { _, i in
                guard let i, player.playing else { return }
                withAnimation { proxy.scrollTo(i, anchor: .center) }
            }
        }
        .navigationTitle(Text(verbatim: ConversationRow.title(c, library: library, recording: r)))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
        .onAppear {
            // 演示数据截图：-heartPlay YES 摆出「正在播第二句」
            if Flavor.isDemo, UserDefaults.standard.bool(forKey: "heartPlay") {
                let lines = library.transcript(r.id), range = c.lines.clamped(to: 0..<lines.count)
                if range.count > 1 { play(from: lines[range.lowerBound + 1].start + 0.1, r) }
            }
        }
    }

    // MARK: 播放

    private func hasAudio(_ r: Recording) -> Bool {
        if Flavor.isDemo { return true }
        return !r.audioRemoved && FileManager.default.fileExists(atPath: library.audioURL(r.id).path)
    }

    private func load(_ r: Recording) {
        guard !loaded else { return }
        loaded = true
        if FileManager.default.fileExists(atPath: library.audioURL(r.id).path) {
            player.load(library.audioURL(r.id))
        } else if Flavor.isDemo {
            player.demoDuration(r.duration)
        }
    }

    private func play(from t: Double, _ r: Recording) {
        guard hasAudio(r) else { return }
        load(r)
        if Flavor.isDemo && !FileManager.default.fileExists(atPath: library.audioURL(r.id).path) {
            player.demoPlaying(at: t) // 演示数据没有音频：只摆出「在播」的样子
            return
        }
        player.play(from: t)
    }

    private func isPlaying(_ line: TranscriptSegment) -> Bool {
        player.playing && player.time >= line.start && player.time < max(line.end, line.start + 0.5)
    }

    private func currentLine(_ range: Range<Int>, _ lines: [TranscriptSegment]) -> Int? {
        guard player.playing else { return nil }
        return range.first { lines[$0].start <= player.time && player.time < lines[$0].end }
    }

    @ViewBuilder private func playerBar(_ r: Recording, _ c: Conversation, audio: Bool) -> some View {
        HStack(spacing: 14) {
            if audio {
                Button {
                    if player.playing { player.pause() }
                    else if player.time >= c.start && player.time < c.end { play(from: player.time, r) }
                    else { play(from: c.start, r) }
                } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.playing ? Text("Pause") : Text("Play"))
                VStack(alignment: .leading, spacing: 2) {
                    let t = player.playing || player.time > 0 ? player.time : c.start
                    Text(verbatim: r.start.addingTimeInterval(t).formatted(date: .omitted, time: .standard))
                        .font(.callout.monospacedDigit())
                    Text("Tap a line to play from there").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "waveform.slash").foregroundStyle(.secondary)
                Text(r.audioRemoved ? "The audio was removed from this iPhone as set in Heart mode. The transcript is kept."
                     : "The audio isn't on this iPhone.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.caption).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
