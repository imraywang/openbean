// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把一条录音的转写按停顿切成一段一段的对话（纯函数，不读文件、不调用大模型）。
///
/// 规则（阈值都是参数）：
/// - 前后两句之间的停顿 ≥ `hardGap` 秒：必切；
/// - `softGap` ≤ 停顿 < `hardGap`：只记作「候选切点」，这一版不切（以后可以交给大模型判断）；
/// - 切完以后，一段从第一句开始到最后一句结束超过 `maxLength` 秒：平均分成刚好不超长的几份，每个等分点附近挑最大的
///   停顿切（不是一刀切在全段最大的停顿处：那样 99 分钟的谈话会被切成长短不一的四份）；一句本身就超长时不再切。
///
/// 段 = 一串连续的句子（转写里的下标范围），句子不重排：脏数据（时间戳乱序、重叠、结束早于开始、非有限数）
/// 只影响停顿怎么算——停顿按「这一句的开始 − 前面所有句子里最晚的结束」算，乱序或重叠得到负数，不会切。
public enum Segmenter {
    /// 切段算法的版本：规则改了就加 1，已有的 segments.json 会重算
    public static let version = 1

    public struct Params: Codable, Hashable, Sendable {
        /// 停顿至少这么多秒必切
        public var hardGap: Double
        /// 停顿至少这么多秒（但不到 hardGap）记作候选切点
        public var softGap: Double
        /// 一段最长多少秒，超过就在段内最大停顿处再切
        public var maxLength: Double

        public init(hardGap: Double = 120, softGap: Double = 30, maxLength: Double = 45 * 60) {
            self.hardGap = hardGap
            self.softGap = softGap
            self.maxLength = maxLength
        }

        public static let standard = Params()
    }

    /// 一段为什么从这里开始
    public enum Cut: String, Codable, Sendable {
        /// 录音的第一段
        case recordingStart
        /// 前面停顿 ≥ hardGap
        case silence
        /// 上一段太长，在最大停顿处切开
        case maxLength
    }

    public struct Line: Sendable, Hashable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public struct Piece: Sendable, Hashable {
        /// 句子下标，左闭右开
        public var lines: Range<Int>
        /// 秒，相对录音开头：段里最早的开始、最晚的结束
        public var start: Double
        public var end: Double
        public var cut: Cut
        /// 段内的候选切点：停顿在 [softGap, hardGap) 的那些句子的下标（停顿在这一句之前）
        public var candidates: [Int]
    }

    public static func split(_ lines: [Line], params p: Params = .standard) -> [Piece] {
        guard !lines.isEmpty else { return [] }
        let gaps = pauses(lines)
        // 第一层：长停顿必切
        var bounds: [(Range<Int>, Cut)] = []
        var from = 0
        for i in 1..<lines.count where gaps[i] >= p.hardGap {
            bounds.append((from..<i, from == 0 ? .recordingStart : .silence))
            from = i
        }
        bounds.append((from..<lines.count, from == 0 ? .recordingStart : .silence))
        // 第二层：超长的段在最大停顿处再切
        var out: [Piece] = []
        for (r, cut) in bounds {
            for (k, sub) in splitLong(r, lines, gaps, p).enumerated() {
                out.append(piece(sub, k == 0 ? cut : .maxLength, lines, gaps, p))
            }
        }
        return out
    }

    /// gaps[i]：第 i 句之前的停顿（第 0 句为 0）。非有限的时间戳当作没有停顿
    static func pauses(_ lines: [Line]) -> [Double] {
        var gaps = [Double](repeating: 0, count: lines.count)
        var latest = -Double.infinity
        for (i, l) in lines.enumerated() {
            let s = l.start.isFinite ? l.start : nil
            let e = [l.start, l.end].filter(\.isFinite).max()
            if i > 0, let s, latest.isFinite { gaps[i] = s - latest }
            if let e { latest = max(latest, e) }
        }
        return gaps
    }

    /// 一段的时长：最晚的结束 − 最早的开始（只看有限值）
    static func span(_ r: Range<Int>, _ lines: [Line]) -> (start: Double, end: Double) {
        var lo = Double.infinity, hi = -Double.infinity
        for l in lines[r] {
            for v in [l.start, l.end] where v.isFinite {
                lo = min(lo, v)
                hi = max(hi, v)
            }
        }
        return lo.isFinite ? (lo, max(hi, lo)) : (0, 0)
    }

    /// 超长的段平均切成 k = ⌈时长 / maxLength⌉ 份：每个等分点附近（前后各四分之一份长）挑最大的停顿切，
    /// 一样大时取离等分点近的；附近没有句子开头（一句话特别长）就取离等分点最近的句子。切完还超长的再按同样办法切
    private static func splitLong(_ r: Range<Int>, _ lines: [Line], _ gaps: [Double], _ p: Params) -> [Range<Int>] {
        let s = span(r, lines)
        let total = s.end - s.start
        guard p.maxLength > 0, total > p.maxLength, r.count > 1 else { return [r] }
        let k = Int((total / p.maxLength).rounded(.up))
        let share = total / Double(k)
        var cuts: [Int] = []
        var prev = r.lowerBound
        for j in 1..<k {
            let target = s.start + share * Double(j)
            let after = ((prev + 1)..<r.upperBound).filter { lines[$0].start.isFinite }
            guard !after.isEmpty else { break }
            let near = after.filter { abs(lines[$0].start - target) <= share / 4 }
            let at: Int
            if near.isEmpty {
                at = after.min { abs(lines[$0].start - target) < abs(lines[$1].start - target) }!
            } else {
                at = near.max { a, b in
                    gaps[a] != gaps[b] ? gaps[a] < gaps[b] : abs(lines[a].start - target) > abs(lines[b].start - target)
                }!
            }
            cuts.append(at)
            prev = at
        }
        let edges = [r.lowerBound] + cuts + [r.upperBound]
        let parts = zip(edges, edges.dropFirst()).map { $0..<$1 }
        // 只切出一份（找不到切点）就别再递归，免得死循环
        guard parts.count > 1 else { return [r] }
        return parts.flatMap { splitLong($0, lines, gaps, p) }
    }

    private static func piece(_ r: Range<Int>, _ cut: Cut, _ lines: [Line], _ gaps: [Double], _ p: Params) -> Piece {
        let s = span(r, lines)
        let candidates = r.dropFirst().filter { gaps[$0] >= p.softGap && gaps[$0] < p.hardGap }
        return Piece(lines: r, start: s.start, end: s.end, cut: cut, candidates: Array(candidates))
    }
}
