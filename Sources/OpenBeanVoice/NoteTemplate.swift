// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 每条录音写进知识库文件夹的 Markdown 笔记：模板渲染和文件名
public enum NoteTemplate {
    /// 默认模板：YAML frontmatter + 摘要 / 要点 / 待办（有才写）+ 打开链接 + 带时间戳的转写
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

    {{transcript}}

    """

    /// 用户模板文件开头的说明（以 `<!--` 开头的第一段注释渲染时去掉）
    public static let help = """
    <!-- OpenBean note template. Delete this file to go back to the default.
    Placeholders: {{title}} {{title_yaml}} {{date}} {{time}} {{created_at}} {{duration}} {{recording_id}}
    {{summary}} {{key_points}} {{action_items}} {{link}} {{transcript}}
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

        public init(title: String, start: Date, duration: Double, recordingID: UInt32, summary: RecordingSummary?,
                    lines: [TimedLine], timeZone: TimeZone = .current) {
            self.title = title
            self.start = start
            self.duration = duration
            self.recordingID = recordingID
            self.summary = summary
            self.lines = lines
            self.timeZone = timeZone
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
                "transcript": lines.map { "[\(Summarizer.clock($0.start))] \($0.text)" }.joined(separator: "\n\n"),
            ]
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
