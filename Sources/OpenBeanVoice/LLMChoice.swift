// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 「整理」（摘要、段摘要、日记）用哪种后端
public enum LLMChoice: String, Sendable, Equatable {
    /// 苹果端侧模型
    case onDevice
    /// OpenAI 兼容服务（云端、或局域网里自己的服务）
    case service
    /// 没有可用的选择（iOS 上端侧模型不可用、也没选服务）
    case none
}

/// 选择和外发的规则（App 的设置页、心力模式引导页都用这一份）
public enum LLMChoiceRule {
    /// Mac 版只有 OpenAI 兼容服务（行为和以前一样）。iOS：选过就用选的；没选过时端侧模型能用就用端侧，
    /// 不能用就是 none —— 绝不默认连任何云端。
    /// - stored：存着的选择（"onDevice" / "service" / 空 = 没选过）
    public static func resolve(stored: String, onDevice: OnDeviceAvailability, isMac: Bool) -> LLMChoice {
        if isMac { return .service }
        switch stored {
        case LLMChoice.onDevice.rawValue: return .onDevice
        case LLMChoice.service.rawValue: return .service
        default: return onDevice.isAvailable ? .onDevice : .none
        }
    }

    /// 这个选择会不会把转写文字发出设备：只有服务、而且地址不是本机或局域网才算（填不出地址的也按外发算，宁严勿宽）
    public static func sendsTextOffDevice(_ choice: LLMChoice, endpoint: String) -> Bool {
        guard choice == .service else { return false }
        guard let u = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), u.host != nil else { return true }
        return !LLMService.isLocal(u)
    }

    /// 从不外发（端侧、局域网、还没选）切到会外发的服务时要先确认一次；确认过之后不再问，在两个云端服务之间换也不问
    public static func needsCloudConfirmation(currentlySendsOut: Bool, toSendsOut: Bool, alreadyConfirmed: Bool) -> Bool {
        toSendsOut && !currentlySendsOut && !alreadyConfirmed
    }

    /// 能不能真的用这个后端发请求：会外发但用户还没确认过的，一律不用（界面出错也不会偷偷发出去）
    public static func usable(_ choice: LLMChoice, sendsOut: Bool, confirmed: Bool) -> Bool {
        switch choice {
        case .none: return false
        case .onDevice: return true
        case .service: return !sendsOut || confirmed
        }
    }

    /// 文字发往的服务名：预置服务用品牌名，自定义地址用主机名
    public static func serviceName(provider: String, endpoint: String) -> String? {
        if let p = CloudPreset.with(id: provider), !p.isCustom { return p.name }
        return URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host
    }
}
