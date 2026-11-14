// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 断点续传：「已经收到的范围 → 下次请求的 offset」。
///
/// 真机实测（固件 04.82，`openbean pull --resume-test`）：1A/07 的 offset 按「线上字节」填，
/// 即 已连续收到的片数 × 166，设备就从那一片开始发，密文和完整下载逐片相同。offset 不是 166 的整数倍
/// 会得到乱序的垃圾数据。每次请求设备都重发文件头、换一把文件密钥，但同一片的密文不变，用这次的头就能解。
public enum ResumeUnit: String, CaseIterable, Sendable {
    /// 线上字节：每片 166（文件头 size 的口径；社区笔记把这个字段叫 already_transferred_size）
    case wireBytes
    /// 解密后字节：每片 160
    case plainBytes
    /// 毫秒：每片 20（文件列表时长的口径）
    case milliseconds
    /// 片数（从文件第一片数起）
    case slices
    /// seq 值本身
    case seq

    /// 从第一片起已经连续收到 `k` 片时，offset 填多少
    public func offset(contiguous k: UInt32, firstSeq: UInt32) -> UInt32 {
        switch self {
        case .wireBytes: return k &* 166
        case .plainBytes: return k &* 160
        case .milliseconds: return k &* 20
        case .slices: return k
        case .seq: return firstSeq &+ k
        }
    }
}

public struct ResumeSupport: Equatable, Sendable {
    /// nil = 设备不支持续传（或还不知道）：一律从 0 请求
    public var unit: ResumeUnit?
    /// 续传时设备会重发 1A/07 文件头（带这次的文件密钥）。为 false 时，续上来的片要用第一次的文件密钥解，
    /// 这需要把第一次的文件头存下来（现在没存：spool 里存的是解密后的帧，只在同一次连接里有效）
    public var headResent: Bool

    public init(unit: ResumeUnit?, headResent: Bool) {
        self.unit = unit
        self.headResent = headResent
    }

    /// 实测结论：线上字节，每次请求重发文件头
    public static let current = ResumeSupport(unit: .wireBytes, headResent: true)

    public var isSupported: Bool { unit != nil && headResent }
}

public enum ResumePlan {
    /// 下一次请求：从哪个 seq 起、offset 填多少。只算从 `firstSeq` 起连续的前缀（中间有洞就从洞的位置续）；
    /// 一片都没有，或不支持续传时从 0 开始。
    /// `total` 是这个文件应有的片数（列表时长 ÷ 20 ms，不知道时为 0）：前缀已经够了（上次只差结束包）时，
    /// 从最后一片再要一次，换回文件头、最后一片和结束包，不用整个重下。
    public static func next(received: SeqRanges, firstSeq: UInt32 = 0, total: Int = 0, support: ResumeSupport = .current)
        -> (offset: UInt32, fromSeq: UInt32) {
        guard support.isSupported, let unit = support.unit else { return (0, firstSeq) }
        var k = UInt32(received.contiguousCount(from: firstSeq))
        if total > 0, k >= UInt32(total) { k = UInt32(total - 1) }
        guard k > 0 else { return (0, firstSeq) }
        return (unit.offset(contiguous: k, firstSeq: firstSeq), firstSeq &+ k)
    }

    /// 日志用：「续传，从第 N 片」或「从头」
    public static func label(fromSeq: UInt32, firstSeq: UInt32 = 0) -> String {
        fromSeq > firstSeq ? "续传，从第 \(fromSeq) 片" : "从头"
    }
}
