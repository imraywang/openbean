// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 包里写日志的出口：App 启动时接到自己的日志（Log.write）。只写元数据，不写回复正文和转写
public enum LLMLog {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?
    static func write(_ s: String) { sink?(s) }
}

/// 回复为什么不能用（写日志、测试用）
public enum ReplyProblem: String, Sendable, Equatable {
    /// 输出顶到了上限，JSON 没写完
    case truncated
    /// 正文是空的（推理把额度用光时常见）
    case empty
    /// 正文里找不到 JSON 对象
    case noJSON
    /// 有 JSON 但解析不了（不是截断）
    case badJSON
    /// JSON 能解析，但缺必要的字段（比如没有 summary）
    case missingFields

    public static func diagnose(_ r: LLMReply) -> ReplyProblem {
        let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return r.truncated ? .truncated : .empty }
        if r.truncated { return .truncated }
        let body = JSONReply.stripWrappers(t)
        guard body.contains("{") else { return .noJSON }
        return JSONReply.object(t) == nil ? .badJSON : .missingFields
    }
}

/// 一次「问模型要一个 JSON」的完整流程，三处整理（录音摘要、段摘要、日记）共用：
/// 1. 按调用方的输出上限问一次；能用就返回（正常情况和以前完全一样，只发一次）。
/// 2. 不能用时在日志里记一行元数据：结束原因、正文字数、推理字数和 token、输出上限、问题类型。
/// 3. 被截断（finish_reason = length，或推理占满额度）：把上限翻倍再问（有推理时翻四倍），最多到 maxCap；
///    到顶还截断时，试着把半截 JSON 补齐用掉；补不齐抛 `LLMBackendError.outputTruncated`，调用方缩小分块重来。
/// 4. 别的不能用（没 JSON、缺字段）：和以前一样原样再问一次，还不行抛 `Summarizer.Failure.unusable`。
struct LLMAsk {
    let channel: any LLMChannel
    let maxOutput: Int
    /// 日志里的名字（段摘要、日记…）
    let label: String

    /// 截断时输出上限最多加到多少
    static func cap(for maxOutput: Int) -> Int { max(maxOutput * 8, 8000) }

    func run<T>(_ system: String, _ user: String, shape: ReplyShape?, temperature: Double = 0.2,
                parse: (String) -> T?) async throws -> (value: T, calls: Int) {
        var limit = maxOutput
        var calls = 0
        var plainRetried = false
        let cap = Self.cap(for: maxOutput)
        while true {
            let reply = try await channel.complete(LLMRequest(system: system, user: user, maxTokens: limit,
                                                              temperature: temperature, shape: shape))
            calls += 1
            if let v = parse(reply.text) { return (v, calls) }
            let problem = ReplyProblem.diagnose(reply)
            LLMLog.write(Self.describe(reply, problem: problem, label: label, attempt: calls))
            if problem == .truncated || (problem == .empty && reply.reasoned) {
                if limit < cap {
                    limit = min(limit * (reply.reasoned ? 4 : 2), cap)
                    continue
                }
                if let fixed = JSONReply.repairTruncated(reply.text), let v = parse(fixed) {
                    LLMLog.write("大模型回复（\(label)）：输出到上限 \(limit) 仍被截断，补齐半截 JSON 后使用")
                    return (v, calls)
                }
                throw LLMBackendError.outputTruncated
            }
            if !plainRetried {
                plainRetried = true
                continue
            }
            throw Summarizer.Failure.unusable
        }
    }

    /// 日志里的一行：只有元数据
    static func describe(_ r: LLMReply, problem: ReplyProblem, label: String, attempt: Int) -> String {
        var parts = ["finish_reason=\(r.finishReason ?? "?")", "正文 \(r.text.count) 字"]
        if r.reasoned {
            parts.append("推理 \(r.reasoningChars) 字" + (r.reasoningTokens.map { "（\($0) token）" } ?? ""))
        } else {
            parts.append("无推理")
        }
        if let c = r.completionTokens { parts.append("输出 \(c) token") }
        if let m = r.maxTokens { parts.append("上限 \(m)") }
        return "大模型回复不能用（\(label)，第 \(attempt) 次）：" + parts.joined(separator: "，") + "，问题：\(problem.rawValue)"
    }
}

extension JSONReply {
    /// 去掉思考块和代码围栏，取出要解析的那段文字
    static func stripWrappers(_ raw: String) -> String {
        var text = raw
        if let r = text.range(of: "</think>", options: .backwards) {
            text = String(text[r.upperBound...])
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") {
            return ""
        }
        return text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
    }

    /// 宽松一点的解析（先按原来的办法，不行再试）：
    /// - 正文前后有说明文字、里面有别的花括号：取第一个括号配平的对象；
    /// - 结尾多了逗号（`[1, 2,]`）：去掉再解析
    static func lenientObject(_ text: String) -> [String: Any]? {
        var candidates: [String] = []
        if let b = balancedObject(text) { candidates.append(b) }
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b { candidates.append(String(text[a...b])) }
        for c in candidates {
            for variant in [c, c.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)] {
                if let d = variant.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    return o
                }
            }
        }
        return nil
    }

    /// 从第一个 `{` 开始、括号配平（跳过字符串里的括号）的那一段
    static func balancedObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" || ch == "[" {
                depth += 1
            } else if ch == "}" || ch == "]" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// 把被截断的 JSON 补成能解析的样子：丢掉写了一半的键（或没有值的键）、末尾的逗号，补上引号和括号。
    /// 写了一半的字符串值保留（截在句中也比整段没有好）。补不出对象时返回 nil
    static func repairTruncated(_ raw: String) -> String? {
        let text = stripWrappers(raw)
        guard let start = text.firstIndex(of: "{") else { return nil }
        let chars = Array(text[start...])
        enum Ctx { case object, array }
        var stack: [Ctx] = []
        var out: [Character] = []
        var inString = false, escaped = false
        /// 对象里下一个字符串是键还是值
        var expectKey: [Bool] = []
        /// 每层里最后一个完整成员结束后的位置（截断时退回到这里）
        var safe: [Int] = []
        var stringIsKey = false
        for ch in chars {
            out.append(ch)
            if inString {
                if escaped { escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == "\"" {
                    inString = false
                    if !stringIsKey, !safe.isEmpty { safe[safe.count - 1] = out.count }
                }
                continue
            }
            switch ch {
            case "\"":
                inString = true
                stringIsKey = stack.last == .object && (expectKey.last ?? false)
            case "{":
                stack.append(.object); expectKey.append(true); safe.append(out.count)
            case "[":
                stack.append(.array); expectKey.append(false); safe.append(out.count)
            case "}", "]":
                guard !stack.isEmpty else { return nil }
                stack.removeLast(); expectKey.removeLast(); safe.removeLast()
                if stack.isEmpty { return String(out) }
                safe[safe.count - 1] = out.count
            case ":":
                if !expectKey.isEmpty { expectKey[expectKey.count - 1] = false }
            case ",":
                if stack.last == .object, !expectKey.isEmpty { expectKey[expectKey.count - 1] = true }
            default:
                // 数字、true/false/null 这类值：读到这里算完整（下一个逗号或括号前）
                if !ch.isWhitespace, !safe.isEmpty, !(expectKey.last ?? true) || stack.last == .array {
                    safe[safe.count - 1] = out.count
                }
            }
        }
        guard !stack.isEmpty else { return nil }
        // 截在字符串值中间：补上引号，算这个值写完了
        if inString {
            if stringIsKey {
                out = Array(out[..<(safe.last ?? out.count)])
            } else {
                if escaped { out.removeLast() }
                out.append("\"")
                safe[safe.count - 1] = out.count
            }
        } else if let last = safe.last {
            out = Array(out[..<last])
        }
        // 退回去之后末尾可能还剩逗号或冒号（以及空白）
        while let c = out.last, c.isWhitespace || c == "," { out.removeLast() }
        if out.last == ":" { return nil }
        for ctx in stack.reversed() { out.append(ctx == .object ? "}" : "]") }
        return String(out)
    }
}
