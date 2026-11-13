// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 只读访问 OpenBean App 的录音库（`<数据目录>/Library`）。
///
/// App 可能正在写这些文件：它都是整份原子替换，但这里仍不假设文件完整——读不了、解析不了的
/// 当作「暂时不可用」，跳过并继续，从不抛到调用方之外，也从不写任何东西。
/// 语音输入留下的片段（isDictation）不算录音，一律过滤掉。
public struct RecordingLibrary: Sendable {
    /// Library 文件夹（里面有 index.json 和每条录音的 <id>/ 文件夹）
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public enum LibraryError: Error, Equatable, CustomStringConvertible {
        /// 没有 index.json：App 没装、没同步过，或路径不对
        case notFound(String)
        /// index.json 读不了或不是 JSON 数组（可能正被写）
        case unreadable(String)

        public var description: String {
            switch self {
            case let .notFound(p): return "No OpenBean recording library at \(p). Open OpenBean and sync a recording first, or check the path."
            case let .unreadable(p): return "The recording library index at \(p) could not be read right now. Try again in a moment."
            }
        }
    }

    /// 单个文件的读取结果
    public enum Load<T: Sendable>: Sendable {
        case ok(T)
        /// 文件不存在
        case missing
        /// 文件在但读不了或解析不了（可能正被写）
        case unreadable

        public var value: T? { if case let .ok(v) = self { return v } else { return nil } }
    }

    var indexURL: URL { folder.appendingPathComponent("index.json") }
    func file(_ id: UInt32, _ name: String) -> URL {
        folder.appendingPathComponent(String(id)).appendingPathComponent(name)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: indexURL.path) }

    // MARK: 索引

    /// 所有录音（不含语音输入片段），新的在前。index.json 里坏掉的项跳过，id 重复的取第一项。
    public func recordings() throws -> [LibraryRecording] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { throw LibraryError.notFound(folder.path) }
        guard let data = try? Data(contentsOf: indexURL), let items = Parse.json(data) as? [Any] else {
            throw LibraryError.unreadable(indexURL.path)
        }
        var seen = Set<UInt32>()
        return items.compactMap(Parse.recording)
            .filter { !$0.isDictation && seen.insert($0.id).inserted }
            .sorted { $0.start != $1.start ? $0.start > $1.start : $0.id > $1.id }
    }

    public func recording(_ id: UInt32) throws -> LibraryRecording? {
        try recordings().first { $0.id == id }
    }

    /// 开始时间落在 range 里的录音（左闭右开），新的在前
    public func recordings(in range: DateInterval?) throws -> [LibraryRecording] {
        let all = try recordings()
        guard let range else { return all }
        return all.filter { $0.start >= range.start && $0.start < range.end }
    }

    // MARK: 每条录音的文件

    private func load<T>(_ url: URL, _ parse: (Any) -> T?) -> Load<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let json = Parse.json(data), let v = parse(json) else { return .unreadable }
        return .ok(v)
    }

    /// 转写的句子，按开始时间排序；坏掉的句子跳过
    public func transcript(_ id: UInt32) -> Load<[LibrarySegment]> {
        load(file(id, "transcript.json")) { json in
            (json as? [Any]).map { $0.compactMap(Parse.segment).sorted { $0.start < $1.start } }
        }
    }

    public func summary(_ id: UInt32) -> Load<LibrarySummary> {
        load(file(id, "summary.json"), Parse.summary)
    }

    /// 知识库里那份 Markdown 笔记的路径（note.json 记的；文件本身可能已被用户移走）
    public func notePath(_ id: UInt32) -> String? {
        load(file(id, "note.json")) { json -> String? in
            guard let p = (json as? [String: Any])?["path"] as? String, !p.isEmpty else { return nil }
            return p
        }.value
    }

    /// 这条录音按停顿切成的对话段（segments.json）。文件和现在的转写对不上（转写刚变、App 还没重算）就当作没有
    public func conversations(_ id: UInt32) -> [Conversation] {
        guard let f = ConversationFile.read(file(id, "segments.json")), let segs = transcript(id).value else { return [] }
        let lines = segs.map { ConversationFile.Line(start: $0.start, end: $0.end, text: $0.text) }
        guard f.transcriptHash == ConversationFile.fingerprint(lines) else { return [] }
        return f.segments.filter { $0.to <= segs.count }
    }

    /// 某天（yyyy-MM-dd）的日文件 days/<日期>/day.json；没有或读不了返回 nil
    public func day(_ key: String) -> DayFile? {
        DayFile.read(DayFile.url(library: folder, date: key))
    }

    /// 有没有转写：以文件为准（index 里的 transcribed 可能和文件不同步）
    public func hasTranscript(_ id: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: file(id, "transcript.json").path)
    }

    public func hasSummary(_ id: UInt32) -> Bool {
        summary(id).value != nil
    }

    // MARK: 搜索

    /// 一处命中
    public struct Match: Sendable, Hashable {
        public enum Field: String, Sendable {
            case title, summary, keyPoint = "key_point", actionItem = "action_item", transcript
        }
        public var field: Field
        /// 转写命中时：这句的开始时间（秒，相对录音开头）
        public var time: Double?
        /// 命中处前后的文字
        public var snippet: String
    }

    public struct Hit: Sendable {
        public var recording: LibraryRecording
        /// 最多 perRecording 处，标题和摘要在前、转写按时间
        public var matches: [Match]
        /// 这条录音里的命中总数
        public var total: Int
    }

    /// 在标题、摘要（含要点、待办）和转写里找子串：不分大小写和全半角，不分词（中文没有空格）。
    /// 返回命中的录音（新的在前，最多 limit 条）和命中的录音总数。
    public func search(_ query: String, in range: DateInterval? = nil, limit: Int = 10,
                       perRecording: Int = 5) throws -> (hits: [Hit], totalRecordings: Int) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], 0) }
        var hits: [Hit] = []
        var total = 0
        for r in try recordings(in: range) {
            let found = matches(in: r, query: q)
            guard !found.isEmpty else { continue }
            total += 1
            if hits.count < limit {
                hits.append(Hit(recording: r, matches: Array(found.prefix(perRecording)), total: found.count))
            }
        }
        return (hits, total)
    }

    /// 这条录音里所有命中
    public func matches(in r: LibraryRecording, query q: String) -> [Match] {
        var out: [Match] = []
        let summary = summary(r.id).value
        let titles = [r.title, summary?.title].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for t in titles where TextMatch.contains(t, q) { out.append(Match(field: .title, snippet: TextMatch.snippet(t, q))) }
        if let s = summary {
            if TextMatch.contains(s.summary, q) { out.append(Match(field: .summary, snippet: TextMatch.snippet(s.summary, q))) }
            for k in s.keyPoints where TextMatch.contains(k, q) { out.append(Match(field: .keyPoint, snippet: TextMatch.snippet(k, q))) }
            for a in s.actionItems where TextMatch.contains(a, q) { out.append(Match(field: .actionItem, snippet: TextMatch.snippet(a, q))) }
        }
        if let segs = transcript(r.id).value {
            for (i, seg) in segs.enumerated() where TextMatch.contains(seg.text, q) {
                let before = i > 0 ? segs[i - 1].text : ""
                let after = i + 1 < segs.count ? segs[i + 1].text : ""
                out.append(Match(field: .transcript, time: seg.start,
                                 snippet: TextMatch.snippet(seg.text, q, before: before, after: after)))
            }
        }
        return out
    }

    /// list 的关键词过滤：标题、摘要或转写里有这个子串
    public func contains(_ r: LibraryRecording, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if let t = r.title, TextMatch.contains(t, q) { return true }
        if let s = summary(r.id).value,
           ([s.title, s.summary] + s.keyPoints + s.actionItems).contains(where: { TextMatch.contains($0, q) }) { return true }
        return transcript(r.id).value?.contains { TextMatch.contains($0.text, q) } ?? false
    }
}

/// 子串匹配和前后文片段
public enum TextMatch {
    static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]

    public static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: options) != nil
    }

    /// 命中处前后各约 radius 个字；before / after 是相邻的句子，各取靠近命中的一段
    public static func snippet(_ text: String, _ query: String, before: String = "", after: String = "", radius: Int = 60) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: query, options: options) else { return String(t.prefix(radius * 2)) }
        let headRoom = t.distance(from: t.startIndex, to: r.lowerBound)
        let tailRoom = t.distance(from: r.upperBound, to: t.endIndex)
        let lo = t.index(r.lowerBound, offsetBy: -min(radius, headRoom))
        let hi = t.index(r.upperBound, offsetBy: min(radius, tailRoom))
        var s = String(t[lo..<hi])
        if lo > t.startIndex { s = "…" + s } else {
            // 命中靠近句首：补上一句的结尾
            let b = before.trimmingCharacters(in: .whitespacesAndNewlines)
            let room = radius - headRoom
            if !b.isEmpty, room > 10 { s = (b.count > room ? "…" + String(b.suffix(room)) : b) + " " + s }
        }
        if hi < t.endIndex { s += "…" } else {
            let a = after.trimmingCharacters(in: .whitespacesAndNewlines)
            let room = radius - tailRoom
            if !a.isEmpty, room > 10 { s += " " + (a.count > room ? String(a.prefix(room)) + "…" : a) }
        }
        return s
    }
}
