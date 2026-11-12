// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 大模型润色：OpenAI 兼容接口，本机（llama-server、Ollama、LM Studio）或云端（填 API Key）都行。每句带前文作参考。
public final class Polisher: @unchecked Sendable {
    public struct Result {
        public let text: String
        public let ms: Double
        /// 模型输出不可信（太短/太长/出错）时退回原文
        public let fellBack: Bool
    }

    private let endpoint: URL
    private let apiKey: String?
    private let model: String
    private let system: String
    private var context: [String] = []
    private let session: URLSession

    /// 默认提示词：最小改动的语音输入润色
    public static let defaultPrompt = """
    你是语音输入法的润色器。用户每次给你一句刚由语音识别得到的中文，以及前文（只作参考，不要输出）。
    把「本句」改成适合直接输入的书面文字：
    1. 结合上下文修正明显的同音、近音识别错误。优先改成「用户常用词」里发音相近的词；拿不准就保留原样，不要换成意思不同的词。
    2. 删掉不承担意思的口头禅、语气词和重复，例如：呃、嗯、啊、就是、就是说、这个、那个、然后（只在它们纯属口癖时删除）。
    3. 修正标点，句末保留合适的标点。
    4. 只做最小改动：保留用户自己的用词和说话风格，不要换成更书面的同义词（如「如果」不要改成「若」），不要删减有意思的词（如「一下」「还是」）。
    5. 不改变原意，不补充信息，不总结，不回答句子里的问题，不加引号，不解释。
    6. 用户口述的「句号」「问号」「逗号」等词是在说话内容里，照原文保留成文字。
    只输出改好的这一句。
    """

    /// - Parameters:
    ///   - endpoint: OpenAI 兼容服务的根地址，如 llama-server 的 `http://127.0.0.1:8092`
    ///   - model: 传给服务的模型名（llama-server 忽略；Ollama 等需要）
    ///   - apiKey: 云端服务的 Key，按 `Authorization: Bearer` 发送；本机服务留空
    public init(endpoint: URL, apiKey: String? = nil, model: String = "local", prompt: String = Polisher.defaultPrompt,
                glossary: [String] = []) {
        self.endpoint = endpoint
        self.apiKey = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        self.model = model
        var s = prompt
        if !glossary.isEmpty { s += "\n用户常用词：" + glossary.joined(separator: "、") }
        system = s
        session = Polisher.session(for: endpoint)
    }

    /// 本机服务不走代理（代理软件可能拦下 127.0.0.1）；云端走系统代理，等得久一点
    private static func session(for base: URL, timeout: TimeInterval? = nil) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        if isLocal(base) {
            cfg.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0]
        }
        cfg.timeoutIntervalForRequest = timeout ?? (isLocal(base) ? 8 : 15)
        return URLSession(configuration: cfg)
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

    /// 新的一次听写，清空前文
    public func resetContext() { context.removeAll() }

    public enum Status: Equatable {
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

    public static func isUp(_ base: URL, apiKey: String? = nil) async -> Bool {
        await check(base, apiKey: apiKey) == .ok
    }

    public func polish(_ raw: String) async -> Result {
        let t0 = Date()
        let prior = context.suffix(3).joined()
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "前文：\(prior.isEmpty ? "（无）" : prior)\n本句：\(raw)"],
            ],
            "model": model, "temperature": 0, "max_tokens": 400,
        ]
        var req = URLRequest(url: Polisher.url(endpoint, "chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var out = raw
        var fellBack = true
        if let (d, _) = try? await session.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let choice = (obj["choices"] as? [[String: Any]])?.first,
           let msg = choice["message"] as? [String: Any],
           var text = msg["content"] as? String {
            if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」"))
            if text.hasPrefix("本句：") { text.removeFirst(3) }
            // 删口头禅会变短，但不该短到一半以下；也不该凭空变长
            let r = Double(text.count) / Double(max(raw.count, 1))
            if !text.isEmpty, r > 0.4, r < 1.6 || text.count <= raw.count + 8 {
                out = text
                fellBack = false
            }
        }
        context.append(out)
        return Result(text: out, ms: Date().timeIntervalSince(t0) * 1000, fellBack: fellBack)
    }
}
