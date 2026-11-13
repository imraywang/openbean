// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一句带时间的转写（秒）
public struct TimedLine: Sendable, Hashable {
    public var start: Double
    public var text: String
    public init(start: Double, text: String) {
        self.start = start
        self.text = text
    }
}

/// 一条录音的摘要
public struct RecordingSummary: Codable, Sendable, Hashable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var actionItems: [String]

    public init(title: String, summary: String, keyPoints: [String] = [], actionItems: [String] = []) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
    }
}

/// 录音摘要：用润色同一个大模型服务。转写太长时按 token 预算分块，各块先出局部摘要，再合并成一份。
/// 本机服务常开 4k 上下文：默认每块转写约 1800 token，加提示词约 350、输出上限 1000，留有余量。
public struct Summarizer: Sendable {
    public let service: LLMService
    /// 每次请求里放多少 token 的转写（或局部摘要）
    public let budget: Int
    /// 每次请求的输出上限
    public let maxOutput: Int
    /// 单次请求超时：本机模型读几千 token 再写摘要可能要几分钟
    public let timeout: TimeInterval
    /// 个人词表（原始行，可带 `词 = 误听写法`）：提示模型按这些词改认错的词，输出再过一遍同音纠正
    public let glossary: [String]

    public init(service: LLMService, budget: Int = 1800, maxOutput: Int = 1000, timeout: TimeInterval? = nil,
                glossary: [String] = []) {
        self.service = service
        self.glossary = glossary
        self.budget = max(budget, 200)
        self.maxOutput = maxOutput
        self.timeout = timeout ?? (service.isLocal ? 300 : 120)
    }

    // MARK: 提示词

    static let chunkPrompt = """
    You summarise transcripts of voice recordings (meetings, interviews, notes to self). The transcript comes from \
    speech recognition, so it may contain recognition errors and filler words; read through them.
    Reply with ONE JSON object and nothing else, no code fences:
    {"title": "...", "summary": "...", "key_points": ["..."], "action_items": ["..."]}
    - title: a short title for the recording, at most 12 words (or 20 Chinese characters), no quotes or date.
    - summary: 2 to 4 sentences on what was said.
    - key_points: 3 to 7 short points with the important facts, decisions, numbers and names.
    - action_items: concrete to-dos that someone committed to or was asked to do, with the owner and deadline when \
    mentioned. Use [] when there are none; do not invent any.
    Only use what is in the transcript. Do not add advice or commentary. Never invent people, numbers, dates or \
    to-dos; a short transcript gets a short summary.
    """

    static let partPrompt = """
    You summarise one part of a long transcript of a voice recording. The transcript comes from speech recognition, \
    so it may contain recognition errors and filler words; read through them.
    Reply with ONE JSON object and nothing else, no code fences:
    {"title": "...", "summary": "...", "key_points": ["..."], "action_items": ["..."]}
    - title: a few words naming the topic of this part.
    - summary: 2 to 4 sentences on what was said in this part.
    - key_points: up to 7 short points with the important facts, decisions, numbers and names.
    - action_items: at most 3 concrete to-dos that someone committed to or was asked to do in this part; general \
    advice and principles are not to-dos. [] when there are none; do not invent any.
    Only use what is in the text.
    """

    static let mergePrompt = """
    You are given partial summaries of consecutive parts of one voice recording, in order. Combine them into one \
    summary of the whole recording.
    Reply with ONE JSON object and nothing else, no code fences:
    {"title": "...", "summary": "...", "key_points": ["..."], "action_items": ["..."]}
    - title: a short title for the whole recording, at most 12 words (or 20 Chinese characters), no quotes or date.
    - summary: 2 to 4 sentences covering the whole recording.
    - key_points: 3 to 8 of the most important points; merge duplicates.
    - action_items: the to-dos from the parts, merged and deduplicated, at most 10; when there are more, keep the most \
    concrete ones (an owner, a deadline or a number) and drop general advice. [] when there are none.
    Only use what is in the partial summaries.
    """

    /// 输出语言：小模型常常忽略「用原文语言」，所以按文字判断后直接点名
    static func languageLine(for text: String) -> String {
        var han = 0, kana = 0, hangul = 0, letters = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            default: if CharacterSet.letters.contains(u) { letters += 1 }
            }
        }
        let total = max(han + kana + hangul + letters, 1)
        if Double(kana) / Double(total) > 0.1 { return "Write the JSON values in Japanese." }
        if Double(hangul) / Double(total) > 0.2 { return "Write the JSON values in Korean." }
        if Double(han) / Double(total) > 0.2 {
            // 只说「和转写稿一致」时，本机模型读多了局部摘要会漂到繁体，所以直接点名
            return isTraditional(text) ? "Write the JSON values in Traditional Chinese (用繁體中文寫)."
                : "Write the JSON values in Simplified Chinese (用简体中文写，不要用繁体字)."
        }
        return "Write the JSON values in the same language as the transcript."
    }

    /// 转写稿是不是繁体：数一批简繁写法不同的常用字，繁体写法占多数才算
    static func isTraditional(_ text: String) -> Bool {
        let trad = Set("們這個來說時會對國學為與過還後發開關點經麼樣讓應實現問題電話機認識聽寫語記錄")
        let simp = Set("们这个来说时会对国学为与过还后发开关点经么样让应实现问题电话机认识听写语记录")
        var t = 0, s = 0
        for ch in text {
            if trad.contains(ch), !simp.contains(ch) { t += 1 } else if simp.contains(ch), !trad.contains(ch) { s += 1 }
        }
        return t > s
    }

    /// 转写少于这么多 token（约 40 个汉字或 30 个英文词）就不摘要
    public static let minTokens = 60

    /// 合并多块之后的上限：模型不听提示里的数量时兜底，免得两小时的录音列出几十条待办
    static let maxKeyPoints = 8, maxActionItems = 10
    static func capped(_ s: RecordingSummary) -> RecordingSummary {
        var s = s
        s.keyPoints = Array(s.keyPoints.prefix(maxKeyPoints))
        s.actionItems = Array(s.actionItems.prefix(maxActionItems))
        return s
    }

    /// 提示词里的词表一行：只放正确写法，最多 60 个，免得挤占上下文
    static func termsLine(_ glossary: [String]) -> String {
        let terms = GlossaryCorrector.canonicalTerms(glossary).prefix(60)
        guard !terms.isEmpty else { return "" }
        return "\nThe speaker's own terms: " + terms.joined(separator: ", ") + ". Speech recognition often gets these wrong. "
            + "When a word in the transcript sounds like one of them and the context fits, write the term as spelled here."
    }

    /// 摘要的每个字段过一遍词表纠正
    static func corrected(_ s: RecordingSummary, with c: GlossaryCorrector) -> RecordingSummary {
        RecordingSummary(title: c.correct(s.title).text, summary: c.correct(s.summary).text,
                         keyPoints: s.keyPoints.map { c.correct($0).text }, actionItems: s.actionItems.map { c.correct($0).text })
    }

    // MARK: 分块

    /// 保守估计 token 数：中日韩字符按每字 1.5 个（不同模型的分词器差别大，宁多勿少），其余按每 3 个字符 1 个
    public static func estimateTokens(_ s: String) -> Int {
        var wide = 0, other = 0
        for u in s.unicodeScalars {
            if u.value >= 0x2E80 { wide += 1 } else { other += 1 }
        }
        return (wide * 3 + 1) / 2 + (other + 2) / 3
    }

    static func line(_ l: TimedLine) -> String { "[\(clock(l.start))] \(l.text)" }

    public static func clock(_ t: Double) -> String {
        let s = Int(max(t, 0).rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 按句子切块，每块（带时间戳的行）不超过预算；单句超长时按字切开
    public static func chunk(_ lines: [TimedLine], budget: Int) -> [[TimedLine]] {
        var out: [[TimedLine]] = []
        var cur: [TimedLine] = []
        var used = 0
        func flush() { if !cur.isEmpty { out.append(cur); cur = []; used = 0 } }
        for l in lines where !l.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cost = estimateTokens(line(l)) + 1
            if cost > budget {
                flush()
                for piece in split(l, budget: budget) { out.append([piece]) }
                continue
            }
            if used + cost > budget { flush() }
            cur.append(l)
            used += cost
        }
        flush()
        return out
    }

    /// 把一句超长的转写按预算切成几段（时间戳都用这句的开头）
    private static func split(_ l: TimedLine, budget: Int) -> [TimedLine] {
        var out: [TimedLine] = []
        var buf = ""
        let prefix = estimateTokens("[\(clock(l.start))] ") + 1
        for ch in l.text {
            if !buf.isEmpty, prefix + estimateTokens(buf + String(ch)) > budget {
                out.append(TimedLine(start: l.start, text: buf))
                buf = ""
            }
            buf.append(ch)
        }
        if !buf.isEmpty { out.append(TimedLine(start: l.start, text: buf)) }
        return out
    }

    // MARK: 解析

    /// 从模型回复里取出摘要：去掉 <think> 块和代码围栏，找 JSON 对象；不可用时返回 nil
    public static func parse(_ raw: String) -> RecordingSummary? {
        var text = raw
        // 思考块：取最后一个 </think> 之后的部分；只有开头没有结尾说明输出被截断了
        if let r = text.range(of: "</think>", options: .backwards) {
            text = String(text[r.upperBound...])
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") {
            return nil
        }
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let d = String(text[a...b]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }

        func str(_ keys: String...) -> String {
            for k in keys {
                if let s = obj[k] as? String { return clean(s) }
                if let a = obj[k] as? [Any] { return clean(a.compactMap { $0 as? String }.joined(separator: " ")) }
            }
            return ""
        }
        func list(_ keys: String...) -> [String] {
            for k in keys {
                if let a = obj[k] as? [Any] {
                    return a.compactMap { item -> String? in
                        if let s = item as? String { return s }
                        // 有的模型把待办写成 {"task": "...", "owner": "..."}
                        if let o = item as? [String: Any] {
                            let parts = ["task", "item", "text", "action", "content"].compactMap { o[$0] as? String }
                            let extra = ["owner", "assignee", "who", "due", "deadline"].compactMap { o[$0] as? String }
                            guard let main = parts.first else { return nil }
                            return extra.isEmpty ? main : "\(main) (\(extra.joined(separator: ", ")))"
                        }
                        return nil
                    }.map(clean).map(stripBullet).filter { !$0.isEmpty && !isNone($0) }
                }
                if let s = obj[k] as? String {
                    return s.split(whereSeparator: \.isNewline).map { stripBullet(clean(String($0))) }
                        .filter { !$0.isEmpty && !isNone($0) }
                }
            }
            return []
        }

        let summary = str("summary", "Summary", "摘要")
        guard !summary.isEmpty, !looksLikePlaceholder(summary) else { return nil }
        var title = str("title", "Title", "标题")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」『』《》#*"))
            .trimmingCharacters(in: .whitespaces)
        if title.count > 60 { title = String(title.prefix(60)) }
        if looksLikePlaceholder(title) { title = "" }
        return RecordingSummary(title: title, summary: summary,
                                keyPoints: list("key_points", "keyPoints", "Key points", "要点"),
                                actionItems: list("action_items", "actionItems", "Action items", "待办"))
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBullet(_ s: String) -> String {
        var t = s
        for p in ["- [ ] ", "- ", "* ", "• ", "· "] where t.hasPrefix(p) { t.removeFirst(p.count) }
        // 模型把「没有负责人」写成结尾的 [无]、(none) 之类，去掉
        t = t.replacingOccurrences(of: #"\s*[\[(（【](无|無|none|n/a|未提及|未指定)[\])）】]\s*$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func isNone(_ s: String) -> Bool {
        ["none", "n/a", "无", "没有", "暂无", "（无）", "(none)"].contains(s.lowercased())
    }

    /// 模型把提示里的示例原样抄回来
    private static func looksLikePlaceholder(_ s: String) -> Bool {
        s == "..." || s == "…" || s.allSatisfy { $0 == "." || $0 == "…" }
    }

    // MARK: 调用

    public enum Failure: Error, CustomStringConvertible {
        case empty
        /// 转写太短，没有可摘要的内容（硬让模型写，它会编出一场会议）
        case tooShort
        case unusable
        public var description: String {
            switch self {
            case .empty: return "empty transcript"
            case .tooShort: return "transcript too short to summarise"
            case .unusable: return "the model's reply could not be used"
            }
        }
    }

    /// 生成摘要。progress 报告已完成的请求比例（0…1）。
    /// 服务不通时抛网络错误；模型回复不可用时抛 `Failure.unusable`（调用方不写入任何摘要）。
    public func summarize(_ lines: [TimedLine], progress: (@Sendable (Double) -> Void)? = nil) async throws -> RecordingSummary {
        let chunks = Self.chunk(lines, budget: budget)
        guard !chunks.isEmpty else { throw Failure.empty }
        guard Self.estimateTokens(lines.map(\.text).joined()) >= Self.minTokens else { throw Failure.tooShort }
        let lang = Self.languageLine(for: lines.map(\.text).joined()) + Self.termsLine(glossary)
        let corrector = GlossaryCorrector(terms: glossary)
        let session = service.makeSession(timeout: timeout)
        // 估计总请求数：每块一次，多块时再加合并
        let total = Double(chunks.count + (chunks.count > 1 ? max(1, chunks.count / 4) : 0))
        var done = 0.0
        func step() { done += 1; progress?(min(done / total, 0.99)) }

        if chunks.count == 1 {
            let user = "Transcript:\n" + chunks[0].map(Self.line).joined(separator: "\n")
            // 回复不可用时再试一次（网络错误直接抛出）
            let s: RecordingSummary
            do { s = try await ask(Self.chunkPrompt + "\n" + lang, user, session: session) } catch Failure.unusable {
                s = try await ask(Self.chunkPrompt + "\n" + lang, user, session: session)
            }
            progress?(1)
            return Self.corrected(s, with: corrector)
        }

        // 各块的局部摘要；某一块失败就重试一次，再不行跳过（只要还有别的块）
        var parts: [RecordingSummary] = []
        for (i, c) in chunks.enumerated() {
            let user = "Part \(i + 1) of \(chunks.count). Transcript:\n" + c.map(Self.line).joined(separator: "\n")
            var got = try? await ask(Self.partPrompt + "\n" + lang, user, session: session)
            if got == nil { got = try? await ask(Self.partPrompt + "\n" + lang, user, session: session) }
            if let got { parts.append(got) } else if await service.check() != .ok {
                throw URLError(.cannotConnectToHost)
            }
            step()
        }
        guard !parts.isEmpty else { throw Failure.unusable }

        // 合并：局部摘要太多时分组合并，直到剩一份
        while true {
            let groups = Self.group(parts, budget: budget)
            var merged: [RecordingSummary] = []
            for g in groups {
                if g.count == 1 && groups.count > 1 { merged.append(g[0]); continue }
                let user = "Partial summaries, in order:\n\n" + g.enumerated().map { Self.render($0.element, index: $0.offset + 1) }
                    .joined(separator: "\n\n")
                merged.append(try await ask(Self.mergePrompt + "\n" + lang, user, session: session))
                step()
            }
            if merged.count == 1 { progress?(1); return Self.corrected(Self.capped(merged[0]), with: corrector) }
            parts = merged
        }
    }

    /// 局部摘要按预算分组（每组至少两份，保证每轮都在变少）
    static func group(_ parts: [RecordingSummary], budget: Int) -> [[RecordingSummary]] {
        var out: [[RecordingSummary]] = []
        var cur: [RecordingSummary] = []
        var used = 0
        for (i, p) in parts.enumerated() {
            let cost = estimateTokens(render(p, index: i + 1)) + 2
            if cur.count >= 2, used + cost > budget { out.append(cur); cur = []; used = 0 }
            cur.append(p)
            used += cost
        }
        if !cur.isEmpty {
            // 最后剩一份单独的就并到上一组
            if cur.count == 1, !out.isEmpty { out[out.count - 1] += cur } else { out.append(cur) }
        }
        return out
    }

    static func render(_ s: RecordingSummary, index: Int) -> String {
        var t = "Part \(index): \(s.title)\nSummary: \(s.summary)"
        if !s.keyPoints.isEmpty { t += "\nKey points:\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") }
        if !s.actionItems.isEmpty { t += "\nAction items:\n" + s.actionItems.map { "- \($0)" }.joined(separator: "\n") }
        return t
    }

    private func ask(_ system: String, _ user: String, session: URLSession) async throws -> RecordingSummary {
        // 本机服务（llama-server 等）关掉思考模式，免得思考把输出额度用光；云端不认识这个参数，不发
        let extra: [String: Any] = service.isLocal ? ["chat_template_kwargs": ["enable_thinking": false]] : [:]
        let raw = try await service.chat(system: system, user: user, maxTokens: maxOutput, temperature: 0.2,
                                         extra: extra, session: session)
        guard let s = Self.parse(raw) else { throw Failure.unusable }
        return s
    }
}
