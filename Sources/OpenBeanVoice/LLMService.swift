// SPDX-License-Identifier: Apache-2.0

import Foundation

/// OpenAI 兼容的大模型服务（润色和摘要共用）：本机（llama-server、Ollama、LM Studio）或云端（填 API Key）都行。
public struct LLMService: Sendable {
    public let endpoint: URL
    public let apiKey: String?
    public let model: String

    /// - Parameters:
    ///   - endpoint: 服务的根地址，如 llama-server 的 `http://127.0.0.1:8092`，带不带 `/v1` 都行
    ///   - apiKey: 云端服务的 Key，按 `Authorization: Bearer` 发送；本机服务留空
    ///   - model: 传给服务的模型名（llama-server 忽略；Ollama 等需要）
    public init(endpoint: URL, apiKey: String? = nil, model: String = "local") {
        self.endpoint = endpoint
        self.apiKey = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        self.model = model
    }

    public var isLocal: Bool { Self.isLocal(endpoint) }

    public enum Failure: Error, CustomStringConvertible {
        case http(Int)
        case badResponse
        public var description: String {
            switch self {
            case let .http(c): return "HTTP \(c)"
            case .badResponse: return "bad response"
            }
        }
    }

    /// 地址是不是本机或局域网（不是的话，文字会离开这台 Mac）
    public static func isLocal(_ base: URL) -> Bool {
        guard let h = base.host?.lowercased() else { return true }
        if ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(h) || h.hasSuffix(".local") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }

    /// 根地址可以带或不带 `/v1`（有的服务给的基础地址就以 /v1 结尾，如通义千问兼容模式）
    static func url(_ base: URL, _ path: String) -> URL {
        let b = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        return b.hasSuffix("/v1") ? base.appendingPathComponent(path) : base.appendingPathComponent("v1").appendingPathComponent(path)
    }

    /// 本机服务不走代理（代理软件可能拦下 127.0.0.1）；云端走系统代理，等得久一点
    static func session(for base: URL, timeout: TimeInterval? = nil) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        if isLocal(base) {
            cfg.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0]
        }
        cfg.timeoutIntervalForRequest = timeout ?? (isLocal(base) ? 8 : 15)
        cfg.timeoutIntervalForResource = max(cfg.timeoutIntervalForRequest, 60)
        return URLSession(configuration: cfg)
    }

    /// 给这个服务建一个会话；timeout 不填时本机 8 秒、云端 15 秒
    public func makeSession(timeout: TimeInterval? = nil) -> URLSession { Self.session(for: endpoint, timeout: timeout) }

    /// 发一次对话补全，返回模型的原始回复（不做任何清理）
    public func chat(system: String, user: String, maxTokens: Int, temperature: Double = 0,
                     extra: [String: Any] = [:], session: URLSession) async throws -> String {
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "model": model, "temperature": temperature, "max_tokens": maxTokens,
        ]
        for (k, v) in extra { body[k] = v }
        var req = URLRequest(url: Self.url(endpoint, "chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, r) = try await session.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any],
              let text = msg["content"] as? String else { throw Failure.badResponse }
        return text
    }

    public enum Status: Equatable, Sendable {
        case ok
        /// 连上了但 Key 不对（401 / 403）
        case unauthorized
        case unreachable(String)
    }

    /// 检查服务：本机等 1 秒，云端等 6 秒
    public static func check(_ base: URL, apiKey: String? = nil) async -> Status {
        var req = URLRequest(url: url(base, "models"))
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let s = session(for: base, timeout: isLocal(base) ? 1 : 6)
        do {
            let (_, r) = try await s.data(for: req)
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return .ok
            case 401, 403: return .unauthorized
            default: return .unreachable("HTTP \(code)")
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    public func check() async -> Status { await Self.check(endpoint, apiKey: apiKey) }
}
