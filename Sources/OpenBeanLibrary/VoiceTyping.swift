// SPDX-License-Identifier: Apache-2.0

import Foundation

/// `Library/voice-typing.json`：录音豆正在录音时用语音输入（旁听）的时间段，墙上时间。
///
/// 心力模式整天在录，旁听时说的话也录进了那条录音。转写照样完整（全文、详情页不变），
/// 但切对话段、段摘要、每日日记要跳过落在这些时间段里的句子：那是打给别的 App 的字，不是当天的谈话。
///
/// - 只记起止时刻，不记文字。读的时候宽容：缺的、坏的项跳过，文件没有就是空的。
/// - 录音开始时刻 = 文件号（设备时钟的 Unix 秒；App 每次连上都会校时），句子的墙上时间 = 开始时刻 + 句内偏移。
public struct VoiceTypingLog: Codable, Sendable, Equatable {
    public static let fileName = "voice-typing.json"
    public static let currentVersion = 1
    /// 时间段两头各放宽多少秒：设备和 Mac 的时钟差、实时流 0.3–0.5 秒的延迟、句子边界不准
    public static let tolerance: Double = 1.5

    public struct Interval: Codable, Sendable, Equatable {
        public var start: Date
        public var end: Date
        public init(start: Date, end: Date) {
            self.start = start
            self.end = max(start, end)
        }
    }

    public var version: Int
    public var intervals: [Interval]

    public init(intervals: [Interval] = []) {
        version = Self.currentVersion
        self.intervals = intervals
    }

    public static func url(library: URL) -> URL { library.appendingPathComponent(fileName) }

    // MARK: 读写

    enum Keys: String, CodingKey { case version, intervals }

    struct LenientInterval: Decodable {
        let value: Interval?
        init(from decoder: Decoder) throws {
            enum K: String, CodingKey { case start, end }
            guard let c = try? decoder.container(keyedBy: K.self),
                  let s = ISODate.decode(c, .start), let e = ISODate.decode(c, .end) else { value = nil; return }
            value = Interval(start: s, end: e)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        intervals = ((try? c.decodeIfPresent([LenientInterval].self, forKey: .intervals)) ?? []).compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        enum K: String, CodingKey { case start, end }
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version)
        var list = c.nestedUnkeyedContainer(forKey: .intervals)
        for i in intervals {
            var o = list.nestedContainer(keyedBy: K.self)
            try o.encode(ISODate.string(i.start), forKey: .start)
            try o.encode(ISODate.string(i.end), forKey: .end)
        }
    }

    /// 没有文件、读不出来：空的
    public static func read(_ url: URL) -> VoiceTypingLog {
        guard let d = try? Data(contentsOf: url), let l = try? JSONDecoder().decode(VoiceTypingLog.self, from: d) else {
            return VoiceTypingLog()
        }
        return l
    }

    /// 读出来、加一段、整份写回（原子写）。按开始时刻排好
    @discardableResult
    public static func append(_ interval: Interval, to url: URL) throws -> VoiceTypingLog {
        var l = read(url)
        l.intervals.append(interval)
        l.intervals.sort { $0.start < $1.start }
        l.version = currentVersion
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(l).write(to: url, options: .atomic)
        return l
    }

    // MARK: 哪些句子是语音输入

    /// 落在语音输入时间段里的句子下标。`spans` 是句子相对录音开头的起止（秒）。
    /// 一句和某个（两头各放宽 `tolerance` 秒的）时间段重叠超过它自己时长的一半，就算语音输入；
    /// 零长度的句子看它在不在时间段里
    public func voiceTypingLines(_ spans: [(start: Double, end: Double)], recordingStart: Date,
                                 tolerance: Double = VoiceTypingLog.tolerance) -> Set<Int> {
        let t0 = recordingStart.timeIntervalSince1970
        let windows = intervals.map { ($0.start.timeIntervalSince1970 - t0 - tolerance, $0.end.timeIntervalSince1970 - t0 + tolerance) }
        guard !windows.isEmpty else { return [] }
        var out = Set<Int>()
        for (i, s) in spans.enumerated() {
            let a = min(s.start, s.end), b = max(s.start, s.end)
            for (wa, wb) in windows {
                let overlap = min(b, wb) - max(a, wa)
                if b - a <= 0 ? (a >= wa && a <= wb) : overlap > (b - a) / 2 {
                    out.insert(i)
                    break
                }
            }
        }
        return out
    }

    /// 这条录音要跳过的句子：只有心力模式的录音才跳（普通录音是用户特意录的，整条都算）
    public func voiceTypingLines(source: RecordingSource, spans: [(start: Double, end: Double)], recordingStart: Date) -> Set<Int> {
        source == .heart ? voiceTypingLines(spans, recordingStart: recordingStart) : []
    }
}
