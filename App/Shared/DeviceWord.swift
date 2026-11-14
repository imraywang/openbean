// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - 设备的叫法

/// 心力模式开着时界面上把设备叫「心力豆」（Heart bean），关着叫「录音豆」（recorder）。
/// 中文目录里是两个键：英文原文分别写 Heart bean 和 recorder。带插值的句子在调用处成对写 String(localized:)
enum DeviceWord {
    static func title(heart: Bool) -> LocalizedStringKey { pick(heart, "Heart bean", "Recorder") }
    static func showDetails(heart: Bool) -> LocalizedStringKey { pick(heart, "Show Heart bean details", "Show recorder details") }
    /// 两种叫法里挑一个（参数写字面量，两个都进字符串目录）
    static func pick(_ heart: Bool, _ heartKey: LocalizedStringKey, _ normalKey: LocalizedStringKey) -> LocalizedStringKey {
        heart ? heartKey : normalKey
    }
}
