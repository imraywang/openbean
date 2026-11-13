// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// `<录音 id>/segments.json`：一条录音按停顿切成的对话段（「段」= 一场连续的谈话，不是转写里的一句）。
///
/// - 只存句子下标、时间和（以后的）段摘要，不复制转写文字；原文以 transcript.json 为准。
/// - 由转写算出来，可以随时重算：`transcriptHash` 和转写对不上（重新转写、词表回填改了字）、
///   切段规则或参数变了，就整份作废重算；重算时范围和文字都没变的段保留它的摘要。
/// - 读的时候宽容：缺字段用默认值，多出来的字段忽略，坏掉的段跳过。日期写成 ISO 8601 字符串，
///   也认 App 的 JSONEncoder 默认格式（2001 年起的秒数）。
public struct ConversationFile: Codable, Sendable, Hashable {
    /// 文件格式版本
    public static let currentVersion = 1

    public var version: Int
    /// 写这份时的切段规则版本（Segmenter.version）
    public var segmenter: Int
    /// 转写的指纹（ConversationFile.fingerprint）
    public var transcriptHash: String
    public var params: Segmenter.Params
    public var segments: [Conversation]

    public init(version: Int = ConversationFile.currentVersion, segmenter: Int = Segmenter.version, transcriptHash: String,
                params: Segmenter.Params, segments: [Conversation]) {
        self.version = version
        self.segmenter = segmenter
        self.transcriptHash = transcriptHash
        self.params = params
        self.segments = segments
    }

    /// 和这份转写、这套参数还对得上（对不上就该重算）
    public func isCurrent(transcriptHash h: String, params p: Segmenter.Params = .standard) -> Bool {
        version == Self.currentVersion && segmenter == Segmenter.version && transcriptHash == h && params == p
    }

    // MARK: 算

    /// 转写的一句：只用到时间和文字
    public struct Line: Sendable, Hashable {
        public var start: Double
        public var end: Double
        public var text: String
        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// 转写的指纹：每句的起止（毫秒精度）和文字。文字用显示的那份（过了词表的），词表回填改了字指纹就变
    public static func fingerprint(_ lines: [Line]) -> String {
        var h = SHA256()
        h.update(data: Data("v1\n".utf8))
        for l in lines {
            h.update(data: Data(String(format: "%.3f|%.3f|", l.start, l.end).utf8))
            h.update(data: Data(l.text.utf8))
            h.update(data: Data([0x0A]))
        }
        return h.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 录音中途停过（暂停后续写）：结束时刻 − 开始时刻 比录音时长多出 5 秒以上。
    /// 这时段内的偏移加到开始时刻上只是近似（暂停的时间不在音频里）。结束时刻不知道（设备给 0）时当作没停过
    public static func likelyPaused(start: Date, end: Date?, duration: Double) -> Bool {
        guard let end, end > start else { return false }
        return end.timeIntervalSince(start) - duration > 5
    }

    /// 切段并生成一份新文件。`previous` 里范围和文字都没变的段，留下它的种类、标记和摘要
    public static func build(_ lines: [Line], recordingStart: Date, wallApprox: Bool,
                             params: Segmenter.Params = .standard, previous: ConversationFile? = nil) -> ConversationFile {
        let pieces = Segmenter.split(lines.map { Segmenter.Line(start: $0.start, end: $0.end) }, params: params)
        let old = Dictionary((previous?.segments ?? []).map { ("\($0.from)-\($0.to)-\($0.hash)", $0) }, uniquingKeysWith: { a, _ in a })
        let segs = pieces.enumerated().map { k, p -> Conversation in
            let hash = fingerprint(Array(lines[p.lines]))
            var c = Conversation(index: k, from: p.lines.lowerBound, to: p.lines.upperBound, start: p.start, end: p.end,
                                 wallStart: recordingStart.addingTimeInterval(p.start), wallEnd: recordingStart.addingTimeInterval(p.end),
                                 wallApprox: wallApprox, cut: p.cut, candidates: p.candidates, hash: hash)
            if let o = old["\(c.from)-\(c.to)-\(hash)"] {
                c.kind = o.kind
                c.marks = o.marks
                c.summary = o.summary
                c.summaryModel = o.summaryModel
                c.summarizedAt = o.summarizedAt
            }
            return c
        }
        return ConversationFile(transcriptHash: fingerprint(lines), params: params, segments: segs)
    }

    // MARK: 读写

    public static func read(_ url: URL) -> ConversationFile? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConversationFile.self, from: d)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    enum Keys: String, CodingKey { case version, segmenter, transcriptHash, params, segments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        segmenter = (try? c.decodeIfPresent(Int.self, forKey: .segmenter)) ?? 0
        transcriptHash = (try? c.decodeIfPresent(String.self, forKey: .transcriptHash)) ?? ""
        params = (try? c.decodeIfPresent(Segmenter.Params.self, forKey: .params)) ?? .standard
        segments = ((try? c.decodeIfPresent([Lenient<Conversation>].self, forKey: .segments)) ?? []).compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version)
        try c.encode(segmenter, forKey: .segmenter)
        try c.encode(transcriptHash, forKey: .transcriptHash)
        try c.encode(params, forKey: .params)
        try c.encode(segments, forKey: .segments)
    }
}

/// 一段对话
public struct Conversation: Codable, Sendable, Hashable, Identifiable {
    /// 这条录音里的第几段（从 0 开始）
    public var index: Int
    /// 转写句子下标，左闭右开
    public var from: Int
    public var to: Int
    /// 秒，相对录音开头
    public var start: Double
    public var end: Double
    /// 墙上时间 = 录音开始时刻 + 段内偏移
    public var wallStart: Date
    public var wallEnd: Date
    /// 墙上时间只是近似（录音中途暂停过）：显示成「约 HH:mm」
    public var wallApprox: Bool
    public var cut: Segmenter.Cut
    /// 段内的候选切点（句子下标），见 Segmenter
    public var candidates: [Int]
    /// 这段句子（时间和文字）的指纹：转写改了只有变了的段需要重新摘要
    public var hash: String
    /// 落在这段里的重点标记（秒，相对录音开头）。录音豆的标记还读不出来，先空着
    public var marks: [Double]
    /// conversation / monologue / media / fragment：由段摘要那一步给，没摘要时没有
    public var kind: String?
    public var summary: ConversationSummary?
    public var summaryModel: String?
    public var summarizedAt: Date?

    public var id: Int { index }
    public var lines: Range<Int> { from..<max(from, to) }
    public var duration: Double { max(end - start, 0) }

    public init(index: Int, from: Int, to: Int, start: Double, end: Double, wallStart: Date, wallEnd: Date,
                wallApprox: Bool = false, cut: Segmenter.Cut = .recordingStart, candidates: [Int] = [], hash: String = "",
                marks: [Double] = [], kind: String? = nil, summary: ConversationSummary? = nil,
                summaryModel: String? = nil, summarizedAt: Date? = nil) {
        self.index = index
        self.from = from
        self.to = to
        self.start = start
        self.end = end
        self.wallStart = wallStart
        self.wallEnd = wallEnd
        self.wallApprox = wallApprox
        self.cut = cut
        self.candidates = candidates
        self.hash = hash
        self.marks = marks
        self.kind = kind
        self.summary = summary
        self.summaryModel = summaryModel
        self.summarizedAt = summarizedAt
    }

    enum Keys: String, CodingKey {
        case index, from, to, start, end, wallStart, wallEnd, wallApprox, cut, candidates, hash, marks, kind, summary,
             summaryModel, summarizedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // 句子范围是必需的，没有就整段不认
        from = try c.decode(Int.self, forKey: .from)
        to = try c.decode(Int.self, forKey: .to)
        guard from >= 0, to >= from else {
            throw DecodingError.dataCorruptedError(forKey: .to, in: c, debugDescription: "bad line range")
        }
        index = (try? c.decodeIfPresent(Int.self, forKey: .index)) ?? 0
        start = (try? c.decodeIfPresent(Double.self, forKey: .start)) ?? 0
        end = (try? c.decodeIfPresent(Double.self, forKey: .end)) ?? start
        wallStart = ISODate.decode(c, .wallStart) ?? .distantPast
        wallEnd = ISODate.decode(c, .wallEnd) ?? wallStart
        wallApprox = (try? c.decodeIfPresent(Bool.self, forKey: .wallApprox)) ?? false
        cut = (try? c.decodeIfPresent(Segmenter.Cut.self, forKey: .cut)) ?? .silence
        candidates = (try? c.decodeIfPresent([Int].self, forKey: .candidates)) ?? []
        hash = (try? c.decodeIfPresent(String.self, forKey: .hash)) ?? ""
        marks = (try? c.decodeIfPresent([Double].self, forKey: .marks)) ?? []
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        summary = try? c.decodeIfPresent(ConversationSummary.self, forKey: .summary)
        summaryModel = try? c.decodeIfPresent(String.self, forKey: .summaryModel)
        summarizedAt = ISODate.decode(c, .summarizedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(index, forKey: .index)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(ISODate.string(wallStart), forKey: .wallStart)
        try c.encode(ISODate.string(wallEnd), forKey: .wallEnd)
        try c.encode(wallApprox, forKey: .wallApprox)
        try c.encode(cut, forKey: .cut)
        try c.encode(candidates, forKey: .candidates)
        try c.encode(hash, forKey: .hash)
        try c.encode(marks, forKey: .marks)
        // 没有的就写 null：一眼能看出「还没摘要」
        try c.encode(kind, forKey: .kind)
        try c.encode(summary, forKey: .summary)
        try c.encode(summaryModel, forKey: .summaryModel)
        try c.encode(summarizedAt.map(ISODate.string), forKey: .summarizedAt)
    }
}

/// 一段对话的摘要（段摘要那一步的输出）。字段都可以空：没有就是没有，不凑数
public struct ConversationSummary: Codable, Sendable, Hashable {
    public var title: String
    public var summary: String
    /// 要点：整条录音的摘要由各段合成时用
    public var keyPoints: [String]
    public var decisions: [String]
    public var todos: [String]
    public var people: [String]
    public var things: [String]

    public init(title: String = "", summary: String = "", keyPoints: [String] = [], decisions: [String] = [],
                todos: [String] = [], people: [String] = [], things: [String] = []) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.todos = todos
        self.people = people
        self.things = things
    }

    enum Keys: String, CodingKey { case title, summary, keyPoints, decisions, todos, people, things }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func strings(_ k: Keys) -> [String] {
            ((try? c.decodeIfPresent([Lenient<String>].self, forKey: k)) ?? []).compactMap(\.value)
        }
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        keyPoints = strings(.keyPoints)
        decisions = strings(.decisions)
        todos = strings(.todos)
        people = strings(.people)
        things = strings(.things)
    }
}

/// 解不了的项变成 nil，不让整个数组失败
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// 日期写成带时区的 ISO 8601 字符串；读的时候也认数字（App 的 JSONEncoder 默认：2001 年起的秒数）
enum ISODate {
    static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return parse(s) }
        if let n = try? c.decodeIfPresent(Double.self, forKey: key), n.isFinite { return Date(timeIntervalSinceReferenceDate: n) }
        return nil
    }
}
