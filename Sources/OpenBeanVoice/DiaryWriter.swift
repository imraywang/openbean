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
        /// 用户在这段里做的重点标记：每个标记处的原话（标记那句和前后各一句）
        public var marks: [String]

        public init(ref: ConversationRef, wallStart: Date, wallEnd: Date, kind: String?, summary: ConversationSummary?, chars: Int,
                    marks: [String] = []) {
            self.marks = marks
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
        /// 和别的条目重复、被去掉的条数（待办之间、决定之间、和待办相近的决定）
        public var duplicates: Int = 0
        /// 不认的负责人（泛称、或出处那几段里找不到）
        public var droppedOwners: Int = 0
    }

    /// 当天进日记的转写至少要这么多字，才写概述
    public static let minChars = 500
    /// 一天的上限：日记是给人扫一眼的，列太多就等于没列。人按出现的段数排，只出现一次的在后面
    static let maxDecisions = 5, maxTodos = 6, maxPeople = 12, maxThings = 8

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
    - decisions: only what was really settled, at most 5, merged across conversations. Each one must come from the \
    Decisions of the conversations it lists in refs. [] when there are none.
    - todos: at most 6 concrete actions, merged and deduplicated, those with an owner or a deadline first. Each one must \
    come from the To-dos of the conversations it lists in refs. owner: a person's name from those conversations, or "" \
    when no name is given; never a pronoun or a role (speaker, manager, 发言人, 店长).
    - Put each item in only one list: an action someone will do is a to-do; otherwise it is a decision. Never list the \
    same thing in both.
    - A conversation with "Marked by the user" has moments the user marked as important on the recorder. Mention \
    what was said there in the overview.
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
        // 不放词表：输入已经是摘要，词表只在事后纠正拼写
        let lang = Summarizer.languageLine(for: languageSample)
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
        let byRef = Dictionary(use.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        var droppedOwners = 0
        let checked = todos.map { t -> DiaryItem in
            let ok = Self.ownerOK(t.owner, refs: t.refs, byRef: byRef)
            if t.owner != nil, !ok { droppedOwners += 1 }
            return DiaryItem(text: t.text, owner: ok ? t.owner : nil, refs: t.refs)
        }
        let cleanTodos = Self.dedupe(checked)
        // 和某条待办说的是同一件事的决定去掉：有动作的归待办
        let cleanDecisions = Self.dedupe(decisions).filter { d in !cleanTodos.contains { TextSimilarity.similar($0.text, d.text) } }
        let duplicates = todos.count - cleanTodos.count + decisions.count - cleanDecisions.count
        let diary = Diary(overview: overview.map { c.correct($0).text },
                          decisions: Array(cleanDecisions.prefix(Self.maxDecisions)).map { Self.fix($0, c) },
                          todos: Array(cleanTodos.prefix(Self.maxTodos)).map { Self.fix($0, c) },
                          people: Array(people.prefix(Self.maxPeople)), things: Array(things.prefix(Self.maxThings)))
        return Output(status: .diary, diary: diary, calls: calls, dropped: dropped, duplicates: duplicates, droppedOwners: droppedOwners)
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
        // 用户在这里做了重点标记：把标记处的原话一起给模型
        if !i.marks.isEmpty { t += "\nMarked by the user as important:\n" + i.marks.map { "- \"\($0)\"" }.joined(separator: "\n") }
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

    /// 文字相近的合成一条：出处合并，负责人取先有的
    static func dedupe(_ items: [DiaryItem]) -> [DiaryItem] {
        var out: [DiaryItem] = []
        for i in items {
            if let k = out.firstIndex(where: { TextSimilarity.similar($0.text, i.text) }) {
                for r in i.refs where !out[k].refs.contains(r) { out[k].refs.append(r) }
                if out[k].owner == nil { out[k].owner = i.owner }
            } else {
                out.append(i)
            }
        }
        return out
    }

    /// 负责人只认具体的人名：不是代词或泛称，并且出现在出处那几段的人名、摘要或待办里（段的人名已经核对过转写）
    static func ownerOK(_ owner: String?, refs: [ConversationRef], byRef: [ConversationRef: Input]) -> Bool {
        guard let owner, !NameFilter.isGeneric(owner) else { return false }
        let o = ConversationSummarizer.normalized(owner)
        return refs.contains { r in
            guard let s = byRef[r]?.summary else { return false }
            let text = ConversationSummarizer.normalized(([s.summary] + s.todos + s.decisions).joined())
            return s.people.contains { let p = ConversationSummarizer.normalized($0); return p == o || p.contains(o) || o.contains(p) }
                || text.contains(o)
        }
    }

    static func fix(_ i: DiaryItem, _ c: GlossaryCorrector) -> DiaryItem {
        DiaryItem(text: c.correct(i.text).text, owner: i.owner.map { c.correct($0).text }, refs: i.refs)
    }

    /// 人和事：照段摘要里的写法，写法不同就是不同的名字（不合并），列出出现在哪几段；按出现的段数排，一样多时按先后
    static func names(_ inputs: [Input], _ pick: (ConversationSummary) -> [String]) -> [DiaryName] {
        var order: [String] = [], refs: [String: [ConversationRef]] = [:]
        for i in inputs {
            for n in pick(i.summary ?? ConversationSummary()) {
                let name = n.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !NameFilter.isGeneric(name) else { continue }
                if refs[name] == nil { order.append(name) }
                if !(refs[name]?.contains(i.ref) ?? false) { refs[name, default: []].append(i.ref) }
            }
        }
        let all = order.map { DiaryName(name: $0, refs: refs[$0] ?? []) }
        return all.enumerated().sorted { a, b in
            a.element.refs.count != b.element.refs.count ? a.element.refs.count > b.element.refs.count : a.offset < b.offset
        }.map(\.element)
    }
}
