// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 「整理」用的大模型后端：摘要、段摘要、日记都只经过这个协议调模型。
///
/// 现有两种实现：
/// - `LLMService`：OpenAI 兼容接口（本机 llama-server / Ollama、局域网里的自建服务、云端服务）；
/// - `OnDeviceLLM`：苹果端侧模型（Foundation Models，iOS / macOS 26 起，要开着 Apple Intelligence）。
///
/// 调用方先 `open(timeout:)` 拿到一个通道，一次整理（一条录音、一段对话、一天的日记）的所有请求都走这个通道；
/// 每个请求都是独立的一问一答，不带上文。
public protocol LLMBackend: Sendable {
    /// 写进摘要、日记记录里的模型名
    var modelName: String { get }
    /// 转写文字会不会离开这台设备（云端服务：会；本机、局域网、端侧模型：不会）
    var sendsTextOffDevice: Bool { get }
    /// 单次请求默认等多久（本机模型读几千 token 可能要几分钟）
    var defaultTimeout: TimeInterval { get }
    /// 除了提示词，每次请求还要占掉的 token（端侧模型：结构化输出的格式说明会放进提示里）
    var promptOverhead: Int { get }
    /// 每次请求的输出上限（nil：用调用方的默认值）
    var preferredMaxOutput: Int? { get }
    /// Summarizer.estimateTokens 比这个模型的分词器多算几倍（≥ 1）。估算是为各种本机模型定的、偏保守
    /// （中文按一字 1.5 个）；分词器已知的后端可以放宽，分块就能放更多字。估少了有「超出上下文就缩小重来」兜底
    var tokenEstimateSlack: Double { get }
    /// 现在能不能用（连得上、密钥对、端侧模型已就绪）
    func check() async -> LLMService.Status
    /// 模型的上下文长度（token）；读不到返回 nil，调用方用保守的默认值
    func contextLength() async -> Int?
    /// 开一个通道（一次整理用一个）
    func open(timeout: TimeInterval) -> any LLMChannel
}

/// 一次整理里发请求用的通道
public protocol LLMChannel: Sendable {
    /// 发一次请求，返回模型的原始回复（JSON 文本，调用方自己解析）和诊断用的元数据
    func complete(_ request: LLMRequest) async throws -> LLMReply
}

/// 模型的一次回复：正文，加上回复不能用时写日志用的元数据（不含正文以外的内容）
public struct LLMReply: Sendable, Equatable {
    public var text: String
    /// OpenAI 兼容接口的 finish_reason（stop / length / content_filter…）；端侧模型没有
    public var finishReason: String?
    /// 推理内容（reasoning_content / reasoning）的字数；没有推理时 0
    public var reasoningChars: Int
    /// 用量里的输出 token 和其中推理的 token（服务给了才有）
    public var completionTokens: Int?
    public var reasoningTokens: Int?
    /// 这次请求的输出上限
    public var maxTokens: Int?

    public init(text: String, finishReason: String? = nil, reasoningChars: Int = 0, completionTokens: Int? = nil,
                reasoningTokens: Int? = nil, maxTokens: Int? = nil) {
        self.text = text
        self.finishReason = finishReason
        self.reasoningChars = reasoningChars
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.maxTokens = maxTokens
    }

    /// 输出被上限截断了（服务明说 length，或输出 token 顶到了上限）
    public var truncated: Bool {
        if finishReason == "length" { return true }
        if let c = completionTokens, let m = maxTokens, m > 0, c >= m { return true }
        return false
    }

    /// 推理占用了输出额度
    public var reasoned: Bool { reasoningChars > 0 || (reasoningTokens ?? 0) > 0 }
}

/// 一次请求
public struct LLMRequest: Sendable {
    public var system: String
    public var user: String
    public var maxTokens: Int
    public var temperature: Double
    /// 期望的回复结构。OpenAI 兼容服务不用它（提示词里已经写了 JSON 格式）；端侧模型用它做结构化生成
    public var shape: ReplyShape?

    public init(system: String, user: String, maxTokens: Int, temperature: Double = 0.2, shape: ReplyShape? = nil) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.shape = shape
    }
}

/// 回复的 JSON 结构（与具体框架无关的描述，端侧后端把它翻成 Foundation Models 的生成格式）
public indirect enum ReplyShape: Sendable, Hashable {
    case text(String? = nil)
    /// 只能是其中之一
    case choice([String], String? = nil)
    /// 列表，最多 max 项
    case list(ReplyShape, max: Int? = nil, String? = nil)
    /// 对象：字段按顺序生成
    case object(String, [Field])

    public struct Field: Sendable, Hashable {
        public var name: String
        public var shape: ReplyShape
        public init(_ name: String, _ shape: ReplyShape) {
            self.name = name
            self.shape = shape
        }
    }
}

/// 后端统一抛出的错误（OpenAI 兼容服务的网络错误照原样抛 URLError / LLMService.Failure）
public enum LLMBackendError: Error, Equatable, LocalizedError, CustomStringConvertible {
    /// 这次请求超出了模型的上下文窗口：调用方缩小分块再试
    case contextExceeded
    /// 模型的安全机制拦下了这段内容（端侧模型）
    case refused
    /// 模型不支持这种语言
    case unsupportedLanguage
    /// 模型现在用不了（原因见 OnDeviceAvailability 的 rawValue）
    case unavailable(String)
    /// 请求太频繁（端侧模型在后台时也会限流）
    case rateLimited
    /// 输出上限加到最大也写不完（推理太长、或这一块要写的太多）：调用方缩小分块再试
    case outputTruncated

    public var description: String {
        switch self {
        case .contextExceeded: return "the request is longer than the model's context window"
        case .refused: return "the model declined to process this text"
        case .unsupportedLanguage: return "the model does not support this language"
        case let .unavailable(why): return "the model is not available (\(why))"
        case .rateLimited: return "the model is busy; try again later"
        case .outputTruncated: return "the model's reply was cut off at the output limit"
        }
    }

    public var errorDescription: String? { description }

    /// 缩小分块再来能解决的
    public var shrinkable: Bool { self == .contextExceeded || self == .outputTruncated }
}

// MARK: OpenAI 兼容服务

extension LLMService: LLMBackend {
    public var modelName: String { model }
    public var sendsTextOffDevice: Bool { !isLocal }
    public var defaultTimeout: TimeInterval { isLocal ? 300 : 120 }
    public var promptOverhead: Int { 0 }
    public var preferredMaxOutput: Int? { nil }
    public var tokenEstimateSlack: Double { 1 }

    public func open(timeout: TimeInterval) -> any LLMChannel {
        Channel(service: self, session: makeSession(timeout: timeout))
    }

    struct Channel: LLMChannel {
        let service: LLMService
        let session: URLSession

        func complete(_ r: LLMRequest) async throws -> LLMReply {
            // 本机服务（llama-server 等）关掉思考模式，免得思考把输出额度用光；云端不认识这个参数，不发
            let extra: [String: Any] = service.isLocal ? ["chat_template_kwargs": ["enable_thinking": false]] : [:]
            return try await service.chatReply(system: r.system, user: r.user, maxTokens: r.maxTokens, temperature: r.temperature,
                                          extra: extra, session: session)
        }
    }
}
