// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// 指向某条录音的某一段对话：写成 `<录音 id>#<段号>`，日记里每条结论都带一个或几个
public struct ConversationRef: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public var recording: UInt32
    public var index: Int

    public init(recording: UInt32, index: Int) {
        self.recording = recording
        self.index = index
    }

    public init?(_ s: String) {
        let p = s.split(separator: "#")
        guard p.count == 2, let r = UInt32(p[0]), let i = Int(p[1]), i >= 0 else { return nil }
        recording = r
        index = i
    }

    public var description: String { "\(recording)#\(index)" }
    public static func < (a: Self, b: Self) -> Bool { (a.recording, a.index) < (b.recording, b.index) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let r = ConversationRef(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad ref \(s)"))
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// `Library/days/<YYYY-MM-DD>/day.json`：一天的对话段列表和（开着「每天写一篇日记」时）当天的日记。
///
/// - 一段对话归哪天按这段的开始时刻（墙上时间）和 DayBoundary 算，不按录音的开始时刻：跨过分界的长录音会分到两天。
/// - `signature` 是当天所有输入（段的指纹和段摘要）的指纹：没变就不重算，过去的日子不会反复调用大模型。
/// - 日记里每条「定了的事」「待办」「人」「事」都带出处（refs）。写的时候已经校验过出处存在，读的人还可以再查。
/// - 读的时候宽容：缺字段用默认值、多出来的字段忽略、坏掉的项跳过。
public struct DayFile: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public enum Status: String, Codable, Sendable {
        /// 有概述、定了的事、待办、人和事
        case diary
        /// 内容太少：只列对话，不写概述
        case brief
    }

    public var version: Int
    /// yyyy-MM-dd
    public var date: String
    /// 写的时候用的时区和「一天从几点开始」
    public var timeZone: String
    public var dayStartHour: Int
    public var signature: String
    public var status: Status
    /// 当天的对话段，按开始时刻排
    public var conversations: [DayConversation]
    public var diary: Diary?
    public var model: String?
    public var createdAt: Date
    /// 这次生成用了几次大模型、多少秒，丢掉了几条出处对不上的结论
    public var stats: DayStats?

    public init(version: Int = DayFile.currentVersion, date: String, timeZone: String, dayStartHour: Int, signature: String,
                status: Status, conversations: [DayConversation], diary: Diary?, model: String?, createdAt: Date,
                stats: DayStats? = nil) {
        self.version = version
        self.date = date
        self.timeZone = timeZone
        self.dayStartHour = dayStartHour
        self.signature = signature
        self.status = status
        self.conversations = conversations
        self.diary = diary
        self.model = model
        self.createdAt = createdAt
        self.stats = stats
    }

    enum Keys: String, CodingKey {
        case version, date, timeZone, dayStartHour, signature, status, conversations, diary, model, createdAt, stats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        date = try c.decode(String.self, forKey: .date)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        timeZone = (try? c.decodeIfPresent(String.self, forKey: .timeZone)) ?? TimeZone.current.identifier
        dayStartHour = (try? c.decodeIfPresent(Int.self, forKey: .dayStartHour)) ?? 4
        signature = (try? c.decodeIfPresent(String.self, forKey: .signature)) ?? ""
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .brief
        conversations = ((try? c.decodeIfPresent([Lenient<DayConversation>].self, forKey: .conversations)) ?? []).compactMap(\.value)
        diary = try? c.decodeIfPresent(Diary.self, forKey: .diary)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        createdAt = ISODate.decode(c, .createdAt) ?? .distantPast
        stats = try? c.decodeIfPresent(DayStats.self, forKey: .stats)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version)
        try c.encode(date, forKey: .date)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(dayStartHour, forKey: .dayStartHour)
        try c.encode(signature, forKey: .signature)
        try c.encode(status, forKey: .status)
        try c.encode(conversations, forKey: .conversations)
        try c.encode(diary, forKey: .diary)
        try c.encode(model, forKey: .model)
        try c.encode(ISODate.string(createdAt), forKey: .createdAt)
        try c.encodeIfPresent(stats, forKey: .stats)
    }

    // MARK: 文件

    public static func folder(library: URL, date: String) -> URL {
        library.appendingPathComponent("days").appendingPathComponent(date)
    }

    public static func url(library: URL, date: String) -> URL {
        folder(library: library, date: date).appendingPathComponent("day.json")
    }

    public static func read(_ url: URL) -> DayFile? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DayFile.self, from: d)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    /// 一天的名字（yyyy-MM-dd）。day 是 DayBoundary.day(of:) 给的那天 0 点，按 calendar 的时区写
    public static func key(_ day: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// key 的反过来：那天的 0 点；格式不对返回 nil
    public static func day(_ key: String, calendar: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// 一组输入的指纹：顺序无关
    public static func signature(_ parts: [String]) -> String {
        var h = SHA256()
        for p in parts.sorted() { h.update(data: Data(p.utf8)); h.update(data: Data([0x0A])) }
        return h.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// 日文件里的一段对话（从 segments.json 抄过来的摘要，方便只读 day.json 的人）
public struct DayConversation: Codable, Sendable, Hashable {
    public var ref: ConversationRef
    public var wallStart: Date
    public var wallEnd: Date
    public var wallApprox: Bool
    public var kind: String?
    public var title: String?
    public var summary: String?

    public init(ref: ConversationRef, wallStart: Date, wallEnd: Date, wallApprox: Bool = false, kind: String? = nil,
                title: String? = nil, summary: String? = nil) {
        self.ref = ref
        self.wallStart = wallStart
        self.wallEnd = wallEnd
        self.wallApprox = wallApprox
        self.kind = kind
        self.title = title
        self.summary = summary
    }

    enum Keys: String, CodingKey { case ref, wallStart, wallEnd, wallApprox, kind, title, summary }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ref = try c.decode(ConversationRef.self, forKey: .ref)
        wallStart = ISODate.decode(c, .wallStart) ?? .distantPast
        wallEnd = ISODate.decode(c, .wallEnd) ?? wallStart
        wallApprox = (try? c.decodeIfPresent(Bool.self, forKey: .wallApprox)) ?? false
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(ref, forKey: .ref)
        try c.encode(ISODate.string(wallStart), forKey: .wallStart)
        try c.encode(ISODate.string(wallEnd), forKey: .wallEnd)
        try c.encode(wallApprox, forKey: .wallApprox)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(summary, forKey: .summary)
    }
}

/// 当天的日记
public struct Diary: Codable, Sendable, Hashable {
    /// 当天概述（2–4 句）；内容太少时没有
    public var overview: String?
    public var decisions: [DiaryItem]
    public var todos: [DiaryItem]
    /// 提到的人：名字照转写写，不合并不同写法；refs 是出现在哪几段
    public var people: [DiaryName]
    public var things: [DiaryName]
    /// 重点标记（录音豆的标记还读不出来，先空着）
    public var marked: [DiaryMark]

    public init(overview: String? = nil, decisions: [DiaryItem] = [], todos: [DiaryItem] = [], people: [DiaryName] = [],
                things: [DiaryName] = [], marked: [DiaryMark] = []) {
        self.overview = overview
        self.decisions = decisions
        self.todos = todos
        self.people = people
        self.things = things
        self.marked = marked
    }

    enum Keys: String, CodingKey { case overview, decisions, todos, people, things, marked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func list<T: Decodable>(_ k: Keys) -> [T] { ((try? c.decodeIfPresent([Lenient<T>].self, forKey: k)) ?? []).compactMap(\.value) }
        overview = try? c.decodeIfPresent(String.self, forKey: .overview)
        decisions = list(.decisions)
        todos = list(.todos)
        people = list(.people)
        things = list(.things)
        marked = list(.marked)
    }
}

/// 一条结论：文字和出处
public struct DiaryItem: Codable, Sendable, Hashable {
    public var text: String
    /// 待办的负责人（模型给的，可能没有）
    public var owner: String?
    public var refs: [ConversationRef]

    public init(text: String, owner: String? = nil, refs: [ConversationRef]) {
        self.text = text
        self.owner = owner
        self.refs = refs
    }

    enum Keys: String, CodingKey { case text, owner, refs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = try c.decode(String.self, forKey: .text)
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        refs = ((try? c.decodeIfPresent([Lenient<ConversationRef>].self, forKey: .refs)) ?? []).compactMap(\.value)
    }
}

public struct DiaryName: Codable, Sendable, Hashable {
    public var name: String
    public var refs: [ConversationRef]

    public init(name: String, refs: [ConversationRef]) {
        self.name = name
        self.refs = refs
    }

    enum Keys: String, CodingKey { case name, refs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        refs = ((try? c.decodeIfPresent([Lenient<ConversationRef>].self, forKey: .refs)) ?? []).compactMap(\.value)
    }
}

public struct DiaryMark: Codable, Sendable, Hashable {
    public var ref: ConversationRef
    /// 秒，相对录音开头
    public var at: Double
    public init(ref: ConversationRef, at: Double) {
        self.ref = ref
        self.at = at
    }
}

public struct DayStats: Codable, Sendable, Hashable {
    /// 合成日记用了几次大模型（不含段摘要）
    public var calls: Int
    public var seconds: Double
    /// 出处对不上、被丢掉的结论条数
    public var dropped: Int
    public init(calls: Int, seconds: Double, dropped: Int) {
        self.calls = calls
        self.seconds = seconds
        self.dropped = dropped
    }
}

// MARK: - 归天

public enum DayAssignment {
    /// 一条录音的各段分别归哪天：按段的开始时刻（墙上时间）。返回 yyyy-MM-dd → 段号
    public static func days(of conversations: [Conversation], boundary: DayBoundary) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for c in conversations {
            out[DayFile.key(boundary.day(of: c.wallStart), calendar: boundary.calendar), default: []].append(c.index)
        }
        return out
    }
}
