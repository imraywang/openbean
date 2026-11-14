// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanVoice

/// 「整理」（摘要、段摘要、日记）用哪个模型（规则在 OpenBeanVoice 的 LLMChoiceRule）。
///
/// Mac 版只有 OpenAI 兼容服务这一种（设置 → 润色里的地址、模型、密钥），行为和以前完全一样。
/// iOS 版可以选苹果端侧模型或云端服务：没选过时，端侧模型能用就用端侧，不能用就不整理（绝不默认连云端）。

/// 整理时文字去哪里：设置页、心力模式引导页都从这里读，说法保持一致
struct LLMDisclosure: Equatable, Sendable {
    let choice: LLMChoice
    /// 转写文字会不会离开这台设备
    let sendsTextOffDevice: Bool
    /// 文字发往的服务名（云端时：DeepSeek、OpenAI…；自定义地址时是主机名）
    let serviceName: String?
    /// 选了服务但还不能用（没选哪家、地址不对、外发还没确认）：什么都不会发出去
    var serviceReady = true

    /// 一句话说明（界面用）
    var sentence: String {
        switch choice {
        case .onDevice:
            return String(localized: "Summaries are written by Apple's on-device model. Nothing leaves this iPhone.")
        case .service where !serviceReady || serviceName == nil:
            return String(localized: "No service is set up yet, so nothing is sent anywhere.")
        case .service where sendsTextOffDevice:
            return String(localized: "Transcripts are sent to \(serviceName ?? "") to write summaries. Audio never leaves this iPhone.")
        case .service:
            return String(localized: "Transcripts are sent to \(serviceName ?? "") on your local network. Audio never leaves this iPhone.")
        case .none:
            return String(localized: "No model is set up for summaries. Choose one in Settings.")
        }
    }
}

@MainActor
extension Settings {
    var llmChoice: LLMChoice {
        #if os(macOS)
        return .service
        #else
        return LLMChoiceRule.resolve(stored: llmChoiceStored, onDevice: OnDeviceLLM.availability, isMac: false)
        #endif
    }

    /// 现在用的 OpenAI 兼容服务（地址填得不对时没有）
    var llmService: LLMService? {
        let t = polishEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t), u.scheme != nil, u.host != nil else { return nil }
        return LLMService(endpoint: u, apiKey: polishAPIKey, model: polishModel)
    }

    /// 整理用的后端；没有可用的返回 nil
    var llmBackend: (any LLMBackend)? {
        switch llmChoice {
        case .onDevice: return OnDeviceLLM()
        case .service:
            #if os(macOS)
            // Mac 和以前一样：地址能解析就用（URL(string:) 能解析的都算）
            return URL(string: polishEndpoint).map { LLMService(endpoint: $0, apiKey: polishAPIKey, model: polishModel) }
            #else
            let out = LLMChoiceRule.sendsTextOffDevice(.service, endpoint: polishEndpoint)
            return LLMChoiceRule.usable(.service, sendsOut: out, confirmed: cloudConfirmed) ? llmService : nil
            #endif
        case .none: return nil
        }
    }

    var llmDisclosure: LLMDisclosure {
        let choice = llmChoice
        switch choice {
        case .onDevice, .none:
            return LLMDisclosure(choice: choice, sendsTextOffDevice: false, serviceName: nil)
        case .service:
            return LLMDisclosure(choice: choice, sendsTextOffDevice: LLMChoiceRule.sendsTextOffDevice(choice, endpoint: polishEndpoint),
                                 serviceName: LLMChoiceRule.serviceName(provider: cloudProvider, endpoint: polishEndpoint),
                                 serviceReady: llmBackend != nil)
        }
    }

    #if os(iOS)
    /// 选一个预置服务：把当前服务的密钥、模型名（和自定义地址）各自存好，换成新服务的
    func selectProvider(_ id: String) {
        guard let p = CloudPreset.with(id: id) else { return }
        let old = cloudProvider
        if !old.isEmpty {
            Keychain.set(polishAPIKey, for: Self.keyAccount(old))
            Flavor.defaults.set(polishModel, forKey: "cloudModel." + old)
            if CloudPreset.with(id: old)?.isCustom == true { Flavor.defaults.set(polishEndpoint, forKey: "cloudEndpoint.custom") }
        }
        cloudProvider = id
        polishEndpoint = p.isCustom ? (Flavor.defaults.string(forKey: "cloudEndpoint.custom") ?? "") : p.endpoint
        polishModel = Flavor.defaults.string(forKey: "cloudModel." + id) ?? p.models.first ?? ""
        polishAPIKey = Keychain.get(Self.keyAccount(id)) ?? ""
    }

    /// 每个服务的密钥各存一份（换服务再换回来不用重填）
    static func keyAccount(_ provider: String) -> String { "llmKey." + provider }
    #endif
}
