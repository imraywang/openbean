// SPDX-License-Identifier: Apache-2.0

import OpenBeanVoice
import Carbon.HIToolbox
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case voice, polish, library, agent, about
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .voice: return "Voice typing"
        case .polish: return "Clean-up"
        case .library: return "Library"
        case .agent: return "Agents"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .voice: return "keyboard"
        case .polish: return "sparkles"
        case .library: return "waveform"
        case .agent: return "point.3.connected.trianglepath.dotted"
        case .about: return "info.circle"
        }
    }
    /// 链接里的名字（openbean://settings/<名字>）；0.4 以前的 models 页现在叫「关于」
    init?(link: String) {
        if link == "models" { self = .about; return }
        self.init(rawValue: link)
    }
}

/// 独立的设置窗口（Settings 场景，⌘, 和菜单栏「设置…」打开）：工具栏放分页，记住上次打开的那页（存在 Navigator 里，链接也能指定）
struct SettingsWindow: View {
    let model: AppModel

    var body: some View {
        @Bindable var nav = model.nav
        TabView(selection: $nav.settingsTab) {
            Tab(SettingsTab.voice.title, systemImage: SettingsTab.voice.icon, value: .voice) {
                VoiceSettings(settings: model.settings).frame(height: 700)
            }
            Tab(SettingsTab.polish.title, systemImage: SettingsTab.polish.icon, value: .polish) {
                PolishSettings(settings: model.settings).frame(height: 560)
            }
            Tab(SettingsTab.library.title, systemImage: SettingsTab.library.icon, value: .library) {
                LibrarySettings(settings: model.settings).frame(height: 640)
            }
            Tab(SettingsTab.agent.title, systemImage: SettingsTab.agent.icon, value: .agent) {
                Form { AgentSettingsSection() }.formStyle(.grouped).frame(height: 420)
            }
            Tab(SettingsTab.about.title, systemImage: SettingsTab.about.icon, value: .about) {
                AboutSettings(models: model.models, updater: model.updater).frame(height: 320)
            }
        }
        .frame(width: 640)
    }
}

/// 把设置窗口带到前台（菜单栏 App：和 bringToFront 一样要等菜单收起再激活）。
/// 第一次打开时 openSettings 返回后窗口还没建好，所以没找到或没成为主窗口就稍后再试几次
@MainActor func bringSettingsToFront(attempt: Int = 0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.12)) {
        NSApp.activate()
        let w = NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }
        if let w {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
        if w?.isKeyWindow != true {
            if attempt < 8 { bringSettingsToFront(attempt: attempt + 1) } else { Log.write("设置窗口没能置前") }
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
                if settings.hotkey == .custom { ShortcutRecorder(settings: settings) }
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
                        Circle().fill(trusted ? Color.green : .orange).frame(width: 8, height: 8)
                        Text(trusted ? "Accessibility permission granted" : "Needs Accessibility permission")
                            .foregroundStyle(trusted ? .secondary : .primary)
                        Spacer()
                        Button("Open System Settings") { Typist.requestTrust(); Typist.openAccessibilitySettings() }
                            .buttonStyle(.link)
                    }
                }
                Toggle(isOn: $settings.keepHistory) {
                    Text("Keep voice typing history on this Mac")
                    Text("Shown on the Voice typing page and in Today")
                }
                Toggle(isOn: $settings.deleteDictationAudio) {
                    Text("Delete voice-typing audio from the recorder")
                    Text("Only files OpenBean created for voice typing are deleted. Deleted audio can't be recovered.")
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
                        Circle().fill(status == .ok ? Color.green : .orange).frame(width: 8, height: 8)
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
                Text("One term per line: names, product names, jargon. OpenBean fixes same-sounding names and spelling to these without an LLM, in voice typing and in library transcripts (where only terms of three or more characters are fixed by sound); clean-up prefers them too. For a word it keeps mishearing, add what it hears after an equals sign: Claude Code = cloud code, 克劳德 code")
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
        #if DEMO || DEBUG
        if Flavor.isFake { status = .ok; return } // 演示版、预览不连任何服务
        #endif
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
                Toggle(isOn: $settings.autoSync) {
                    Text("Sync new recordings automatically")
                    Text("Over Bluetooth, when the recorder connects or goes back in its case")
                }
                Toggle(isOn: $settings.autoTranscribe) {
                    Text("Transcribe recordings after download")
                    Text("Runs on this Mac with SenseVoice")
                }
                LabeledContent("Library folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.library) }
                }
            }
            Section {
                Picker("A day starts at", selection: $settings.dayStartHour) {
                    ForEach(0..<7) { h in
                        Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
                            .formatted(date: .omitted, time: .shortened)).tag(h)
                    }
                }
            } footer: {
                Text("Today groups recordings by day. With 4:00 AM, a conversation at 2 AM still counts as the day before.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NoteSettingsSections(settings: settings, notes: AppModel.shared.library.notes)
        }
        .formStyle(.grouped)
    }
}

// MARK: - 关于（版本、更新、语音模型）

private struct AboutSettings: View {
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
            Section("OpenBean") {
                LabeledContent("Version") {
                    HStack {
                        Text(version).textSelection(.enabled)
                        Button("Check now") { updater.check() }
                            .disabled(!updater.canCheck)
                    }
                }
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                    .disabled(!Flavor.updates)
                Link("Source code and protocol notes", destination: URL(string: "https://github.com/imraywang/openbean")!)
            }
            Section("Speech models") {
                ModelStatusRow(models: models)
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
                // 「正常」统一画法：绿色的图标，文字照常
                Label {
                    Text("SenseVoice and voice activity models are ready")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case let .failed(e):
                Label("Download failed: \(e)", systemImage: "xmark.octagon").foregroundStyle(.red)
                Spacer()
                Button("Retry") { Task { await models.download() } }
            }
        }
    }
}

/// 录一个自定义快捷键：点按钮后按下组合键；Esc 取消。录的时候先停掉现有快捷键，免得它被触发
struct ShortcutRecorder: View {
    @Bindable var settings: Settings
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                Button(recording ? String(localized: "Press the shortcut…")
                                 : (settings.hotkeyCustom?.label ?? String(localized: "Record shortcut"))) {
                    recording ? stop() : start()
                }
            }
        } label: {
            Text("Custom shortcut")
            Text("Click, then press the keys. Use ⌘, ⌥ or ⌃ with a key, or an F key on its own. Esc cancels.")
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hint = nil
        Hotkey.shared.register(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if Int(e.keyCode) == kVK_Escape { stop(); return nil }
            guard let combo = Hotkey.Combo(event: e) else {
                hint = String(localized: "Add ⌘, ⌥ or ⌃")
                return nil
            }
            // 先试着注册：被系统或别的 App 占用就不保存
            if Hotkey.shared.register((combo.code, combo.mods)) {
                settings.hotkeyCustom = combo
                stop()
            } else {
                hint = String(localized: "\(combo.label) is taken by another app")
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        Hotkey.shared.register(settings.hotkeyKey)
    }
}
