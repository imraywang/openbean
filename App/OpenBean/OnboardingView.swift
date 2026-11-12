// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// 首次启动：连接录音豆 → 下载语音模型 → 打字权限 → 试一试
struct OnboardingView: View {
    let model: AppModel
    @State private var step = 0
    @State private var trusted = Typist.trusted
    @State private var tryText = ""
    @Environment(\.dismissWindow) private var dismiss
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: recorder
                case 2: speech
                case 3: typing
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < steps - 1 {
                    Button(step == 0 ? "Get started" : "Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        model.settings.onboardingDone = true
                        dismiss(id: "onboarding")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 420)
        .onReceive(tick) { _ in trusted = Typist.trusted }
    }

    private func header(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Color.accentColor)
            Text(title).font(.title.weight(.semibold))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("waveform.circle", "Welcome to OpenBean",
                   "Use your soundcore Work recorder on this Mac — no vendor app, no cloud.")
            VStack(alignment: .leading, spacing: 8) {
                Label("Press the recorder's button and speak; the text is typed where your cursor is.", systemImage: "keyboard")
                Label("Sync recordings to your Mac and get searchable transcripts.", systemImage: "music.note.list")
                Label("Speech is recognised on this Mac, offline.", systemImage: "lock")
            }
        }
    }

    private var recorder: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("mic.circle", "Connect your recorder",
                   "Take the recorder out of its case. OpenBean finds it over Bluetooth — no pairing in System Settings needed. If macOS asks for Bluetooth access, allow it.")
            HStack(spacing: 10) {
                switch model.device.state {
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Connected to \(model.device.deviceName)")
                case let .failed(e):
                    ProgressView().controlSize(.small)
                    Text("Still looking… \(e)").foregroundStyle(.secondary)
                default:
                    ProgressView().controlSize(.small)
                    Text("Searching…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var speech: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("square.and.arrow.down", "Download speech models",
                   "SenseVoice turns your speech into punctuated text on this Mac. The download is about 240 MB and happens once.")
            ModelStatusRow(models: model.models)
        }
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("keyboard", "Allow typing into other apps",
                   "To put text where your cursor is, macOS needs to let OpenBean send keystrokes. Turn on OpenBean under Privacy & Security → Accessibility (on some versions: Device Control and Data Access).")
            HStack {
                if trusted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Open System Settings") { Typist.requestTrust(); Typist.openAccessibilitySettings() }
                    Text("You can skip this; text then only appears in OpenBean.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("hand.tap", "Try it",
                   "Click in the box, press the recorder's button, wait for “Listening”, then speak. Press the button again to finish. The keyboard shortcut \(model.settings.hotkey.label) does the same.")
            TextEditor(text: $tryText)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }
}
