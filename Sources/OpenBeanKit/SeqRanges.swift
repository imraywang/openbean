// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 收到了哪些 seq：按顺序排好、互不相邻的闭区间。正常下载是一段一段顺序追加，只有一个区间，
/// 8 小时的录音（144 万片）也只占几十字节；乱序或缺片时区间多几个。
public struct SeqRanges: Equatable, Codable, Sendable {
    public private(set) var ranges: [ClosedRange<UInt32>] = []

    public init() {}
    public init(_ ranges: [ClosedRange<UInt32>]) { ranges.forEach { insert(range: $0) } }

    public var isEmpty: Bool { ranges.isEmpty }
    public var first: UInt32? { ranges.first?.lowerBound }
    public var last: UInt32? { ranges.last?.upperBound }
    /// 一共多少个 seq
    public var count: Int { ranges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 } }

    /// 第一个 lowerBound > seq 的区间下标
    private func upperIndex(_ seq: UInt32) -> Int {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].lowerBound <= seq { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public func contains(_ seq: UInt32) -> Bool {
        let i = upperIndex(seq)
        return i > 0 && ranges[i - 1].contains(seq)
    }

    /// 记下一个 seq；已经有了返回 false
    @discardableResult
    public mutating func insert(_ seq: UInt32) -> Bool {
        // 最常见：接在最后一段后面
        if let l = ranges.last {
            if seq == l.upperBound &+ 1, seq != 0 {
                ranges[ranges.count - 1] = l.lowerBound...seq
                return true
            }
            if l.contains(seq) { return false }
        }
        let i = upperIndex(seq)
        if i > 0, ranges[i - 1].contains(seq) { return false }
        insert(range: seq...seq)
        return true
    }

    /// 并进一段区间（和相邻、重叠的合并）
    public mutating func insert(range r: ClosedRange<UInt32>) {
        var lo = r.lowerBound, hi = r.upperBound
        var keep: [ClosedRange<UInt32>] = []
        keep.reserveCapacity(ranges.count + 1)
        var placed = false
        for x in ranges {
            if UInt64(x.upperBound) + 1 < UInt64(lo) {
                keep.append(x)
            } else if UInt64(hi) + 1 < UInt64(x.lowerBound) {
                if !placed { keep.append(lo...hi); placed = true }
                keep.append(x)
            } else {
                lo = min(lo, x.lowerBound)
                hi = max(hi, x.upperBound)
            }
        }
        if !placed { keep.append(lo...hi) }
        ranges = keep
    }

    /// 从 `start` 起连续收到了多少个（续传从 start + 这个数接着要）
    public func contiguousCount(from start: UInt32) -> Int {
        let i = upperIndex(start)
        guard i > 0, ranges[i - 1].contains(start) else { return 0 }
        return Int(ranges[i - 1].upperBound - start) + 1
    }

    /// `start..<start+count` 里缺的区间
    public func missing(from start: UInt32, count: Int) -> [ClosedRange<UInt32>] {
        guard count > 0 else { return [] }
        let end = UInt64(start) + UInt64(count) - 1
        var out: [ClosedRange<UInt32>] = []
        var cursor = UInt64(start)
        for r in ranges where UInt64(r.upperBound) >= cursor {
            if UInt64(r.lowerBound) > end { break }
            if UInt64(r.lowerBound) > cursor { out.append(UInt32(cursor)...UInt32(UInt64(r.lowerBound) - 1)) }
            cursor = UInt64(r.upperBound) + 1
            if cursor > end { break }
        }
        if cursor <= end { out.append(UInt32(cursor)...UInt32(end)) }
        return out
    }

    /// 日志用：`0…12345, 12400…20000`
    public var summary: String {
        ranges.isEmpty ? "无" : ranges.prefix(6).map { "\($0.lowerBound)…\($0.upperBound)" }.joined(separator: ", ")
            + (ranges.count > 6 ? " …（共 \(ranges.count) 段）" : "")
    }
}
