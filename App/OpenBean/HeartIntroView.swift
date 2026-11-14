// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import SwiftUI

// MARK: - 心力模式介绍（单独的小窗口）
//
// 是什么 → 写日记用的大模型服务通不通 → 确认同步后从心力豆删除、本机音频留多久 → 打开。
// 心力模式默认关，只有在这里点「打开心力模式」（或之后在心力模式设置里打开开关）才会开。
// 「以后再说」：不开，以后不再自动出现；心力模式页关着时可以从那里再打开这个介绍。
// 谁在什么时候自动看到、选项预填成什么，见 OpenBeanLibrary 的 HeartIntro。

struct HeartIntroView: View {
    let model: AppModel
    @State private var step: Int
    @State private var deleteFromRecorder: Bool
    @State private var retention: AudioRetention
    @State private var hadDailyDiary: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    static let steps = 4

    /// step、prefill：预览用；平时从第一步开始，选项按现在存着的设置预填
    init(model: AppModel, step: Int = 0, prefill: HeartIntro.Prefill? = nil) {
        self.model = model
        let p = prefill ?? model.settings.heartIntroPrefill
        _step = State(initialValue: step)
        _deleteFromRecorder = State(initialValue: p.deleteFromRecorder)
        _retention = State(initialValue: p.audioRetention)
        _hadDailyDiary = State(initialValue: p.hadDailyDiary)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: what
                case 1: service
                case 2: choices
                default: turnOn
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<Self.steps, id: \.self) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Step \(step + 1) of \(Self.steps)"))
                Button("Later") { later() }
                    .keyboardShortcut(.cancelAction)
                    .help("Keep Heart mode off. You can set it up later from the Heart mode page.")
                    .padding(.leading, 10)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < Self.steps - 1 {
                    Button("Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Turn on Heart mode") { turnOnNow() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: 470)
        #if DEMO
        .onChange(of: DemoState.shared.heartIntroStep, initial: true) { _, s in
            step = s
            hadDailyDiary = DemoState.shared.heartIntroDiary
        }
        #endif
    }

    // MARK: 各步

    private func header(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Color.accentColor)
            Text(title).font(.title.weight(.semibold))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var what: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("heart", "Meet Heart mode",
                   "Wear your recorder all day as a Heart bean. When it goes back in its case, OpenBean takes care of the rest.")
            VStack(alignment: .leading, spacing: 9) {
                Label("Syncs over Bluetooth by itself when the Heart bean is back in its case.", systemImage: "arrow.triangle.2.circlepath")
                Label("Transcribes on this Mac and splits the day into conversations.", systemImage: "text.bubble")
                Label("Writes today's diary and to-dos with your LLM service.", systemImage: "book.closed")
                Label("Clears synced recordings off the Heart bean so it has room for tomorrow.", systemImage: "trash")
            }
            .labelStyle(IntroIconLabel())
            if hadDailyDiary {
                Label("You used the daily diary. It's part of Heart mode now and stays off until you turn Heart mode on.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
            }
        }
    }

    private var service: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("sparkles", "Check the LLM service",
                   "The diary and conversation summaries are written by the LLM service set up under Voice typing → Clean-up. Recordings are still synced and transcribed without it.")
            LLMServiceStatusRow(settings: model.settings) { model.openSettings(.voiceTyping(cleanUp: true)) }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            Text("You can turn on Heart mode even if it isn't reachable yet; the diary is written once it is.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("slider.horizontal.3", "After each sync",
                   "You can change these later in Heart mode settings.")
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $deleteFromRecorder) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete recordings from the Heart bean once they're synced and transcribed")
                        Text("Deleted recordings can't be recovered. A recording is only deleted when the copy on this Mac is complete and checked against the Heart bean. The Heart mode page shows how many were deleted after each sync.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Picker(selection: $retention) {
                    Text("Delete after transcription").tag(AudioRetention.afterTranscription)
                    Text("7 days").tag(AudioRetention.sevenDays)
                    Text("Keep").tag(AudioRetention.forever)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep audio on this Mac")
                        Text("Transcripts, summaries and the diary are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var turnOn: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("heart.fill", "Ready to turn on Heart mode",
                   "Here's what happens from now on. Recording and voice typing work as before.")
            VStack(alignment: .leading, spacing: 9) {
                Label("Syncs automatically when the Heart bean goes back in its case", systemImage: "arrow.triangle.2.circlepath")
                if deleteFromRecorder {
                    Label("Synced recordings are deleted from the Heart bean", systemImage: "trash")
                } else {
                    Label("Recordings stay on the Heart bean", systemImage: "tray.full")
                }
                Label { Text(verbatim: SyncRunText.retention(retention)) } icon: { Image(systemName: "waveform") }
                Label("A notification when today's record is updated (macOS asks once)", systemImage: "bell")
            }
            .labelStyle(IntroIconLabel())
        }
    }

    // MARK: 动作

    private func later() {
        model.settings.heartIntroSeen = true
        Log.write("心力模式介绍：以后再说（第 \(step + 1) 步）")
        dismissWindow(id: "heart-intro")
    }

    private func turnOnNow() {
        let s = model.settings
        s.heartDeleteFromRecorder = deleteFromRecorder
        s.heartAudioRetention = retention
        s.heartIntroSeen = true
        s.heartMode = true
        Log.write("心力模式介绍：打开心力模式（同步后从设备删除=\(deleteFromRecorder)，本机音频=\(retention.rawValue)）")
        // 心力模式页开着时它的 onChange 也会补一遍，没变的天不会再调用大模型
        model.library.notes.diary.catchUp()
        Notifier.requestPermission()
        model.nav.goHome(s.mode)
        dismissWindow(id: "heart-intro")
        openWindow(id: "main")
        bringToFront("main")
    }
}

/// 图标列固定宽度
private struct IntroIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(Color.accentColor).frame(width: 22, alignment: .center)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
