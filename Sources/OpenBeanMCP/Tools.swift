// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary

/// 一次工具调用的结果：给模型读的文字 + 结构化内容；isError 表示工具执行出错（不是协议错误）
public struct ToolResult: Sendable {
    public var text: String
    public var structured: JSON?
    public var isError: Bool

    static func failure(_ message: String) -> ToolResult { ToolResult(text: message, structured: nil, isError: true) }
}

/// 参数不对、录音不存在之类：作为工具错误交给模型，让它自己改参数重试
struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 五个只读工具：列出、取一条、取转写、搜索、某天概览
public final class LibraryTools: @unchecked Sendable {
    public let location: LibraryLocation
    let library: RecordingLibrary
    let timeZone: TimeZone
    let now: () -> Date
    let calendar: Calendar
    /// 一天从几点开始（和 App 的「今天」、每日日记同一个规则：默认凌晨 4 点，凌晨两点的录音算前一天）
    let boundary: DayBoundary
    /// App 设置「允许 Agent 读取心力模式录音的原文」：每次调用时问一次（用户在 App 里改了不用重启 agent）
    let heartTranscriptsAllowed: () -> Bool

    public init(location: LibraryLocation, timeZone: TimeZone = .current, dayStartHour: Int = 4,
                now: @escaping () -> Date = Date.init, heartTranscriptsAllowed: @escaping () -> Bool = { false }) {
        self.location = location
        self.heartTranscriptsAllowed = heartTranscriptsAllowed
        library = RecordingLibrary(folder: location.folder)
        self.timeZone = timeZone
        self.now = now
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        calendar = c
        boundary = DayBoundary(startHour: dayStartHour, calendar: c)
    }

    public static let names = ["list_recordings", "get_recording", "get_transcript", "search_recordings", "day_overview"]

    /// 不认识的工具返回 nil（由协议层回 -32602）
    public func call(_ name: String, arguments: [String: JSON]) -> ToolResult? {
        let run: ([String: JSON]) throws -> ToolResult
        switch name {
        case "list_recordings": run = listRecordings
        case "get_recording": run = getRecording
        case "get_transcript": run = getTranscript
        case "search_recordings": run = searchRecordings
        case "day_overview": run = dayOverview
        default: return nil
        }
        do {
            return try run(arguments)
        } catch let e as ToolError {
            return .failure(e.message)
        } catch let e as RecordingLibrary.LibraryError {
            return .failure(e.description)
        } catch {
            return .failure("Unexpected error: \(error)")
        }
    }

    // MARK: - 工具定义（写给模型看）

    public var definitions: [JSON] {
        let dateHelp = "Local date (YYYY-MM-DD), or \"today\" / \"yesterday\". \(dayRule)"
        let id: JSON = ["type": "integer", "description": "Recording id, from list_recordings, search_recordings or day_overview."]
        let readOnly: JSON = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: JSON], required: [String] = []) -> JSON {
            var schema: [String: JSON] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
            if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
            var a = readOnly.object!
            a["title"] = .string(title)
            return ["name": .string(name), "title": .string(title), "description": .string(description),
                    "inputSchema": .object(schema), "annotations": .object(a)]
        }
        return [
            tool("list_recordings", "List recordings",
                 "List the user's recordings in OpenBean (audio from their soundcore Work recorder, transcribed on their Mac), newest first. "
                 + "Optionally limit to a range of local dates and/or a keyword that must appear in the title, summary or transcript. "
                 + "Returns each recording's id, start time, duration, title, whether it has a transcript and a summary, and a one-line gist. "
                 + "Use get_recording or get_transcript with an id for the details.",
                 ["from": ["type": "string", "description": .string("First day to include. " + dateHelp)],
                  "to": ["type": "string", "description": .string("Last day to include. " + dateHelp)],
                  "query": ["type": "string", "description": "Only recordings whose title, summary or transcript contains this text (case-insensitive substring)."],
                  "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20, "description": "Maximum number of recordings to return (default 20)."]]),
            tool("get_recording", "Get a recording",
                 "Get one recording: start time, duration, title, its LLM-written summary with key points and action items (if it has one), "
                 + "the path of the Markdown note OpenBean saved for it (if any), the size of its transcript, "
                 + "the moments the user marked as important on the recorder (seconds from the start; read around them with get_transcript) "
                 + "its conversations (long pauses split a recording) with their summaries when it has them, "
                 + "and a link that opens it in OpenBean. "
                 + "Does not include the transcript itself; use get_transcript for that.",
                 ["id": id], required: ["id"]),
            tool("get_transcript", "Read a transcript",
                 "Read a recording's transcript as timestamped sentences ([mm:ss] from the start of the recording). "
                 + "Long transcripts are cut at max_chars; the result then says which start_seconds to pass to read on. "
                 + "Use start_seconds / end_seconds to read only part of a recording, e.g. around a timestamp from search_recordings, "
                 + "or conversation to read one conversation of a long recording (day_overview lists them). "
                 + "The text is automatic speech recognition and can contain mis-heard words, especially names. "
                 + "Recordings made in OpenBean's Heart mode (all-day recording) only share their transcript if the user allows it in OpenBean's settings; "
                 + "otherwise this returns their conversation summaries instead, and day_overview has the day's diary.",
                 ["id": id,
                  "start_seconds": ["type": "number", "minimum": 0, "description": "Read from this many seconds into the recording (default 0)."],
                  "end_seconds": ["type": "number", "minimum": 0, "description": "Stop at this many seconds into the recording (default: the end)."],
                  "conversation": ["type": "integer", "minimum": 0,
                                   "description": "Read only this conversation of the recording (its index from day_overview). Replaces start_seconds / end_seconds."],
                  "max_chars": ["type": "integer", "minimum": 200, "maximum": 50000, "default": 6000,
                                "description": "Stop after about this many characters of transcript (default 6000)."]],
                 required: ["id"]),
            tool("search_recordings", "Search recordings",
                 "Find where something was said: searches titles, summaries, key points, action items and transcripts for a keyword. "
                 + "Matching is a case-insensitive substring, without word splitting (works for Chinese); use a short, distinctive keyword "
                 + "and try synonyms or other spellings if nothing is found, since transcripts can mis-hear words. "
                 + "Returns matching recordings, newest first, with up to 5 snippets each and the timestamp of each transcript match. "
                 + "For Heart mode recordings whose transcripts the user keeps private, conversation summaries are searched instead of the words.",
                 ["query": ["type": "string", "minLength": 1, "description": "Text to look for."],
                  "from": ["type": "string", "description": .string("First day to search. " + dateHelp)],
                  "to": ["type": "string", "description": .string("Last day to search. " + dateHelp)],
                  "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "Maximum number of recordings to return (default 10)."]],
                 required: ["query"]),
            tool("day_overview", "Overview of a day",
                 "Everything recorded on one local day, in order: each recording's time, duration, title, summary, key points and action items, "
                 + "plus all action items of the day together. Recordings without a summary show the start of their transcript instead. "
                 + "Long recordings are split into conversations at long pauses; each is listed with its time, title and summary, and "
                 + "get_transcript with that conversation index reads just that part. When the user has OpenBean's daily diary turned on, "
                 + "the day's diary comes first: an overview, what was decided, to-dos and people mentioned, each pointing to the "
                 + "conversation it comes from (recording id and conversation index).",
                 ["date": ["type": "string", "description": .string("The day. " + dateHelp + " Default: today.")]]),
        ]
    }

    // MARK: - list_recordings

    func listRecordings(_ a: [String: JSON]) throws -> ToolResult {
        let range = try dateRange(a)
        let query = try optionalString(a, "query")
        let limit = try int(a, "limit", default: 20, in: 1...100)
        var all = try library.recordings(in: range?.interval)
        if let query { all = all.filter { library.contains($0, query: query, transcript: transcriptVisible($0)) } }
        let shown = Array(all.prefix(limit))

        var lines: [String] = []
        let scope = [range?.label, query.map { "matching \"\($0)\"" }].compactMap { $0 }.joined(separator: ", ")
        if all.isEmpty {
            lines.append("No recordings\(scope.isEmpty ? "" : " " + scope). \(contextLine)")
            if try library.recordings().isEmpty { lines.append("The library has no recordings yet.") }
        } else {
            lines.append("\(shown.count == all.count ? "\(all.count)" : "\(shown.count) of \(all.count)") recording\(all.count == 1 ? "" : "s")"
                         + "\(scope.isEmpty ? "" : " " + scope), newest first. \(contextLine)")
            for r in shown {
                let s = library.summary(r.id).value
                lines.append("")
                lines.append("• id \(r.id) — \(localDateTime(r.start)), \(clock(r.duration)) — \(title(r, s) ?? "(untitled)") [\(flags(r, s))]")
                if let g = gist(r, s) { lines.append("  " + g) }
            }
            if shown.count < all.count { lines.append("\n\(all.count - shown.count) more not shown: raise limit or narrow the dates.") }
        }
        let items: [JSON] = shown.map { r in
            let s = library.summary(r.id).value
            var o = brief(r, s).object!
            o["gist"] = .from(gist(r, s))
            return .object(o)
        }
        var out = contextJSON
        out["total"] = .int(all.count)
        out["recordings"] = .array(items)
        if let range { out["from"] = .string(range.from); out["to"] = .string(range.to) }
        if let query { out["query"] = .string(query) }
        return ToolResult(text: lines.joined(separator: "\n"), structured: .object(out), isError: false)
    }

    // MARK: - get_recording

    func getRecording(_ a: [String: JSON]) throws -> ToolResult {
        let r = try recording(a)
        let s = library.summary(r.id).value
        let transcript = library.transcript(r.id)
        var lines = ["Recording \(r.id): \(title(r, s) ?? "(untitled)")",
                     "Start: \(localDateTime(r.start)) (\(iso(r.start))) · Duration \(clock(r.duration))"]
        var o = brief(r, s).object!
        let visible = transcriptVisible(r)
        o["transcript_private"] = .bool(!visible)
        switch transcript {
        case .ok where !visible:
            lines.append("Transcript: private. \(Self.privateNote)")
            o["transcript"] = .null
        case let .ok(segs):
            let chars = segs.reduce(0) { $0 + $1.text.count }
            lines.append("Transcript: \(segs.count) sentences, \(chars) characters. Read it with get_transcript.")
            o["transcript"] = ["sentences": .int(segs.count), "characters": .int(chars)]
        case .unreadable:
            lines.append("Transcript: can't be read right now (OpenBean may be writing it). Try again shortly.")
            o["transcript"] = .null
        case .missing:
            lines.append("Transcript: \(statusSentence(r))")
            o["transcript"] = .null
        }
        if let s {
            lines.append("")
            lines.append("Summary\(s.model.map { " (written by \($0))" } ?? ""):")
            if !s.summary.isEmpty { lines.append(s.summary) }
            if !s.keyPoints.isEmpty { lines.append("\nKey points:"); lines += s.keyPoints.map { "- " + $0 } }
            if !s.actionItems.isEmpty { lines.append("\nAction items:"); lines += s.actionItems.map { "- " + $0 } }
            var so: [String: JSON] = ["title": .string(s.title), "summary": .string(s.summary),
                                      "key_points": .array(s.keyPoints.map { .string($0) }),
                                      "action_items": .array(s.actionItems.map { .string($0) }), "model": .from(s.model)]
            so["created_at"] = s.createdAt.map { .string(iso($0)) } ?? .null
            o["summary"] = .object(so)
        } else {
            lines.append("No summary.")
            o["summary"] = .null
        }
        // 重点标记：用户在录音豆上双击标出的时刻（先敲后说：要说的话一般在标记后一两秒）
        if let marks = library.marks(r.id) {
            let convs = library.conversations(r.id)
            let spans = transcript.value?.map { (start: $0.start, end: $0.end) } ?? []
            func conversation(_ m: Double) -> Conversation? {
                guard let i = MarkPlacement.line(for: m, spans: spans) else { return nil }
                return convs.first { $0.lines.contains(i) }
            }
            lines.append("")
            if marks.isEmpty {
                lines.append("Marks: none.")
            } else {
                lines.append("Marks (moments the user marked as important on the recorder; what they said usually follows within a second or two):")
                lines += marks.map { m in
                    "- \(clock(m)) (\(localDateTime(r.start.addingTimeInterval(m))))" + (conversation(m).map { ", conversation \($0.index)" } ?? "")
                }
            }
            o["marks"] = .array(marks.map { m in
                var mo: [String: JSON] = ["seconds": .double(m), "time": .string(iso(r.start.addingTimeInterval(m)))]
                mo["conversation"] = conversation(m).map { .int($0.index) } ?? .null
                return .object(mo)
            })
        } else {
            // 没有 marks.json：加这个功能之前下载的，不知道有没有标记
            o["marks"] = .null
        }
        // 对话段和段摘要（心力模式录音的原文不给看时，这是能读到的内容）
        let convs = library.conversations(r.id)
        if convs.count > 1 || convs.contains(where: { $0.summary != nil }) {
            lines.append("")
            lines.append(visible ? "Conversations (read one with get_transcript and its conversation number):" : "Conversations:")
            lines += convs.map(conversationLine)
            o["conversations"] = .array(convs.map { conversationJSON(r, $0) })
        }
        lines.append("")
        let note = library.notePath(r.id)
        if let note { lines.append("Note file: \(note)") }
        o["note_path"] = .from(note)
        lines.append("Open in OpenBean: \(openURL(r.id))")
        o.merge(contextJSON) { a, _ in a }
        return ToolResult(text: lines.joined(separator: "\n"), structured: .object(o), isError: false)
    }

    // MARK: - get_transcript

    func getTranscript(_ a: [String: JSON]) throws -> ToolResult {
        let r = try recording(a)
        if !transcriptVisible(r) { return privateTranscript(r) }
        var from = try number(a, "start_seconds") ?? 0
        var to = try number(a, "end_seconds")
        var conv: Conversation?
        if let n = try number(a, "conversation") {
            let all = library.conversations(r.id)
            guard let c = all.first(where: { Double($0.index) == n }) else {
                throw ToolError(all.isEmpty ? "Recording \(r.id) isn't split into conversations; read it with start_seconds / end_seconds."
                                : "Recording \(r.id) has conversations 0 to \(all.count - 1); there is no conversation \(seconds(n)).")
            }
            conv = c
            from = c.start
            to = c.end + 0.01
        }
        let maxChars = try int(a, "max_chars", default: 6000, in: 200...50000)
        if let to, to <= from { throw ToolError("end_seconds must be greater than start_seconds.") }
        let segs: [LibrarySegment]
        switch library.transcript(r.id) {
        case let .ok(s): segs = s
        case .unreadable: throw ToolError("The transcript of recording \(r.id) can't be read right now (OpenBean may be writing it). Try again shortly.")
        case .missing: throw ToolError("Recording \(r.id) has no transcript: \(statusSentence(r))")
        }
        // 和范围有重叠的句子（时长为 0 的句子按开始时间算）
        let wanted = segs.filter { seg in
            (seg.end > from || seg.start >= from) && (to.map { seg.start < $0 } ?? true)
        }
        var picked: [LibrarySegment] = []
        var used = 0
        var next: Double?
        for seg in wanted {
            let line = "\(timestamp(seg.start)) \(seg.text)"
            if !picked.isEmpty, used + line.count > maxChars { next = seg.start; break }
            picked.append(seg)
            used += line.count + 1
        }
        let s = library.summary(r.id).value
        var span = (from > 0 || to != nil) ? " from \(timestamp(from)) to \(to.map(timestamp) ?? "the end")" : ""
        if let conv { span = ", conversation \(conv.index)" + span }
        var lines = ["Transcript of recording \(r.id) (\(title(r, s) ?? "untitled"), started \(localDateTime(r.start)))\(span):"]
        if picked.isEmpty { lines.append("(nothing in this range; the recording is \(clock(r.duration)) long)") }
        lines += picked.map { "\(timestamp($0.start)) \($0.text)" }
        if let next {
            lines.append("[Cut at about \(maxChars) characters. Call get_transcript with id \(r.id) and start_seconds=\(seconds(next)) to read on.]")
        }
        var o: [String: JSON] = ["id": .int(Int(r.id)), "title": .from(title(r, s)), "start": .string(iso(r.start)),
                                 "start_seconds": .double(from), "end_seconds": .from(to),
                                 "segments": .array(picked.map { ["start": .double($0.start), "end": .double($0.end), "text": .string($0.text)] }),
                                 "total_segments": .int(segs.count), "truncated": .bool(next != nil),
                                 "next_start_seconds": .from(next)]
        if let conv { o["conversation"] = conversationJSON(r, conv) }
        o.merge(contextJSON) { a, _ in a }
        return ToolResult(text: lines.joined(separator: "\n"), structured: .object(o), isError: false)
    }

    // MARK: - search_recordings

    func searchRecordings(_ a: [String: JSON]) throws -> ToolResult {
        guard let query = try optionalString(a, "query") else { throw ToolError("query is required: the text to look for.") }
        let range = try dateRange(a)
        let limit = try int(a, "limit", default: 10, in: 1...50)
        let (hits, total) = try library.search(query, in: range?.interval, limit: limit, transcriptVisible: transcriptVisible)
        let scope = range.map { " " + $0.label } ?? ""
        var lines: [String] = []
        if hits.isEmpty {
            lines.append("No recordings\(scope) mention \"\(query)\". \(contextLine)")
            lines.append("Matching is by exact substring (case-insensitive). Try a shorter keyword, a synonym or another spelling.")
        } else {
            lines.append("\"\(query)\" found in \(total) recording\(total == 1 ? "" : "s")\(scope)"
                         + "\(hits.count < total ? ", showing the newest \(hits.count)" : ""). \(contextLine)")
        }
        var results: [JSON] = []
        for h in hits {
            let r = h.recording
            let s = library.summary(r.id).value
            lines.append("")
            lines.append("• id \(r.id) — \(localDateTime(r.start)) — \(title(r, s) ?? "(untitled)") (\(h.total) match\(h.total == 1 ? "" : "es"))")
            var ms: [JSON] = []
            for m in h.matches {
                if let c = m.conversation {
                    lines.append("  conversation \(c) summary: \(m.snippet)")
                    ms.append(["field": .string(m.field.rawValue), "conversation": .int(c), "snippet": .string(m.snippet)])
                } else if let t = m.time {
                    lines.append("  \(timestamp(t)) \(m.snippet)")
                    ms.append(["field": .string(m.field.rawValue), "time_seconds": .double(t), "timestamp": .string(timestamp(t)),
                               "at": .string(iso(r.start.addingTimeInterval(t))), "snippet": .string(m.snippet)])
                } else {
                    lines.append("  \(m.field.rawValue.replacingOccurrences(of: "_", with: " ")): \(m.snippet)")
                    ms.append(["field": .string(m.field.rawValue), "snippet": .string(m.snippet)])
                }
            }
            if h.total > h.matches.count { lines.append("  … \(h.total - h.matches.count) more in this recording") }
            var o = brief(r, s).object!
            o["match_count"] = .int(h.total)
            o["matches"] = .array(ms)
            results.append(.object(o))
        }
        var out = contextJSON
        out["query"] = .string(query)
        out["total"] = .int(total)
        out["results"] = .array(results)
        if let range { out["from"] = .string(range.from); out["to"] = .string(range.to) }
        return ToolResult(text: lines.joined(separator: "\n"), structured: .object(out), isError: false)
    }

    // MARK: - day_overview

    func dayOverview(_ a: [String: JSON]) throws -> ToolResult {
        let dayText = try optionalString(a, "date") ?? "today"
        let day = try parseDay(dayText, key: "date")
        let interval = boundary.interval(of: day)
        // 只有一段的录音按开始时刻归天；切成多段的按段的开始时刻（前一天开始的长录音，后面的段可能落在这天）
        var list: [LibraryRecording] = []
        var dayConvs: [UInt32: [Conversation]] = [:]
        for r in try library.recordings(in: DateInterval(start: interval.start.addingTimeInterval(-86_400), end: interval.end)).reversed() {
            let convs = library.conversations(r.id)
            if convs.count > 1 {
                let mine = convs.filter { $0.wallStart >= interval.start && $0.wallStart < interval.end }
                if !mine.isEmpty { list.append(r); dayConvs[r.id] = mine }
            } else if r.start >= interval.start && r.start < interval.end {
                list.append(r)
            }
        }
        let label = dayLabel(day)
        let total = list.reduce(0.0) { $0 + $1.duration }
        var lines = [list.isEmpty ? "\(label): no recordings. \(contextLine)"
                                  : "\(label): \(list.count) recording\(list.count == 1 ? "" : "s"), \(clock(total)) in total. \(contextLine)"]
        var out = contextJSON
        if let file = library.day(dayString(day)), file.dayStartHour == boundary.startHour, let d = file.diary {
            lines += diaryLines(file, d)
            out["diary"] = diaryJSON(file, d)
        }
        var items: [JSON] = []
        var todos: [JSON] = []
        for r in list {
            let s = library.summary(r.id).value
            lines.append("")
            lines.append("\(time(r.start)) · \(clock(r.duration)) · \(title(r, s) ?? "(untitled)") (id \(r.id))")
            var o = brief(r, s).object!
            if let convs = dayConvs[r.id] {
                lines.append(transcriptVisible(r) ? "Conversations (read one with get_transcript id \(r.id) and its conversation number):"
                                                  : "Conversations (Heart mode recording; the words are private):")
                lines += convs.map(conversationLine)
                o["conversations"] = .array(convs.map { conversationJSON(r, $0) })
            }
            if let s {
                if !s.summary.isEmpty { lines.append(s.summary) }
                if !s.keyPoints.isEmpty { lines.append("Key points:"); lines += s.keyPoints.map { "- " + $0 } }
                if !s.actionItems.isEmpty { lines.append("Action items:"); lines += s.actionItems.map { "- " + $0 } }
                o["summary"] = .string(s.summary)
                o["key_points"] = .array(s.keyPoints.map { .string($0) })
                o["action_items"] = .array(s.actionItems.map { .string($0) })
                todos += s.actionItems.map { ["recording_id": .int(Int(r.id)), "text": .string($0)] }
            } else {
                lines.append(gist(r, nil).map { "No summary. Starts: " + $0 } ?? "No summary. " + statusSentence(r))
                o["summary"] = .null
                o["gist"] = .from(gist(r, nil))
            }
            items.append(.object(o))
        }
        if !todos.isEmpty {
            lines.append("")
            lines.append("All action items of the day:")
            lines += todos.map { "- \($0["text"]?.string ?? "") (id \($0["recording_id"]?.number.map { String(Int($0)) } ?? ""))" }
        }
        out["date"] = .string(dayString(day))
        out["recordings"] = .array(items)
        out["total_duration_seconds"] = .double((total * 10).rounded() / 10)
        out["action_items"] = .array(todos)
        return ToolResult(text: lines.joined(separator: "\n"), structured: .object(out), isError: false)
    }

    // MARK: - 对话段和日记

    /// 「09:12–09:40」（墙上时间只是近似时前面加 ~）
    func wall(_ c: Conversation) -> String { (c.wallApprox ? "~" : "") + "\(time(c.wallStart))–\(time(c.wallEnd))" }

    func conversationJSON(_ r: LibraryRecording, _ c: Conversation) -> JSON {
        var o: [String: JSON] = ["recording_id": .int(Int(r.id)), "index": .int(c.index), "start": .string(iso(c.wallStart)),
                                 "end": .string(iso(c.wallEnd)), "approximate_time": .bool(c.wallApprox),
                                 "start_seconds": .double(c.start), "end_seconds": .double(c.end), "kind": .from(c.kind)]
        if let s = c.summary {
            o["title"] = .string(s.title)
            o["summary"] = .string(s.summary)
            o["decisions"] = .array(s.decisions.map { .string($0) })
            o["todos"] = .array(s.todos.map { .string($0) })
            o["people"] = .array(s.people.map { .string($0) })
        }
        return .object(o)
    }

    func refText(_ ref: ConversationRef, _ byRef: [ConversationRef: DayConversation]) -> String {
        let at = byRef[ref].map { ($0.wallApprox ? "~" : "") + time($0.wallStart) + " " } ?? ""
        return "\(at)id \(ref.recording) conversation \(ref.index)"
    }

    func diaryLines(_ f: DayFile, _ d: Diary) -> [String] {
        let byRef = Dictionary(f.conversations.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        func refs(_ r: [ConversationRef]) -> String { r.map { refText($0, byRef) }.joined(separator: "; ") }
        var l = ["", "Diary (written by OpenBean from the conversation summaries; each item names where it comes from):"]
        if let o = d.overview, !o.isEmpty { l.append(o) }
        if !d.decisions.isEmpty { l.append("Decided:"); l += d.decisions.map { "- \($0.text) (\(refs($0.refs)))" } }
        if !d.todos.isEmpty {
            l.append("To-dos:")
            l += d.todos.map { "- \($0.text)\($0.owner.map { " — " + $0 } ?? "") (\(refs($0.refs)))" }
        }
        if !d.people.isEmpty {
            l.append("People mentioned (as spelled in the transcripts, not merged):")
            l += d.people.map { "- \($0.name) (\(refs($0.refs)))" }
        }
        return l
    }

    func diaryJSON(_ f: DayFile, _ d: Diary) -> JSON {
        func refs(_ r: [ConversationRef]) -> JSON { .array(r.map { ["recording_id": .int(Int($0.recording)), "conversation": .int($0.index)] }) }
        func items(_ xs: [DiaryItem]) -> JSON {
            .array(xs.map { x in ["text": .string(x.text), "owner": .from(x.owner), "sources": refs(x.refs)] })
        }
        return ["overview": .from(d.overview), "decisions": items(d.decisions), "todos": items(d.todos),
                "people": .array(d.people.map { ["name": .string($0.name), "sources": refs($0.refs)] }),
                "things": .array(d.things.map { ["name": .string($0.name), "sources": refs($0.refs)] }),
                "written_at": .string(iso(f.createdAt)), "model": .from(f.model)]
    }

    // MARK: - 共用

    /// 每条录音的基本字段
    func brief(_ r: LibraryRecording, _ s: LibrarySummary?) -> JSON {
        [
            "id": .int(Int(r.id)), "title": .from(title(r, s)), "start": .string(iso(r.start)),
            "end": r.end.map { .string(iso($0)) } ?? .null,
            "duration_seconds": .double((r.duration * 10).rounded() / 10),
            "status": .string(status(r)), "has_transcript": .bool(library.hasTranscript(r.id)), "has_summary": .bool(s != nil),
            "open_url": .string(openURL(r.id)),
        ]
    }

    func title(_ r: LibraryRecording, _ s: LibrarySummary?) -> String? {
        if let t = r.title { return t }
        if let t = s?.title, !t.isEmpty { return t }
        return nil
    }

    func status(_ r: LibraryRecording) -> String {
        if library.hasTranscript(r.id) { return "transcribed" }
        return r.downloaded ? "not_transcribed" : "not_on_mac"
    }

    func statusSentence(_ r: LibraryRecording) -> String {
        switch status(r) {
        case "not_on_mac": return "this recording is still only on the recorder; OpenBean hasn't synced it to the Mac yet."
        case "not_transcribed": return "this recording hasn't been transcribed yet."
        default: return "transcribed."
        }
    }

    func flags(_ r: LibraryRecording, _ s: LibrarySummary?) -> String {
        switch status(r) {
        case "transcribed": return s != nil ? "transcript, summary" : "transcript"
        case "not_on_mac": return "only on the recorder, not synced yet"
        default: return "not transcribed yet"
        }
    }

    /// 一行要点：摘要的开头，没有就用转写的开头
    func gist(_ r: LibraryRecording, _ s: LibrarySummary?) -> String? {
        if let t = s?.summary, !t.isEmpty { return oneLine(t, 160) }
        guard transcriptVisible(r) else {
            // 原文不给看：用第一段的段摘要
            return library.conversations(r.id).lazy.compactMap { $0.summary?.summary }.first { !$0.isEmpty }.map { oneLine($0, 160) }
        }
        guard let segs = library.transcript(r.id).value, !segs.isEmpty else { return nil }
        var text = ""
        for seg in segs { text += (text.isEmpty ? "" : " ") + seg.text; if text.count >= 120 { break } }
        return oneLine(text, 120)
    }

    // MARK: 心力模式录音的原文

    static let privateNote = "This recording was made in OpenBean's Heart mode, and the user keeps the words of Heart mode recordings private from agents "
        + "(they can allow it in OpenBean → Settings → Heart mode). Its conversation summaries and the day's diary (day_overview) are available."

    /// 这条录音的转写原文能不能给（HeartPrivacy）
    func transcriptVisible(_ r: LibraryRecording) -> Bool {
        HeartPrivacy.transcriptVisible(source: r.source, agentMayReadHeartTranscripts: heartTranscriptsAllowed())
    }

    func conversationLine(_ c: Conversation) -> String {
        var line = "- conversation \(c.index): \(wall(c))"
        if let cs = c.summary {
            if !cs.title.isEmpty { line += " · \(cs.title)" }
            if !cs.summary.isEmpty { line += " — \(cs.summary)" }
        } else if c.kind == "fragment" { line += " · a few words" }
        return line
    }

    /// get_transcript 遇到不给原文的录音：不算出错，说明原因，给出段摘要和那天的 day_overview
    func privateTranscript(_ r: LibraryRecording) -> ToolResult {
        let s = library.summary(r.id).value
        let convs = library.conversations(r.id)
        let day = dayString(boundary.day(of: r.start))
        var lines = ["Transcript of recording \(r.id) (\(title(r, s) ?? "untitled"), started \(localDateTime(r.start))) is private.",
                     Self.privateNote]
        let summarized = convs.filter { $0.summary != nil }
        if summarized.isEmpty {
            lines.append("It has no conversation summaries yet\(s == nil ? "" : "; get_recording has its summary").")
        } else {
            lines.append("")
            lines.append("Conversation summaries:")
            lines += convs.map(conversationLine)
        }
        lines.append("")
        lines.append("The day's diary: day_overview with date \(day).")
        var o: [String: JSON] = ["id": .int(Int(r.id)), "title": .from(title(r, s)), "start": .string(iso(r.start)),
                                 "transcript_private": .bool(true), "segments": .array([]),
                                 "conversations": .array(convs.map { conversationJSON(r, $0) }),
                                 "day": .string(day)]
        o.merge(contextJSON) { a, _ in a }
        return ToolResult(text: lines.joined(separator: "\n"), structured: .object(o), isError: false)
    }

    func oneLine(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    func openURL(_ id: UInt32) -> String { "\(location.linkScheme)://open/\(id)" }

    func recording(_ a: [String: JSON]) throws -> LibraryRecording {
        guard let v = a["id"] else { throw ToolError("id is required: a recording id from list_recordings or search_recordings.") }
        guard let d = v.number ?? v.string.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
              d >= 0, d <= Double(UInt32.max), d == d.rounded() else {
            throw ToolError("id must be a whole number, e.g. 1794467493.")
        }
        guard let r = try library.recording(UInt32(d)) else {
            throw ToolError("No recording with id \(Int(d)). Use list_recordings or search_recordings to find ids.")
        }
        return r
    }

    // MARK: 参数

    func optionalString(_ a: [String: JSON], _ key: String) throws -> String? {
        guard let v = a[key], v != .null else { return nil }
        guard let s = v.string else { throw ToolError("\(key) must be a string.") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func number(_ a: [String: JSON], _ key: String) throws -> Double? {
        guard let v = a[key], v != .null else { return nil }
        guard let d = v.number ?? v.string.flatMap({ Double($0) }), d.isFinite, d >= 0 else {
            throw ToolError("\(key) must be a number of seconds, 0 or more.")
        }
        return d
    }

    /// 整数参数；超出范围的夹到范围内
    func int(_ a: [String: JSON], _ key: String, default def: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let d = try number(a, key) else { return def }
        return min(max(Int(d.rounded()), range.lowerBound), range.upperBound)
    }

    struct Range {
        var interval: DateInterval
        var from: String
        var to: String
        var label: String
    }

    /// from / to 两个本地日期（都含），任一可省
    func dateRange(_ a: [String: JSON]) throws -> Range? {
        let f = try optionalString(a, "from"), t = try optionalString(a, "to")
        guard f != nil || t != nil else { return nil }
        let firstDay = try f.map { try parseDay($0, key: "from") }
        let lastDay = try t.map { try parseDay($0, key: "to") }
        // 每天按 boundary 的起点算：from 那天的起点到 to 那天的终点（下一天的起点）
        let start = firstDay.map { boundary.interval(of: $0).start } ?? Date.distantPast
        let end = lastDay.map { boundary.interval(of: $0).end } ?? Date.distantFuture
        guard start < end else { throw ToolError("from (\(f!)) is after to (\(t!)).") }
        let fs = firstDay.map(dayString) ?? "", ts = lastDay.map(dayString) ?? ""
        let label: String
        switch (f, t) {
        case (.some, .some) where fs == ts: label = "on \(fs)"
        case (.some, .some): label = "from \(fs) to \(ts)"
        case (.some, nil): label = "since \(fs)"
        default: label = "until \(ts)"
        }
        return Range(interval: DateInterval(start: start, end: end), from: fs, to: ts, label: label)
    }

    /// 本地日期的零点（当作那一天的标识）；today / yesterday 按 boundary 算，凌晨 4 点前的「今天」还是前一天
    func parseDay(_ s: String, key: String) throws -> Date {
        let today = boundary.day(of: now())
        switch s.lowercased() {
        case "today": return today
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)!
        default: break
        }
        let parts = s.split(separator: "-")
        if parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
           let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
           calendar.component(.month, from: date) == m, calendar.component(.day, from: date) == d {
            return calendar.startOfDay(for: date)
        }
        throw ToolError("\(key) must be a local date like \(dayString(today)), or \"today\" / \"yesterday\"; got \"\(s)\".")
    }

    // MARK: 时间格式

    /// 每个结果都带上时区和今天的日期：模型常常不知道用户那边是几号
    var contextLine: String { "Times are in \(timeZone.identifier); today is \(dayString(boundary.day(of: now()))). \(dayRule)" }
    var contextJSON: [String: JSON] {
        ["time_zone": .string(timeZone.identifier), "today": .string(dayString(boundary.day(of: now()))),
         "day_starts_at": .string(String(format: "%02d:00", boundary.startHour))]
    }

    /// 「一天从几点算」的说明（写给模型看）
    var dayRule: String {
        boundary.startHour == 0 ? ""
            : String(format: "A day runs from %02d:00 to %02d:00 the next morning, so a recording at 01:30 belongs to the day before.",
                     boundary.startHour, boundary.startHour)
    }

    func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.calendar = calendar
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = timeZone
        d.dateFormat = f
        return d
    }

    func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    func dayString(_ d: Date) -> String { formatter("yyyy-MM-dd").string(from: d) }
    func dayLabel(_ d: Date) -> String { formatter("yyyy-MM-dd (EEEE)").string(from: d) }
    func localDateTime(_ d: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: d) }
    func time(_ d: Date) -> String { formatter("HH:mm").string(from: d) }

    /// 时长：m:ss 或 h:mm:ss
    func clock(_ t: Double) -> String {
        let s = max(Int(t.rounded()), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 转写里的时间戳，和笔记一样用 [mm:ss]，超过一小时 [h:mm:ss]
    func timestamp(_ t: Double) -> String {
        let s = max(Int(t), 0)
        return s >= 3600 ? String(format: "[%d:%02d:%02d]", s / 3600, s / 60 % 60, s % 60) : String(format: "[%02d:%02d]", s / 60, s % 60)
    }

    func seconds(_ t: Double) -> String { t == t.rounded() ? String(Int(t)) : String(format: "%.2f", t) }
}
