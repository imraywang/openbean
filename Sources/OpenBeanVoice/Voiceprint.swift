// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 佩戴者的声纹（voiceprint.json）：只有数字，没有音频，也没有文字。
/// 是生物特征数据：只存在本机 App 的数据文件夹里（不在录音库文件夹、不进笔记、导出、MCP、日志、网络请求）。
///
/// 登记是自动的（规则见 SpeakerID）：
/// - 学习中（vector == nil）：长的心力模式录音各给一个候选，等两段**不同日子**的候选相似（≥ 0.75），
///   把相似的候选按窗口数加权平均，就是声纹；候选随即清掉；
/// - 有了声纹以后：只在这段录音最响的声音和声纹也相似（≥ 0.75）时，用高置信窗口慢慢挪一点（每段最多 5%）；
///   对不上的录音不碰声纹。
public struct Voiceprint: Codable, Equatable, Sendable {
    /// 等待确认的候选：哪段录音、哪一天（按 App 的日界算，那天 0 点）
    public struct Pending: Codable, Equatable, Sendable {
        public var recording: UInt32
        public var day: Date
        public var candidate: SpeakerID.Candidate
        public init(recording: UInt32, day: Date, candidate: SpeakerID.Candidate) {
            self.recording = recording
            self.day = day
            self.candidate = candidate
        }
    }

    /// 这份声纹的标识：「忘掉」后重新学的是新的一份；每段录音记着它是按哪一份判定的
    public var id: String
    public var model: String
    public var dim: Int
    /// 声纹向量（归一化）；nil = 还在学
    public var vector: [Float]?
    /// 声纹由多少个窗口平均来的（慢更新的权重也看它）
    public var sampleCount: Int
    /// 用到了几段录音（确认时的几段加上之后更新过的）
    public var recordings: Int
    public var confirmedAt: Date?
    public var updatedAt: Date
    public var pending: [Pending]

    public init(model: String = SpeakerEmbedder.modelName, dim: Int = 192, now: Date = Date()) {
        id = UUID().uuidString
        self.model = model
        self.dim = dim
        vector = nil
        sampleCount = 0
        recordings = 0
        confirmedAt = nil
        updatedAt = now
        pending = []
    }

    public var isReady: Bool { vector != nil }

    /// 一段录音的候选交过来之后发生了什么
    public enum Event: Equatable, Sendable {
        /// 学习中：存下来等另一天的
        case stored
        /// 学习中：和另一天的候选对上了，声纹确认
        case confirmed
        /// 已有声纹：最响的声音和声纹相似到可以拿来更新（余弦）
        case agrees(Float)
        /// 已有声纹：最响的声音不是声纹（余弦）；不更新
        case differs(Float)
    }

    /// 交一个候选（只给长的心力模式录音的）
    public mutating func offer(_ c: SpeakerID.Candidate, recording: UInt32, day: Date, now: Date = Date()) -> Event {
        if let v = vector {
            let cos = SpeakerMath.dot(c.vector, v)
            return cos >= SpeakerID.sameVoice ? .agrees(cos) : .differs(cos)
        }
        pending.removeAll { $0.recording == recording }
        pending.append(Pending(recording: recording, day: day, candidate: c))
        if pending.count > SpeakerID.maxCandidates { pending.removeFirst(pending.count - SpeakerID.maxCandidates) }
        updatedAt = now
        // 找最相似的一对不同日子的候选
        var best: (Int, Int, Float)?
        for i in pending.indices {
            for j in pending.indices where j > i && pending[i].day != pending[j].day {
                let cos = SpeakerMath.dot(pending[i].candidate.vector, pending[j].candidate.vector)
                if cos >= SpeakerID.sameVoice, cos > (best?.2 ?? -2) { best = (i, j, cos) }
            }
        }
        guard let (i, j, _) = best else { return .stored }
        // 和这一对都相似的候选也算进来（同一个人的更多样本）
        let group = pending.filter {
            SpeakerMath.dot($0.candidate.vector, pending[i].candidate.vector) >= SpeakerID.sameVoice
                && SpeakerMath.dot($0.candidate.vector, pending[j].candidate.vector) >= SpeakerID.sameVoice
        }
        var sum = [Float](repeating: 0, count: c.vector.count)
        var n = 0
        for p in group {
            for d in sum.indices { sum[d] += p.candidate.vector[d] * Float(p.candidate.windows) }
            n += p.candidate.windows
        }
        vector = SpeakerMath.normalized(sum)
        dim = sum.count
        sampleCount = n
        recordings = group.count
        confirmedAt = now
        pending = []
        return .confirmed
    }

    /// 慢更新：用一段（已经确认戴着的）录音里高置信窗口的平均挪一点。
    /// 步长 = 新窗口在总样本里的占比，但不超过 5%：样本越多越稳，一段录音挪不动多少
    public mutating func refine(with mean: [Float], count: Int, now: Date = Date()) {
        guard let v = vector, mean.count == v.count, count > 0 else { return }
        let rate = min(SpeakerID.refineMaxRate, Float(count) / Float(sampleCount + count))
        vector = SpeakerMath.normalized(zip(v, mean).map { $0 * (1 - rate) + $1 * rate })
        sampleCount += count
        recordings += 1
        updatedAt = now
    }

    // MARK: 文件

    public static func read(_ url: URL) -> Voiceprint? {
        guard let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(Voiceprint.self, from: d) else { return nil }
        return v
    }

    public func write(_ url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: [.atomic])
    }
}

/// 一段录音认佩戴者的结果（index.json 里每条录音记一份，不含声纹）
public struct SpeakerScan: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// 每句都判定过了
        case labelled
        /// 还在学声纹：这段只（可能）交了候选，没有标签
        case learning
        /// 最响的声音不是声纹：录音豆多半没戴，这段不标
        case notWorn
        /// 本机音频已经按心力模式的保留设置删了，没法补算
        case noAudio
    }

    public var at: Date
    public var outcome: Outcome
    /// 按哪一份声纹判定的（Voiceprint.id）；学习中、没有音频时为 nil
    public var voiceprint: String?
    /// 标成佩戴者的句数、总句数
    public var wearerLines: Int?
    public var lines: Int?

    public init(at: Date = Date(), outcome: Outcome, voiceprint: String? = nil, wearerLines: Int? = nil, lines: Int? = nil) {
        self.at = at
        self.outcome = outcome
        self.voiceprint = voiceprint
        self.wearerLines = wearerLines
        self.lines = lines
    }

    /// 这条录音要不要（重新）扫一遍：没扫过；或者有了一份新的声纹、这条还不是按它判定的（没音频的就算了）
    public static func needsScan(_ scan: SpeakerScan?, current: Voiceprint?) -> Bool {
        guard let scan else { return true }
        guard let current, current.isReady else { return false }
        if scan.outcome == .noAudio { return false }
        return scan.voiceprint != current.id
    }
}
