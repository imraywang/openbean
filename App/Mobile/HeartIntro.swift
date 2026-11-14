// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

// MARK: - 心力模式引导（手机上分页）
//
// 是什么 → 文字去了哪（转写在本机；用云端模型时转写文字发给那个服务）→ 每次同步之后（从心力豆删除、本机音频留多久）
// → 打开（在后台怎么工作；这一步请求通知权限）。参照 Mac 的 HeartIntroView，内容按手机改写。
// 心力模式只有在最后一步点「打开心力模式」才开；「以后再说」不开，心力模式页关着时可以再打开引导。

struct HeartIntroSheet: View {
    let model: MobileModel
    @State private var step: Int
    @State private var deleteFromRecorder: Bool
    @State private var retention: AudioRetention
    @Environment(\.dismiss) private var dismiss
    static let steps = 4

    init(model: MobileModel, step: Int = 0) {
        self.model = model
        let p = model.settings.heartIntroPrefill
        _step = State(initialValue: min(max(step, 0), Self.steps - 1))
        _deleteFromRecorder = State(initialValue: p.deleteFromRecorder)
        _retention = State(initialValue: p.audioRetention)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $step) {
                page { what }.tag(0)
                page { privacy }.tag(1)
                page { choices }.tag(2)
                page { turnOn }.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .safeAreaInset(edge: .bottom) { buttons }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { later() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func page<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        ScrollView {
            c().frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 56)
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            if step < Self.steps - 1 {
                Button { withAnimation { step += 1 } } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button { turnOnNow() } label: {
                    Text("Turn on Heart mode").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 8)
    }

    // MARK: 各页

    private func header(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Color.accentColor)
            Text(title).font(.title.weight(.bold))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var what: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("heart", "Meet Heart mode",
                   "Wear your recorder all day as a Heart bean. When it goes back in its case, OpenBean takes care of the rest — even with your iPhone in your pocket.")
            VStack(alignment: .leading, spacing: 14) {
                Label("Syncs over Bluetooth by itself when the Heart bean is back in its case.", systemImage: "arrow.triangle.2.circlepath")
                Label("Transcribes on this iPhone and splits the day into conversations.", systemImage: "text.bubble")
                Label("Writes today's diary and to-dos with your LLM service.", systemImage: "book.closed")
                Label("Clears synced recordings off the Heart bean so it has room for tomorrow.", systemImage: "trash")
            }
            .labelStyle(IntroIconLabel())
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("lock.shield", "Where your words go",
                   "Audio, transcripts and the diary are kept on this iPhone.")
            VStack(alignment: .leading, spacing: 14) {
                Label("Speech is transcribed on this iPhone, offline. The speech recognition model is downloaded once.", systemImage: "iphone")
                Label("The diary and conversation summaries are written by the LLM service set in Settings.", systemImage: "sparkles")
                serviceLine
                Label("Recordings are still synced and transcribed without an LLM service; the diary is written once one is reachable.", systemImage: "clock.arrow.circlepath")
            }
            .labelStyle(IntroIconLabel())
        }
    }

    /// 现在选的整理用模型：端侧、局域网还是云端；云端就说清楚转写文字会发给它（说法和设置页共用）
    @ViewBuilder private var serviceLine: some View {
        let d = model.settings.llmDisclosure
        if d.choice == .none {
            Label("No model is chosen yet. If you choose a cloud service, transcript text is sent to it.", systemImage: "cloud")
        } else {
            Label { Text(d.sentence) }
                icon: { Image(systemName: d.sendsTextOffDevice ? "cloud" : "lock.shield").foregroundStyle(d.sendsTextOffDevice ? .orange : .secondary) }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("slider.horizontal.3", "After each sync", "You can change these later in Heart mode settings.")
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $deleteFromRecorder) {
                    Text("Delete recordings from the Heart bean once they're synced and transcribed")
                }
                Text("Deleted recordings can't be recovered. A recording is only deleted when the copy on this iPhone is complete and checked against the Heart bean.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep audio on this iPhone").font(.headline)
                Picker("Keep audio on this iPhone", selection: $retention) {
                    Text("Delete after transcription").tag(AudioRetention.afterTranscription)
                    Text("7 days").tag(AudioRetention.sevenDays)
                    Text("Keep").tag(AudioRetention.forever)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Transcripts, summaries and the diary are always kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var turnOn: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("heart.fill", "Ready to turn on Heart mode", "Here's what happens from now on.")
            VStack(alignment: .leading, spacing: 14) {
                Label("Syncs automatically when the Heart bean goes back in its case", systemImage: "arrow.triangle.2.circlepath")
                if deleteFromRecorder {
                    Label("Synced recordings are deleted from the Heart bean", systemImage: "trash")
                } else {
                    Label("Recordings stay on the Heart bean", systemImage: "tray.full")
                }
                Label { Text(verbatim: SyncRunText.retention(retention)) } icon: { Image(systemName: "waveform") }
                Label("Works in the background. Keep Bluetooth on, and don't swipe OpenBean away in the app switcher — iOS then stops waking it until you open it again.",
                      systemImage: "iphone.radiowaves.left.and.right")
                Label("A notification when today's record is updated or something needs you (iOS asks once).", systemImage: "bell")
            }
            .labelStyle(IntroIconLabel())
        }
    }

    // MARK: 动作

    private func later() {
        model.settings.heartIntroSeen = true
        Log.write("心力模式引导：以后再说（第 \(step + 1) 步）")
        dismiss()
    }

    private func turnOnNow() {
        let s = model.settings
        s.heartDeleteFromRecorder = deleteFromRecorder
        s.heartAudioRetention = retention
        s.heartIntroSeen = true
        s.heartMode = true
        Log.write("心力模式引导：打开心力模式（同步后从设备删除=\(deleteFromRecorder)，本机音频=\(retention.rawValue)）")
        Notifier.requestPermission()
        MobileRouter.shared.open(.today)
        dismiss()
    }
}

/// 图标列固定宽度
struct IntroIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.icon.foregroundStyle(Color.accentColor).frame(width: 26, alignment: .center)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
