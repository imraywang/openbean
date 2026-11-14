// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - 设置在主窗口里的位置
//
// 0.5 以前设置是一个独立窗口，分 heart / voice / polish / library / agent / about 几页（models 是 about 更早的名字）。
// 现在各模块的设置放在各自的页面里，侧栏底部的「设置」页只留通用的几组。
// openbean://settings/<名字> 的老链接照样能用：这里把名字换成新的位置。纯值，方便测试。

public enum SettingsRoute: Sendable, Hashable {
    /// 心力模式页的设置
    case heart
    /// 语音输入页的设置；cleanUp = 翻到「润色」那一组
    case voiceTyping(cleanUp: Bool)
    /// 录音豆页里的同步、清理选项
    case recorder
    /// 侧栏底部的「设置」页，翻到哪一组
    case general(GeneralSettingsGroup)

    /// 链接里的名字（openbean://settings/<名字>）；空 = 通用设置页的开头。不认识的名字 = nil
    public init?(link: String) {
        switch link.lowercased() {
        case "", "general": self = .general(.top)
        case "heart": self = .heart
        case "voice", "dictation", "voice-typing": self = .voiceTyping(cleanUp: false)
        case "polish", "clean-up", "cleanup": self = .voiceTyping(cleanUp: true)
        case "recorder", "sync": self = .recorder
        case "library", "notes": self = .general(.library)
        case "agent", "agents", "mcp": self = .general(.agents)
        case "about", "models", "updates": self = .general(.about)
        default: return nil
        }
    }
}

/// 通用设置页里的几组（从上到下）
public enum GeneralSettingsGroup: String, Sendable, Hashable, CaseIterable {
    case top, library, agents, about
}
