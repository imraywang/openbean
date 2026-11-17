// SPDX-License-Identifier: Apache-2.0

import OpenBeanVoice
import SwiftUI

/// 心力模式设置里的「认出我的声音」（Mac 和 iPhone 共用）：开关、一句话说明声纹只在本机、状态、「忘掉我的声音」
struct MyVoiceSection: View {
    @Bindable var speakers: SpeakerIdentity
    var wifiOnly = false
    @State private var confirmForget = false

    #if os(macOS)
    private let explanation: LocalizedStringKey = "Marks the sentences you said in transcripts. Your voiceprint is computed and kept on this Mac and never leaves it."
    #else
    private let explanation: LocalizedStringKey = "Marks the sentences you said in transcripts. Your voiceprint is computed and kept on this iPhone and never leaves it."
    #endif

    var body: some View {
        Section {
            #if os(macOS)
            Toggle(isOn: $speakers.enabled) {
                Text("Recognise my voice")
                Text(explanation)
            }
            #else
            Toggle("Recognise my voice", isOn: $speakers.enabled)
            #endif
            if speakers.enabled { statusRow }
            if speakers.voiceprint != nil {
                Button("Forget my voice", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget your voice?", isPresented: $confirmForget) {
                        Button("Forget my voice", role: .destructive) { speakers.forget() }
                    } message: {
                        Text("Deletes the voiceprint and the marks on every sentence, and turns this off. It can learn your voice again later.")
                    }
            }
        } header: {
            Text("My voice")
        } footer: {
            #if os(iOS)
            Text(explanation)
            #endif
        }
    }

    @ViewBuilder private var statusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch speakers.status {
            case .off:
                EmptyView()
            case .needsModel:
                HStack {
                    Text("Needs the voice model (28 MB).")
                    Spacer()
                    Button("Download") { Task { await speakers.models?.downloadSpeaker(wifiOnly: wifiOnly); speakers.start() } }
                }
            case let .downloadingModel(p):
                ProgressView(value: p) { Text("Downloading the voice model…") }
            case let .modelFailed(e):
                Text("Couldn't download the voice model: \(e)").foregroundStyle(.orange)
                Button("Try again") { Task { await speakers.models?.downloadSpeaker(wifiOnly: wifiOnly); speakers.start() } }
            case let .learning(candidates, days):
                Text("Learning your voice")
                Text("It needs long Heart mode recordings from two different days, with the Heart bean clipped on.")
                    .font(.caption).foregroundStyle(.secondary)
                if candidates > 0 {
                    Text("So far: \(candidates) recordings from \(days) days.").font(.caption).foregroundStyle(.secondary)
                }
            case let .ready(since, recordings):
                Text("Ready since \(since.formatted(date: .abbreviated, time: .omitted)), learned from \(recordings) recordings")
                Text("In transcripts, \(Text(WearerMark.symbol)) marks a sentence that sounds like you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let p = speakers.backfillProgress, p.total > 0 {
                Text("Checking earlier recordings… \(p.done) of \(p.total)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 转写里标「这句是我说的」：句子前一个小圆点，颜色淡，不抢文字
enum WearerMark {
    static var symbol: AttributedString {
        var a = AttributedString("●")
        a.foregroundColor = Color.accentColor.opacity(0.6)
        a.font = .system(size: 7)
        a.baselineOffset = 2
        return a
    }

    /// 放在句子前面（带一个窄空格）
    static var prefix: AttributedString {
        symbol + AttributedString("\u{2009}")
    }
}
