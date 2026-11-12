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
    private let system: String
    private var context: [String] = []
    private let session: URLSession

    public init(endpoint: URL, promptFile: URL, glossaryFile: URL?) throws {
        self.endpoint = endpoint
        var s = try String(contentsOf: promptFile, encoding: .utf8)
        if let g = glossaryFile, let words = try? String(contentsOf: g, encoding: .utf8) {
            let list = words.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !list.isEmpty { s += "\n用户常用词：" + list.joined(separator: "、") }
        }
        system = s
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0]
        cfg.timeoutIntervalForRequest = 8
        session = URLSession(configuration: cfg)
    }

    public static func isUp(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: d, as: UTF8.self).contains("ok")
    }

    public func polish(_ raw: String) async -> Result {
        let t0 = Date()
        let prior = context.suffix(3).joined()
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "前文：\(prior.isEmpty ? "（无）" : prior)\n本句：\(raw)"],
            ],
            "temperature": 0, "max_tokens": 400,
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
