// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary

/// 每天一篇的日记笔记（Markdown，写在笔记文件夹的子文件夹里，文件名 yyyy-MM-dd.md）。
///
/// 链接用普通 Markdown 链接，和逐条笔记里的「Open in OpenBean」一样：Obsidian 和别的编辑器都认。
/// 指向逐条笔记时写相对路径（`../<笔记文件名>`，空格和括号转义）；没有逐条笔记时指向 openbean://open/<id>。
/// 不写到标题的锚点：Obsidian 的标题链接不认冒号，而段的小标题以时间开头。
public enum DiaryNote {
    /// 小节标题：跟着 App 的语言走（App 传入本地化的文字）；frontmatter 的键名不翻译
    public struct Labels: Sendable {
        public var overview = "Overview"
        public var decisions = "Decisions"
        public var todos = "To-dos"
        public var peopleAndThings = "People and things"
        public var people = "People"
        public var things = "Things"
        public var conversations = "Conversations"
        public var transcript = "Transcript"
        public var media = "media"
        public var marks = "Marked"

        public init() {}
        public init(overview: String, decisions: String, todos: String, peopleAndThings: String, people: String,
                    things: String, conversations: String, transcript: String, media: String, marks: String = "Marked") {
            self.marks = marks
            self.overview = overview
            self.decisions = decisions
            self.todos = todos
            self.peopleAndThings = peopleAndThings
            self.people = people
            self.things = things
            self.conversations = conversations
            self.transcript = transcript
            self.media = media
        }
    }

    public struct Values: Sendable {
        public var day: DayFile
        /// 当天录音总时长（秒）
        public var recordedSeconds: Double
        /// 当天涉及的录音
        public var recordings: [UInt32]
        public var timeZone: TimeZone
        /// 出处 → 链接地址
        public var link: @Sendable (ConversationRef) -> String
        public var labels: Labels

        public init(day: DayFile, recordedSeconds: Double, recordings: [UInt32], timeZone: TimeZone = .current,
                    labels: Labels = Labels(), link: @escaping @Sendable (ConversationRef) -> String) {
            self.labels = labels
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
        let L = v.labels
        if let o = v.day.diary?.overview, !o.isEmpty { s += "\n## \(L.overview)\n\n\(o)\n" }
        // 标记：用户在录音豆上双击标出的时刻。每条：时刻、所在的那段对话（链接）、标记那句和前后各一句的原话
        if !v.day.marks.isEmpty {
            s += "\n## \(L.marks)\n\n" + v.day.marks.map { m in
                var line = "- **\((m.wallApprox ? "~" : "") + time(m.wall))**"
                if let c = byRef[m.ref] {
                    var name = "\(clock(c))–\(time(c.wallEnd))"
                    if let t = c.title, !t.isEmpty { name += " " + t }
                    line += " · [\(name)](\(v.link(m.ref)))"
                } else {
                    line += " · [\(L.transcript)](\(v.link(m.ref)))"
                }
                if !m.quote.isEmpty { line += "\n  > " + m.quote.joined(separator: " ") }
                return line
            }.joined(separator: "\n") + "\n"
        }
        if let d = v.day.diary {
            if !d.decisions.isEmpty {
                s += "\n## \(L.decisions)\n\n" + d.decisions.map { "- \($0.text) (\(refLinks($0.refs)))" }.joined(separator: "\n") + "\n"
            }
            if !d.todos.isEmpty {
                s += "\n## \(L.todos)\n\n" + d.todos.map { t in
                    let who = t.owner.map { " — \($0)" } ?? ""
                    return "- [ ] \(t.text)\(who) (\(refLinks(t.refs)))"
                }.joined(separator: "\n") + "\n"
            }
            if !d.people.isEmpty || !d.things.isEmpty {
                s += "\n## \(L.peopleAndThings)\n\n"
                if !d.people.isEmpty { s += "- **\(L.people)**: " + d.people.map { "\($0.name) (\(refLinks($0.refs)))" }.joined(separator: "; ") + "\n" }
                if !d.things.isEmpty { s += "- **\(L.things)**: " + d.things.map { "\($0.name) (\(refLinks($0.refs)))" }.joined(separator: "; ") + "\n" }
            }
        }
        if !shown.isEmpty {
            s += "\n## \(L.conversations)\n"
            for c in shown {
                var head = "\(clock(c))–\(time(c.wallEnd))"
                if let t = c.title, !t.isEmpty { head += " " + t }
                if c.kind == "media" { head += " (\(L.media))" }
                s += "\n### \(head)\n\n"
                if let sum = c.summary, !sum.isEmpty { s += sum + " " }
                s += "[\(L.transcript)](\(v.link(c.ref)))\n"
            }
        }
        return s
    }

    /// 日记在笔记文件夹的子文件夹里：指向笔记文件夹里另一篇笔记的相对链接
    public static func siblingLink(_ fileName: String) -> String { encode("../" + fileName) }

    /// 从日记所在的文件夹指向另一个文件的相对链接（两边都是本机路径）
    public static func relativeLink(from dir: URL, to file: URL) -> String {
        let a = dir.standardizedFileURL.pathComponents, b = file.standardizedFileURL.pathComponents
        var i = 0
        while i < a.count, i < b.count - 1, a[i] == b[i] { i += 1 }
        let up = Array(repeating: "..", count: a.count - i)
        return encode((up + b[i...]).joined(separator: "/"))
    }

    /// 日记子文件夹的设置（相对笔记文件夹的路径）→ 实际的文件夹。规则：
    /// - 空：笔记文件夹/defaultName；
    /// - 不能是绝对路径、不能以 ~ 开头；
    /// - 最多往上走到笔记文件夹的上一级（`../30-日记` 可以，`../../x` 不行），而且结果必须是一个具体的子文件夹：
    ///   不能是笔记文件夹本身，也不能是它的上一级本身（日记不和别的东西混在同一层）；
    /// - 每一级的名字按文件名规则清理（去掉 `: * ? " < > |` 等）。
    /// 不合规返回 nil（App 退回默认文件夹并在设置里提示）
    public static func folder(_ setting: String, notesFolder: URL, defaultName: String) -> URL? {
        let t = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notesFolder.standardizedFileURL
        guard !t.isEmpty else { return notes.appendingPathComponent(NoteTemplate.sanitize(defaultName), isDirectory: true) }
        guard !t.hasPrefix("/"), !t.hasPrefix("~") else { return nil }
        // 相对笔记文件夹的上一级记路径
        var stack = [notes.lastPathComponent]
        for part in t.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty || p == "." { continue }
            if p == ".." {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            } else {
                stack.append(NoteTemplate.sanitize(p))
            }
        }
        guard !stack.isEmpty, stack != [notes.lastPathComponent] else { return nil }
        return stack.reduce(notes.deletingLastPathComponent()) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    static func encode(_ path: String) -> String {
        var out = ""
        for ch in path {
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
