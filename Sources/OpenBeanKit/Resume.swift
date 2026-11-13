// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 断点续传：「已经收到的范围 → 下次请求的 offset」。
///
/// 设备认不认 1A/07 里的 offset、单位是什么、续传时会不会重发文件头，都还没实测
/// （`openbean pull --resume-test` 就是测这个的）。所以这里只把换算做好、留一个开关：
/// `ResumeSupport.current` 现在是「不支持」，App 一律从 0 请求；拿到实验结果后填上单位，续传就生效。
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

    /// 等 A2 实验结果再改
    public static let current = ResumeSupport(unit: nil, headResent: true)

    public var isSupported: Bool { unit != nil && headResent }
}

public enum ResumePlan {
    /// 下一次请求：从哪个 seq 起、offset 填多少。已经有的不够连续一片，或不支持续传时从 0 开始
    public static func next(received: SeqRanges, firstSeq: UInt32 = 0, support: ResumeSupport = .current)
        -> (offset: UInt32, fromSeq: UInt32) {
        guard support.isSupported, let unit = support.unit else { return (0, firstSeq) }
        let k = UInt32(received.contiguousCount(from: firstSeq))
        guard k > 0 else { return (0, firstSeq) }
        return (unit.offset(contiguous: k, firstSeq: firstSeq), firstSeq &+ k)
    }
}
