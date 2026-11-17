// SPDX-License-Identifier: Apache-2.0

import Accelerate
import Foundation

/// 认出佩戴者说的句子：规则和参数都在这里，全是纯函数，方便测试。
///
/// 做法（可行性实验见 docs/GUIDE.md「Recognise my voice」）：
/// - 每句按 1.5 秒窗口（步长 0.75 秒）算声纹向量和响度，不给整句一个向量（一句里常有两个人）；
/// - 窗口和声纹的余弦 ≥ 0.5 算佩戴者；一句存佩戴者窗口占比（过半 = 他说的，正好一半看中位数）和窗口得分的中位数；
/// - 不到 1 秒的句子不单独判定：前后两句都有标签且一致时跟着它们，否则是未知（nil），不默认成「别人」；
/// - 自动登记：领口上最响的声音就是佩戴者。长的心力模式录音取最响 20% 的窗口聚类，最大簇的中心是这段的候选；
///   两段不同日子录音的候选相似（≥ 0.75）才认定为声纹；之后只用高置信窗口慢慢更新；
/// - 这段录音最响的声音和声纹对不上：录音豆多半没戴在身上，这段不标、也不拿来更新声纹。
public enum SpeakerID {
    public static let windowSeconds = 1.5
    public static let hopSeconds = 0.75
    /// 窗口算佩戴者的余弦阈值（CAM++，1.5 秒窗口；人工标注验证过）
    public static let windowThreshold: Float = 0.5
    /// 短于这个的句子不单独判定
    public static let minSentenceSeconds = 1.0
    /// 短句跟随前后句时，和前后句的间隔不超过这么多秒
    public static let neighbourGap = 5.0
    /// 取最响的这一部分窗口建候选
    public static let loudFraction = 0.2
    /// 最响窗口聚类：平均连接，余弦距离 ≤ 0.6 的合并（余弦 ≥ 0.4）
    public static let clusterDistance: Float = 0.6
    /// 聚类最多用这么多个窗口（多了等间隔抽样）：距离矩阵是 n²
    public static let clusterLimit = 2000
    /// 候选至少要有这么多个窗口，且占最响窗口的比例不低于 minClusterShare：不然这段没有一个明显的主声音
    public static let minClusterWindows = 30
    public static let minClusterShare = 0.25
    /// 拿来登记的录音：心力模式、至少这么长、最大簇至少这么多窗口
    public static let enrolMinSeconds = 15.0 * 60
    public static let enrolMinWindows = 60
    /// 两个候选（或候选和声纹）算同一个人
    public static let sameVoice: Float = 0.75
    /// 这段最响的声音和声纹至少这么像，才算录音豆戴在身上
    public static let wornThreshold: Float = 0.5
    /// 慢更新只用得分这么高的窗口，至少这么多个；每段录音最多挪动这么多
    public static let refineThreshold: Float = 0.7
    public static let refineMinWindows = 20
    public static let refineMaxRate: Float = 0.05
    /// 等待确认的候选最多留几个（最新的）
    public static let maxCandidates = 8

    /// 一句（相对句首，秒）里的窗口：不长于 1.5 秒的句子整句一个窗口；
    /// 长句从头每 0.75 秒一个，最后一个窗口离句尾还差 0.25 秒以上时，再补一个贴着句尾的
    public static func windows(duration: Double) -> [(start: Double, end: Double)] {
        guard duration > 0 else { return [] }
        guard duration > windowSeconds else { return [(0, duration)] }
        var out: [(Double, Double)] = []
        var t = 0.0
        while t <= duration - windowSeconds + 1e-6 {
            out.append((t, t + windowSeconds))
            t += hopSeconds
        }
        if let last = out.last, last.1 < duration - 0.25 { out.append((duration - windowSeconds, duration)) }
        return out
    }

    // MARK: 一段录音的候选

    /// 最响窗口的主声音：中心（归一化）、簇里几个窗口、占最响窗口的比例
    public struct Candidate: Codable, Equatable, Sendable {
        public var vector: [Float]
        public var windows: Int
        public var share: Double
        public init(vector: [Float], windows: Int, share: Double) {
            self.vector = vector
            self.windows = windows
            self.share = share
        }
    }

    /// 取最响 20% 的窗口聚类，最大簇就是这段的主声音；没有明显的主声音返回 nil
    public static func loudCandidate(_ w: SpeakerWindows) -> Candidate? {
        guard w.count >= minClusterWindows else { return nil }
        let cut = percentile(w.rmsDb, 1 - loudFraction)
        var loud = (0..<w.count).filter { w.rmsDb[$0] >= cut }
        if loud.count > clusterLimit {
            let step = Double(loud.count) / Double(clusterLimit)
            loud = (0..<clusterLimit).map { loud[Int(Double($0) * step)] }
        }
        guard loud.count >= minClusterWindows else { return nil }
        var flat = [Float](); flat.reserveCapacity(loud.count * w.dim)
        for i in loud { flat += w.vector(i) }
        let labels = averageLinkage(flat, dim: w.dim, count: loud.count, maxDistance: clusterDistance)
        var sizes: [Int: Int] = [:]
        for l in labels { sizes[l, default: 0] += 1 }
        guard let (top, n) = sizes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        let share = Double(n) / Double(loud.count)
        guard n >= minClusterWindows, share >= minClusterShare else { return nil }
        var sum = [Float](repeating: 0, count: w.dim)
        for (k, l) in labels.enumerated() where l == top {
            for d in 0..<w.dim { sum[d] += flat[k * w.dim + d] }
        }
        return Candidate(vector: SpeakerMath.normalized(sum), windows: n, share: share)
    }

    /// 平均连接层次聚类，在余弦距离 maxDistance 处截断；返回每个点的簇号。
    /// 最近邻链算法（平均连接满足可约性）：O(n²) 时间、n² 个 Float 的距离矩阵。
    /// 互为最近邻的一对距离已经超过截断值时，这两个点都不会再和谁合并（可约性），直接收起来
    public static func averageLinkage(_ flat: [Float], dim: Int, count n: Int, maxDistance: Float) -> [Int] {
        guard n > 1 else { return Array(repeating: 0, count: n) }
        // 距离 = 1 - 余弦（向量已归一化）：D = 1 - X Xᵀ
        var dist = [Float](repeating: 0, count: n * n)
        flat.withUnsafeBufferPointer { x in
            dist.withUnsafeMutableBufferPointer { d in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(n), Int32(dim),
                            -1, x.baseAddress, Int32(dim), x.baseAddress, Int32(dim), 0, d.baseAddress, Int32(n))
            }
        }
        for i in 0..<(n * n) { dist[i] += 1 }
        var size = [Int](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var activeCount = n
        // 并查集：合并后的簇用其中一个点代表
        var parent = Array(0..<n)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var chain: [Int] = []
        while activeCount > 1 {
            if chain.isEmpty { chain.append(active.firstIndex(of: true)!) }
            let a = chain.last!
            let prev = chain.count >= 2 ? chain[chain.count - 2] : -1
            var best = -1
            var bestD = Float.infinity
            for b in 0..<n where active[b] && b != a {
                let d = dist[a * n + b]
                if d < bestD || (d == bestD && b == prev) { best = b; bestD = d }
            }
            if best == prev {
                chain.removeLast(2)
                if bestD > maxDistance {
                    // 截断：这两个点（簇）到此为止
                    active[a] = false; active[prev] = false
                    activeCount -= 2
                    chain.removeAll()
                    continue
                }
                // 合并 prev 到 a：Lance-Williams 平均连接更新
                let na = Float(size[a]), nb = Float(size[prev])
                for k in 0..<n where active[k] && k != a && k != prev {
                    let d = (na * dist[a * n + k] + nb * dist[prev * n + k]) / (na + nb)
                    dist[a * n + k] = d
                    dist[k * n + a] = d
                }
                size[a] += size[prev]
                active[prev] = false
                activeCount -= 1
                parent[prev] = a
            } else {
                chain.append(best)
            }
        }
        var ids: [Int: Int] = [:]
        return (0..<n).map { i in
            let r = root(i)
            if let id = ids[r] { return id }
            ids[r] = ids.count
            return ids[r]!
        }
    }

    // MARK: 每句的得分和标签

    /// 一句的结果：佩戴者窗口占比、窗口得分的中位数、窗口数
    public struct SentenceScore: Equatable, Sendable {
        public var share: Double
        public var median: Double
        public var windows: Int
        public init(share: Double, median: Double, windows: Int) {
            self.share = share
            self.median = median
            self.windows = windows
        }
    }

    /// 每句的得分（一个窗口也没有的句子是 nil）
    public static func sentenceScores(_ w: SpeakerWindows, voiceprint: [Float], sentences: Int) -> [SentenceScore?] {
        var scores = [[Float]](repeating: [], count: sentences)
        for i in 0..<w.count {
            let s = Int(w.sentence[i])
            guard s >= 0, s < sentences else { continue }
            scores[s].append(w.cosine(i, voiceprint))
        }
        return scores.map { s in
            guard !s.isEmpty else { return nil }
            let hits = s.filter { $0 >= windowThreshold }.count
            return SentenceScore(share: Double(hits) / Double(s.count), median: Double(median(s)), windows: s.count)
        }
    }

    /// 一句（够长）算不算佩戴者说的：佩戴者窗口过半；正好一半时看窗口得分的中位数到没到阈值
    public static func isWearer(_ s: SentenceScore) -> Bool {
        s.share > 0.5 || (s.share == 0.5 && s.median >= Double(windowThreshold))
    }

    /// 这段录音戴没戴在身上
    public enum Worn: String, Codable, Sendable {
        /// 最响的声音就是声纹
        case worn
        /// 最响的声音是别人：录音豆多半放在桌上了
        case notWorn
        /// 没有明显的主声音（短录音、没人说话），照常判定
        case unknown
    }

    public static func worn(candidate: Candidate?, voiceprint: [Float]) -> Worn {
        guard let candidate else { return .unknown }
        return SpeakerMath.dot(candidate.vector, voiceprint) >= wornThreshold ? .worn : .notWorn
    }

    /// 每句是不是佩戴者说的：没戴的录音全是 nil；≥ 1 秒的句子看佩戴者窗口占比 ≥ 0.5；
    /// 短句前后两句（间隔都不超过 5 秒）有一致的标签时跟着它们，否则 nil
    public static func labels(times: [(start: Double, end: Double)], scores: [SentenceScore?], worn: Worn) -> [Bool?] {
        precondition(times.count == scores.count)
        guard worn != .notWorn else { return Array(repeating: nil, count: times.count) }
        let first: [Bool?] = zip(times, scores).map { t, s in
            guard let s, t.end - t.start >= minSentenceSeconds else { return nil }
            return isWearer(s)
        }
        return times.indices.map { i in
            if let l = first[i] { return l }
            guard times[i].end - times[i].start < minSentenceSeconds, i > 0, i + 1 < times.count,
                  let a = first[i - 1], let b = first[i + 1], a == b,
                  times[i].start - times[i - 1].end <= neighbourGap,
                  times[i + 1].start - times[i].end <= neighbourGap else { return nil }
            return a
        }
    }

    /// 慢更新用的高置信窗口的平均（归一化）和个数；不够数返回 nil
    public static func confidentMean(_ w: SpeakerWindows, voiceprint: [Float]) -> (vector: [Float], count: Int)? {
        var sum = [Float](repeating: 0, count: w.dim)
        var n = 0
        for i in 0..<w.count where w.cosine(i, voiceprint) >= refineThreshold {
            for (d, x) in w.vector(i).enumerated() { sum[d] += x }
            n += 1
        }
        guard n >= refineMinWindows else { return nil }
        return (SpeakerMath.normalized(sum), n)
    }

    // MARK: 小工具

    static func percentile(_ x: [Float], _ q: Double) -> Float {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let pos = q * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + Float(pos - Double(lo)) * (s[hi] - s[lo])
    }

    static func median(_ x: [Float]) -> Float { percentile(x, 0.5) }
}

/// 一段录音的全部窗口：所在句子、响度（dBFS）、声纹向量（归一化，平铺存放省内存）
public struct SpeakerWindows: Sendable {
    public let dim: Int
    public private(set) var sentence: [Int32] = []
    public private(set) var rmsDb: [Float] = []
    public private(set) var vectors: [Float] = []

    public init(dim: Int) { self.dim = dim }

    public var count: Int { sentence.count }

    public mutating func append(sentence s: Int, rmsDb r: Float, vector v: [Float]) {
        precondition(v.count == dim)
        sentence.append(Int32(s))
        rmsDb.append(r)
        vectors += v
    }

    public func vector(_ i: Int) -> ArraySlice<Float> { vectors[(i * dim)..<((i + 1) * dim)] }

    public func cosine(_ i: Int, _ v: [Float]) -> Float {
        var s: Float = 0
        let base = i * dim
        for d in 0..<dim { s += vectors[base + d] * v[d] }
        return s
    }
}

public enum SpeakerMath {
    public static func dot<A: Collection, B: Collection>(_ a: A, _ b: B) -> Float where A.Element == Float, B.Element == Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    public static func normalized<C: Collection>(_ v: C) -> [Float] where C.Element == Float {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : Array(v)
    }

    /// 均方根响度（dBFS）
    public static func rmsDb(_ x: UnsafeBufferPointer<Float>) -> Float {
        guard x.count > 0 else { return -120 }
        var ms: Float = 0
        vDSP_measqv(x.baseAddress!, 1, &ms, vDSP_Length(x.count))
        return 20 * log10(sqrt(ms) + 1e-9)
    }
}
