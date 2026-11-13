// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 排查用的传输记录（命令行 `pull --marks`、`--resume-test` 打开）：
/// 收到的每个 1A/12 包、flags 不为 0 的单元、每个文件头，以及（续传实验时）每片的密文。
/// App 的同步不打开它，内存不受影响。
public struct TransferDiagnostics {
    /// 一个 1A/12 包（社区笔记叫 file slice (mark/variant)，没有抓包样本）
    public struct MarkFrame {
        /// 这是第几个分片包（1A/08 和 1A/12 一起数，从 0 开始）
        public let packetIndex: Int
        /// 离开始请求过了多少秒
        public let elapsed: Double
        /// 按 1A/08 的布局解析出来的 seq 和 flags（布局不同时这两项没意义，看 raw）
        public let seqs: [UInt32]
        public let flags: [UInt8]
        public let rawLength: Int
        /// 整帧前 64 字节
        public let rawHead: [UInt8]
        /// 整帧长度减去帧头 9 字节和校验 1 字节后除以 166 的余数；
        /// 按 1A/08 的布局应为 0（最后一个单元没有填充字节时是 165）
        public var unitRemainder: Int { (rawLength - 10) % 166 }
    }

    /// flags 不为 0 的一个单元
    public struct FlaggedUnit {
        public let packetIndex: Int
        public let frameId: UInt8
        public let seq: UInt32
        public let flags: UInt8
    }

    /// 打开时是否记下每片密文（续传实验要用第一次的文件密钥重新解）
    public let keepCipher: Bool
    /// 各种分片包（1A/08、1A/12）各收到几个
    public internal(set) var sliceFrames: [UInt8: Int] = [:]
    /// 每种 flags 值出现了几次
    public internal(set) var flagCounts: [UInt8: Int] = [:]
    public internal(set) var markFrames: [MarkFrame] = []
    public internal(set) var flaggedUnits: [FlaggedUnit] = []
    /// flags 不为 0 的单元总数（`flaggedUnits` 最多只留 `cap` 条）
    public internal(set) var flaggedTotal = 0
    /// 长度不是整数个单元的分片包
    public internal(set) var oddFrames = 0
    /// 每片的密文（只在 keepCipher 时记）
    public internal(set) var cipher: [UInt32: [UInt8]] = [:]
    public static let cap = 500

    public init(keepCipher: Bool = false) { self.keepCipher = keepCipher }

    mutating func note(frame p: Packet, slices: [Slice], packetIndex: Int, elapsed: Double) {
        sliceFrames[p.id, default: 0] += 1
        let rem = (p.raw.count - 10) % 166
        if rem != 0, rem != 165 { oddFrames += 1 }
        if p.id == Rx.fileSliceMark, markFrames.count < Self.cap {
            markFrames.append(MarkFrame(packetIndex: packetIndex, elapsed: elapsed, seqs: slices.map(\.seq),
                                        flags: slices.map(\.flags), rawLength: p.raw.count,
                                        rawHead: Array(p.raw.prefix(64))))
        }
        for s in slices {
            flagCounts[s.flags, default: 0] += 1
            if s.flags != 0 {
                flaggedTotal += 1
                if flaggedUnits.count < Self.cap {
                    flaggedUnits.append(FlaggedUnit(packetIndex: packetIndex, frameId: p.id, seq: s.seq, flags: s.flags))
                }
            }
            if keepCipher { cipher[s.seq] = s.data }
        }
    }

    /// seq 换算成音频里的秒数（每片 20 ms，从这次收到的第一片算起）
    public static func seconds(seq: UInt32, firstSeq: UInt32) -> Double {
        Double(Int64(seq) - Int64(firstSeq)) * 0.02
    }
}
