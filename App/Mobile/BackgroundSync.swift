// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit

/// 后台同步的位置。这一版只做了一件事：切到后台时如果正在同步或转写，向系统要一段后台时间（约 30 秒）把手上这条做完，
/// 并把前后台切换写进日志。完整的后台自动同步还没做，打算这样做：
///
/// 1. 连接常驻：Info.plist 已声明 bluetooth-central。还要给 CBCentralManager 加 CBCentralManagerOptionRestoreIdentifierKey
///    （状态恢复：App 被系统杀掉后，设备事件来了系统会在后台把 App 拉起来），并实现 willRestoreState。
/// 2. 重连不设超时：Link.connect 现在 8 / 25 秒超时就取消。iOS 上对已知设备发一个不超时的 connect，
///    录音豆进入范围时系统自己连上（后台也行），不需要扫描；后台扫描必须指定服务 UUID，withServices: nil 在后台收不到任何广播。
/// 3. 触发：录音豆放回盒子（01/04 充电事件）→ AutoSync 已有的逻辑开始蓝牙下载。后台里只要蓝牙数据一直在来，
///    App 就一直有执行时间；下载期间不要做重活。
/// 4. 转写、切段、写日记是重活：不在蓝牙回调里做，下完后排一个 BGProcessingTask（requiresExternalPower 可选），
///    或等 App 回到前台再做。日记要联网的，BGProcessingTask 设 requiresNetworkConnectivity。
/// 5. 结果用本地通知告诉用户（共用的 Notifier 已经能发，iOS 上还没请求通知权限）。
@MainActor
final class BackgroundSync {
    private var task: UIBackgroundTaskIdentifier = .invalid

    func phaseChanged(_ phase: ScenePhase, model: MobileModel) {
        switch phase {
        case .background:
            let busy = model.library.syncRunning || !model.library.transcribing.isEmpty
            Log.write("进入后台\(busy ? "（正在同步或转写，申请后台时间）" : "")")
            guard busy, task == .invalid else { return }
            task = UIApplication.shared.beginBackgroundTask(withName: "OpenBean sync") { [weak self] in
                Log.write("后台时间用完，同步或转写会在回到前台后继续")
                self?.end()
            }
            Task { [weak self] in
                while model.library.syncRunning || !model.library.transcribing.isEmpty {
                    try? await Task.sleep(for: .seconds(1))
                    if self?.task == .invalid { return }
                }
                self?.end()
            }
        case .active:
            Log.write("回到前台")
            end()
        default:
            break
        }
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
