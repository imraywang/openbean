// SPDX-License-Identifier: Apache-2.0

import AppKit
import OpenBeanKit
import SwiftUI

@main
enum Main {
    static func main() {
        if #available(macOS 26.0, *) {
            OpenBeanApp.main()
        } else {
            let a = NSAlert()
            a.messageText = "openbean 的语音输入需要 macOS 26 或更新版本"
            a.runModal()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings = Settings()
    let device = DeviceController()
    lazy var dictation = Dictation(device: device, settings: settings)
    lazy var hud = HUDController(dictation: dictation)

    func start() {
        device.onEvent = { [weak self] e in self?.dictation.handle(e) }
        device.start()
        hud.start()
        if settings.typeIntoApp, !Typist.trusted { Typist.requestTrust() }
    }
}

@available(macOS 26.0, *)
struct OpenBeanApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: AppModel.shared)
        } label: {
            MenuIcon(device: AppModel.shared.device, dictation: AppModel.shared.dictation)
        }
        .menuBarExtraStyle(.menu)

        SwiftUI.Settings {
            SettingsView(settings: AppModel.shared.settings)
        }
    }
}

@available(macOS 26.0, *)
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { AppModel.shared.start() }
    }
}

@available(macOS 26.0, *)
struct MenuIcon: View {
    let device: DeviceController
    let dictation: Dictation
    var body: some View {
        switch (device.state, dictation.phase) {
        case (_, .listening), (_, .starting): Image(systemName: "waveform.circle.fill")
        case (.ready, _): Image(systemName: "mic.circle")
        default: Image(systemName: "mic.slash.circle")
        }
    }
}

@available(macOS 26.0, *)
struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let d = model.device, dict = model.dictation, s = model.settings
        Text(deviceLine(d))
        if let e = dict.lastError { Text("⚠︎ \(e)") }
        if !dict.recognizerReady { Text("正在加载 SenseVoice…") }
        Divider()
        Button(dict.phase == .idle ? "开始听写（也可以按录音豆按键）" : "停止听写") {
            Task { await dict.toggle() }
        }
        .disabled(d.session == nil)
        Divider()
        Toggle("打字到光标处", isOn: Binding(get: { s.typeIntoApp }, set: {
            s.typeIntoApp = $0
            if $0, !Typist.trusted { Typist.requestTrust() }
        }))
        Toggle("本地大模型润色", isOn: Binding(get: { s.polishEnabled }, set: { s.polishEnabled = $0 }))
        Button("编辑个人词表…") {
            _ = AppPaths.readGlossary()
            NSWorkspace.shared.open(AppPaths.glossary)
        }
        Button("设置…") {
            NSApp.activate()
            openSettings()
        }
        Button("打开日志") { NSWorkspace.shared.open(AppPaths.log) }
        Divider()
        Button("退出 openbean") { NSApp.terminate(nil) }
    }

    private func deviceLine(_ d: DeviceController) -> String {
        switch d.state {
        case .idle, .searching: return "正在寻找录音豆…"
        case .connecting: return "正在连接…"
        case .ready:
            let b = d.battery.map { " · 电量 \($0)%" } ?? ""
            return "录音豆已连接\(b)"
        case let .failed(m): return "未连接：\(m)"
        }
    }
}

@available(macOS 26.0, *)
struct SettingsView: View {
    @Bindable var settings: Settings
    var body: some View {
        Form {
            Section("润色（OpenAI 兼容接口，如 llama-server、Ollama、LM Studio）") {
                Toggle("启用", isOn: $settings.polishEnabled)
                TextField("地址", text: $settings.polishEndpoint)
                TextField("模型名", text: $settings.polishModel)
            }
            Section("切句") {
                HStack {
                    Slider(value: $settings.sentencePause, in: 0.4...1.5, step: 0.1)
                    Text(String(format: "停顿 %.1f 秒定稿一句", settings.sentencePause)).monospacedDigit()
                }
                Text("太短会把一句话切碎、错字变多；太长定稿变慢。重启 App 后生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("分段") {
                HStack {
                    Slider(value: $settings.paragraphGap, in: 0.8...4, step: 0.1)
                    Text(String(format: "停顿 %.1f 秒换段", settings.paragraphGap)).monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
