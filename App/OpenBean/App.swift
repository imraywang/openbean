// SPDX-License-Identifier: Apache-2.0

import AppKit
import OpenBeanKit
import SwiftUI

@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings = Settings()
    let device = DeviceController()
    let models = ModelStore()
    let log = DictationLog()
    let nav = Navigator()
    lazy var dictation = Dictation(device: device, settings: settings)
    lazy var library = LibraryStore(device: device, settings: settings)
    lazy var hud = HUDController(dictation: dictation)
    lazy var autoSync = AutoSync(device: device, library: library, settings: settings)
    /// 自动更新：start() 里创建，第二份 App 退出前不会碰到它
    lazy var updater = Updater()

    func start() {
        models.check()
        models.onReady = { [weak self] in self?.dictation.loadRecognizer() }
        device.onEvent = { [weak self] e in
            self?.dictation.handle(e)
            self?.autoSync.handle(e)
        }
        library.onListRefreshed = { [weak self] in self?.autoSync.listRefreshed() }
        device.onConnected = { [weak self] in Task { await self?.library.refreshDeviceList() } }
        dictation.onStarted = { [weak self] id in self?.library.markDictation(id) }
        dictation.onFinished = { [weak self] in self?.library.resumeIfNeeded() }
        dictation.onEntry = { [weak self] in self?.log.add($0) }
        Hotkey.shared.onPress = { [weak self] in
            guard let self, self.device.isReady else { return }
            Task { await self.dictation.toggle() }
        }
        Hotkey.shared.register(settings.hotkey)
        settings.onHotkeyChange = { [weak self] in
            guard let self else { return }
            Hotkey.shared.register(self.settings.hotkey)
        }
        device.start()
        hud.start()
        _ = updater
    }

    /// 主窗口打开回调（由 MainView 登记，用于 openbean://open）
    var openMain: (() -> Void)?

    func handle(_ url: URL) {
        guard url.scheme == "openbean" else { return }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).joined(separator: "/")
        Log.write("链接 \(url.absoluteString)")
        switch path {
        case "dictate/toggle", "dictate":
            Task { await dictation.toggle() }
        case "dictate/start":
            if dictation.phase == .idle { Task { await dictation.toggle() } }
        case "dictate/stop":
            if dictation.phase != .idle { Task { await dictation.toggle() } }
        case "sync":
            Task { await library.syncAll() }
        case "open":
            openMain?()
        case "settings":
            nav.section = .settings
            openMain?()
        case let p where p.hasPrefix("settings/"):
            // openbean://settings/voice|polish|library|models
            if let tab = SettingsTab(rawValue: String(p.dropFirst(9))) { nav.settingsTab = tab }
            nav.section = .settings
            openMain?()
        case let p where p.hasPrefix("summarize/"):
            // openbean://summarize/<录音 id>：摘要（或重新摘要）一条已转写的录音
            if let id = UInt32(p.dropFirst(10)), let r = library.recordings.first(where: { $0.id == id }),
               library.notes.canSummarize(r) { library.notes.summarize(id) }
        case "notes/backfill":
            library.notes.backfillNotes()
        case let p where p.hasPrefix("open/"):
            if let id = UInt32(p.dropFirst(5)) { nav.show(recording: id, in: library) }
            openMain?()
        default:
            break
        }
    }
}

@main
struct OpenBeanApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuIcon(device: model.device, dictation: model.dictation)
        }
        .menuBarExtraStyle(.menu)

        Window("OpenBean", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to OpenBean", id: "onboarding") {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.settings.onboardingDone ? .suppressed : .presented)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    /// 这份真的跑起来了（不是发现已有一份而自行退出的那份）
    private var started = false

    func applicationDidFinishLaunching(_ n: Notification) {
        // 只允许一份在跑：两份会同时抢录音豆的蓝牙连接，谁都连不上
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if let other = others.first {
            Log.write("已有一份 OpenBean 在运行（pid \(other.processIdentifier)），这份退出")
            other.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        started = true
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    /// openbean:// 链接：dictate/toggle|start|stop、sync、open
    func application(_ app: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppModel.shared.handle(url) }
        }
    }

    /// 退出时记一笔：电量统计脚本据此把退出后的时间排除在外
    func applicationWillTerminate(_ n: Notification) {
        guard started else { return }
        Log.write("battery event=quit")
        Log.flush()
    }

    /// 关掉主窗口后继续在菜单栏运行
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - 主窗口

/// 把窗口真正带到前台。
/// macOS 14 起 NSApp.activate() 只是「请求」，菜单栏 App 在菜单还没收起时发出常被系统忽略；
/// 窗口已经开着、只是被别的 App 盖住时，openWindow 也只在本 App 内排序。
/// 所以等到下一轮（菜单已收起）再激活，并把窗口强制排到最前。
@MainActor func bringToFront(_ id: String) {
    DispatchQueue.main.async {
        NSApp.activate()
        let w = NSApp.windows.first { $0.identifier?.rawValue == id || $0.identifier?.rawValue.hasPrefix("\(id)-") == true }
        guard let w else { Log.write("没找到窗口 \(id)"); return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }
}

/// 菜单栏菜单第一次渲染时登记「打开主窗口」的方法（链接 openbean://open 用）
private struct OpenWindowBinder: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            model.openMain = { openWindow(id: "main"); bringToFront("main") }
        }
    }
}

// MARK: - 菜单栏

struct MenuIcon: View {
    let device: DeviceController
    let dictation: Dictation
    var body: some View {
        Image(nsImage: BeanArt.menuIcons[state]!)
    }

    private var state: BeanArt.State {
        if dictation.phase == .listening || dictation.phase == .starting { return .listening }
        guard device.state == .ready else { return .disconnected }
        return device.activity == .syncing ? .syncing : .connected
    }
}

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let d = model.device, dict = model.dictation, s = model.settings
        Text(deviceLine(d))
            .background(OpenWindowBinder(model: model))
        if let e = dict.lastError { Text("⚠︎ \(e)") }
        if model.models.state != .ready { Text("Speech models not downloaded") }
        Divider()
        Button(dict.phase == .idle ? "Start voice typing" : "Stop voice typing") {
            Task { await dict.toggle() }
        }
        .disabled(!d.isReady)
        Button("Sync recordings") { Task { await model.library.syncAll() } }
            .disabled(!d.isReady || d.activity != .idle)
        Divider()
        Toggle("Type into the active app", isOn: Binding(get: { s.typeIntoApp }, set: {
            s.typeIntoApp = $0
            if $0, !Typist.trusted { Typist.requestTrust() }
        }))
        Toggle("Clean up with an LLM", isOn: Binding(get: { s.polishEnabled }, set: { s.polishEnabled = $0 }))
        Divider()
        Button("Open OpenBean") { open("main") }
            .keyboardShortcut("o")
        Button("Settings…") { model.nav.section = .settings; open("main") }
            .keyboardShortcut(",")
        if !s.onboardingDone { Button("Set up…") { open("onboarding") } }
        Button("Check for Updates…") { model.updater.check() }
            .disabled(!model.updater.canCheck)
        Divider()
        Button("Quit OpenBean") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ id: String) {
        openWindow(id: id)
        bringToFront(id)
    }

    private func deviceLine(_ d: DeviceController) -> String {
        switch d.state {
        case .idle, .searching: return String(localized: "Looking for your recorder…")
        case .connecting: return String(localized: "Connecting…")
        case .ready:
            let b = d.battery.map { String(localized: " · battery \($0)%") } ?? ""
            return String(localized: "Recorder connected") + b
        case let .failed(m): return String(localized: "Not connected: \(m)")
        }
    }
}
