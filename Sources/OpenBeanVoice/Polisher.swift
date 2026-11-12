// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 本地大模型润色（llama-server 的 OpenAI 兼容接口）。每句带前文作参考。
public final class Polisher: @unchecked Sendable {
    public struct Result {
        public let text: String
        public let ms: Double
        /// 模型输出不可信（太短/太长/出错）时退回原文
        public let fellBack: Bool
    }

    private let endpoint: URL
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
    public init(endpoint: URL, model: String = "local", prompt: String = Polisher.defaultPrompt, glossary: [String] = []) {
        self.endpoint = endpoint
        self.model = model
        var s = prompt
        if !glossary.isEmpty { s += "\n用户常用词：" + glossary.joined(separator: "、") }
        system = s
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0]
        cfg.timeoutIntervalForRequest = 8
        session = URLSession(configuration: cfg)
    }

    /// 新的一次听写，清空前文
    public func resetContext() { context.removeAll() }

    public static func isUp(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.timeoutInterval = 1
        guard let (_, r) = try? await URLSession.shared.data(for: req) else { return false }
        return (r as? HTTPURLResponse)?.statusCode == 200
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
        var req = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
