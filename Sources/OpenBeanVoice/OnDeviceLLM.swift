// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 端侧模型现在能不能用。rawValue 写日志、也是 `LLMBackendError.unavailable` 里的原因
public enum OnDeviceAvailability: String, Sendable, Equatable, CaseIterable {
    case available
    /// 系统太旧（iOS / macOS 26 起才有 Foundation Models）或这个平台没有
    case unsupportedOS
    /// 机型不支持 Apple Intelligence（也包括所在地区没有开放 Apple Intelligence 的设备）
    case deviceNotEligible
    /// 机型支持，但设置里没开 Apple Intelligence
    case appleIntelligenceOff
    /// 开了，模型还在下载或准备中
    case modelNotReady

    public var isAvailable: Bool { self == .available }

    /// 用户自己能不能解决（打开 Apple Intelligence、等下载完）；不能的就别让用户反复去试
    public var userCanFix: Bool { self == .appleIntelligenceOff || self == .modelNotReady }
}

/// 苹果端侧模型（Foundation Models 的 `SystemLanguageModel`）。
///
/// 和云端相比的限制（按苹果文档「Managing the context window」）：
/// - 上下文窗口每个会话 4096 token（iOS 27 起用 `contextSize` 读实际值），提示词、格式说明和输出都算在里面；
///   中文大约一字一 token，所以每块转写只放一千多字，长录音靠分块 + 合并；
/// - 每个请求都开一个新会话，不带上文；
/// - 有 shape 时用结构化生成（DynamicGenerationSchema），模型只能按格式输出，不用再从文字里抠 JSON；
///   结构化生成总是走默认安全机制，被拦下时退回「宽松转写」模式生成文字，再用原来的 JSON 解析；
/// - 超出上下文时抛 `LLMBackendError.contextExceeded`，Summarizer 收到后缩小分块重来。
public struct OnDeviceLLM: LLMBackend {
    public init() {}

    /// 记录里的模型名
    public static let name = "apple-on-device"
    public var modelName: String { Self.name }
    public var sendsTextOffDevice: Bool { false }
    /// 端侧模型一块一千多字，一两分钟内写完；放宽到 3 分钟
    public var defaultTimeout: TimeInterval { 180 }
    /// 结构化生成的格式说明放进提示里（includeSchemaInPrompt），段摘要那种八个字段的大约 300 token
    public var promptOverhead: Int { 350 }
    /// 输出上限：中文摘要的 JSON 一般三四百 token；留够余量，又不挤占转写
    public var preferredMaxOutput: Int? { 700 }
    /// 苹果文档：中文大约一字一 token，英文三四个字符一 token；估算按一字 1.5、三字符一个算，放宽 1.3 倍仍有余量
    public var tokenEstimateSlack: Double { 1.3 }

    /// 苹果文档给的上下文窗口（读不到实际值时用）
    public static let documentedContextSize = 4096

    public static var availability: OnDeviceAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return FM.availability()
        }
        #endif
        return .unsupportedOS
    }

    public func check() async -> LLMService.Status {
        let a = Self.availability
        return a.isAvailable ? .ok : .unreachable(a.rawValue)
    }

    public func contextLength() async -> Int? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *), Self.availability.isAvailable {
            let n = SystemLanguageModel.default.contextSize
            return n > 0 ? n : Self.documentedContextSize
        }
        #endif
        return Self.documentedContextSize
    }

    public func open(timeout: TimeInterval) -> any LLMChannel { Channel(timeout: timeout) }

    /// 用模型自己的分词器数 token（iOS / macOS 26.4 起，模型可用时）；实测分块用
    public static func tokenCount(_ text: String) async -> Int? {
        #if canImport(FoundationModels)
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *), availability.isAvailable {
            return try? await SystemLanguageModel.default.tokenCount(for: text)
        }
        #endif
        return nil
    }

    struct Channel: LLMChannel {
        let timeout: TimeInterval

        func complete(_ r: LLMRequest) async throws -> LLMReply {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                let a = OnDeviceLLM.availability
                guard a.isAvailable else { throw LLMBackendError.unavailable(a.rawValue) }
                let text = try await withTimeout(timeout) { try await FM.run(r) }
                return LLMReply(text: text, maxTokens: r.maxTokens)
            }
            #endif
            throw LLMBackendError.unavailable(OnDeviceAvailability.unsupportedOS.rawValue)
        }
    }
}

/// 给一次请求设上限：端侧模型没有自己的超时
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await body() }
        g.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw URLError(.timedOut)
        }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum FM {
    static func availability() -> OnDeviceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .deviceNotEligible
        }
    }

    static func run(_ r: LLMRequest) async throws -> String {
        let options = GenerationOptions(temperature: r.temperature, maximumResponseTokens: r.maxTokens)
        do {
            if let shape = r.shape {
                do {
                    let schema = try GenerationSchema(root: dynamic(shape, path: "Reply"), dependencies: [])
                    let session = LanguageModelSession(model: SystemLanguageModel(useCase: .general), instructions: r.system)
                    let reply = try await session.respond(to: r.user, schema: schema, includeSchemaInPrompt: true, options: options)
                    return reply.content.jsonString
                } catch where classify(error) == .refused {
                    // 结构化生成只能用默认安全机制；被拦下时换宽松模式生成文字（提示词里本来就要求 JSON）
                }
            }
            let session = LanguageModelSession(model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
                                               instructions: r.system)
            return try await session.respond(to: r.user, options: options).content
        } catch {
            throw classify(error).map { $0 as Error } ?? error
        }
    }

    /// 把框架的错误归到 LLMBackendError（认不出的返回 nil，照原样抛）
    static func classify(_ e: Error) -> LLMBackendError? {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            if let e = e as? LanguageModelError {
                switch e {
                case .contextSizeExceeded: return .contextExceeded
                case .guardrailViolation, .refusal: return .refused
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                case .rateLimited: return .rateLimited
                default: return nil
                }
            }
            if e is SystemLanguageModel.Error { return .unavailable(OnDeviceAvailability.modelNotReady.rawValue) }
            if let e = e as? LanguageModelSession.Error, e == .concurrentRequests { return .rateLimited }
        }
        return legacy(e)
    }

    /// iOS / macOS 26 上抛的是 LanguageModelSession.GenerationError（27 起换成了 LanguageModelError）
    @available(iOS, deprecated: 27.0)
    @available(macOS, deprecated: 27.0)
    @available(visionOS, deprecated: 27.0)
    private static func legacy(_ e: Error) -> LLMBackendError? {
        guard let e = e as? LanguageModelSession.GenerationError else { return nil }
        switch e {
        case .exceededContextWindowSize: return .contextExceeded
        case .guardrailViolation, .refusal: return .refused
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .rateLimited, .concurrentRequests: return .rateLimited
        case .assetsUnavailable: return .unavailable(OnDeviceAvailability.modelNotReady.rawValue)
        default: return nil
        }
    }

    /// ReplyShape → DynamicGenerationSchema。path 让每个对象和枚举都有唯一的名字
    static func dynamic(_ s: ReplyShape, path: String) -> DynamicGenerationSchema {
        switch s {
        case .text:
            return DynamicGenerationSchema(type: String.self)
        case let .choice(options, description):
            return DynamicGenerationSchema(name: path, description: description, anyOf: options)
        case let .list(item, max, _):
            return DynamicGenerationSchema(arrayOf: dynamic(item, path: path + "Item"), minimumElements: 0, maximumElements: max)
        case let .object(name, fields):
            return DynamicGenerationSchema(name: path == "Reply" ? name : path, properties: fields.map { f in
                DynamicGenerationSchema.Property(name: f.name, description: description(f.shape),
                                                 schema: dynamic(f.shape, path: path + "_" + f.name))
            })
        }
    }

    static func description(_ s: ReplyShape) -> String? {
        switch s {
        case let .text(d): return d
        case let .choice(_, d): return d
        case let .list(_, _, d): return d
        case .object: return nil
        }
    }
}
#endif
