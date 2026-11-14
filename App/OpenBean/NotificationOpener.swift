// SPDX-License-Identifier: Apache-2.0

import Foundation
import UserNotifications

/// 点通知：打开主窗口的心力模式页
final class NotificationOpener: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationOpener()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            let m = AppModel.shared
            m.nav.goHome(m.settings.mode)
            m.openMain?()
        }
    }

    /// App 在前台时也显示横幅（菜单栏 App 常常算在前台）
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }
}
