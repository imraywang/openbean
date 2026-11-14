// SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI

/// 菜单栏图标：左键直接打开主窗口，右键（或按住 Control 点）出菜单。
/// 自己管 NSStatusItem，不用 SwiftUI 的 MenuBarExtra（它只会「点了出菜单」）。
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private var model: AppModel?
    private var actions: [() -> Void] = []

    func install(model: AppModel) {
        guard item == nil else { return }
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeading
            // 开发版在图标旁加个小 D、演示版加 DEMO，和正式版一眼分得清
            if let badge = Flavor.badge {
                b.attributedTitle = NSAttributedString(string: badge, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold)])
            }
            // 拿 SwiftUI 的 openWindow：一个看不见的视图，随按钮一直在
            let binder = NSHostingView(rootView: OpenWindowBinder(model: model))
            binder.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            binder.alphaValue = 0
            b.addSubview(binder)
        }
        refresh()
    }

    /// 图标跟着连接 / 同步 / 语音输入的状态变
    private func refresh() {
        guard let model, let b = item?.button else { return }
        let state = withObservationTracking {
            MenuIcon.state(device: model.device, dictation: model.dictation)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        b.image = BeanArt.menuIcons[state]
    }

    @objc private func clicked() {
        guard let model else { return }
        let e = NSApp.currentEvent
        let wantsMenu = e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true
        // 主窗口还打不开（openMain 没登记上）就出菜单，不让图标点了没反应
        if wantsMenu || model.openMain == nil {
            if model.openMain == nil { Log.write("菜单栏图标：openMain 还没登记，改出菜单") }
            showMenu()
        } else {
            Log.write("菜单栏图标：左键，打开主窗口")
            model.nav.goHome(model.settings.mode)
            model.openMain?()
        }
    }

    private func showMenu() {
        guard let model, let item, let statusButton = item.button else { return }
        let d = model.device, dict = model.dictation, s = model.settings
        actions = []
        let menu = NSMenu()
        menu.autoenablesItems = false
        func text(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func button(_ t: String, key: String = "", enabled: Bool = true, _ run: @escaping () -> Void) {
            let i = NSMenuItem(title: t, action: #selector(run(_:)), keyEquivalent: key)
            i.target = self
            i.tag = actions.count
            i.isEnabled = enabled
            actions.append(run)
            menu.addItem(i)
        }
        text(Self.deviceLine(model))
        if let e = dict.lastError { text("⚠︎ \(e)") }
        if model.models.state != .ready { text(String(localized: "Speech models not downloaded")) }
        menu.addItem(.separator())
        button(dict.phase == .idle ? String(localized: "Start voice typing") : String(localized: "Stop voice typing"), enabled: d.isReady) {
            Task { await dict.toggle() }
        }
        button(String(localized: "Sync recordings"), enabled: d.isReady && d.activity == .idle) { Task { await model.library.syncAll() } }
        menu.addItem(.separator())
        // 菜单只留马上要用的：打字 / 润色的开关在「语音输入」页，检查更新在「设置」页
        button(String(localized: "Open OpenBean"), key: "o") { model.nav.goHome(s.mode); model.openMain?() }
        button(String(localized: "Settings…"), key: ",") { model.nav.open(.general(.top)); model.openMain?() }
        if !s.onboardingDone { button(String(localized: "Set up…")) { model.openOnboarding?() } }
        menu.addItem(.separator())
        button(String(localized: "Quit OpenBean"), key: "q") { NSApp.terminate(nil) }
        // 临时挂上菜单再点一下：菜单出现在图标正下方、图标保持高亮；收起后摘掉，左键才不会又出菜单
        item.menu = menu
        statusButton.performClick(nil)
        item.menu = nil
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    static func deviceLine(_ model: AppModel) -> String {
        let d = model.device, heart = model.settings.mode.callsDeviceHeartBean
        switch d.state {
        case .idle, .searching:
            return heart ? String(localized: "Looking for your Heart bean…") : String(localized: "Looking for your recorder…")
        case .connecting: return String(localized: "Connecting…")
        case .ready:
            let b = d.battery.map { String(localized: " · battery \($0)%") } ?? ""
            return (heart ? String(localized: "Heart bean connected") : String(localized: "Recorder connected")) + b
        case let .failed(m): return String(localized: "Not connected: \(d.problem?.title ?? m)")
        }
    }
}
