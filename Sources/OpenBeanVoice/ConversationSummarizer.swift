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
        /// 模型说是佩戴者的、但对不上佩戴者说的话的待办：待办留着，只是不算他的
        public var droppedMine: Int = 0
        /// 要点归属：模型说是本人的、代码没核实（改成不知道或别人）的条数
        public var unverifiedMine: Int = 0
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
    - decisions: at most 3 things the speakers clearly settled that still matter after this conversation ends. Not \
    suggestions, ideas, options under discussion, principles or open questions. Not how this conversation itself runs \
    (who speaks first, the agenda, taking turns), ordering food or drinks, who pays the bill, or "let's talk about it \
    later". [] when nothing was settled, which is common.
    - todos: at most 2 concrete actions that someone committed to or was asked to do after this conversation. Add the \
    owner only when a person's name is said in the transcript, and the deadline when one is said. General advice and \
    things done on the spot are not to-dos. [] when there are none.
    - Put each item in only one list: an action someone will do is a to-do, not also a decision.
    - people: names of people who speak or are mentioned, written exactly as in the transcript. Only real names: not \
    pronouns (I, you, he, 我, 你, 他), not roles or titles (manager, speaker, 店长, 督导, 员工, 发言人). \
    [] when there are none.
    - things: at most 5 named projects, products, companies or places that are said in this transcript, written exactly \
    as in the transcript.
    - A line that ends with \(markNote) is where the user marked the moment as important on the recorder (usually \
    just before saying it). Make sure the summary or a key point covers what was said there.
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
    - decisions: the decisions from the parts, merged; at most 3, only things that were really settled and still matter \
    after the conversation.
    - todos: the to-dos from the parts, merged and deduplicated; at most 2, the most concrete ones (an owner, a \
    deadline or a number). An item is either a to-do or a decision, never both.
    - people, things: write [] (they are collected from the parts).
    Only use what is in the part summaries.
    """

    // MARK: 带「认出我的声音」标签时

    /// 送给模型的转写里每句前面的说话人：佩戴者 / 别人 / 不知道
    public static let meTag = "[me]", otherTag = "[other]", unknownTag = "[?]"

    /// 每句前面加说话人：`wearer` 里的是 `[me]`，`other` 里的是 `[other]`，其余 `[?]`。
    /// 别人也用「我」说自己的事（「我做的产品……」），只标本人那几句时模型会把所有的「我」都当成佩戴者，所以三种都标
    public static func tagSpeakers(_ lines: [TimedLine], wearer: Set<Int>, other: Set<Int>) -> [TimedLine] {
        guard !wearer.isEmpty else { return lines }
        return lines.enumerated().map { i, l in
            let tag = wearer.contains(i) ? meTag : other.contains(i) ? otherTag : unknownTag
            return TimedLine(start: l.start, text: tag + " " + l.text)
        }
    }

    static let labelledFields = """
    {"title": "...", "summary": "...", "kind": "conversation", "key_points": [{"text": "...", "said_by": "me"}], \
    "decisions": ["..."], "my_todos": ["..."], "todos": ["..."], "people": ["..."], "things": ["..."]}
    """

    /// 说话人标签的规则和怎么称呼佩戴者
    static func wearerNote(_ voice: WearerVoice) -> String {
        let me = """
        Every line starts with who said it. \(meTag): the person wearing the recorder; this is his or her diary, and he or \
        she is called "the wearer" below. \(otherTag): someone else. \(unknownTag): the speaker is not known.
        - Only \(meTag) lines are the wearer speaking. "I", "my", "我", "我的" in an \(otherTag) line mean that other \
        speaker, never the wearer: "\(otherTag) 我做的产品是咖啡袋" is the other speaker's product, not the wearer's.
        - Never attribute a \(unknownTag) line to the wearer.
        - For a promise or an offer between two people, the direction comes from who said the committing line: \
        "\(meTag) 我来安排" means the wearer will do it; "\(otherTag) 我帮你安排" means the other person will do it for the \
        wearer. When it is not clear who will do what, write it neutrally ("a trial class of up to 20 people was agreed").
        """
        switch voice {
        case .you:
            return me + "\nWrite \"you\" (in Chinese 你) only for what \(meTag) lines say, decide or promise, or what was asked of " +
                "the wearer. Write what other people said as \"Wang said…\", \"someone said…\" or \"you were told…\", never as " +
                "something \"you\" did, have or said. Never write as \"I\"."
        case .neutral:
            return me + "\nDescribe what was recorded; do not write as \"I\" or \"you\", and do not call anyone \"the wearer\" in the reply."
        }
    }

    static let labelledKeyPoints = """
    - key_points: up to 5 short points with the important facts, numbers, ideas and advice: both what the wearer said, \
    decided or promised, and what other people told the wearer. Each is {"text": "...", "said_by": "..."}: said_by is \
    "me" when the point comes from \(meTag) lines, "other" when it comes from \(otherTag) lines, "?" when you cannot tell. \
    Write text as a neutral statement without "I" or "you" ("plans to send the quote by Friday", "Wang's company makes \
    coffee bags"), so that it reads right whoever said it. [] when there are none.
    """

    static func labelledRules(_ voice: WearerVoice) -> String {
        """
        \(labelledKeyPoints)
        - decisions: at most 3 things the speakers clearly settled that still matter after this conversation ends. Not \
        suggestions, ideas, options under discussion, principles or open questions. Not how this conversation itself runs \
        (who speaks first, the agenda, taking turns), ordering food or drinks, who pays the bill, or "let's talk about it \
        later". [] when nothing was settled, which is common.
        - my_todos: at most 2 concrete actions the wearer committed to (in a \(meTag) line), or was asked to do, after this \
        conversation; the deadline when one is said. Not what another speaker offered to do for the wearer. [] when there \
        are none.
        - todos: at most 2 concrete actions that other people committed to or were asked to do after this conversation, \
        including what they offered to do for the wearer. Add the owner only when a person's name is said in the \
        transcript, and the deadline when one is said. [] when there are none.
        - General advice and things done on the spot are not to-dos. Put each item in only one list: an action someone \
        will do is a to-do, not also a decision, and a to-do of the wearer's is not also in todos.
        - people: names of people who speak or are mentioned, written exactly as in the transcript. Only real names: not \
        pronouns (I, you, he, 我, 你, 他), not roles or titles (manager, speaker, 店长, 督导, 员工, 发言人). \
        [] when there are none.
        - things: at most 5 named projects, products, companies or places that are said in this transcript, written exactly \
        as in the transcript.
        - A line that ends with \(markNote) is where the user marked the moment as important on the recorder (usually \
        just before saying it). Make sure the summary or a key point covers what was said there.
        Leave a list empty rather than guessing. Never invent people, numbers, dates, decisions or to-dos.
        \(wearerNote(voice))
        """
    }

    static func labelledSegmentPrompt(_ voice: WearerVoice) -> String {
        """
        You summarise one conversation from a voice recording made during the wearer's day: a meeting, a call, a chat, a \
        note to self, or background audio. The transcript comes from speech recognition, so it may contain recognition \
        errors and filler words; read through them.
        Reply with ONE JSON object and nothing else, no code fences:
        \(labelledFields)
        - title: a few words naming what was talked about, at most 10 words (or 16 Chinese characters), no quotes or time.
        - summary: 1 to 3 sentences on what was talked about. A short conversation gets one short sentence.
        - kind: "conversation" when two or more people talk with each other; "monologue" when one person dictates notes or \
        talks to themselves; "media" when it is mostly a TV, a video, a podcast, a radio or announcements; "fragment" when \
        there is too little to say what it is about.
        \(labelledRules(voice))
        """
    }

    static func labelledPartPrompt(_ voice: WearerVoice) -> String {
        """
        You summarise one part of a long conversation from a voice recording made during the wearer's day. The transcript \
        comes from speech recognition, so it may contain recognition errors and filler words; read through them.
        Reply with ONE JSON object and nothing else, no code fences:
        \(labelledFields)
        - title: a few words naming the topic of this part.
        - summary: 1 to 3 sentences on what was said in this part.
        - kind: as for the whole conversation: "conversation", "monologue", "media" or "fragment".
        \(labelledRules(voice))
        """
    }

    static func labelledMergePrompt(_ voice: WearerVoice) -> String {
        """
        You are given summaries of consecutive parts of one conversation from a voice recording made during the wearer's \
        day, in order. Combine them into one summary of the whole conversation. Key points are marked with who said \
        them: \(meTag) the wearer, \(otherTag) someone else, \(unknownTag) not known.
        Reply with ONE JSON object and nothing else, no code fences:
        \(labelledFields)
        - title: a few words naming what the whole conversation was about, at most 10 words (or 16 Chinese characters).
        - summary: 1 to 3 sentences covering the whole conversation.
        - kind: "conversation", "monologue", "media" or "fragment", for the conversation as a whole.
        - key_points: up to 5 of the most important points, both the wearer's and what others told the wearer; merge \
        duplicates. Keep each point's said_by from the parts ("me", "other" or "?"); text is a neutral statement without \
        "I" or "you".
        - decisions: the decisions from the parts, merged; at most 3, only things that were really settled and still matter \
        after the conversation.
        - my_todos: the wearer's to-dos from the parts, merged and deduplicated; at most 2.
        - todos: the other people's to-dos from the parts, merged and deduplicated; at most 2, the most concrete ones (an \
        owner, a deadline or a number). An item is either a to-do or a decision, never both.
        - people, things: write [] (they are collected from the parts).
        Only use what is in the part summaries. The wearer is the person whose diary this is; \
        \(voice == .you ? "write \"you\" (in Chinese 你) only for what the wearer said, decided or promised, never for what other people said, and never write as \"I\"." : "do not write as \"I\" or \"you\".")
        """
    }

    /// 送给模型的转写里，用户做了重点标记的那句后面加这一句（「用户在这里做了重点标记」）
    public static let markNote = "[MARKED: the user marked this as important]"

    /// 把标记写进送给模型的那份转写：`marked` 里的句子（下标）后面加 `markNote`
    public static func annotate(_ lines: [TimedLine], marked: Set<Int>) -> [TimedLine] {
        guard !marked.isEmpty else { return lines }
        return lines.enumerated().map { i, l in marked.contains(i) ? TimedLine(start: l.start, text: l.text + " " + markNote) : l }
    }

    /// `marked`：用户在录音豆上做了重点标记的句子（`lines` 的下标，见 MarkPlacement）。
    /// `wearer`：「认出我的声音」标成佩戴者说的句子（`lines` 的下标）；`other`：标成别人说的句子（isWearer == false），
    /// 其余是不知道。wearer 为 nil = 这条录音没有能用的标签（开关关着、录音豆没戴、还没扫），提示词和以前一字不差；
    /// 有标签但这段一句本人的都没有（空集合）时提示词也不变，只是摘要记下「带标签写的、没有他的待办」（mine = []），
    /// 要点由代码按别人的话归属
    public func summarize(_ lines: [TimedLine], marked: Set<Int> = [], wearer: Set<Int>? = nil, other: Set<Int> = [],
                          voice: WearerVoice = .labelled) async throws -> Result {
        do { return try await summarizeOnce(lines, marked: marked, wearer: wearer, other: other, voice: voice) } catch let e as LLMBackendError where e.shrinkable {
            guard let smaller = base.shrunk() else { throw e }
            return try await ConversationSummarizer(smaller).summarize(lines, marked: marked, wearer: wearer, other: other, voice: voice)
        }
    }

    private func summarizeOnce(_ lines: [TimedLine], marked: Set<Int>, wearer: Set<Int>?, other: Set<Int>,
                               voice: WearerVoice) async throws -> Result {
        let text = lines.map(\.text).joined()
        let mine = (wearer ?? []).filter { lines.indices.contains($0) }
        let others = other.subtracting(mine).filter { lines.indices.contains($0) }
        let tagged = !mine.isEmpty
        let chunks = Summarizer.chunk(Self.annotate(Self.tagSpeakers(lines, wearer: mine, other: others), marked: marked),
                                      budget: base.budget)
        guard !chunks.isEmpty, Summarizer.estimateTokens(text) >= Summarizer.minTokens else {
            return Result(summary: nil, kind: "fragment", calls: 0, droppedNames: 0)
        }
        // 不把词表放进提示词：模型会把词表原样抄进「人」和「事」。词表只在事后纠正拼写（finish）
        let lang = Summarizer.languageLine(for: text)
        let session = base.backend.open(timeout: base.timeout)
        var calls = 0
        func ask(_ system: String, _ user: String) async throws -> Parsed {
            // 回复不可用时再试一次、截断时加大输出上限（LLMAsk）；网络错误直接抛
            let (p, n) = try await LLMAsk(channel: session, maxOutput: base.maxOutput, label: "段摘要")
                .run(system, user, shape: tagged ? Self.labelledShape : Self.shape, parse: Self.parse)
            calls += n
            return p
        }
        let segmentPrompt = tagged ? Self.labelledSegmentPrompt(voice) : Self.segmentPrompt
        let partPrompt = tagged ? Self.labelledPartPrompt(voice) : Self.partPrompt
        let mergePrompt = tagged ? Self.labelledMergePrompt(voice) : Self.mergePrompt

        var merged: Parsed
        if chunks.count == 1 {
            merged = try await ask(segmentPrompt + "\n" + lang, "Transcript:\n" + chunks[0].map(Summarizer.line).joined(separator: "\n"))
        } else {
            var parts: [Parsed] = []
            for (i, c) in chunks.enumerated() {
                let user = "Part \(i + 1) of \(chunks.count). Transcript:\n" + c.map(Summarizer.line).joined(separator: "\n")
                if let p = try await Summarizer.skippable({ try await ask(partPrompt + "\n" + lang, user) }) { parts.append(p) }
                else if await base.backend.check() != .ok { throw URLError(.cannotConnectToHost) }
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
                    next.append(try await ask(mergePrompt + "\n" + lang, user))
                }
                level = next
            }
            merged = level[0]
            merged.people = Self.unique(parts.flatMap(\.people))
            merged.things = Self.unique(parts.flatMap(\.things))
        }
        // 核对「是他的待办」用：本人说的句子和紧挨着的前后句（别人让他做的事常在他前后那句说）
        let near = wearer == nil ? nil : Set(mine.flatMap { [$0 - 1, $0, $0 + 1] }).filter { lines.indices.contains($0) }.sorted()
            .map { lines[$0].text }.joined(separator: "\n")
        // 核对要点是谁说的用：只是本人的句子 / 只是别人的句子（不知道的句子两边都不算）
        let speakers = wearer == nil ? nil : (me: mine.sorted().map { lines[$0].text }.joined(separator: "\n"),
                                              other: others.sorted().map { lines[$0].text }.joined(separator: "\n"))
        return finish(merged, transcript: text, calls: calls, wearerText: near, wearerLines: mine.count, speakers: speakers)
    }

    /// 回复的结构（端侧模型做结构化生成用；OpenAI 兼容服务不发）。上限比代码里的封顶宽一点，收尾时再封顶
    static let shape = ReplyShape.object("ConversationSummary", [
        .init("title", .text("A few words naming what was talked about")),
        .init("summary", .text("1 to 3 sentences")),
        .init("kind", .choice(["conversation", "monologue", "media", "fragment"])),
        .init("key_points", .list(.text(), max: maxKeyPoints)),
        .init("decisions", .list(.text(), max: maxDecisions, "Only what was clearly settled; usually empty")),
        .init("todos", .list(.text(), max: maxTodos, "Concrete actions someone committed to; usually empty")),
        .init("people", .list(.text(), max: maxPeople, "Real names written exactly as in the transcript")),
        .init("things", .list(.text(), max: maxThings, "Named projects, products, companies or places")),
    ])

    /// 带标签时的结构：多一栏 my_todos（佩戴者的待办）
    static let labelledShape = ReplyShape.object("ConversationSummary", [
        .init("title", .text("A few words naming what was talked about")),
        .init("summary", .text("1 to 3 sentences")),
        .init("kind", .choice(["conversation", "monologue", "media", "fragment"])),
        .init("key_points", .list(.object("KeyPoint", [
            .init("text", .text("A neutral statement without I or you")),
            .init("said_by", .choice(["me", "other", "?"])),
        ]), max: maxKeyPoints)),
        .init("decisions", .list(.text(), max: maxDecisions, "Only what was clearly settled; usually empty")),
        .init("my_todos", .list(.text(), max: maxTodos, "Actions the wearer committed to or was asked to do; usually empty")),
        .init("todos", .list(.text(), max: maxTodos, "Actions other people committed to; usually empty")),
        .init("people", .list(.text(), max: maxPeople, "Real names written exactly as in the transcript")),
        .init("things", .list(.text(), max: maxThings, "Named projects, products, companies or places")),
    ])

    /// 收尾：词表纠正；人名去掉代词和泛称、和专有名词一样要在转写里找得到；待办去掉泛称的负责人；
    /// 和待办相近的决定去掉（同一件事只归一类，有动作的算待办）；短段不出待办；封顶。
    /// `wearerText`：本人说的句子和前后句（nil = 没有标签）；`wearerLines`：这段里本人说了几句。
    /// 模型说是他的待办，代码再核一遍，对不上的待办留着，只是不算他的；他的待办排在前面。核法分两种：
    /// - 他确实参与了这段（说了 `minWearerLines` 句以上）：待办在整段转写里找得到就算。别人交代给他的事（教练让他练什么、
    ///   朋友请他帮什么）是别人说的，常常不挨着他的话；真机上按「要和他自己的话重合」核，9 条里错降了 6 条（2026-11-18）。
    /// - 他只说了一两句：要和他自己的话或前后句有重合才算，免得把旁人之间的事算给他。
    /// `speakers`：本人说的句子 / 别人说的句子（nil = 没有标签）。每条要点是谁说的由代码按字面重合核一遍（`attribute`）
    func finish(_ p: Parsed, transcript: String, calls: Int, wearerText: String? = nil, wearerLines: Int = 0,
                speakers: (me: String, other: String)? = nil) -> Result {
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
        func clean(_ xs: [String]) -> [String] { xs.map { NameFilter.stripGenericOwner(fix($0)) }.filter { !$0.isEmpty } }
        var mineKept: [String] = [], demoted: [String] = []
        if let wearerText {
            let took = wearerLines >= Self.minWearerLines
            let hay = took ? c.correct(transcript).text + "\n" + transcript : c.correct(wearerText).text + "\n" + wearerText
            let meLines = speakers.map { $0.me.components(separatedBy: "\n") } ?? []
            let otherLines = speakers.map { $0.other.components(separatedBy: "\n") } ?? []
            for t in TextSimilarity.dedupe(clean(p.myTodos)) {
                if !wearerText.isEmpty, Self.overlaps(t, hay), !Self.offeredByOther(t, me: meLines, other: otherLines) {
                    mineKept.append(t)
                } else {
                    demoted.append(t)
                }
            }
        }
        var others = TextSimilarity.dedupe(demoted + clean(p.todos)).filter { o in !mineKept.contains { TextSimilarity.similar($0, o) } }
        if transcript.count < Self.minCharsForTodos { mineKept = []; others = [] }
        mineKept = Array(mineKept.prefix(Self.maxTodos))
        others = Array(others.prefix(Self.maxTodos - mineKept.count))
        let todos = mineKept + others
        let decisions = TextSimilarity.dedupe(p.decisions.map(fix)).filter { d in !todos.contains { TextSimilarity.similar($0, d) } }
        let keyPoints = Array(p.keyPoints.map(fix).prefix(Self.maxKeyPoints))
        var said: [Speaker]?, unverified = 0
        if let speakers {
            let me = c.correct(speakers.me).text + "\n" + speakers.me, other = c.correct(speakers.other).text + "\n" + speakers.other
            said = keyPoints.indices.map { i in
                let claim = i < p.keyPointSaid.count ? p.keyPointSaid[i] : ""
                let v = Self.attribute(keyPoints[i], claim: claim, me: me, other: other)
                if Self.claimsMe(claim), v != .me { unverified += 1 }
                return v
            }
        }
        let s = ConversationSummary(title: fix(p.title), summary: fix(p.summary), keyPoints: keyPoints,
                                    decisions: Array(decisions.prefix(Self.maxDecisions)), todos: todos,
                                    people: Array(people.prefix(Self.maxPeople)), things: Array(things.prefix(Self.maxThings)),
                                    mine: wearerText == nil ? nil : Array(0..<mineKept.count), said: said)
        return Result(summary: s, kind: kind, calls: calls, droppedNames: max(dropped, 0),
                      droppedGeneric: rawPeople.count - named.count, droppedMine: demoted.count, unverifiedMine: unverified)
    }

    /// 别人主动说要替他做的事（「[other] 我下周帮你安排试用课」）不是他的待办：和这条待办最像的一句是别人说的、
    /// 又是「我帮你 / 我给你 / 我替你」这类主动提出的说法，就不算他的
    static func offeredByOther(_ todo: String, me: [String], other: [String]) -> Bool {
        let bestMe = me.map { overlapScore(todo, $0) }.max() ?? 0
        guard let best = other.max(by: { overlapScore(todo, $0) < overlapScore(todo, $1) }) else { return false }
        let score = overlapScore(todo, best)
        guard score >= 2, score > bestMe else { return false }
        let l = best.lowercased()
        return ["帮你", "给你", "替你", "为你", "我来", "我帮", "i'll", "i will", "let me", "for you"].contains { l.contains($0) }
    }

    /// 本人在一段里至少说这么多句，才算他参与了这段
    static let minWearerLines = 3

    /// 很常见、说明不了是同一件事的两字词
    static let commonBigrams: Set<String> = ["我们", "你们", "他们", "这个", "那个", "一下", "就是", "然后", "什么", "没有", "可以",
                                             "一个", "这样", "那样", "知道", "觉得", "现在", "还是", "的话", "因为", "所以", "但是"]

    /// 待办和（本人说的）原话在字面上有没有重合：中文至少两个不常见的相同两字词，或者一个相同的英文词（四个字母以上）或数字
    static func overlaps(_ item: String, _ text: String) -> Bool { overlapScore(item, text) >= 2 }

    static func claimsMe(_ claim: String) -> Bool { ["me", "wearer", "i", "我"].contains(claim.lowercased()) }
    static func claimsOther(_ claim: String) -> Bool { ["other", "others", "someone else", "别人"].contains(claim.lowercased()) }

    /// 一条要点是谁说的。模型给的 said_by 只是一个说法，代码按字面重合核：和本人的句子重合得多算本人，
    /// 和别人的句子重合得多算别人。说是本人、但核不出来的算不知道（不是本人）；说是别人、又没有本人的证据的算别人
    static func attribute(_ point: String, claim: String, me: String, other: String) -> Speaker {
        let sm = me.isEmpty ? 0 : overlapScore(point, me), so = other.isEmpty ? 0 : overlapScore(point, other)
        let byMe = sm >= 2 && sm > so, byOther = so >= 2 && so >= sm
        if claimsOther(claim) { return byMe && so < 2 ? .unknown : .other }
        return byMe ? .me : byOther ? .other : .unknown
    }

    /// 字面重合的分数：相同的不常见中文两字词个数，加上相同的英文词（四个字母以上）或数字个数的两倍
    static func overlapScore(_ item: String, _ text: String) -> Int {
        func tokens(_ s: String) -> (cjk: Set<String>, words: Set<String>) {
            var cjk = Set<String>(), words = Set<String>(), run: [Character] = [], word = ""
            func flushRun() {
                if run.count > 1 { for i in 0..<(run.count - 1) { cjk.insert(String(run[i...i + 1])) } }
                run = []
            }
            func flushWord() {
                if word.count >= 4 || (word.count >= 2 && word.allSatisfy(\.isNumber)) { words.insert(word) }
                word = ""
            }
            for ch in s.lowercased() {
                if let u = ch.unicodeScalars.first, u.value >= 0x2E80, ch.isLetter {
                    flushWord(); run.append(ch)
                } else if ch.isLetter || ch.isNumber {
                    flushRun(); word.append(ch)
                } else {
                    flushRun(); flushWord()
                }
            }
            flushRun(); flushWord()
            return (cjk.subtracting(commonBigrams), words)
        }
        let a = tokens(item), b = tokens(text)
        return a.cjk.intersection(b.cjk).count + 2 * a.words.intersection(b.words).count
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
        /// 佩戴者的待办（只有带标签的提示词才要这一栏）
        var myTodos: [String] = []
        /// 每条要点模型说是谁说的（"me" / "other" / "?"；没给是 ""），和 keyPoints 一一对应
        var keyPointSaid: [String] = []
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
        let kp = JSONReply.attributed(obj, "key_points", "keyPoints")
        p.keyPoints = kp.map(\.text)
        p.keyPointSaid = kp.map(\.saidBy)
        p.decisions = JSONReply.list(obj, "decisions", "decided")
        p.todos = JSONReply.list(obj, "todos", "action_items", "to_dos")
        p.myTodos = JSONReply.list(obj, "my_todos", "myTodos", "wearer_todos")
        p.people = JSONReply.list(obj, "people", "names")
        p.things = JSONReply.list(obj, "things", "entities")
        return p
    }

    static func render(_ p: Parsed, index: Int) -> String {
        var t = "Part \(index): \(p.title)\nSummary: \(p.summary)"
        // 带标签的部分才有「佩戴者的待办」；没有时和以前一样
        // 要点带着各部分说的说话人（带标签时）
        let points = p.keyPoints.enumerated().map { i, k in
            let by = i < p.keyPointSaid.count ? p.keyPointSaid[i] : ""
            return claimsMe(by) ? "\(meTag) \(k)" : claimsOther(by) ? "\(otherTag) \(k)" : by == "?" ? "\(unknownTag) \(k)" : k
        }
        for (name, items) in [("Key points", points), ("Decisions", p.decisions), ("Wearer's to-dos", p.myTodos), ("To-dos", p.todos)]
            where !items.isEmpty {
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
        // 先按原来的办法；不行（前后有说明文字、多了逗号）再宽松地试
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? lenientObject(text)
    }

    static func string(_ obj: [String: Any], _ keys: String...) -> String {
        for k in keys {
            if let s = obj[k] as? String { return Summarizer.clean(s) }
            if let a = obj[k] as? [Any] { return Summarizer.clean(a.compactMap { $0 as? String }.joined(separator: " ")) }
        }
        return ""
    }

    /// 和 list 一样取出文字（同样的清理和过滤，所以文字和 list 给的一样），另外带上每条的 said_by（没给是 ""）
    static func attributed(_ obj: [String: Any], _ keys: String...) -> [(text: String, saidBy: String)] {
        for k in keys {
            if let a = obj[k] as? [Any] {
                return a.compactMap { item -> (String, String)? in
                    if let s = item as? String { return (s, "") }
                    if let o = item as? [String: Any] {
                        let main = ["text", "task", "item", "name", "action", "content"].compactMap { o[$0] as? String }.first
                        let extra = ["owner", "assignee", "who", "due", "deadline"].compactMap { o[$0] as? String }
                            .filter { !$0.isEmpty && !NameFilter.isGeneric($0) }
                        guard let main else { return nil }
                        let by = ["said_by", "saidBy", "speaker", "by"].compactMap { o[$0] as? String }.first ?? ""
                        return (extra.isEmpty ? main : "\(main) (\(extra.joined(separator: ", ")))", by.trimmingCharacters(in: .whitespaces))
                    }
                    return nil
                }.map { (Summarizer.stripBullet(Summarizer.clean($0.0)), $0.1) }.filter { !$0.0.isEmpty && !Summarizer.isNone($0.0) }
                    .map { (text: $0.0, saidBy: $0.1) }
            }
            if obj[k] is String { return list(obj, k).map { (text: $0, saidBy: "") } }
        }
        return []
    }

    static func list(_ obj: [String: Any], _ keys: String...) -> [String] {
        list(obj, keys)
    }

    static func list(_ obj: [String: Any], _ keys: [String]) -> [String] {
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
