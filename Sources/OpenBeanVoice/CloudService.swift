// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(Network)
import Network
#endif

/// 预置的 OpenAI 兼容服务：选服务后只填密钥。地址和推荐模型核对自各家官方文档（2026-11-14）：
/// - DeepSeek：api-docs.deepseek.com（首页示例、/models 接口）——根地址 https://api.deepseek.com，模型 deepseek-flash、deepseek-v4-pro
/// - OpenAI：developers.openai.com/api/docs/models——根地址 https://api.openai.com/v1，最便宜的文字模型 gpt-6-luna
/// - OpenRouter：openrouter.ai/docs/api-reference/overview 和 openrouter.ai/api/v1/models——根地址
///   https://openrouter.ai/api/v1，模型名带厂商前缀，默认 deepseek/deepseek-v4.1-flash（中文好、便宜）
/// 模型名会随厂商更新而变：设置里模型名可以改，「测试连接」会对照服务的模型列表提示。
public struct CloudPreset: Sendable, Hashable, Identifiable {
    public let id: String
    /// 服务名（不翻译，是品牌名；自定义的显示名由 App 自己写）
    public let name: String
    public let endpoint: String
    /// 推荐的模型，第一个是默认
    public let models: [String]
    /// 去哪里申请密钥
    public let keyPage: String?
    /// 请求方言（关掉整理用不着的思考/推理）
    public var dialect: LLMService.Dialect = .standard

    public static let deepseek = CloudPreset(id: "deepseek", name: "DeepSeek", endpoint: "https://api.deepseek.com",
                                             models: ["deepseek-flash", "deepseek-v4-pro"],
                                             keyPage: "https://platform.deepseek.com/api_keys", dialect: .deepseek)
    public static let openai = CloudPreset(id: "openai", name: "OpenAI", endpoint: "https://api.openai.com/v1",
                                           models: ["gpt-6-luna", "gpt-6.1-terra"],
                                           keyPage: "https://platform.openai.com/api-keys", dialect: .openai)
    public static let openrouter = CloudPreset(id: "openrouter", name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1",
                                               models: ["deepseek/deepseek-v4.1-flash", "qwen/qwen3.8-flash"],
                                               keyPage: "https://openrouter.ai/settings/keys")
    /// 自定义地址：别的云端服务，或局域网里自己的服务（家里电脑上的 llama-server、Ollama）
    public static let custom = CloudPreset(id: "custom", name: "Custom", endpoint: "", models: [], keyPage: nil)

    public static let all: [CloudPreset] = [.deepseek, .openai, .openrouter, .custom]

    public static func with(id: String) -> CloudPreset? { all.first { $0.id == id } }

    public var isCustom: Bool { id == Self.custom.id }
}

/// 「测试连接」发现的问题。App 把它翻成给人看的话
public enum LLMConnectionProblem: Sendable, Equatable {
    /// 地址填得不对（不是 http(s) 地址）
    case invalidAddress
    /// 地址指向手机自己（127.0.0.1、localhost）：手机上没有模型服务
    case pointsToThisDevice
    /// http:// 的公网地址：系统只允许加密连接
    case needsHTTPS
    /// 密钥不对（或没填）
    case badKey
    /// 余额、额度不够
    case noCredit
    /// 请求太频繁
    case rateLimited
    /// 服务不认这个模型名；suggestions：服务列出的、名字相近的模型
    case modelNotFound(suggestions: [String])
    /// 手机没联网
    case offline
    /// 局域网地址连不上：可能没允许 OpenBean 访问本地网络，或电脑没开、不在同一个 Wi‑Fi
    case localNetwork(denied: Bool)
    /// 找不到这个域名（拼错了、或网络屏蔽）
    case cannotFindHost
    /// 连不上（服务没开、端口不对）
    case cannotConnect
    /// 等太久没回应
    case timedOut
    /// 加密连接失败（证书问题、被代理拦截）
    case secureConnection
    /// 服务出错（5xx）
    case server(Int)
    /// 回了别的状态码（多半地址不是 OpenAI 兼容接口的根地址）
    case unexpected(Int)
    /// 其他网络错误
    case other(String)
}

/// 测试连接：先 GET /models（多数服务在这里就能看出密钥对不对、模型在不在），云端再发一次只要 1 个 token 的请求
/// 确认密钥和模型名真能用（有的服务模型列表不要密钥）。只发一个「ping」，不发任何转写
public enum LLMConnectionTest {
    public static func run(_ service: LLMService, onPhone: Bool) async -> LLMConnectionProblem? {
        if let p = precheck(service.endpoint, onPhone: onPhone) { return p }
        let s = service.makeSession(timeout: service.isLocal ? 4 : 10)
        defer { s.finishTasksAndInvalidate() }
        var listed: [String] = []
        do {
            var req = URLRequest(url: LLMService.url(service.endpoint, "models"))
            if let k = service.apiKey { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
            let (d, r) = try await s.data(for: req)
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                listed = modelIDs(d)
            } else if code != 404 && code != 405 {
                return classify(status: code, body: d, model: service.model)
            }
        } catch {
            return classify(error, endpoint: service.endpoint)
        }
        if !listed.isEmpty, !listed.contains(service.model) {
            return .modelNotFound(suggestions: suggestions(for: service.model, in: listed))
        }
        // 本机、局域网的服务：列表能读就够了（没加载模型时一次补全可能要很久）
        if service.isLocal, !listed.isEmpty { return nil }
        do {
            var body: [String: Any] = ["model": service.model, "max_tokens": 1, "temperature": 0,
                                       "messages": [["role": "user", "content": "ping"]]]
            service.dialect.apply(&body)
            var req = URLRequest(url: LLMService.url(service.endpoint, "chat/completions"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let k = service.apiKey { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, r) = try await s.data(for: req)
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? nil : classify(status: code, body: d, model: service.model)
        } catch {
            return classify(error, endpoint: service.endpoint)
        }
    }

    /// 不用联网就能看出的问题
    public static func precheck(_ endpoint: URL, onPhone: Bool) -> LLMConnectionProblem? {
        guard let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = endpoint.host?.lowercased(), !host.isEmpty else { return .invalidAddress }
        if onPhone, ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host) { return .pointsToThisDevice }
        if scheme == "http", !LLMService.isLocal(endpoint) { return .needsHTTPS }
        return nil
    }

    /// 按状态码和错误内容归类（各家的错误体不一样，只认状态码和 message 里的几个词）
    public static func classify(status: Int, body: Data?, model: String) -> LLMConnectionProblem {
        let text = body.map { String(decoding: $0, as: UTF8.self).lowercased() } ?? ""
        let mentionsModel = text.contains("model") && (text.contains("not found") || text.contains("not exist")
            || text.contains("does not exist") || text.contains("invalid") || text.contains("unknown") || text.contains("not a valid")
            || text.contains("model_not_found") || text.contains("no endpoints"))
        let mentionsCredit = ["insufficient_quota", "insufficient balance", "insufficient credits", "credit_balance",
                              "quota", "balance", "billing", "credits"].contains { text.contains($0) }
        switch status {
        case 401, 403: return mentionsCredit ? .noCredit : .badKey
        case 402: return .noCredit
        case 429: return mentionsCredit ? .noCredit : .rateLimited
        case 400, 404, 422: return mentionsModel ? .modelNotFound(suggestions: []) : status == 404 ? .unexpected(404) : .unexpected(status)
        case 500...599: return .server(status)
        default: return .unexpected(status)
        }
    }

    /// 网络错误归类。局域网地址连不上时，看系统给的原因是不是「本地网络被拒」
    public static func classify(_ error: Error, endpoint: URL) -> LLMConnectionProblem {
        let lan = LLMService.isLocal(endpoint)
        guard let u = error as? URLError else { return .other(error.localizedDescription) }
        let denied = localNetworkDenied(u)
        switch u.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return lan ? .localNetwork(denied: denied) : .offline
        case .timedOut:
            return lan ? .localNetwork(denied: denied) : .timedOut
        case .cannotConnectToHost:
            return lan ? .localNetwork(denied: denied) : .cannotConnect
        case .cannotFindHost, .dnsLookupFailed:
            return .cannotFindHost
        case .appTransportSecurityRequiresSecureConnection:
            return .needsHTTPS
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return .secureConnection
        case .badURL, .unsupportedURL:
            return .invalidAddress
        default:
            return .other(u.localizedDescription)
        }
    }

    /// iOS 拒绝本地网络访问时，URLError 里带着的网络路径会写明原因
    static func localNetworkDenied(_ e: URLError) -> Bool {
        #if canImport(Network)
        if #available(iOS 14.2, macOS 11.0, *), let path = e.userInfo["_NSURLErrorNWPathKey"] as? NWPath {
            return path.unsatisfiedReason == .localNetworkDenied
        }
        #endif
        return false
    }

    /// `GET /models` 的模型名
    static func modelIDs(_ d: Data) -> [String] {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        let list = (o["data"] as? [[String: Any]]) ?? (o["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) ?? ($0["model"] as? String) }
    }

    /// 名字相近的模型（同前缀、或互相包含），最多 3 个；都不像时给列表里的前 3 个
    static func suggestions(for model: String, in listed: [String]) -> [String] {
        let m = model.lowercased()
        let stem = m.split(whereSeparator: { "-/:._".contains($0) }).first.map(String.init) ?? m
        let close = listed.filter { id in
            let i = id.lowercased()
            return i.contains(m) || m.contains(i) || (!stem.isEmpty && i.contains(stem))
        }
        return Array((close.isEmpty ? listed : close).prefix(3))
    }
}
