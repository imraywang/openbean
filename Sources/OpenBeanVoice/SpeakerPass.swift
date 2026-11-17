// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一段录音的窗口算完之后：交候选（登记 / 更新声纹）、判定每句。新转写和补算都走这一个函数
public enum SpeakerPass {
    public struct Recording: Sendable {
        public var id: UInt32
        /// 这段录音属于哪一天（App 的日界，那天 0 点）
        public var day: Date
        /// 能拿来登记：心力模式、够长
        public var enrols: Bool
        public init(id: UInt32, day: Date, enrols: Bool) {
            self.id = id
            self.day = day
            self.enrols = enrols
        }

        /// 心力模式、至少 15 分钟的录音才拿来登记（领口上最响的才是佩戴者）
        public static func enrols(heart: Bool, duration: Double) -> Bool {
            heart && duration >= SpeakerID.enrolMinSeconds
        }
    }

    public struct Result: Sendable {
        public var scan: SpeakerScan
        /// 交候选时声纹的变化（没交为 nil）
        public var event: Voiceprint.Event?
        public var worn: SpeakerID.Worn?
        /// 声纹变了（确认、存了候选、慢更新）：调用方要写回声纹文件
        public var voiceprintChanged: Bool
    }

    /// - Parameters:
    ///   - candidate: 这段的主声音（SpeakerID.loudCandidate，算起来最贵，调用方在后台线程先算好）
    ///   - voiceprint: 当前声纹，会被更新
    ///   - segments: 这段的转写，判定结果写进每句；学习中、没戴的时候清掉旧的标签
    public static func run(windows: SpeakerWindows, candidate: SpeakerID.Candidate?, recording: Recording,
                           voiceprint: inout Voiceprint, segments: inout [TranscriptSegment], now: Date = Date()) -> Result {
        var event: Voiceprint.Event?
        var changed = false
        if recording.enrols, let c = candidate, c.windows >= SpeakerID.enrolMinWindows {
            let e = voiceprint.offer(c, recording: recording.id, day: recording.day, now: now)
            event = e
            if case .stored = e { changed = true }
            if case .confirmed = e { changed = true }
        }
        for i in segments.indices { segments[i].clearWearer() }
        guard let v = voiceprint.vector else {
            return Result(scan: SpeakerScan(at: now, outcome: .learning), event: event, worn: nil, voiceprintChanged: changed)
        }
        let worn = SpeakerID.worn(candidate: candidate, voiceprint: v)
        let scores = SpeakerID.sentenceScores(windows, voiceprint: v, sentences: segments.count)
        let labels = SpeakerID.labels(times: segments.map { ($0.start, $0.end) }, scores: scores, worn: worn)
        for i in segments.indices {
            if let s = scores[i] {
                segments[i].wearerShare = (s.share * 1000).rounded() / 1000
                segments[i].wearerScore = (s.median * 1000).rounded() / 1000
            }
            segments[i].isWearer = labels[i]
        }
        // 慢更新：只在最响的声音就是声纹（交了候选且对上）时；刚确认的这段不再重复算
        if case .agrees = event, let m = SpeakerID.confidentMean(windows, voiceprint: v) {
            voiceprint.refine(with: m.vector, count: m.count, now: now)
            changed = true
        }
        let wearer = labels.filter { $0 == true }.count
        let scan = SpeakerScan(at: now, outcome: worn == .notWorn ? .notWorn : .labelled, voiceprint: voiceprint.id,
                               wearerLines: wearer, lines: segments.count)
        return Result(scan: scan, event: event, worn: worn, voiceprintChanged: changed)
    }
}
