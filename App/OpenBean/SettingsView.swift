// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    let models: ModelStore
    @State private var trusted = Typist.trusted
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Voice typing") {
                Picker("Recorder button", selection: $settings.buttonDictates) {
                    Text("Voice typing").tag(true)
                    Text("Record only").tag(false)
                }
                Picker("Keyboard shortcut", selection: $settings.hotkey) {
                    ForEach(Hotkey.Preset.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Play a sound when it's ready to listen", isOn: $settings.readySound)
                Toggle("Type into the active app", isOn: $settings.typeIntoApp)
                if settings.typeIntoApp && !trusted {
                    HStack {
                        Label("Needs Accessibility permission", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") { Typist.requestTrust(); Typist.openAccessibilitySettings() }
                    }
                }
            }

            Section {
                SliderRow(title: "End a phrase after a pause of", value: $settings.sentencePause, range: 0.4...1.5)
                SliderRow(title: "New paragraph after a pause of", value: $settings.paragraphGap, range: 1.0...5.0)
            } header: {
                Text("Pauses")
            } footer: {
                Text("Short pauses finalise a phrase; slightly longer ones become a comma, longer ones a full stop. A too-short phrase pause chops sentences and hurts accuracy. Restart OpenBean after changing it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Clean up each sentence with a local LLM", isOn: $settings.polishEnabled)
                TextField("Server address", text: $settings.polishEndpoint, prompt: Text("http://127.0.0.1:8092"))
                TextField("Model name", text: $settings.polishModel)
                Button("Edit personal word list…") {
                    _ = AppPaths.readGlossary()
                    NSWorkspace.shared.open(AppPaths.glossary)
                }
            } header: {
                Text("Clean-up")
            } footer: {
                Text("Any OpenAI-compatible server works: llama.cpp (llama-server), Ollama, LM Studio. It removes filler words, fixes likely homophones using your word list and keeps your wording.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Library") {
                Toggle("Transcribe recordings after download", isOn: $settings.autoTranscribe)
                Button("Show library folder") { NSWorkspace.shared.open(AppPaths.library) }
            }

            Section("Speech models") {
                ModelStatusRow(models: models)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Link("Source code and protocol notes", destination: URL(string: "https://github.com/imraywang/openbean")!)
                Button("Open log") { NSWorkspace.shared.open(AppPaths.log) }
            }
        }
        .formStyle(.grouped)
        .onReceive(tick) { _ in trusted = Typist.trusted }
    }
}

struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 0.1).frame(width: 180)
                Text(String(format: "%.1f s", value)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

struct ModelStatusRow: View {
    let models: ModelStore
    var body: some View {
        HStack {
            switch models.state {
            case .checking:
                ProgressView().controlSize(.small); Text("Checking…")
            case .missing:
                Label("Not downloaded (about 240 MB)", systemImage: "arrow.down.circle")
                Spacer()
                Button("Download") { Task { await models.download() } }
            case let .downloading(p):
                ProgressView(value: p) { Text("Downloading speech models… \(Int(p * 100))%") }
            case .ready:
                Label("SenseVoice and voice activity models are ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case let .failed(e):
                Label("Download failed: \(e)", systemImage: "xmark.octagon").foregroundStyle(.red)
                Spacer()
                Button("Retry") { Task { await models.download() } }
            }
        }
    }
}
