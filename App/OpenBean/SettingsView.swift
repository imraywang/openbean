// SPDX-License-Identifier: Apache-2.0

import OpenBeanVoice
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case voice, polish, library, models
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .voice: return "Voice typing"
        case .polish: return "Clean-up"
        case .library: return "Library"
        case .models: return "Models"
        }
    }
}

/// 主窗口里的「设置」页：工具栏中间的分段控件切四组（语音输入 / 润色 / 录音库 / 模型）
struct SettingsPage: View {
    let model: AppModel

    var body: some View {
        @Bindable var nav = model.nav
        Group {
            switch nav.settingsTab {
            case .voice: VoiceSettings(settings: model.settings)
            case .polish: PolishSettings(settings: model.settings)
            case .library: LibrarySettings(settings: model.settings)
            case .models: ModelSettings(models: model.models, updater: model.updater)
            }
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Settings", selection: $nav.settingsTab) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

// MARK: - 语音输入

private struct VoiceSettings: View {
    @Bindable var settings: Settings
    @State private var trusted = Typist.trusted
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Trigger") {
                // 分段按钮按文字宽度靠右；直接给 Picker 加 fixedSize 会让整行收缩、按钮浮在中间
                LabeledContent("Recorder button") {
                    Picker("Recorder button", selection: $settings.buttonDictates) {
                        Text("Voice typing").tag(true)
                        Text("Record only").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Picker("Keyboard shortcut", selection: $settings.hotkey) {
                    ForEach(Hotkey.Preset.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $settings.readySound) {
                    Text("Play a sound when it's ready to listen")
                    Text("A soft tick when the bar turns into a microphone")
                }
            }

            Section("Output") {
                Toggle(isOn: $settings.typeIntoApp) {
                    Text("Type into the active app")
                    Text("Needs Accessibility permission. When off, the text is copied to the clipboard.")
                }
                if settings.typeIntoApp {
                    HStack(spacing: 8) {
                        Circle().fill(trusted ? Color.accentColor : .orange).frame(width: 8, height: 8)
                        Text(trusted ? "Accessibility permission granted" : "Needs Accessibility permission")
                            .foregroundStyle(trusted ? .secondary : .primary)
                        Spacer()
                        Button("Open System Settings") { Typist.requestTrust(); Typist.openAccessibilitySettings() }
                            .buttonStyle(.link)
                    }
                }
                Toggle(isOn: $settings.keepHistory) {
                    Text("Keep voice typing history on this Mac")
                    Text("Used by the Voice typing page and the Overview totals")
                }
            }

            Section {
                SliderRow(title: "End a phrase after a pause of", value: $settings.sentencePause, range: 0.4...1.5)
                SliderRow(title: "New paragraph after a pause of", value: $settings.paragraphGap, range: 1.0...5.0)
                PauseTimeline(phrase: settings.sentencePause, paragraph: settings.paragraphGap)
            } header: {
                Text("Pauses and layout")
            } footer: {
                Text("A too-short phrase pause chops sentences and hurts accuracy. Restart OpenBean after changing it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 16) {
                    Button("Edit personal word list…") {
                        _ = AppPaths.readGlossary()
                        NSWorkspace.shared.open(AppPaths.glossary)
                    }
                    Button("Open log") { NSWorkspace.shared.open(AppPaths.log) }
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .onReceive(tick) { _ in trusted = Typist.trusted }
    }
}

/// 停顿时间轴：多久定稿、哪段算逗号、哪段算句号、多久换段
private struct PauseTimeline: View {
    let phrase: Double
    let paragraph: Double

    var body: some View {
        let comma = 0.3
        let period = max(paragraph - phrase - comma, 0.2)
        let tail = 0.8
        GeometryReader { geo in
            let total = phrase + comma + period + tail
            let w = geo.size.width / total
            HStack(spacing: 0) {
                segment(Text("\(phrase, specifier: "%.1f") s · phrase"), width: phrase * w, color: Color(red: 0.478, green: 0.525, blue: 0.722))
                segment(Text("comma"), width: comma * w, color: Color(red: 0.616, green: 0.667, blue: 1))
                segment(Text("full stop"), width: period * w, color: Color(red: 0.725, green: 0.769, blue: 0.925))
                segment(Text("\(paragraph, specifier: "%.1f") s · new paragraph"), width: tail * w, color: .accentColor, emphasis: true)
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }

    private func segment(_ label: Text, width: CGFloat, color: Color, emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(color).frame(height: 3)
            label.font(.caption2).foregroundStyle(emphasis ? Color.accentColor : .secondary)
                .lineLimit(1).fixedSize()
        }
        .frame(width: width, alignment: .leading)
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
                Text("\(value, specifier: "%.1f") s").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - 润色

private struct PolishSettings: View {
    @Bindable var settings: Settings
    @State private var status: Polisher.Status?
    @State private var checking = false

    private var url: URL? { URL(string: settings.polishEndpoint) }
    private var isCloud: Bool { url.map { !Polisher.isLocal($0) } ?? false }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.polishEnabled) {
                    Text("Clean up each sentence with an LLM")
                    Text("Removes filler words, fixes likely homophones using your word list and keeps your wording.")
                }
            }
            Section {
                TextField("Server address", text: $settings.polishEndpoint, prompt: Text("http://127.0.0.1:8092"))
                SecureField("API key", text: $settings.polishAPIKey, prompt: Text("Only needed for cloud services"))
                TextField("Model name", text: $settings.polishModel)
                HStack(spacing: 8) {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if let status {
                        Circle().fill(status == .ok ? Color.accentColor : .orange).frame(width: 8, height: 8)
                        statusText(status).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Check connection") { Task { await check() } }
                }
                if isCloud, let host = url?.host {
                    Label {
                        Text("The text of each sentence is sent to \(host). Audio and speech recognition stay on this Mac.")
                    } icon: {
                        Image(systemName: "icloud").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Any OpenAI-compatible service works: llama.cpp (llama-server), Ollama or LM Studio on this Mac, or cloud services such as DeepSeek, Qwen, Kimi and OpenAI. The API key is kept in your keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Edit personal word list…") {
                    _ = AppPaths.readGlossary()
                    NSWorkspace.shared.open(AppPaths.glossary)
                }
                .buttonStyle(.link)
            } footer: {
                Text("One term per line: names, product names, jargon. Clean-up prefers these when a word sounds similar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await check() }
        .onChange(of: settings.polishEndpoint) { status = nil }
        .onChange(of: settings.polishAPIKey) { status = nil }
    }

    private func statusText(_ s: Polisher.Status) -> Text {
        switch s {
        case .ok: return Text("Connected")
        case .unauthorized: return Text("Connected, but the API key was rejected")
        case let .unreachable(why): return Text("Not reachable: \(why)")
        }
    }

    private func check() async {
        guard let url else { status = .unreachable(String(localized: "invalid address")); return }
        checking = true
        status = await Polisher.check(url, apiKey: settings.polishAPIKey)
        checking = false
    }
}

// MARK: - 录音库

private struct LibrarySettings: View {
    @Bindable var settings: Settings
    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.autoTranscribe) {
                    Text("Transcribe recordings after download")
                    Text("Runs on this Mac with SenseVoice")
                }
                LabeledContent("Library folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.library) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 模型与关于

private struct ModelSettings: View {
    let models: ModelStore
    @Bindable var updater: Updater

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Speech models") {
                ModelStatusRow(models: models)
            }
            Section("About") {
                LabeledContent("Version") {
                    HStack {
                        Text(version).textSelection(.enabled)
                        Button("Check now") { updater.check() }
                            .disabled(!updater.canCheck)
                    }
                }
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                Link("Source code and protocol notes", destination: URL(string: "https://github.com/imraywang/openbean")!)
            }
        }
        .formStyle(.grouped)
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
