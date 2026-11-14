// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import OpenBeanVoice
import Carbon.HIToolbox
import SwiftUI

// 设置不再是独立窗口：各模块的设置在各自的页面里（心力模式页 HeartSettings、语音输入页 VoiceTypingSettings、
// 录音豆页 RecorderSettingsSections），侧栏底部的「设置」页（GeneralSettingsPage）只放通用的几组。
// 老链接 openbean://settings/<名字> 由 SettingsRoute 换到新位置。

// MARK: - 语音输入页的设置

struct VoiceTypingSettings: View {
    @Bindable var settings: Settings
    let nav: Navigator

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                VoiceSettingsSections(settings: settings)
                CleanUpSettingsSections(settings: settings)
                Section {
                    Button("Edit personal word list…") {
                        _ = AppPaths.readGlossary()
                        NSWorkspace.shared.open(AppPaths.glossary)
                    }
                    .buttonStyle(.link)
                } header: {
                    Text("Personal word list")
                } footer: {
                    Text("One term per line: names, product names, jargon. OpenBean fixes same-sounding names and spelling to these without an LLM, in voice typing and in library transcripts (where only terms of three or more characters are fixed by sound); clean-up prefers them too. For a word it keeps mishearing, add what it hears after an equals sign: Claude Code = cloud code, 克劳德 code")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .modifier(ScrollToSettingsAnchor(nav: nav, proxy: proxy))
        }
    }
}

/// 触发、输出、停顿
private struct VoiceSettingsSections: View {
    @Bindable var settings: Settings
    @State private var trusted = Typist.trusted
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Trigger") {
            // 分段按钮按文字宽度靠右；直接给 Picker 加 fixedSize 会让整行收缩、按钮浮在中间
            LabeledContent(DeviceWord.pick(settings.mode.callsDeviceHeartBean, "Heart bean button", "Recorder button")) {
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
        }
        .onReceive(tick) { _ in trusted = Typist.trusted }

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

// MARK: - 润色（语音输入页；心力模式的日记和段摘要也用这里设的大模型服务）

private struct CleanUpSettingsSections: View {
    @Bindable var settings: Settings
    @State private var status: Polisher.Status?
    @State private var checking = false

    private var url: URL? { URL(string: settings.polishEndpoint) }
    private var isCloud: Bool { url.map { !Polisher.isLocal($0) } ?? false }

    var body: some View {
        Section {
            Toggle(isOn: $settings.polishEnabled) {
                Text("Clean up each sentence with an LLM")
                Text("Removes filler words, fixes likely homophones using your word list and keeps your wording.")
            }
        } header: {
            Text("Clean-up")
        }
        .id(SettingsAnchor.cleanUp)
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
            Text("LLM server")
        } footer: {
            Text("Any OpenAI-compatible service works: llama.cpp (llama-server), Ollama or LM Studio on this Mac, or cloud services such as DeepSeek, Qwen, Kimi and OpenAI. The API key is kept in your keychain. Summaries and the Heart mode diary use the same service.")
                .font(.caption).foregroundStyle(.secondary)
        }
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

// MARK: - 录音豆页里的设置（同步、从设备删除）

struct RecorderSettingsSections: View {
    @Bindable var settings: Settings

    var body: some View {
        let heart = settings.mode.callsDeviceHeartBean
        Section {
            // 心力模式下固定自动同步：开关锁住、显示为开（关掉心力模式后回到用户自己的选择）
            Toggle(isOn: settings.mode.autoSyncLocked ? .constant(true) : $settings.autoSync) {
                Text("Sync new recordings automatically")
                if settings.mode.autoSyncLocked {
                    Text("Always on in Heart mode")
                } else {
                    Text("Over Bluetooth, when the recorder connects or goes back in its case")
                }
            }
            .disabled(settings.mode.autoSyncLocked)
        } header: {
            Text("Sync")
        } footer: {
            Text("Large recordings can be fetched over the recorder's own Wi‑Fi: OpenBean offers it in the toolbar while a long sync is running.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .id(SettingsAnchor.recorderSync)

        Section("Deleting from the device") {
            Toggle(isOn: $settings.deleteDictationAudio) {
                if heart {
                    Text("Delete voice-typing audio from the Heart bean")
                } else {
                    Text("Delete voice-typing audio from the recorder")
                }
                Text("Only files OpenBean created for voice typing are deleted. Deleted audio can't be recovered.")
            }
            if heart {
                // 心力模式的「同步后从心力豆删除」在心力模式页的设置里
                LabeledContent {
                    Button("Heart mode settings…") { AppModel.shared.nav.open(.heart) }
                } label: {
                    Text(settings.heartDeleteFromRecorder ? "Recordings are deleted from the Heart bean after they're synced"
                                                          : "Recordings stay on the Heart bean after they're synced")
                    Text("Set in Heart mode.")
                }
            }
        }
    }
}

// MARK: - 设置页（侧栏底部）：录音库和笔记、Agent、语音模型、更新和关于

struct GeneralSettingsPage: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        ScrollViewReader { proxy in
            Form {
                Section {
                    Toggle(isOn: $settings.autoTranscribe) {
                        Text("Transcribe recordings after download")
                        Text("Runs on this Mac with SenseVoice")
                    }
                    LabeledContent("Library folder") {
                        Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.library) }
                    }
                    // 和心力模式设置里的是同一个设置
                    DayStartPicker(settings: settings)
                } header: {
                    Text("Library")
                } footer: {
                    Text("The day start is used to group recordings and voice typing by day.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .id(GeneralSettingsGroup.library.rawValue)
                NoteSettingsSections(settings: settings, notes: model.library.notes)
                AgentSettingsSection()
                    .id(GeneralSettingsGroup.agents.rawValue)
                Section("Speech models") {
                    ModelStatusRow(models: model.models)
                }
                .id(GeneralSettingsGroup.about.rawValue)
                AboutSection(updater: model.updater)
            }
            .formStyle(.grouped)
            .modifier(ScrollToSettingsAnchor(nav: model.nav, proxy: proxy))
        }
        .navigationTitle("Settings")
    }
}

/// 版本、更新、源代码、日志
private struct AboutSection: View {
    @Bindable var updater: Updater

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
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
            HStack(spacing: 16) {
                Link("Source code and protocol notes", destination: URL(string: "https://github.com/imraywang/openbean")!)
                Button("Open log") { NSWorkspace.shared.open(AppPaths.log) }
                    .buttonStyle(.link)
            }
            // 菜单栏图标左键直接打开主窗口，菜单要右键才出来：这里也放一个退出，不知道右键的人也能退出
            LabeledContent {
                Button("Quit OpenBean") { NSApp.terminate(nil) }
            } label: {
                Text("OpenBean keeps running in the menu bar after you close this window. Right-click its icon for the menu.")
                    .font(.callout).foregroundStyle(.secondary)
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
