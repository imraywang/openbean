// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary

/// 一段对话的摘要：小标题、两三句摘要、定了的事、待办、提到的人和事、这段是什么。
///
/// 沿用 Summarizer 的保护：按 token 预算分块（长段先分块摘要再合并）、点名简繁、词表提示和纠正、关掉思考、
/// 太短的段不摘要（直接记作碎片，不让模型编）。另外几条只在这里有：
/// - 列表都没有下限（没有就空），待办每段最多 3 条，定了的事最多 5 条；
/// - 「人」和「事」必须在这段的转写里原样出现过（忽略空白和大小写），对不上的丢掉——模型最容易编的就是名字；
/// - 摘要用「录到的谈话」的口吻，不写「我」「你」。
public struct ConversationSummarizer: Sendable {
    public let base: Summarizer

    public init(_ base: Summarizer) {
        self.base = base
    }

    public struct Result: Sendable, Hashable {
        /// 太短（碎片）时没有
        public var summary: ConversationSummary?
        /// conversation / monologue / media / fragment
        public var kind: String
        /// 用了几次大模型
        public var calls: Int
        /// 被丢掉的人名和专有名词（在转写里找不到）
        public var droppedNames: Int
    }

    public static let kinds: Set<String> = ["conversation", "monologue", "media", "fragment"]
    static let maxDecisions = 5, maxTodos = 3, maxPeople = 12, maxThings = 5, maxKeyPoints = 5

    static let fields = """
    {"title": "...", "summary": "...", "kind": "conversation", "key_points": ["..."], "decisions": ["..."], \
    "todos": ["..."], "people": ["..."], "things": ["..."]}
    """

    static let rules = """
    - key_points: up to 5 short points with the important facts, numbers and names. [] when there are none.
    - decisions: things the speakers clearly agreed on or settled. Not suggestions, options under discussion or open \
    questions. [] when there are none.
    - todos: at most 3 concrete to-dos that someone committed to or was asked to do, with the owner and deadline when \
    they are said. General advice is not a to-do. [] when there are none.
    - people: names of people who speak or are mentioned in this transcript, written exactly as in the transcript. \
    [] when there are none.
    - things: at most 5 named projects, products, companies or places that are said in this transcript, written exactly \
    as in the transcript. The speaker's own terms below are only a spelling guide: list a term only when it is said here.
    Leave a list empty rather than guessing. Never invent people, numbers, dates, decisions or to-dos. Describe what was \
    recorded ("they agreed…", "someone suggested…"); do not write as "I" or "you".
    """

    static let segmentPrompt = """
    You summarise one conversation from a voice recording made during someone's day: a meeting, a call, a chat, a note \
    to self, or background audio. The transcript comes from speech recognition, so it may contain recognition errors \
    and filler words; read through them.
    Reply with ONE JSON object and nothing else, no code fences:
    \(fields)
    - title: a few words naming what was talked about, at most 10 words (or 16 Chinese characters), no quotes or time.
    - summary: 1 to 3 sentences on what was talked about. A short conversation gets one short sentence.
    - kind: "conversation" when two or more people talk with each other; "monologue" when one person dictates notes or \
    talks to themselves; "media" when it is mostly a TV, a video, a podcast, a radio or announcements; "fragment" when \
    there is too little to say what it is about.
    \(rules)
    """

    static let partPrompt = """
    You summarise one part of a long conversation from a voice recording. The transcript comes from speech \
    recognition, so it may contain recognition errors and filler words; read through them.
    Reply with ONE JSON object and nothing else, no code fences:
    \(fields)
    - title: a few words naming the topic of this part.
    - summary: 1 to 3 sentences on what was said in this part.
    - kind: as for the whole conversation: "conversation", "monologue", "media" or "fragment".
    \(rules)
    """

    static let mergePrompt = """
    You are given summaries of consecutive parts of one conversation from a voice recording, in order. Combine them \
    into one summary of the whole conversation.
    Reply with ONE JSON object and nothing else, no code fences:
    \(fields)
    - title: a few words naming what the whole conversation was about, at most 10 words (or 16 Chinese characters).
    - summary: 1 to 3 sentences covering the whole conversation.
    - kind: "conversation", "monologue", "media" or "fragment", for the conversation as a whole.
    - key_points: up to 5 of the most important points; merge duplicates.
    - decisions: the decisions from the parts, merged; at most 5.
    - todos: the to-dos from the parts, merged and deduplicated; at most 3, the most concrete ones (an owner, a \
    deadline or a number).
    - people, things: write [] (they are collected from the parts).
    Only use what is in the part summaries.
    """

    public func summarize(_ lines: [TimedLine]) async throws -> Result {
        let text = lines.map(\.text).joined()
        let chunks = Summarizer.chunk(lines, budget: base.budget)
        guard !chunks.isEmpty, Summarizer.estimateTokens(text) >= Summarizer.minTokens else {
            return Result(summary: nil, kind: "fragment", calls: 0, droppedNames: 0)
        }
        let lang = Summarizer.languageLine(for: text) + Summarizer.termsLine(base.glossary)
        let session = base.service.makeSession(timeout: base.timeout)
        var calls = 0
        func ask(_ system: String, _ user: String) async throws -> Parsed {
            // 回复不可用时再试一次；网络错误直接抛
            calls += 1
            if let p = try Self.parse(await chat(system, user, session)) { return p }
            calls += 1
            if let p = try Self.parse(await chat(system, user, session)) { return p }
            throw Summarizer.Failure.unusable
        }

        var merged: Parsed
        if chunks.count == 1 {
            merged = try await ask(Self.segmentPrompt + "\n" + lang, "Transcript:\n" + chunks[0].map(Summarizer.line).joined(separator: "\n"))
        } else {
            var parts: [Parsed] = []
            for (i, c) in chunks.enumerated() {
                let user = "Part \(i + 1) of \(chunks.count). Transcript:\n" + c.map(Summarizer.line).joined(separator: "\n")
                if let p = try? await ask(Self.partPrompt + "\n" + lang, user) { parts.append(p) }
                else if await base.service.check() != .ok { throw URLError(.cannotConnectToHost) }
            }
            guard !parts.isEmpty else { throw Summarizer.Failure.unusable }
            // 合并：分组合并到只剩一份；人和事由代码从各部分收集
            var level = parts
            while level.count > 1 {
                var next: [Parsed] = []
                for g in Self.group(level, budget: base.budget) {
                    if g.count == 1 { next.append(g[0]); continue }
                    let user = "Part summaries, in order:\n\n" + g.enumerated().map { Self.render($0.element, index: $0.offset + 1) }
                        .joined(separator: "\n\n")
                    next.append(try await ask(Self.mergePrompt + "\n" + lang, user))
                }
                level = next
            }
            merged = level[0]
            merged.people = Self.unique(parts.flatMap(\.people))
            merged.things = Self.unique(parts.flatMap(\.things))
        }
        return finish(merged, transcript: text, calls: calls)
    }

    private func chat(_ system: String, _ user: String, _ session: URLSession) async throws -> String {
        let extra: [String: Any] = base.service.isLocal ? ["chat_template_kwargs": ["enable_thinking": false]] : [:]
        return try await base.service.chat(system: system, user: user, maxTokens: base.maxOutput, temperature: 0.2,
                                           extra: extra, session: session)
    }

    /// 封顶、词表纠正、人名和专有名词要在转写里找得到
    func finish(_ p: Parsed, transcript: String, calls: Int) -> Result {
        let c = GlossaryCorrector(terms: base.glossary)
        func fix(_ s: String) -> String { c.correct(s).text }
        let haystack = Self.normalized(c.correct(transcript).text + transcript)
        let people = Self.unique(p.people.map(fix)).filter { haystack.contains(Self.normalized($0)) }
        let things = Self.unique(p.things.map(fix)).filter { haystack.contains(Self.normalized($0)) }
        let dropped = Self.unique(p.people).count + Self.unique(p.things).count - people.count - things.count
        let kind = Self.kinds.contains(p.kind) ? p.kind : "conversation"
        let s = ConversationSummary(title: fix(p.title), summary: fix(p.summary),
                                    keyPoints: Array(p.keyPoints.map(fix).prefix(Self.maxKeyPoints)),
                                    decisions: Array(p.decisions.map(fix).prefix(Self.maxDecisions)),
                                    todos: Array(p.todos.map(fix).prefix(Self.maxTodos)),
                                    people: Array(people.prefix(Self.maxPeople)), things: Array(things.prefix(Self.maxThings)))
        return Result(summary: s, kind: kind, calls: calls, droppedNames: max(dropped, 0))
    }

    /// 对比用：去掉空白和标点、转小写
    static func normalized(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }))
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: 解析

    struct Parsed: Hashable {
        var title = "", summary = "", kind = "conversation"
        var keyPoints: [String] = [], decisions: [String] = [], todos: [String] = [], people: [String] = [], things: [String] = []
    }

    static func parse(_ raw: String) -> Parsed? {
        guard let obj = JSONReply.object(raw) else { return nil }
        let summary = JSONReply.string(obj, "summary", "Summary", "摘要")
        guard !summary.isEmpty, !Summarizer.looksLikePlaceholder(summary) else { return nil }
        var p = Parsed()
        p.summary = summary
        var title = JSONReply.string(obj, "title", "Title", "标题")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」『』《》#*")).trimmingCharacters(in: .whitespaces)
        if title.count > 40 { title = String(title.prefix(40)) }
        p.title = Summarizer.looksLikePlaceholder(title) ? "" : title
        p.kind = JSONReply.string(obj, "kind", "type").lowercased()
        p.keyPoints = JSONReply.list(obj, "key_points", "keyPoints")
        p.decisions = JSONReply.list(obj, "decisions", "decided")
        p.todos = JSONReply.list(obj, "todos", "action_items", "to_dos")
        p.people = JSONReply.list(obj, "people", "names")
        p.things = JSONReply.list(obj, "things", "entities")
        return p
    }

    static func render(_ p: Parsed, index: Int) -> String {
        var t = "Part \(index): \(p.title)\nSummary: \(p.summary)"
        for (name, items) in [("Key points", p.keyPoints), ("Decisions", p.decisions), ("To-dos", p.todos)] where !items.isEmpty {
            t += "\n\(name):\n" + items.map { "- \($0)" }.joined(separator: "\n")
        }
        return t
    }

    /// 按预算分组（每组至少两份）
    static func group(_ parts: [Parsed], budget: Int) -> [[Parsed]] {
        var out: [[Parsed]] = [], cur: [Parsed] = []
        var used = 0
        for (i, p) in parts.enumerated() {
            let cost = Summarizer.estimateTokens(render(p, index: i + 1)) + 2
            if cur.count >= 2, used + cost > budget { out.append(cur); cur = []; used = 0 }
            cur.append(p)
            used += cost
        }
        if !cur.isEmpty {
            if cur.count == 1, !out.isEmpty { out[out.count - 1] += cur } else { out.append(cur) }
        }
        return out
    }
}

/// 从模型回复里取 JSON（去掉思考块和代码围栏）
enum JSONReply {
    static func object(_ raw: String) -> [String: Any]? {
        var text = raw
        if let r = text.range(of: "</think>", options: .backwards) {
            text = String(text[r.upperBound...])
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") {
            return nil
        }
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let d = String(text[a...b]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func string(_ obj: [String: Any], _ keys: String...) -> String {
        for k in keys {
            if let s = obj[k] as? String { return Summarizer.clean(s) }
            if let a = obj[k] as? [Any] { return Summarizer.clean(a.compactMap { $0 as? String }.joined(separator: " ")) }
        }
        return ""
    }

    static func list(_ obj: [String: Any], _ keys: String...) -> [String] {
        for k in keys {
            if let a = obj[k] as? [Any] {
                return a.compactMap { item -> String? in
                    if let s = item as? String { return s }
                    if let o = item as? [String: Any] {
                        let main = ["text", "task", "item", "name", "action", "content"].compactMap { o[$0] as? String }.first
                        let extra = ["owner", "assignee", "who", "due", "deadline"].compactMap { o[$0] as? String }.filter { !$0.isEmpty }
                        guard let main else { return nil }
                        return extra.isEmpty ? main : "\(main) (\(extra.joined(separator: ", ")))"
                    }
                    return nil
                }.map(Summarizer.clean).map(Summarizer.stripBullet).filter { !$0.isEmpty && !Summarizer.isNone($0) }
            }
            if let s = obj[k] as? String {
                return s.split(whereSeparator: \.isNewline).map { Summarizer.stripBullet(Summarizer.clean(String($0))) }
                    .filter { !$0.isEmpty && !Summarizer.isNone($0) }
            }
        }
        return []
    }
}
