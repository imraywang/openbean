// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary

/// 每天一篇的日记笔记（Markdown，写在笔记文件夹的子文件夹里，文件名 yyyy-MM-dd.md）。
///
/// 链接用普通 Markdown 链接，和逐条笔记里的「Open in OpenBean」一样：Obsidian 和别的编辑器都认。
/// 指向逐条笔记时写相对路径（`../<笔记文件名>`，空格和括号转义）；没有逐条笔记时指向 openbean://open/<id>。
/// 不写到标题的锚点：Obsidian 的标题链接不认冒号，而段的小标题以时间开头。
public enum DiaryNote {
    public struct Values: Sendable {
        public var day: DayFile
        /// 当天录音总时长（秒）
        public var recordedSeconds: Double
        /// 当天涉及的录音
        public var recordings: [UInt32]
        public var timeZone: TimeZone
        /// 出处 → 链接地址
        public var link: @Sendable (ConversationRef) -> String

        public init(day: DayFile, recordedSeconds: Double, recordings: [UInt32], timeZone: TimeZone = .current,
                    link: @escaping @Sendable (ConversationRef) -> String) {
            self.day = day
            self.recordedSeconds = recordedSeconds
            self.recordings = recordings
            self.timeZone = timeZone
            self.link = link
        }
    }

    public static func render(_ v: Values) -> String {
        let byRef = Dictionary(v.day.conversations.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        func time(_ d: Date) -> String { NoteTemplate.format(d, "HH:mm", v.timeZone) }
        func clock(_ c: DayConversation) -> String { (c.wallApprox ? "~" : "") + time(c.wallStart) }
        func refLinks(_ refs: [ConversationRef]) -> String {
            refs.compactMap { r in byRef[r].map { "[\(clock($0))](\(v.link(r)))" } }.joined(separator: ", ")
        }
        let shown = v.day.status == .brief ? v.day.conversations : v.day.conversations.filter { $0.kind != "fragment" }

        var s = """
        ---
        date: \(v.day.date)
        source: openbean
        type: diary
        recorded: "\(Summarizer.clock(v.recordedSeconds))"
        conversations: \(shown.count)
        recordings: [\(v.recordings.map(String.init).joined(separator: ", "))]
        tags: [diary]
        ---

        """
        if let d = v.day.diary {
            if let o = d.overview, !o.isEmpty { s += "\n## Overview\n\n\(o)\n" }
            if !d.decisions.isEmpty {
                s += "\n## Decisions\n\n" + d.decisions.map { "- \($0.text) (\(refLinks($0.refs)))" }.joined(separator: "\n") + "\n"
            }
            if !d.todos.isEmpty {
                s += "\n## To-dos\n\n" + d.todos.map { t in
                    let who = t.owner.map { " — \($0)" } ?? ""
                    return "- [ ] \(t.text)\(who) (\(refLinks(t.refs)))"
                }.joined(separator: "\n") + "\n"
            }
            if !d.people.isEmpty || !d.things.isEmpty {
                s += "\n## People and things\n\n"
                if !d.people.isEmpty { s += "- **People**: " + d.people.map { "\($0.name) (\(refLinks($0.refs)))" }.joined(separator: "; ") + "\n" }
                if !d.things.isEmpty { s += "- **Things**: " + d.things.map { "\($0.name) (\(refLinks($0.refs)))" }.joined(separator: "; ") + "\n" }
            }
        }
        if !shown.isEmpty {
            s += "\n## Conversations\n"
            for c in shown {
                var head = "\(clock(c))–\(time(c.wallEnd))"
                if let t = c.title, !t.isEmpty { head += " " + t }
                if c.kind == "media" { head += " (media)" }
                s += "\n### \(head)\n\n"
                if let sum = c.summary, !sum.isEmpty { s += sum + " " }
                s += "[Transcript](\(v.link(c.ref)))\n"
            }
        }
        return s
    }

    /// 日记在笔记文件夹的子文件夹里：指向笔记文件夹里另一篇笔记的相对链接
    public static func siblingLink(_ fileName: String) -> String {
        var out = "../"
        for ch in fileName {
            switch ch {
            case " ": out += "%20"
            case "(": out += "%28"
            case ")": out += "%29"
            case "%": out += "%25"
            case "#": out += "%23"
            case "<": out += "%3C"
            case ">": out += "%3E"
            case "?": out += "%3F"
            default: out.append(ch)
            }
        }
        return out
    }
}
