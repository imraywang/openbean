// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary

/// 把一天的段摘要合成当天的日记：概述、要点、定了的事、待办（大模型合并去重），提到的人和事（代码直接收集）。
///
/// 防编造的主要手段是出处：每段编号 S1、S2…，模型写的每条「要点」「定了的事」「待办」都要写出处编号；
/// 代码只留下出处存在、而且那一段自己的摘要里确实有「要点」/「定了的事」/「待办」的条目，其余丢掉并计数。
/// 概述的长度和要点的条数跟着这天的大小走（Target）。
/// 碎片和媒体声（电视、视频）的段不进日记；剩下的转写加起来太少（< minChars 字）时不调用大模型，只列对话。
///
/// 「认出我的声音」开着、有段带着佩戴者的说话占比（Input.wearerShare）时，这天是「带标签的一天」：
/// 提示词告诉模型这是佩戴者的日记、各段他说了多少、哪些待办是他的；要点和定了的事按「他说过话的段」排前面，
/// 他一句没说的段（旁听到的）排最后、要点里最多占三分之一；待办分成他的和别人的，他的在前。
/// 没有标签的日子提示词和以前一字不差。
public struct DiaryWriter: Sendable {
    public let base: Summarizer
    public let timeZone: TimeZone

    /// 带标签的日子用什么口吻（没标签的日子总是中性的「录到的谈话」）
    public let voice: WearerVoice

    public init(_ base: Summarizer, timeZone: TimeZone = .current, voice: WearerVoice = .labelled) {
        self.base = base
        self.timeZone = timeZone
        self.voice = voice
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
        /// 佩戴者说话的时长占比（WearerStats.share）：nil = 不知道（没有标签，或判定过的句子太少），0 = 他没说话
        public var wearerShare: Double?

        public init(ref: ConversationRef, wallStart: Date, wallEnd: Date, kind: String?, summary: ConversationSummary?, chars: Int,
                    marks: [String] = [], wearerShare: Double? = nil) {
            self.marks = marks
            self.wearerShare = wearerShare
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
        /// 和别的条目重复、被去掉的条数（同类之间、和待办相近的决定、和决定或待办相近的要点）
        public var duplicates: Int = 0
        /// 不认的负责人（泛称、或出处那几段里找不到）
        public var droppedOwners: Int = 0
        /// 丢掉的条目按「哪一栏:原因」计数，如 "highlights:noRefs"（排查用，只有条数）
        public var dropReasons: [String: Int] = [:]
        /// 模型说是佩戴者的、但出处那几段里没有他的待办，改成别人的待办的条数
        public var droppedMine: Int = 0
        /// 这天带不带「认出我的声音」的标签
        public var labelled: Bool = false
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

    /// 带标签的一天：进日记的段里有知道佩戴者说了多少的
    public static func isLabelled(_ inputs: [Input]) -> Bool {
        usable(inputs).contains { $0.wearerShare != nil }
    }

    /// 一段的排位：0 他说过话，1 不知道，2 他没说话（旁听到的）
    static func rank(_ i: Input?) -> Int {
        guard let s = i?.wearerShare else { return 1 }
        return s > 0 ? 0 : 2
    }

    /// 一条的排位：取出处里最好的那段
    static func rank(_ item: DiaryItem, _ byRef: [ConversationRef: Input]) -> Int {
        item.refs.map { rank(byRef[$0]) }.min() ?? 1
    }

    /// 按排位稳定排序；有来自他说过话（或不知道）的段的条目时，只来自旁听段的最多留 `overheardCap` 条
    static func ordered(_ items: [DiaryItem], _ byRef: [ConversationRef: Input], overheardCap: Int? = nil) -> [DiaryItem] {
        let sorted = items.enumerated().sorted { a, b in
            let ra = rank(a.element, byRef), rb = rank(b.element, byRef)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        guard let cap = overheardCap, sorted.contains(where: { rank($0, byRef) < 2 }) else { return sorted }
        var n = 0
        return sorted.filter { item in
            guard rank(item, byRef) == 2 else { return true }
            n += 1
            return n <= cap
        }
    }

    /// 这一天写多长：概述几句、要点最多几条。按进日记的段数和转写字数各定一个等级，取平均（向上取整）：
    /// 很少的一天一两句，很长的一天四到六句短句
    public struct Target: Sendable, Hashable {
        /// 0 很短 … 3 很长
        public var level: Int
        public init(level: Int) { self.level = max(0, min(3, level)) }
        public var sentences: ClosedRange<Int> { [1...2, 2...3, 3...4, 4...6][level] }
        public var maxHighlights: Int { [3, 5, 6, 8][level] }
        /// 给模型看的长度说明
        public var sentencesText: String {
            let r = sentences
            return level >= 2 ? "\(r.lowerBound) to \(r.upperBound) short sentences" : "\(r.lowerBound) or \(r.upperBound) sentences"
        }
        public static let short = Target(level: 0), long = Target(level: 3)
    }

    /// inputs 应该已经是 usable 过的段
    public static func target(_ inputs: [Input]) -> Target {
        let chars = inputs.reduce(0) { $0 + $1.chars }, n = inputs.count
        let byChars = chars < 3000 ? 0 : chars < 10000 ? 1 : chars < 25000 ? 2 : 3
        let byCount = n <= 2 ? 0 : n <= 4 ? 1 : n <= 7 ? 2 : 3
        return Target(level: (byChars + byCount + 1) / 2)
    }

    static func prompt(_ t: Target) -> String {
        """
        You write the daily summary of the conversations a voice recorder picked up during one day. You get a short \
        summary of each conversation, labelled S1, S2, … with its time, in time order.
        Reply with ONE JSON object and nothing else, no code fences:
        {"overview": "...", "highlights": [{"text": "...", "refs": ["S1"]}], "decisions": [{"text": "...", "refs": ["S1"]}], \
        "todos": [{"text": "...", "owner": "...", "refs": ["S2"]}]}
        - overview: \(t.sentencesText) on what the day's recorded conversations were about. Start with the most \
        important thing rather than the earliest, and do not go through the conversations one by one. Describe what \
        was recorded ("there was a meeting about…"); do not write as "I" or "you".
        - highlights: at most \(t.maxHighlights) of the most noteworthy facts, numbers, ideas and lessons of the day, each \
        one short line, merged and deduplicated across conversations. Each one must come from the Key points of the \
        conversations it lists in refs. Do not repeat what is in decisions or todos. [] when there are none.
        - decisions: at most 5 things that were really settled AND still matter after that conversation ended, such as \
        a choice about work, money, plans, people or a product. These are not decisions: how the conversation itself \
        runs (who speaks first, the agenda, taking turns), ordering food or drinks, who pays the bill, where to sit, \
        "let's talk about it later" or "let's continue next time". Merge them across conversations. Each one must come \
        from the Decisions of the conversations it lists in refs. [] when there are none, which is common.
        - todos: at most 6 concrete actions still to be done after that conversation, merged and deduplicated, those \
        with an owner or a deadline first. Steps of the conversation itself and things done on the spot are not to-dos. \
        Each one must come from the To-dos of the conversations it lists in refs. owner: a person's name from those \
        conversations, or "" when no name is given; never a pronoun or a role (speaker, manager, 发言人, 店长).
        - Put each item in only one list: an action someone will do is a to-do; otherwise it is a decision. Never list the \
        same thing in both.
        - A conversation with "Marked by the user" has moments the user marked as important on the recorder. Mention \
        what was said there in the overview or the highlights.
        Only use what is in the summaries. Never add an item that is not in them, and never leave refs empty.
        """
    }

    /// 最长那一档的提示
    static var prompt: String { prompt(.long) }

    /// 带标签的一天的提示：这是佩戴者的日记
    static func labelledPrompt(_ t: Target, voice: WearerVoice) -> String {
        let who = voice == .you
            ? "Write to the wearer as \"you\" (in Chinese 你): \"you agreed with Wang to…\". Use \"you\" for nobody else, and never write as \"I\"."
            : "Describe what was recorded; do not write as \"I\" or \"you\", and do not call anyone \"the wearer\"."
        return """
        You write the daily diary of the person who wore a voice recorder all day (called "the wearer" below), from the \
        conversations it picked up. You get a short summary of each conversation, labelled S1, S2, … with its time, in \
        time order. "Wearer:" says how much of a conversation the wearer spoke; "did not speak" means it was only \
        overheard. "Wearer's to-dos" are things the wearer committed to or was asked to do.
        Reply with ONE JSON object and nothing else, no code fences:
        {"overview": "...", "highlights": [{"text": "...", "refs": ["S1"]}], "decisions": [{"text": "...", "refs": ["S1"]}], \
        "my_todos": [{"text": "...", "refs": ["S2"]}], "todos": [{"text": "...", "owner": "...", "refs": ["S2"]}]}
        - overview: \(t.sentencesText) on the wearer's day. Start with the most important thing the wearer said, decided \
        or learned in conversations he or she took part in, rather than the earliest; do not go through the \
        conversations one by one. Mention overheard conversations last and briefly, if at all. \(who)
        - highlights: at most \(t.maxHighlights) of the most noteworthy facts, numbers, ideas and lessons of the day, each \
        one short line, merged and deduplicated across conversations, with what the wearer said, decided, promised or \
        learned first; overheard conversations last. Each one must come from the Key points of the conversations it \
        lists in refs. Do not repeat what is in decisions or todos. [] when there are none.
        - decisions: at most 5 things that were really settled AND still matter after that conversation ended, such as \
        a choice about work, money, plans, people or a product. These are not decisions: how the conversation itself \
        runs (who speaks first, the agenda, taking turns), ordering food or drinks, who pays the bill, where to sit, \
        "let's talk about it later" or "let's continue next time". Merge them across conversations. Each one must come \
        from the Decisions of the conversations it lists in refs. [] when there are none, which is common.
        - my_todos: the wearer's own to-dos, merged and deduplicated, those with a deadline first. Each one must come \
        from the Wearer's to-dos of the conversations it lists in refs.
        - todos: other people's to-dos, merged and deduplicated, those with an owner or a deadline first. Each one must \
        come from the Other to-dos or To-dos of the conversations it lists in refs. owner: a person's name from those \
        conversations, or "" when no name is given; never a pronoun or a role (speaker, manager, 发言人, 店长).
        - At most 6 to-dos in all. Steps of the conversation itself and things done on the spot are not to-dos.
        - Put each item in only one list: an action someone will do is a to-do; otherwise it is a decision. Never list the \
        same thing in both.
        - A conversation with "Marked by the user" has moments the user marked as important on the recorder. Mention \
        what was said there in the overview or the highlights.
        Only use what is in the summaries. Never add an item that is not in them, and never leave refs empty.
        """
    }

    static func labelledOverviewPrompt(_ t: Target, voice: WearerVoice) -> String {
        """
        You are given overviews of consecutive parts of the diary of the person who wore a voice recorder all day, in \
        order. Combine them into one overview of \(t.sentencesText). Start with the most important thing the wearer \
        said, decided or learned rather than the earliest, and do not go through the parts one by one. \
        \(voice == .you ? "Write to the wearer as \"you\" (in Chinese 你), and never write as \"I\"." : "Do not write as \"I\" or \"you\".")
        Reply with ONE JSON object and nothing else, no code fences: {"overview": "..."}
        """
    }

    static func overviewPrompt(_ t: Target) -> String {
        """
        You are given overviews of consecutive parts of one day's recorded conversations, in order. Combine them into one \
        overview of \(t.sentencesText). Start with the most important thing rather than the earliest, and do not go \
        through the parts one by one. Describe what was recorded; do not write as "I" or "you".
        Reply with ONE JSON object and nothing else, no code fences: {"overview": "..."}
        """
    }

    public func write(_ inputs: [Input], languageSample: String) async throws -> Output {
        do { return try await writeOnce(inputs, languageSample: languageSample) } catch let e as LLMBackendError where e.shrinkable {
            guard let smaller = base.shrunk() else { throw e }
            return try await DiaryWriter(smaller, timeZone: timeZone, voice: voice).write(inputs, languageSample: languageSample)
        }
    }

    private func writeOnce(_ inputs: [Input], languageSample: String) async throws -> Output {
        let use = Self.usable(inputs)
        let people = Self.names(use) { $0.people }, things = Self.names(use) { $0.things }
        guard !Self.isBrief(inputs) else {
            return Output(status: .brief, diary: nil, calls: 0, dropped: 0)
        }
        let labels = Dictionary(uniqueKeysWithValues: use.enumerated().map { ("S\($0.offset + 1)", $0.element) })
        let byRef = Dictionary(use.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        let labelled = Self.isLabelled(inputs)
        // 不放词表：输入已经是摘要，词表只在事后纠正拼写
        let lang = Summarizer.languageLine(for: languageSample)
        let session = base.backend.open(timeout: base.timeout)
        var calls = 0
        // 日记比一段的摘要长（概述 + 要点 + 决定 + 待办，长的一天有二十来条）：1000 token 常常不够，第一次就被截断再重试。
        // 接服务时起步给 3000；端侧模型有自己的上限（preferredMaxOutput），照它的来
        let maxOutput = base.backend.preferredMaxOutput == nil ? max(base.maxOutput, 3000) : base.maxOutput
        func ask(_ system: String, _ user: String, shape: ReplyShape) async throws -> [String: Any] {
            // 回复不可用时再试一次、截断时加大输出上限（LLMAsk）
            let (o, n) = try await LLMAsk(channel: session, maxOutput: maxOutput, label: "日记")
                .run(system, user, shape: shape, parse: JSONReply.object)
            calls += n
            return o
        }

        // 一次放不下就分组，各组各写一份，再把各组的概述合成一段
        let rendered = use.enumerated().map { (input: $0.element, text: render($0.element, label: "S\($0.offset + 1)", labelled: labelled)) }
        var groups: [[(input: Input, text: String)]] = [], cur: [(input: Input, text: String)] = [], used = 0
        for r in rendered {
            let cost = Summarizer.estimateTokens(r.text) + 2
            if !cur.isEmpty, used + cost > base.budget { groups.append(cur); cur = []; used = 0 }
            cur.append(r)
            used += cost
        }
        if !cur.isEmpty { groups.append(cur) }
        let day = Self.target(use)

        var overviews: [String] = [], highlights: [DiaryItem] = [], decisions: [DiaryItem] = [], todos: [DiaryItem] = []
        var dropped = 0, dropReasons: [String: Int] = [:], droppedMine = 0
        for g in groups {
            // 每组按这组自己的大小定长度；只有一组时就是全天
            let t = groups.count == 1 ? day : Self.target(g.map(\.input))
            let system = labelled ? Self.labelledPrompt(t, voice: voice) : Self.prompt(t)
            let o = try await ask(system + "\n" + lang, "Conversations:\n\n" + g.map(\.text).joined(separator: "\n\n"),
                                  shape: labelled ? Self.labelledShape(t) : Self.shape(t))
            let ov = JSONReply.string(o, "overview", "summary")
            if !ov.isEmpty { overviews.append(ov) }
            let h = Self.items(o["highlights"] ?? o["key_points"], labels: labels) { !($0.summary?.keyPoints.isEmpty ?? true) }
            let d = Self.items(o["decisions"], labels: labels) { !($0.summary?.decisions.isEmpty ?? true) }
            var td = Self.items(o["todos"] ?? o["action_items"], labels: labels) { !($0.summary?.todos.isEmpty ?? true) }
            if labelled {
                // 他的待办：出处那几段里要有他的待办，不然算别人的（留着，不丢）。别人的待办和出处里他的某条待办说的是同一件事时算他的
                let mt = Self.items(o["my_todos"], labels: labels) { !($0.summary?.todos.isEmpty ?? true) }
                let mine = mt.kept.map { t -> DiaryItem in
                    var t = t
                    t.mine = t.refs.contains { !(byRef[$0]?.summary?.myTodos.isEmpty ?? true) }
                    if t.mine == false { droppedMine += 1 }
                    t.owner = nil
                    return t
                }
                let others = td.kept.map { t -> DiaryItem in
                    var t = t
                    t.mine = t.refs.contains { r in (byRef[r]?.summary?.myTodos ?? []).contains { TextSimilarity.similar($0, t.text) } }
                    if t.mine == true { t.owner = nil }
                    return t
                }
                var why = td.why
                for (k, n) in mt.why { why["mine.\(k)", default: 0] += n }
                td = (mine + others, td.dropped + mt.dropped, why)
            }
            // 要点没有负责人
            highlights += h.kept.map { DiaryItem(text: $0.text, refs: $0.refs) }
            decisions += d.kept
            todos += td.kept
            dropped += h.dropped + d.dropped + td.dropped
            for (name, r) in [("highlights", h.why), ("decisions", d.why), ("todos", td.why)] {
                for (k, n) in r { dropReasons["\(name):\(k)", default: 0] += n }
            }
        }
        var overview = overviews.first
        if overviews.count > 1 {
            let o = try await ask((labelled ? Self.labelledOverviewPrompt(day, voice: voice) : Self.overviewPrompt(day)) + "\n" + lang, overviews.enumerated().map { "Part \($0.offset + 1): \($0.element)" }
                .joined(separator: "\n\n"), shape: Self.overviewShape(day))
            let ov = JSONReply.string(o, "overview", "summary")
            overview = ov.isEmpty ? overviews.joined(separator: " ") : ov
        }
        let c = GlossaryCorrector(terms: base.glossary)
        var droppedOwners = 0
        let checked = todos.map { t -> DiaryItem in
            let ok = Self.ownerOK(t.owner, refs: t.refs, byRef: byRef)
            if t.owner != nil, !ok { droppedOwners += 1 }
            return DiaryItem(text: t.text, owner: ok ? t.owner : nil, refs: t.refs, mine: t.mine)
        }
        var cleanTodos = Self.dedupe(checked)
        // 和某条待办说的是同一件事的决定去掉：有动作的归待办
        var cleanDecisions = Self.dedupe(decisions).filter { d in !cleanTodos.contains { TextSimilarity.similar($0.text, d.text) } }
        // 要点不重复定了的事和待办
        var cleanHighlights = Self.dedupe(highlights).filter { h in
            !(cleanTodos + cleanDecisions).contains { TextSimilarity.similar($0.text, h.text) }
        }
        let duplicates = todos.count - cleanTodos.count + decisions.count - cleanDecisions.count
            + highlights.count - cleanHighlights.count
        var overheard = 0
        if labelled {
            // 他的待办在前；要点和定了的事按「他说过话的段」排前面，旁听段的要点最多占三分之一
            cleanTodos = cleanTodos.enumerated().sorted { a, b in
                (a.element.mine == true) != (b.element.mine == true) ? a.element.mine == true : a.offset < b.offset
            }.map(\.element)
            let n = cleanHighlights.count
            cleanHighlights = Self.ordered(cleanHighlights, byRef, overheardCap: Self.overheardHighlights(day))
            overheard = n - cleanHighlights.count
            cleanDecisions = Self.ordered(cleanDecisions, byRef)
        }
        let diary = Diary(overview: overview.map { c.correct($0).text },
                          highlights: Array(cleanHighlights.prefix(day.maxHighlights)).map { Self.fix($0, c) },
                          decisions: Array(cleanDecisions.prefix(Self.maxDecisions)).map { Self.fix($0, c) },
                          todos: Array(cleanTodos.prefix(Self.maxTodos)).map { Self.fix($0, c) },
                          people: Array(people.prefix(Self.maxPeople)), things: Array(things.prefix(Self.maxThings)))
        if overheard > 0 { dropReasons["highlights:overheard", default: 0] += overheard }
        return Output(status: .diary, diary: diary, calls: calls, dropped: dropped, duplicates: duplicates, droppedOwners: droppedOwners,
                      dropReasons: dropReasons, droppedMine: droppedMine, labelled: labelled)
    }

    /// 回复的结构（端侧模型做结构化生成用；OpenAI 兼容服务不发）
    static func shape(_ t: Target) -> ReplyShape {
        .object("DayDiary", [
            .init("overview", .text("\(t.sentencesText) on the day's recorded conversations, the most important thing first")),
            .init("highlights", .list(.object("Highlight", [
                .init("text", .text()),
                .init("refs", .list(.text("A conversation label such as S1"), max: 4)),
            ]), max: t.maxHighlights)),
            .init("decisions", .list(.object("Decision", [
                .init("text", .text()),
                .init("refs", .list(.text("A conversation label such as S1"), max: 4)),
            ]), max: maxDecisions)),
            .init("todos", .list(.object("Todo", [
                .init("text", .text()),
                .init("owner", .text("A person's name from those conversations, or empty")),
                .init("refs", .list(.text("A conversation label such as S2"), max: 4)),
            ]), max: maxTodos)),
        ])
    }

    static var shape: ReplyShape { shape(.long) }

    /// 带标签的一天：多一栏 my_todos
    static func labelledShape(_ t: Target) -> ReplyShape {
        .object("DayDiary", [
            .init("overview", .text("\(t.sentencesText) on the wearer's day, the most important thing first")),
            .init("highlights", .list(.object("Highlight", [
                .init("text", .text()),
                .init("refs", .list(.text("A conversation label such as S1"), max: 4)),
            ]), max: t.maxHighlights)),
            .init("decisions", .list(.object("Decision", [
                .init("text", .text()),
                .init("refs", .list(.text("A conversation label such as S1"), max: 4)),
            ]), max: maxDecisions)),
            .init("my_todos", .list(.object("MyTodo", [
                .init("text", .text()),
                .init("refs", .list(.text("A conversation label such as S2"), max: 4)),
            ]), max: maxTodos)),
            .init("todos", .list(.object("Todo", [
                .init("text", .text()),
                .init("owner", .text("A person's name from those conversations, or empty")),
                .init("refs", .list(.text("A conversation label such as S2"), max: 4)),
            ]), max: maxTodos)),
        ])
    }

    /// 旁听段的要点最多几条（这天有他说过话的段时）
    static func overheardHighlights(_ t: Target) -> Int { max(1, t.maxHighlights / 3) }

    static func overviewShape(_ t: Target) -> ReplyShape {
        .object("DayOverview", [.init("overview", .text(t.sentencesText))])
    }

    static var overviewShape: ReplyShape { overviewShape(.long) }

    func render(_ i: Input, label: String, labelled: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        let s = i.summary ?? ConversationSummary()
        var t = "[\(label) \(f.string(from: i.wallStart))–\(f.string(from: i.wallEnd))] \(s.title)\nSummary: \(s.summary)"
        if !s.keyPoints.isEmpty { t += "\nKey points:\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") }
        if !s.decisions.isEmpty { t += "\nDecisions:\n" + s.decisions.map { "- \($0)" }.joined(separator: "\n") }
        if labelled {
            // 他说了多少；他的待办和别人的分开列（不带标签写的段摘要：只有 To-dos）
            if let share = i.wearerShare {
                t += share > 0 ? "\nWearer: spoke about \(max(1, Int((share * 100).rounded())))% of the time" : "\nWearer: did not speak (overheard)"
            }
            if s.labelled {
                if !s.myTodos.isEmpty { t += "\nWearer's to-dos:\n" + s.myTodos.map { "- \($0)" }.joined(separator: "\n") }
                if !s.otherTodos.isEmpty { t += "\nOther to-dos:\n" + s.otherTodos.map { "- \($0)" }.joined(separator: "\n") }
            } else if !s.todos.isEmpty {
                t += "\nTo-dos:\n" + s.todos.map { "- \($0)" }.joined(separator: "\n")
            }
        } else if !s.todos.isEmpty {
            t += "\nTo-dos:\n" + s.todos.map { "- \($0)" }.joined(separator: "\n")
        }
        // 用户在这里做了重点标记：把标记处的原话一起给模型
        if !i.marks.isEmpty { t += "\nMarked by the user as important:\n" + i.marks.map { "- \"\($0)\"" }.joined(separator: "\n") }
        return t
    }

    // MARK: 校验出处

    /// 解析模型给的条目，只留下出处存在、而且出处那一段确实有这类内容的；返回留下的和丢掉的条数
    static func items(_ v: Any?, labels: [String: Input], allowed: (Input) -> Bool)
        -> (kept: [DiaryItem], dropped: Int, why: [String: Int]) {
        guard let arr = v as? [Any] else { return ([], 0, [:]) }
        var kept: [DiaryItem] = [], dropped = 0, why: [String: Int] = [:]
        for e in arr {
            guard let o = e as? [String: Any] else { dropped += 1; why["notObject", default: 0] += 1; continue }
            let text = Summarizer.stripBullet(Summarizer.clean((o["text"] ?? o["item"] ?? o["task"]) as? String ?? ""))
            guard !text.isEmpty, !Summarizer.isNone(text) else { continue }
            var refs: [ConversationRef] = []
            let given = refLabels(o["refs"] ?? o["ref"] ?? o["sources"])
            for l in given {
                if let i = labels[l], allowed(i), !refs.contains(i.ref) { refs.append(i.ref) }
            }
            guard !refs.isEmpty else {
                dropped += 1
                // 为什么丢：没写出处、出处的编号不存在、还是出处那段没有这类内容（只记原因和条数，不记内容）
                let reason = given.isEmpty ? "noRefs" : given.contains { labels[$0] != nil } ? "sourceHasNone" : "unknownRef"
                why[reason, default: 0] += 1
                continue
            }
            let owner = Summarizer.clean(o["owner"] as? String ?? "")
            kept.append(DiaryItem(text: text, owner: owner.isEmpty || Summarizer.isNone(owner) ? nil : owner, refs: refs))
        }
        return (kept, dropped, why)
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
                if i.mine == true { out[k].mine = true }
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
        DiaryItem(text: c.correct(i.text).text, owner: i.owner.map { c.correct($0).text }, refs: i.refs, mine: i.mine)
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

/// 带「认出我的声音」标签时，段摘要和日记怎么称呼佩戴者
public enum WearerVoice: Sendable, Hashable {
    /// 「你」：「你答应了王总周五前发报价」
    case you
    /// 和没有标签时一样，写「录到的谈话」，不用「我」「你」
    case neutral

    /// 带标签时默认用哪种：只改这一处
    public static let labelled: WearerVoice = .you
}
