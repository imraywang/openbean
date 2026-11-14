// SPDX-License-Identifier: Apache-2.0

// 演示版的状态切换、链接和启动小窗口（只有 Mac）；假数据本身在 App/Shared/Demo.swift，iOS 版也用
#if DEMO || DEBUG
import AppKit
import Observation
import OpenBeanKit
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

// MARK: - 状态切换和链接

@MainActor
final class DemoController {
    static let shared = DemoController()
    private var model: AppModel?
    var openWindow: OpenWindowAction?
    private var menuObserver: NSObjectProtocol?

    func start(_ m: AppModel) {
        model = m
        m.models.demoSet(DemoState.isEmpty ? .missing : .ready)
        m.hud.start()
        apply(state: DemoState.isEmpty ? "searching" : "connected")
    }

    func handle(_ path: String, query: String?) {
        guard let m = model else { return }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.9
        switch parts[0] {
        case "ping": delay = 0.2
        case "state": apply(state: arg)
        case "hud": hud(arg)
        case "page":
            if let s = MainSection(link: arg) { m.nav.section = s }
            openMain()
        case "today":
            // today/<天数>：「今天」页翻到前几天（today/0 或 today 回到今天；today/-7 是一个没有录音的日子）
            let b = DayBoundary(startHour: m.settings.dayStartHour)
            let n = Int(arg) ?? 0
            m.nav.day = n == 0 ? nil : b.day(b.day(of: Date()), offsetBy: n)
            m.nav.section = .heart
            m.nav.showingSettings.remove(.heart)
            openMain()
        case "settings":
            // 老的设置窗口分页名照样认（见 SettingsRoute）；设置现在在主窗口里
            m.nav.open(SettingsRoute(link: arg) ?? .general(.top))
            openMain()
        case "select":
            DemoState.shared.query = ""
            m.library.filter = .all
            m.library.selection = pick(arg)
            m.nav.section = .library
            openMain()
        case "search":
            m.library.filter = .all
            DemoState.shared.query = parts.dropFirst().joined(separator: "/")
            m.library.selection = m.library.visible.first { m.library.matches($0, query: DemoState.shared.query) }?.id
            m.nav.section = .library
        case "filter":
            DemoState.shared.query = ""
            if let f = LibraryStore.Filter(rawValue: arg) { m.library.filter = f }
            m.library.selection = m.library.visible.first?.id
            m.nav.section = .library
        case "play":
            // play/<秒>：详情页假装播放到这里（看跟随高亮）；play/off 停
            DemoState.shared.playAt = Double(arg)
            m.library.selection = m.library.selection // 重新出现时读
        case "todo":
            // todo/check：把选中录音的第一条待办勾上；todo/clear：全部取消
            if let id = m.library.selection, let items = m.library.notes.summary(id)?.actionItems {
                for (i, t) in items.enumerated() { m.library.notes.setDone(id, t, arg == "check" && i == 0) }
            }
        case "onboarding":
            DemoState.shared.onboardingStep = Int(arg) ?? 0
            openWindow?(id: "onboarding")
            bringToFront("onboarding")
        case "heart-intro":
            // heart-intro/<0–3>；heart-intro/diary = 第一步，以前开着每日日记的人看到的版本
            DemoState.shared.heartIntroDiary = arg == "diary"
            DemoState.shared.heartIntroStep = Int(arg) ?? 0
            openWindow?(id: "heart-intro")
            bringToFront("heart-intro")
        case "close":
            window(arg)?.close()
            delay = 0.4
        case "window":
            if parts.count > 2 { resize(arg, parts[2]) }
            delay = 0.6
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
        case "sync":
            // sync/<名字>：心力模式页顶上的四步条（见 DemoSyncRun.names；sync/none 不显示）
            DemoSyncRun.apply(arg, to: m.library.progress)
            m.nav.section = .heart
            m.nav.day = nil
            m.nav.showingSettings.remove(.heart)
            openMain()
        case "trusted": DemoState.shared.trusted = arg != "no"
        case "models":
            m.models.demoSet(arg == "missing" ? .missing : arg == "downloading" ? .downloading(0.42) : .ready)
        case "menu":
            openStatusMenu()
            delay = 0.1
        case "quit":
            NSApp.terminate(nil)
            return
        default:
            Log.write("演示：不认识的命令 \(path)")
        }
        guard let seq = query?.split(separator: "&").first(where: { $0.hasPrefix("seq=") })?.dropFirst(4) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.ack(String(seq)) }
    }

    private func openMain() {
        if let openWindow { openWindow(id: "main") }
        bringToFront("main")
    }

    private func pick(_ what: String) -> UInt32? {
        model.flatMap { Self.pick(what, in: $0.library) }
    }

    /// 选一条有代表性的录音：summary、untranscribed、ondevice、long、none 或录音 id
    static func pick(_ what: String, in lib: LibraryStore) -> UInt32? {
        let all = lib.recordings.filter { !$0.isDictation }
        switch what {
        case "summary": return all.first { lib.notes.summary($0.id) != nil }?.id
        case "untranscribed": return all.first { $0.downloaded && !$0.transcribed }?.id
        case "ondevice": return all.first { !$0.downloaded }?.id
        case "long": return all.max { $0.duration < $1.duration }?.id
        // 切成多段对话的录音（段最多的那条）
        case "segmented": return all.max { lib.conversations.conversations($0.id).count < lib.conversations.conversations($1.id).count }?.id
        case "none": return nil
        default: return UInt32(what)
        }
    }

    func apply(state name: String) {
        guard let m = model else { return }
        Self.apply(state: name, to: m)
    }

    /// 把一种设备状态摆到某个 AppModel 上（演示版的链接和 Xcode 预览共用）
    static func apply(state name: String, to m: AppModel) {
        let d = m.device
        m.library.demoSet(sync: .idle)
        m.dictation.demoSet(phase: .idle)
        switch name {
        case "searching": d.demoApply(state: .searching, info: nil, activity: .idle)
        case "connecting": d.demoApply(state: .connecting, info: nil, activity: .idle)
        case "failed":
            d.demoApply(state: .failed("\(LinkError.missing(String(localized: "recorder. Take it out of the case or press the case button to wake it.")))"),
                        info: nil, activity: .idle, problem: .notFound)
        case "bluetooth-off":
            d.demoApply(state: .failed("\(LinkError.bluetooth("蓝牙已关闭"))"), info: nil, activity: .idle, problem: .bluetoothOff)
        case "no-permission":
            d.demoApply(state: .failed("\(LinkError.bluetooth("没有蓝牙权限"))"), info: nil, activity: .idle, problem: .noPermission)
        case "lost":
            d.demoApply(state: .failed("\(LinkError.disconnected)"), info: nil, activity: .idle, problem: .lost)
        case "syncing":
            d.demoApply(state: .ready, info: DemoData.info(), activity: .syncing)
            let pending = m.library.pendingDownloads()
            let transcribing = m.library.recordings.first { $0.downloaded && !$0.transcribed && !$0.isDictation }?.id
            m.library.demoSet(sync: .downloading(id: pending.first?.id ?? 0, done: 1, total: max(pending.count, 2), fraction: 0.38, kbps: 22.4),
                              secondsLeft: 1_730, transcribing: transcribing.map { [$0: 0.42] } ?? [:])
        case "dictating":
            d.demoApply(state: .ready, info: DemoData.info(), activity: .dictating)
            m.dictation.demoSet(phase: .listening, level: 0.55, since: Date().addingTimeInterval(-14))
        case "sync-failed":
            d.demoApply(state: .ready, info: DemoData.info(), activity: .idle)
            m.library.demoSet(sync: .failed(String(localized: "The recorder stopped answering.")))
        case "recording": d.demoApply(state: .ready, info: DemoData.info(recording: true), activity: .idle)
        case "low-battery": d.demoApply(state: .ready, info: DemoData.info(battery: 10, caseBattery: 20), activity: .idle)
        case "charging": d.demoApply(state: .ready, info: DemoData.info(battery: 60, charging: true, caseCharging: true), activity: .idle)
        default: d.demoApply(state: .ready, info: DemoData.info(), activity: .idle)
        }
    }

    private func hud(_ mode: String) {
        guard let m = model else { return }
        let h = m.hud
        switch mode {
        case "starting": h.demoShow(.starting)
        case "listening":
            m.dictation.demoSet(phase: m.dictation.phase, level: 0.6, since: Date().addingTimeInterval(-23))
            h.demoShow(.listening)
        case "polishing":
            m.dictation.demoSet(phase: m.dictation.phase, polishing: 2)
            h.demoShow(.finishing)
        case "wrapping":
            m.dictation.demoSet(phase: m.dictation.phase)
            h.demoShow(.finishing)
        case "reconnecting": h.demoShow(.reconnecting)
        case "typed": h.demoShow(.done(count: 86, clipboard: false))
        case "copied": h.demoShow(.done(count: 86, clipboard: true))
        case "nothing": h.demoShow(.done(count: 0, clipboard: false))
        case "error": h.demoShow(.error(String(localized: "The recorder is recording. Stop it first.")))
        default: h.demoShow(.hidden)
        }
    }

    // MARK: 窗口

    func window(_ role: String) -> NSWindow? {
        switch role {
        case "hud": return model?.hud.demoPanel
        case "status": return NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }
        default:
            return NSApp.windows.first { w in
                guard let id = w.identifier?.rawValue else { return false }
                return id == role || id.hasPrefix("\(role)-")
            }
        }
    }

    /// 内容区设成 宽x高，放在屏幕左上角固定位置（截图前后一致）
    private func resize(_ role: String, _ size: String) {
        let wh = size.split(separator: "x").compactMap { Double($0) }
        guard wh.count == 2, let w = window(role), let screen = w.screen ?? NSScreen.main else { return }
        let frame = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: wh[0], height: wh[1]))
        let vf = screen.visibleFrame
        w.setFrame(NSRect(x: vf.minX + 40, y: vf.maxY - 30 - frame.height, width: frame.width, height: frame.height), display: true)
    }

    /// 点开菜单栏图标的菜单。菜单跟踪会占住主线程，所以 6 秒后自己关掉
    private func openStatusMenu() {
        menuObserver.map(NotificationCenter.default.removeObserver)
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            let t = Timer(timeInterval: 6, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(t, forMode: .common)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let w = self.window("status"), let button = Self.find(NSStatusBarButton.self, in: w.contentView) else {
                Log.write("演示：没找到菜单栏按钮"); return
            }
            button.performClick(nil)
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for s in view.subviews { if let v = find(type, in: s) { return v } }
        return nil
    }

    /// 告诉截图脚本：第 seq 条命令处理完了，以及各窗口的窗口号（= CGWindowID）
    private func ack(_ seq: String) {
        var windows: [String: Int] = [:]
        for role in ["main", "onboarding", "heart-intro", "hud", "demo"] {
            if let w = window(role), w.isVisible { windows[role] = w.windowNumber }
        }
        var body: [String: Any] = ["seq": seq, "pid": Int(ProcessInfo.processInfo.processIdentifier), "windows": windows]
        // 菜单栏图标不是能单独截的窗口：给出它在屏幕上的位置（左上角为原点，screencapture -R 用）
        if let w = window("status"), let top = NSScreen.screens.first?.frame.maxY {
            let f = w.frame
            body["statusRect"] = "\(Int(f.minX) - 6),\(Int(top - f.maxY)),\(Int(f.width) + 12),\(Int(f.height))"
        }
        if let d = try? JSONSerialization.data(withJSONObject: body) {
            try? d.write(to: AppPaths.support.appendingPathComponent("demo-ack.json"), options: .atomic)
        }
    }
}

// MARK: - 启动时的小窗口

enum DemoScenes {
    /// 启动时打开、拿到 openWindow 之后就藏起来
    @SceneBuilder static func window(model: AppModel) -> some Scene {
        Window(Text(verbatim: "OpenBean Demo"), id: "demo") {
            DemoBinder(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
    }
}

private struct DemoBinder: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(verbatim: "OpenBean Demo — openbean-demo://demo/…")
            .font(.caption).foregroundStyle(.secondary)
            .padding(12)
            .onAppear {
                DemoController.shared.openWindow = openWindow
                model.openMain = { openWindow(id: "main"); bringToFront("main") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { DemoController.shared.window("demo")?.orderOut(nil) }
            }
    }
}
#endif
