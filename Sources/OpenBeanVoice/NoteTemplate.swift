// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 每条录音写进知识库文件夹的 Markdown 笔记：模板渲染和文件名
public enum NoteTemplate {
    /// 默认模板：YAML frontmatter + 摘要 / 要点 / 待办（有才写）+ 打开链接 + 带时间戳的转写。
    /// 转写用 {{segments}}：一条录音只有一段对话时和 {{transcript}} 完全一样，有多段时每段一个小标题（见 Values.sections）
    public static let defaultTemplate = """
    ---
    title: {{title_yaml}}
    created_at: {{created_at}}
    duration: "{{duration}}"
    source: openbean
    recording_id: {{recording_id}}
    tags: [recording]
    ---
    {{#summary}}

    ## Summary

    {{summary}}
    {{/summary}}
    {{#key_points}}

    ## Key points

    {{key_points}}
    {{/key_points}}
    {{#action_items}}

    ## Action items

    {{action_items}}
    {{/action_items}}

    {{link}}

    ## Transcript

    {{segments}}

    """

    /// 用户模板文件开头的说明（以 `<!--` 开头的第一段注释渲染时去掉）
    public static let help = """
    <!-- OpenBean note template. Delete this file to go back to the default.
    Placeholders: {{title}} {{title_yaml}} {{date}} {{time}} {{created_at}} {{duration}} {{recording_id}}
    {{summary}} {{key_points}} {{action_items}} {{link}} {{transcript}}
    {{segments}} is the transcript split into conversations, one heading each (same as {{transcript}} when there is only one).
    {{#name}}…{{/name}} keeps the text in between only when {{name}} is not empty. Unknown placeholders are left as they are. -->

    """

    /// 笔记里用到的值
    public struct Values {
        public var title: String
        public var start: Date
        public var duration: Double
        public var recordingID: UInt32
        public var summary: RecordingSummary?
        public var lines: [TimedLine]
        public var timeZone: TimeZone
        /// 按停顿切出的对话段；少于两段时 {{segments}} 就是 {{transcript}}
        public var sections: [Section]
        /// 重点标记：句子下标（lines）→ 落在这句的标记（秒）。转写里这句的时间戳后面标出 ⚑ 和标记时刻
        public var marks: [Int: [Double]]

        public init(title: String, start: Date, duration: Double, recordingID: UInt32, summary: RecordingSummary?,
                    lines: [TimedLine], timeZone: TimeZone = .current, sections: [Section] = [], marks: [Int: [Double]] = [:]) {
            self.marks = marks
            self.title = title
            self.start = start
            self.duration = duration
            self.recordingID = recordingID
            self.summary = summary
            self.lines = lines
            self.timeZone = timeZone
            self.sections = sections
        }

        func transcript(_ r: Range<Int>) -> String {
            r.map { i in
                let l = lines[i]
                let flag = marks[i].map { m in " ⚑ " + m.map { "[\(Summarizer.clock($0))]" }.joined(separator: " ") } ?? ""
                return "[\(Summarizer.clock(l.start))]\(flag) \(l.text)"
            }.joined(separator: "\n\n")
        }

        /// 分节的转写：每段一个三级标题「HH:mm–HH:mm 小标题」（时间只是近似时前面加 ~），下面是这段的句子
        var segmented: String {
            let r = sections.map { $0.lines.clamped(to: 0..<lines.count) }.filter { !$0.isEmpty }
            guard r.count > 1 else { return transcript(0..<lines.count) }
            return zip(sections, r).map { s, range in
                "### \(s.heading(timeZone))\n\n\(transcript(range))"
            }.joined(separator: "\n\n")
        }

        public var dictionary: [String: String] {
            let iso = ISO8601DateFormatter()
            iso.timeZone = timeZone
            iso.formatOptions = [.withInternetDateTime]
            return [
                "title": title,
                "title_yaml": NoteTemplate.yamlString(title),
                "date": NoteTemplate.format(start, "yyyy-MM-dd", timeZone),
                "time": NoteTemplate.format(start, "HH:mm", timeZone),
                "created_at": iso.string(from: start),
                "duration": Summarizer.clock(duration),
                "recording_id": String(recordingID),
                "summary": summary?.summary ?? "",
                "key_points": (summary?.keyPoints ?? []).map { "- \($0)" }.joined(separator: "\n"),
                "action_items": (summary?.actionItems ?? []).map { "- [ ] \($0)" }.joined(separator: "\n"),
                "link": "[Open in OpenBean](openbean://open/\(recordingID))",
                "transcript": transcript(0..<lines.count),
                "segments": segmented,
            ]
        }
    }

    /// 笔记里的一节（一段对话）
    public struct Section: Sendable, Hashable {
        /// 句子下标（Values.lines），左闭右开
        public var lines: Range<Int>
        public var start: Date
        public var end: Date
        /// 时间只是近似（录音中途暂停过）
        public var approximate: Bool
        /// 段的小标题（段摘要给的）；没有时标题只有时间
        public var title: String?

        public init(lines: Range<Int>, start: Date, end: Date, approximate: Bool = false, title: String? = nil) {
            self.lines = lines
            self.start = start
            self.end = end
            self.approximate = approximate
            self.title = title
        }

        /// 「09:12–09:40 小标题」。不含 # [ ] | ^ 这些在 Obsidian 标题链接里有特殊含义的字符
        public func heading(_ tz: TimeZone) -> String {
            var h = (approximate ? "~" : "") + NoteTemplate.format(start, "HH:mm", tz) + "–" + NoteTemplate.format(end, "HH:mm", tz)
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                h += " " + NoteTemplate.sanitize(t, maxLength: 40)
            }
            return h
        }
    }

    public static func render(_ template: String, _ values: Values) -> String {
        render(template, values.dictionary)
    }

    /// 渲染模板：先处理 `{{#name}}…{{/name}}` 段落（值为空时整段去掉），再一次性替换 `{{name}}`。
    /// 替换进去的值不会再被当成模板（转写里出现 `{{title}}` 也原样保留）；不认识的占位符原样保留。
    public static func render(_ template: String, _ values: [String: String]) -> String {
        var t = template
        // 去掉开头的说明注释
        if t.hasPrefix("<!--"), let r = t.range(of: "-->") {
            t = String(t[r.upperBound...])
            while t.first?.isNewline == true { t.removeFirst() }
        }
        // 独占一行的段落标记连同换行一起去掉，免得留下空行
        t = t.replacingOccurrences(of: #"(?m)^[ \t]*(\{\{[#/][a-z_]+\}\})[ \t]*\n"#, with: "$1", options: .regularExpression)
        // 段落
        let section = try! NSRegularExpression(pattern: #"\{\{#([a-z_]+)\}\}(.*?)\{\{/\1\}\}"#, options: [.dotMatchesLineSeparators])
        while let m = section.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let whole = Range(m.range, in: t), let name = Range(m.range(at: 1), in: t), let body = Range(m.range(at: 2), in: t) {
            let keep = !(values[String(t[name])] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            t.replaceSubrange(whole, with: keep ? String(t[body]) : "")
        }
        // 占位符
        let ph = try! NSRegularExpression(pattern: #"\{\{\s*([a-z_]+)\s*\}\}"#)
        var out = ""
        var last = t.startIndex
        for m in ph.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let whole = Range(m.range, in: t), let name = Range(m.range(at: 1), in: t) else { continue }
            out += t[last..<whole.lowerBound]
            out += values[String(t[name])] ?? String(t[whole])
            last = whole.upperBound
        }
        out += t[last...]
        return out
    }

    /// YAML 双引号字符串
    public static func yamlString(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
        return "\"\(e)\""
    }

    static func format(_ d: Date, _ f: String, _ tz: TimeZone) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = f
        return df.string(from: d)
    }

    // MARK: 文件名

    /// 标题变成能当文件名的样子：去掉路径和 Obsidian 链接里有特殊含义的字符，压缩空白，限制长度
    public static func sanitize(_ title: String, maxLength: Int = 80) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]{}").union(.controlCharacters).union(.newlines)
        var s = String(String.UnicodeScalarView(title.unicodeScalars.map {
            CharacterSet.whitespacesAndNewlines.contains($0) ? " " : bad.contains($0) ? "-" : $0
        }))
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if s.count > maxLength { s = String(s.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: " .-")) }
        return s.isEmpty ? "Recording" : s
    }

    /// `<yyyy-MM-dd>-<标题>.md`；名字被占用时加上时间 `-HHmm`，还占用就再加 `-2`、`-3`…
    /// 没有标题（还没摘要）时用 `<yyyy-MM-dd>-<HHmm>.md`，不把日期再写一遍
    public static func fileName(title: String?, start: Date, timeZone: TimeZone = .current,
                                isTaken: (String) -> Bool) -> String {
        let day = format(start, "yyyy-MM-dd", timeZone), time = format(start, "HHmm", timeZone)
        let timed: String
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = "\(day)-\(sanitize(title))"
            if !isTaken(base + ".md") { return base + ".md" }
            timed = "\(base)-\(time)"
        } else {
            timed = "\(day)-\(time)"
        }
        if !isTaken(timed + ".md") { return timed + ".md" }
        var n = 2
        while isTaken("\(timed)-\(n).md") { n += 1 }
        return "\(timed)-\(n).md"
    }
}
