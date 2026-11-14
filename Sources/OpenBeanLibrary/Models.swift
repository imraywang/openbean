// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 录音库里的一条录音（index.json 的一项）。
/// 只读这里用得到的字段；App 以后加字段不影响，缺可选字段用默认值。
public struct LibraryRecording: Sendable, Hashable {
    public var id: UInt32
    public var start: Date
    public var end: Date?
    public var durationMs: UInt32
    /// 用户起的名字或摘要自动填的标题；可能没有
    public var title: String?
    /// 录音豆上还有这条
    public var onDevice: Bool
    /// 音频已下载到本机
    public var downloaded: Bool
    /// App 记为已转写（转写文件仍可能暂时读不到）
    public var transcribed: Bool
    public var isDictation: Bool
    /// 在哪种模式下同步进来的（旧录音没有这个字段 = 普通）
    public var source: RecordingSource

    public init(id: UInt32, start: Date, end: Date? = nil, durationMs: UInt32, title: String? = nil,
                onDevice: Bool = false, downloaded: Bool = true, transcribed: Bool = false, isDictation: Bool = false,
                source: RecordingSource = .normal) {
        self.id = id
        self.start = start
        self.end = end
        self.durationMs = durationMs
        self.title = title
        self.onDevice = onDevice
        self.downloaded = downloaded
        self.transcribed = transcribed
        self.isDictation = isDictation
        self.source = source
    }

    public var duration: TimeInterval { Double(durationMs) / 1000 }
}

/// 转写的一句（秒，相对录音开头）
public struct LibrarySegment: Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// summary.json：大模型写的标题、摘要、要点、待办
public struct LibrarySummary: Sendable, Hashable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var actionItems: [String]
    /// 写摘要的模型名
    public var model: String?
    public var createdAt: Date?

    public init(title: String, summary: String, keyPoints: [String] = [], actionItems: [String] = [],
                model: String? = nil, createdAt: Date? = nil) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.model = model
        self.createdAt = createdAt
    }
}

// MARK: - 宽容解析

/// 用 JSONSerialization 逐项解析，不用 Codable：一项坏了只跳过这一项，多出来的字段直接忽略。
/// App 用 JSONEncoder 默认的日期格式写 Date：2001-01-01 起的秒数（Apple 参考时间）。
enum Parse {
    static func json(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func number(_ v: Any?) -> Double? {
        // JSONSerialization 把 true/false 也解成 NSNumber，排除掉
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func uint32(_ v: Any?) -> UInt32? {
        guard let d = number(v), d >= 0, d <= Double(UInt32.max), d == d.rounded() else { return nil }
        return UInt32(d)
    }

    static func date(_ v: Any?) -> Date? {
        number(v).map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    static func strings(_ v: Any?) -> [String] {
        (v as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func recording(_ v: Any) -> LibraryRecording? {
        guard let o = v as? [String: Any], let id = uint32(o["id"]), let start = date(o["start"]) else { return nil }
        return LibraryRecording(
            id: id, start: start, end: date(o["end"]), durationMs: uint32(o["durationMs"]) ?? 0,
            title: (o["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            onDevice: bool(o["onDevice"]) ?? false, downloaded: bool(o["downloaded"]) ?? false,
            transcribed: bool(o["transcribed"]) ?? false, isDictation: bool(o["isDictation"]) ?? false,
            source: RecordingSource(stored: o["source"] as? String))
    }

    static func segment(_ v: Any) -> LibrarySegment? {
        guard let o = v as? [String: Any], let text = o["text"] as? String, let start = number(o["start"]) else { return nil }
        return LibrarySegment(start: start, end: number(o["end"]) ?? start, text: text)
    }

    static func summary(_ v: Any) -> LibrarySummary? {
        guard let o = v as? [String: Any], let s = o["summary"] as? [String: Any] else { return nil }
        let title = s["title"] as? String ?? ""
        let text = s["summary"] as? String ?? ""
        let keyPoints = strings(s["keyPoints"]), actionItems = strings(s["actionItems"])
        guard !(title.isEmpty && text.isEmpty && keyPoints.isEmpty && actionItems.isEmpty) else { return nil }
        return LibrarySummary(title: title, summary: text, keyPoints: keyPoints, actionItems: actionItems,
                              model: o["model"] as? String, createdAt: date(o["createdAt"]))
    }
}
