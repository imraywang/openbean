// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import Observation
import Sparkle

/// 自动更新（Sparkle 2）。
/// 订阅地址 SUFeedURL、公钥 SUPublicEDKey、检查间隔都在 Info.plist（App/project.yml）；
/// appcast.xml 由 bin/release 签名 DMG 后写入仓库根目录。
@MainActor @Observable
final class Updater: NSObject {
    /// 开发版不建更新器：它不该被正式包覆盖
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var watch: AnyCancellable?

    /// 正在检查或下载时为 false，菜单项和按钮跟着变灰
    private(set) var canCheck = false

    /// 设置页的「自动检查更新」开关，直接读写 Sparkle 自己存的偏好
    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { withMutation(keyPath: \.automaticallyChecks) { controller?.updater.automaticallyChecksForUpdates = newValue } }
    }

    override init() {
        super.init()
        guard !Flavor.isDev else { return }
        // startingUpdater: true 即启动时开始按计划在后台检查
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller = c
        watch = c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    /// 手动检查（菜单栏「检查更新…」、设置页「立即检查」）
    func check() {
        // 菜单栏 App 不在前台，先激活，Sparkle 的「正在检查」窗口才不会被别的 App 盖住
        NSApp.activate()
        guard let controller else { return }
        controller.checkForUpdates(nil)
        Updater.bringWindowsToFront()
    }

    /// 本 App 是 accessory（LSUIElement），Sparkle 弹的窗口默认不抢前台；
    /// 等下一轮再激活，并把 Sparkle 的窗口强制排到最前（同 App.swift 的 bringToFront）
    static func bringWindowsToFront() {
        DispatchQueue.main.async {
            NSApp.activate()
            for w in NSApp.windows where w.isVisible {
                guard let wc = w.windowController else { continue }
                let name = String(describing: type(of: wc))
                guard name.hasPrefix("SU") || name.hasPrefix("SPU") else { continue }
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// 告诉 Sparkle 我们自己处理「后台 App 的温和提醒」：计划检查发现新版时把窗口带到前台
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let user = state.userInitiated
        MainActor.assumeIsolated {
            Log.write("发现新版本 \(version)（\(user ? "手动检查" : "计划检查")）")
            if handleShowingUpdate { Updater.bringWindowsToFront() }
        }
    }
}
