// SPDX-License-Identifier: Apache-2.0

import Foundation

/// `<录音 id>/marks.json`：用户在录音豆上做的重点标记（双击顶部），秒，相对录音开头。
///
/// 下载时从音频分片的 flags 取出来（每片 20 ms，标记时刻 = seq × 0.02 秒），音频存成 audio.ogg 的同时写这份；
/// 下载完的录音都有这个文件，没有标记时 `marks` 是空的。没有这个文件 = 加这个功能之前下载的，不知道有没有标记。
/// 实测用户是先敲再说：标记一般比说那件事早一秒左右，所以标记落在两句之间时归后一句（见 `MarkPlacement`）。
public struct RecordingMarks: Codable, Sendable, Hashable {
    public static let fileName = "marks.json"
    public static let currentVersion = 1

    public var version: Int
    /// 从小到大、不重复
    public var marks: [Double]

    public init(marks: [Double]) {
        version = Self.currentVersion
        self.marks = Self.normalized(marks)
    }

    static func normalized(_ marks: [Double]) -> [Double] {
        Array(Set(marks.filter { $0.isFinite && $0 >= 0 }.map { ($0 * 100).rounded() / 100 })).sorted()
    }

    enum Keys: String, CodingKey { case version, marks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        marks = Self.normalized(((try? c.decodeIfPresent([Lenient<Double>].self, forKey: .marks)) ?? []).compactMap(\.value))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version)
        try c.encode(marks, forKey: .marks)
    }

    public static func read(_ url: URL) -> RecordingMarks? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingMarks.self, from: d)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}

/// 标记落在哪一句、哪一段对话，以及摘出来给人看的前后文
public enum MarkPlacement {
    /// 标记归哪一句（下标）：在某句的起止之间（前面放宽 0.3 秒）就是这句；落在两句之间归后一句（先敲后说）；
    /// 在最后一句之后归最后一句。没有句子时为 nil。`spans` 按开始时间排好
    public static func line(for mark: Double, spans: [(start: Double, end: Double)]) -> Int? {
        guard !spans.isEmpty else { return nil }
        for (i, s) in spans.enumerated() {
            if mark < s.start - 0.3 { return i }   // 在这句之前（两句之间或第一句之前）
            if mark <= max(s.end, s.start) { return i }
        }
        return spans.count - 1
    }

    /// 每个标记归哪一句：句子下标 → 落在这句的标记（秒，从小到大）
    public static func byLine(_ marks: [Double], spans: [(start: Double, end: Double)]) -> [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        for m in marks.sorted() { if let i = line(for: m, spans: spans) { out[i, default: []].append(m) } }
        return out
    }

    /// 每段对话里的标记（和 `conversations` 一一对应）：标记先归句，再看那句在哪段
    public static func byConversation(_ marks: [Double], spans: [(start: Double, end: Double)],
                                      conversations: [Conversation]) -> [[Double]] {
        let lines = byLine(marks, spans: spans)
        return conversations.map { c in c.lines.flatMap { lines[$0] ?? [] }.sorted() }
    }

    /// 标记那句和前后各 `around` 句（不跨出 `within`，一般是所在的那段对话）
    public static func quote(_ texts: [String], line i: Int, within: Range<Int>? = nil, around: Int = 1) -> [String] {
        let bounds = (within ?? 0..<texts.count).clamped(to: 0..<texts.count)
        guard bounds.contains(i) else { return [] }
        let lo = max(bounds.lowerBound, i - around), hi = min(bounds.upperBound, i + around + 1)
        return texts[lo..<hi].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
