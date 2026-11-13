// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary

/// 把一天的段摘要合成当天的日记：概述、定了的事、待办（大模型合并去重），提到的人和事（代码直接收集）。
///
/// 防编造的主要手段是出处：每段编号 S1、S2…，模型写的每条「定了的事」「待办」都要写出处编号；
/// 代码只留下出处存在、而且那一段自己的摘要里确实有「定了的事」/「待办」的条目，其余丢掉并计数。
/// 碎片和媒体声（电视、视频）的段不进日记；剩下的转写加起来太少（< minChars 字）时不调用大模型，只列对话。
public struct DiaryWriter: Sendable {
    public let base: Summarizer
    public let timeZone: TimeZone

    public init(_ base: Summarizer, timeZone: TimeZone = .current) {
        self.base = base
        self.timeZone = timeZone
    }

    public struct Input: Sendable, Hashable {
        public var ref: ConversationRef
        public var wallStart: Date
        public var wallEnd: Date
        public var kind: String?
        public var summary: ConversationSummary?
        /// 这段转写有多少字
        public var chars: Int

        public init(ref: ConversationRef, wallStart: Date, wallEnd: Date, kind: String?, summary: ConversationSummary?, chars: Int) {
            self.ref = ref
            self.wallStart = wallStart
            self.wallEnd = wallEnd
            self.kind = kind
            self.summary = summary
            self.chars = chars
        }
    }

    public struct Output: Sendable, Hashable {
        public var status: DayFile.Status
        public var diary: Diary?
        public var calls: Int
        /// 出处对不上被丢掉的条数
        public var dropped: Int
    }

    /// 当天进日记的转写至少要这么多字，才写概述
    public static let minChars = 500
    static let maxDecisions = 8, maxTodos = 10

    /// 进日记的段：有段摘要，不是碎片、不是媒体声
    public static func usable(_ inputs: [Input]) -> [Input] {
        inputs.filter { $0.summary != nil && $0.kind != "fragment" && $0.kind != "media" }.sorted { $0.wallStart < $1.wallStart }
    }

    public static func isBrief(_ inputs: [Input]) -> Bool {
        usable(inputs).reduce(0) { $0 + $1.chars } < minChars
    }

    static let prompt = """
    You write the daily summary of the conversations a voice recorder picked up during one day. You get a short \
    summary of each conversation, labelled S1, S2, … with its time, in time order.
    Reply with ONE JSON object and nothing else, no code fences:
    {"overview": "...", "decisions": [{"text": "...", "refs": ["S1"]}], "todos": [{"text": "...", "owner": "...", "refs": ["S2"]}]}
    - overview: 2 to 4 sentences on what the day's recorded conversations were about, in time order. Describe what was \
    recorded ("there was a meeting about…"); do not write as "I" or "you".
    - decisions: the most important things that were settled, at most 8, merged across conversations. Each one must come \
    from the Decisions of the conversations it lists in refs. [] when there are none.
    - todos: at most 10 to-dos, merged and deduplicated, those with an owner or a deadline first. Each one must come from \
    the To-dos of the conversations it lists in refs. owner: "" when it is not said.
    Only use what is in the summaries. Never add an item that is not in them, and never leave refs empty.
    """

    static let overviewPrompt = """
    You are given overviews of consecutive parts of one day's recorded conversations, in order. Combine them into one \
    overview of 2 to 4 sentences, in time order. Describe what was recorded; do not write as "I" or "you".
    Reply with ONE JSON object and nothing else, no code fences: {"overview": "..."}
    """

    public func write(_ inputs: [Input], languageSample: String) async throws -> Output {
        let use = Self.usable(inputs)
        let people = Self.names(use) { $0.people }, things = Self.names(use) { $0.things }
        guard !Self.isBrief(inputs) else {
            return Output(status: .brief, diary: nil, calls: 0, dropped: 0)
        }
        let labels = Dictionary(uniqueKeysWithValues: use.enumerated().map { ("S\($0.offset + 1)", $0.element) })
        let lang = Summarizer.languageLine(for: languageSample) + Summarizer.termsLine(base.glossary)
        let session = base.service.makeSession(timeout: base.timeout)
        var calls = 0
        func ask(_ system: String, _ user: String) async throws -> [String: Any] {
            for _ in 0..<2 {
                calls += 1
                if let o = JSONReply.object(try await chat(system, user, session)) { return o }
            }
            throw Summarizer.Failure.unusable
        }

        // 一次放不下就分组，各组各写一份，再把各组的概述合成一句话
        let rendered = use.enumerated().map { render($0.element, label: "S\($0.offset + 1)") }
        var groups: [[String]] = [], cur: [String] = [], used = 0
        for r in rendered {
            let cost = Summarizer.estimateTokens(r) + 2
            if !cur.isEmpty, used + cost > base.budget { groups.append(cur); cur = []; used = 0 }
            cur.append(r)
            used += cost
        }
        if !cur.isEmpty { groups.append(cur) }

        var overviews: [String] = [], decisions: [DiaryItem] = [], todos: [DiaryItem] = []
        var dropped = 0
        for g in groups {
            let o = try await ask(Self.prompt + "\n" + lang, "Conversations:\n\n" + g.joined(separator: "\n\n"))
            let ov = JSONReply.string(o, "overview", "summary")
            if !ov.isEmpty { overviews.append(ov) }
            let d = Self.items(o["decisions"], labels: labels) { !($0.summary?.decisions.isEmpty ?? true) }
            let t = Self.items(o["todos"] ?? o["action_items"], labels: labels) { !($0.summary?.todos.isEmpty ?? true) }
            decisions += d.kept
            todos += t.kept
            dropped += d.dropped + t.dropped
        }
        var overview = overviews.first
        if overviews.count > 1 {
            let o = try await ask(Self.overviewPrompt + "\n" + lang, overviews.enumerated().map { "Part \($0.offset + 1): \($0.element)" }
                .joined(separator: "\n\n"))
            let ov = JSONReply.string(o, "overview", "summary")
            overview = ov.isEmpty ? overviews.joined(separator: " ") : ov
        }
        let c = GlossaryCorrector(terms: base.glossary)
        let diary = Diary(overview: overview.map { c.correct($0).text },
                          decisions: Array(Self.dedupe(decisions).prefix(Self.maxDecisions)).map { Self.fix($0, c) },
                          todos: Array(Self.dedupe(todos).prefix(Self.maxTodos)).map { Self.fix($0, c) },
                          people: people, things: things)
        return Output(status: .diary, diary: diary, calls: calls, dropped: dropped)
    }

    private func chat(_ system: String, _ user: String, _ session: URLSession) async throws -> String {
        let extra: [String: Any] = base.service.isLocal ? ["chat_template_kwargs": ["enable_thinking": false]] : [:]
        return try await base.service.chat(system: system, user: user, maxTokens: base.maxOutput, temperature: 0.2,
                                           extra: extra, session: session)
    }

    func render(_ i: Input, label: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        let s = i.summary ?? ConversationSummary()
        var t = "[\(label) \(f.string(from: i.wallStart))–\(f.string(from: i.wallEnd))] \(s.title)\nSummary: \(s.summary)"
        if !s.decisions.isEmpty { t += "\nDecisions:\n" + s.decisions.map { "- \($0)" }.joined(separator: "\n") }
        if !s.todos.isEmpty { t += "\nTo-dos:\n" + s.todos.map { "- \($0)" }.joined(separator: "\n") }
        return t
    }

    // MARK: 校验出处

    /// 解析模型给的条目，只留下出处存在、而且出处那一段确实有这类内容的；返回留下的和丢掉的条数
    static func items(_ v: Any?, labels: [String: Input], allowed: (Input) -> Bool) -> (kept: [DiaryItem], dropped: Int) {
        guard let arr = v as? [Any] else { return ([], 0) }
        var kept: [DiaryItem] = [], dropped = 0
        for e in arr {
            guard let o = e as? [String: Any] else { dropped += 1; continue }
            let text = Summarizer.stripBullet(Summarizer.clean((o["text"] ?? o["item"] ?? o["task"]) as? String ?? ""))
            guard !text.isEmpty, !Summarizer.isNone(text) else { continue }
            var refs: [ConversationRef] = []
            for l in refLabels(o["refs"] ?? o["ref"] ?? o["sources"]) {
                if let i = labels[l], allowed(i), !refs.contains(i.ref) { refs.append(i.ref) }
            }
            guard !refs.isEmpty else { dropped += 1; continue }
            let owner = Summarizer.clean(o["owner"] as? String ?? "")
            kept.append(DiaryItem(text: text, owner: owner.isEmpty || Summarizer.isNone(owner) ? nil : owner, refs: refs))
        }
        return (kept, dropped)
    }

    /// "S3"、["S1", "S2"]、"S1, S2"、[1, 2] 都认
    static func refLabels(_ v: Any?) -> [String] {
        var raw: [String] = []
        if let a = v as? [Any] {
            for x in a {
                if let s = x as? String { raw.append(s) } else if let n = x as? NSNumber { raw.append("S\(n.intValue)") }
            }
        } else if let s = v as? String {
            raw = s.components(separatedBy: CharacterSet(charactersIn: ",，;； "))
        }
        return raw.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .map { $0.hasPrefix("S") ? $0 : "S" + $0 }.filter { $0.count > 1 }
    }

    static func dedupe(_ items: [DiaryItem]) -> [DiaryItem] {
        var seen = Set<String>()
        return items.filter { seen.insert(ConversationSummarizer.normalized($0.text)).inserted }
    }

    static func fix(_ i: DiaryItem, _ c: GlossaryCorrector) -> DiaryItem {
        DiaryItem(text: c.correct(i.text).text, owner: i.owner.map { c.correct($0).text }, refs: i.refs)
    }

    /// 人和事：照段摘要里的写法，写法不同就是不同的名字（不合并），列出出现在哪几段
    static func names(_ inputs: [Input], _ pick: (ConversationSummary) -> [String]) -> [DiaryName] {
        var order: [String] = [], refs: [String: [ConversationRef]] = [:]
        for i in inputs {
            for n in pick(i.summary ?? ConversationSummary()) {
                let name = n.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if refs[name] == nil { order.append(name) }
                if !(refs[name]?.contains(i.ref) ?? false) { refs[name, default: []].append(i.ref) }
            }
        }
        return order.map { DiaryName(name: $0, refs: refs[$0] ?? []) }
    }
}
