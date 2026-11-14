// SPDX-License-Identifier: Apache-2.0

import AppKit
import OpenBeanKit
import OpenBeanLibrary
import SwiftUI
import UserNotifications

@MainActor
final class AppModel {
    static let shared = AppModel()
    #if DEMO || DEBUG
    /// 演示版、Xcode 预览：在建任何存储之前先准备假数据和设置（属性按声明顺序初始化）
    private let demoPrepared: Void = Flavor.isFake ? DemoData.prepare() : ()
    #endif
    let settings = Settings()
    let device = DeviceController()
    let models = ModelStore()
    let log = DictationLog()
    let nav = Navigator()
    lazy var dictation = Dictation(device: device, settings: settings)
    lazy var library = LibraryStore(device: device, settings: settings)
    lazy var hud = HUDController(dictation: dictation)
    lazy var autoSync = AutoSync(device: device, library: library, settings: settings)
    /// 词表变了就重新应用到已有的转写
    lazy var glossaryBackfill = GlossaryBackfill(library: library)
    /// 自动更新：start() 里创建，第二份 App 退出前不会碰到它
    lazy var updater = Updater()

    func start() {
        #if DEMO
        DemoController.shared.start(self)
        return
        #endif
        nav.goHome(settings.mode)
        models.check()
        models.onReady = { [weak self] in self?.dictation.loadRecognizer() }
        device.onEvent = { [weak self] e in
            self?.dictation.handle(e)
            self?.autoSync.handle(e)
        }
        library.onListRefreshed = { [weak self] in self?.autoSync.listRefreshed() }
        device.onConnected = { [weak self] in Task { await self?.library.refreshDeviceList() } }
        dictation.onStarted = { [weak self] id in self?.library.markDictation(id) }
        // 先删这次语音输入的设备文件（占着连接），再让暂停的同步继续
        dictation.onFinished = { [weak self] evidence in
            Task { @MainActor in
                if let evidence { await self?.library.deleteDictationFile(evidence) }
                self?.library.resumeIfNeeded()
            }
        }
        dictation.cleanupRunning = { [weak self] in self?.library.deletingFromRecorder != nil }
        dictation.syncBlocksDictation = { [weak self] in self?.library.dictationBlockMessage() }
        dictation.onEntry = { [weak self] in self?.log.add($0) }
        Hotkey.shared.onPress = { [weak self] in
            guard let self else { return }
            guard self.device.isReady else { Log.write("按了快捷键，但录音豆没连上"); return }
            Log.write("快捷键 \(self.settings.hotkeyLabel)")
            Task { await self.dictation.toggle() }
        }
        Hotkey.shared.register(settings.hotkeyKey)
        settings.onHotkeyChange = { [weak self] in
            guard let self else { return }
            Hotkey.shared.register(self.settings.hotkeyKey)
        }
        // 心力模式同步结束的通知：点了打开心力模式页
        if Notifier.enabled { UNUserNotificationCenter.current().delegate = NotificationOpener.shared }
        device.start()
        hud.start()
        glossaryBackfill.start()
        // 已转写的录音补算对话段（后台，缺了或过时了才算）
        library.conversations.backfill()
        // 开着每日日记：今天和昨天的日记补一遍（等补算完；没变就不调用大模型）
        library.notes.diary.catchUp()
        // 心力模式录音的本机音频保留期：启动时和之后每小时看一遍（同步、转写完也会看）
        Task { [weak self] in
            while !Task.isCancelled {
                self?.library.applyAudioRetention()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        _ = updater
    }

    /// 主窗口打开回调（菜单栏菜单第一次渲染时登记，用于 openbean://open、settings）
    var openMain: (() -> Void)?
    /// 打开首次使用向导（菜单里的「设置向导…」）
    var openOnboarding: (() -> Void)?

    /// 打开主窗口里的某处设置（设置不再是独立窗口：各模块的设置在各自的页面里，通用的在侧栏底部的「设置」页）
    func openSettings(_ route: SettingsRoute = .general(.top)) {
        nav.open(route)
        openMain?()
    }

    func handle(_ url: URL) {
        guard let scheme = url.scheme, Flavor.schemes.contains(scheme) else { return }
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
            // 「打开 OpenBean」回到首页（心力模式是今天，普通模式是录音库）；⌘1–4 和 open/<id> 这类链接才去指定的页面
            nav.goHome(settings.mode)
            openMain?()
        case "settings":
            openSettings()
        case let p where p.hasPrefix("settings/"):
            // openbean://settings/heart|voice|polish|recorder|library|agent|about（老的设置窗口分页名换到新位置，见 SettingsRoute）
            openSettings(SettingsRoute(link: String(p.dropFirst(9))) ?? .general(.top))
        case let p where p.hasPrefix("summarize/"):
            // openbean://summarize/<录音 id>：摘要（或重新摘要）一条已转写的录音
            if let id = UInt32(p.dropFirst(10)), let r = library.recordings.first(where: { $0.id == id }),
               library.notes.canSummarize(r) { library.notes.summarize(id) }
        case "type-test":
            // openbean://type-test：3 秒后往当前输入框打一行字，用来查「文字打不进去」
            Log.write("打字测试：辅助功能=\(Typist.trusted) 可发按键=\(CGPreflightPostEventAccess())")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                Log.write("打字测试：前台是 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                let f = Typist.focus()
                Log.write("打字测试：焦点 \(f.kind)（\(f.role)）")
                if f.kind != .notEditable { Typist.type("OpenBean 打字测试 OK。") }
            }
        case "glossary/apply":
            // 手动把词表重新应用到录音库的所有转写（平时词表一变就会自动做）
            glossaryBackfill.check(force: true)
        case "notes/backfill":
            library.notes.backfillNotes()
        case let p where p.hasPrefix("open/"):
            if let id = UInt32(p.dropFirst(5)) { nav.show(recording: id, in: library) }
            openMain?()
        #if DEMO
        case let p where p.hasPrefix("demo/"):
            DemoController.shared.handle(String(p.dropFirst(5)), query: url.query)
        #endif
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
        // 菜单栏图标不用 MenuBarExtra（它只会「点了出菜单」）：见 StatusItemController，左键开主窗口、右键出菜单

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

        // 心力模式介绍：已经用过 OpenBean 的人升级后第一次启动时出现；新装的人在首次使用向导之后出现（OnboardingView）；
        // 心力模式页关着时也可以从那里打开
        Window("Heart mode", id: "heart-intro") {
            HeartIntroView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.settings.onboardingDone && model.settings.heartIntroPending ? .presented : .suppressed)

        #if DEMO
        // 演示版：启动时开一个小窗口拿到 openWindow（菜单栏菜单没人点开就拿不到），也用来把菜单内容画成普通窗口
        DemoScenes.window(model: model)
        #endif
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    /// 这份真的跑起来了（不是发现已有一份而自行退出的那份）
    private var started = false

    func applicationDidFinishLaunching(_ n: Notification) {
        #if DEBUG
        // Xcode 预览也会把整个 App 跑起来：不连录音豆、不注册快捷键、不检查更新，也不去碰正在运行的那份
        if Flavor.isPreview { return }
        #endif
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
        MainActor.assumeIsolated {
            AppModel.shared.start()
            StatusItemController.shared.install(model: AppModel.shared)
        }
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

/// 登记「打开主窗口」的方法（菜单栏图标、链接 openbean://open、settings 用）。
/// 放在菜单栏图标按钮里的一个看不见的 SwiftUI 视图里：App 一启动就在，不用等哪个窗口或菜单先出现
struct OpenWindowBinder: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 1, height: 1).onAppear {
            model.openMain = { openWindow(id: "main"); bringToFront("main") }
            model.openOnboarding = { openWindow(id: "onboarding"); bringToFront("onboarding") }
            Log.write("菜单栏图标：已登记打开主窗口的方法")
        }
    }
}

// MARK: - 菜单栏

struct MenuIcon: View {
    let device: DeviceController
    let dictation: Dictation
    var body: some View {
        // 开发版在图标旁加个小 D、演示版加 DEMO，和正式版一眼分得清
        if let badge = Flavor.badge {
            HStack(spacing: 1) {
                Image(nsImage: BeanArt.menuIcons[state]!)
                Text(verbatim: badge).font(.system(size: 9, weight: .bold))
            }
        } else {
            Image(nsImage: BeanArt.menuIcons[state]!)
        }
    }

    private var state: BeanArt.State { Self.state(device: device, dictation: dictation) }

    static func state(device: DeviceController, dictation: Dictation) -> BeanArt.State {
        if dictation.phase == .listening || dictation.phase == .starting { return .listening }
        guard device.state == .ready else { return .disconnected }
        return device.activity == .syncing ? .syncing : .connected
    }
}
