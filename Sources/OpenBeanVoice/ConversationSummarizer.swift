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
        /// 被丢掉的代词、泛称和职位（「我」「店长」「发言人」）
        public var droppedGeneric: Int = 0
    }

    public static let kinds: Set<String> = ["conversation", "monologue", "media", "fragment"]
    /// 每段的上限：一段对话里真正定下来的事、能执行的待办通常就一两件；多了多半是把讨论和建议也算进去了
    static let maxDecisions = 3, maxTodos = 2, maxPeople = 8, maxThings = 5, maxKeyPoints = 5
    /// 转写不到这么多字的段不出待办（几句话里列出的待办多半是凑的）
    public static let minCharsForTodos = 150

    static let fields = """
    {"title": "...", "summary": "...", "kind": "conversation", "key_points": ["..."], "decisions": ["..."], \
    "todos": ["..."], "people": ["..."], "things": ["..."]}
    """

    static let rules = """
    - key_points: up to 5 short points with the important facts, numbers and names. [] when there are none.
    - decisions: at most 3 things the speakers clearly settled. Not suggestions, ideas, options under discussion, \
    principles or open questions. [] when nothing was settled, which is common.
    - todos: at most 2 concrete actions that someone committed to or was asked to do. Add the owner only when a \
    person's name is said in the transcript, and the deadline when one is said. General advice is not a to-do. \
    [] when there are none.
    - Put each item in only one list: an action someone will do is a to-do, not also a decision.
    - people: names of people who speak or are mentioned, written exactly as in the transcript. Only real names: not \
    pronouns (I, you, he, 我, 你, 他), not roles or titles (manager, speaker, 店长, 督导, 员工, 发言人). \
    [] when there are none.
    - things: at most 5 named projects, products, companies or places that are said in this transcript, written exactly \
    as in the transcript.
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
    - decisions: the decisions from the parts, merged; at most 3, only things that were really settled.
    - todos: the to-dos from the parts, merged and deduplicated; at most 2, the most concrete ones (an owner, a \
    deadline or a number). An item is either a to-do or a decision, never both.
    - people, things: write [] (they are collected from the parts).
    Only use what is in the part summaries.
    """

    public func summarize(_ lines: [TimedLine]) async throws -> Result {
        let text = lines.map(\.text).joined()
        let chunks = Summarizer.chunk(lines, budget: base.budget)
        guard !chunks.isEmpty, Summarizer.estimateTokens(text) >= Summarizer.minTokens else {
            return Result(summary: nil, kind: "fragment", calls: 0, droppedNames: 0)
        }
        // 不把词表放进提示词：模型会把词表原样抄进「人」和「事」。词表只在事后纠正拼写（finish）
        let lang = Summarizer.languageLine(for: text)
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

    /// 收尾：词表纠正；人名去掉代词和泛称、和专有名词一样要在转写里找得到；待办去掉泛称的负责人；
    /// 和待办相近的决定去掉（同一件事只归一类，有动作的算待办）；短段不出待办；封顶
    func finish(_ p: Parsed, transcript: String, calls: Int) -> Result {
        let c = GlossaryCorrector(terms: base.glossary)
        func fix(_ s: String) -> String { c.correct(s).text }
        let haystack = Self.normalized(c.correct(transcript).text + transcript)
        let rawPeople = Self.unique(p.people.map(fix))
        let named = rawPeople.filter { !NameFilter.isGeneric($0) }
        let people = named.filter { haystack.contains(Self.normalized($0)) }
        let rawThings = Self.unique(p.things.map(fix))
        let things = rawThings.filter { haystack.contains(Self.normalized($0)) }
        let dropped = named.count - people.count + rawThings.count - things.count
        let kind = Self.kinds.contains(p.kind) ? p.kind : "conversation"
        var todos = TextSimilarity.dedupe(p.todos.map { NameFilter.stripGenericOwner(fix($0)) }.filter { !$0.isEmpty })
        if transcript.count < Self.minCharsForTodos { todos = [] }
        todos = Array(todos.prefix(Self.maxTodos))
        let decisions = TextSimilarity.dedupe(p.decisions.map(fix)).filter { d in !todos.contains { TextSimilarity.similar($0, d) } }
        let s = ConversationSummary(title: fix(p.title), summary: fix(p.summary),
                                    keyPoints: Array(p.keyPoints.map(fix).prefix(Self.maxKeyPoints)),
                                    decisions: Array(decisions.prefix(Self.maxDecisions)), todos: todos,
                                    people: Array(people.prefix(Self.maxPeople)), things: Array(things.prefix(Self.maxThings)))
        return Result(summary: s, kind: kind, calls: calls, droppedNames: max(dropped, 0),
                      droppedGeneric: rawPeople.count - named.count)
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
                        let extra = ["owner", "assignee", "who", "due", "deadline"].compactMap { o[$0] as? String }
                            .filter { !$0.isEmpty && !NameFilter.isGeneric($0) }
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
