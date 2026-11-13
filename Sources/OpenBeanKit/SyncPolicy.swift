// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一次下载收到的东西算不算完整（蓝牙和 Wi‑Fi 共用）。纯函数，单元测试覆盖。
public enum DownloadCheck {
    public enum Verdict: Equatable, Sendable {
        /// 一片不缺
        case complete
        /// 收到结束包，只缺零星几片（不超过 `tolerance`）：缺的补成静音保存，日志里记一笔
        case completeWithGaps(missing: Int)
        /// 没下完：留着临时文件，下次再来
        case incomplete(String)
        /// 拿到的不能用（别的文件的头、设备报错、解不开）：临时文件也不该留
        case rejected(String)

        public var isUsable: Bool {
            switch self {
            case .complete, .completeWithGaps: return true
            default: return false
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public let verdict: Verdict
        /// 按哪个口径算的应有片数（文件头 size÷166 和列表时长÷20 里和收到的最接近的那个）
        public let expectedFrames: Int
        /// 从哪个 seq 开始算（收到的第一片）
        public let firstSeq: UInt32
        /// 缺几片（中间的空洞 + 末尾不够的）
        public let missing: Int
    }

    /// 中间偶尔丢一两片（BLE 帧校验和错时整帧丢掉）不该让 8 小时的下载从头再来：
    /// 收到结束包时，缺的不超过 1 秒或 0.1%（取大的）就算能用
    public static func tolerance(expected: Int) -> Int { max(50, expected / 1000) }

    /// 解密正确时几乎所有帧的 TOC 字节都一样；低于这个比例当成密钥不对
    public static let minTOCConsistency = 0.8

    public static func evaluate(requestedId: UInt32, head: FileHead?, decrypted: Bool, received: SeqRanges,
                                gotDone: Bool, listFrames: Int, tocConsistency: Double) -> Result {
        func result(_ v: Verdict, expected: Int = 0, missing: Int = 0) -> Result {
            Result(verdict: v, expectedFrames: expected, firstSeq: received.first ?? 0, missing: missing)
        }
        if let head {
            if head.fileId != requestedId {
                return result(.rejected("文件头是别的文件（\(head.fileId)，请求的是 \(requestedId)）"))
            }
            if head.errorCode != 0 { return result(.rejected("设备拒绝传这个文件（文件头 err=\(head.errorCode)）")) }
            if !decrypted { return result(.rejected("文件密钥解不开")) }
        }
        guard let first = received.first, let last = received.last else {
            return result(.incomplete(head == nil ? "没收到文件头和数据" : "一片数据也没收到"))
        }
        if head == nil { return result(.incomplete("没收到文件头")) }
        let count = received.count
        if count >= 50, tocConsistency < minTOCConsistency {
            return result(.rejected("解出来的不像 Opus（TOC 一致率 \(Int(tocConsistency * 100))%）"))
        }
        let span = Int(last - first) + 1
        let holes = span - count
        let headFrames = Int(head!.size) / 166
        let candidates = [headFrames, listFrames].filter { $0 > 0 }
        // 末尾（或开头）比应有的少多少：取和收到的范围最接近的口径
        let expected = candidates.min { abs($0 - span) < abs($1 - span) } ?? span
        let short = max(0, expected - span)
        let missing = holes + short
        let tol = tolerance(expected: expected)
        if missing == 0, gotDone || span >= expected { return result(.complete, expected: expected) }
        if gotDone, missing <= tol { return result(.completeWithGaps(missing: missing), expected: expected, missing: missing) }
        let why = "收到 \(count) / \(expected) 片（\(received.summary)）"
            + (gotDone ? "，有结束包但缺 \(missing) 片" : "，没收到结束包")
        return result(.incomplete(why), expected: expected, missing: missing)
    }
}

/// 同步和语音输入谁让谁、失败后多久重试、要不要提示改用 Wi‑Fi。都是纯函数，阈值是常量。
public enum SyncPolicy {
    // MARK: 语音输入

    /// 没有断点续传时，这一条下载还剩多久以上就不让给语音输入（让了就得从头再下）
    public static let keepSyncOverDictation: TimeInterval = 10 * 60

    public enum DictationDecision: Equatable, Sendable {
        /// 同步让出连接，语音输入照常开始
        case yield
        /// 不让：语音输入不开始，提示「正在同步长录音，约剩 X 分钟」
        case keepSyncing(secondsLeft: Double)
    }

    /// `remaining`：正在下的这一条还剩多少秒（不在下载时为 nil）。`resumable`：中断后能不能接着下
    /// （断点续传做出来以后为 true，这条规则就回到「让，之后续」）
    public static func dictation(remaining: Double?, resumable: Bool) -> DictationDecision {
        guard !resumable, let remaining, remaining > keepSyncOverDictation else { return .yield }
        return .keepSyncing(secondsLeft: remaining)
    }

    // MARK: 自动同步重试

    public enum Failure: Equatable, Sendable {
        /// Mac 睡眠、连接断开：不是设备或数据的问题，重连后再试
        case interrupted
        /// 下了一部分、或数据不能用、或出错
        case failed
    }

    /// 长文件：估计要下 10 分钟以上
    public static let longFile: TimeInterval = 10 * 60

    /// 第 `failures` 次连续失败后等多久再试。
    /// - 中断：第一次不等（重连就试），之后 1、2、4…分钟，免得在蓝牙边缘反复断连时一遍遍从头下
    /// - 失败：短文件 1、2、4…分钟；长文件 5、10、20…分钟（每次从头下要很久）；都最多 30 分钟
    public static func retryDelay(failures: Int, kind: Failure, longFile: Bool) -> TimeInterval {
        guard failures > 0 else { return 0 }
        switch kind {
        case .interrupted:
            return failures == 1 ? 0 : min(60 * pow(2, Double(failures - 2)), 1800)
        case .failed:
            return min((longFile ? 300 : 60) * pow(2, Double(failures - 1)), 1800)
        }
    }

    // MARK: Wi‑Fi

    /// Wi‑Fi 热点下载实测约 1.5 MB/s
    public static let wifiBytesPerSecond: Double = 1_500_000
    /// 开热点、Mac 加入、结束后连回原网络的固定开销（秒，推断）
    public static let wifiOverhead: TimeInterval = 90
    /// 蓝牙预计超过这么久时提示可以改用 Wi‑Fi（只提示，不自动：Mac 会断网）
    public static let suggestWifiAfter: TimeInterval = 20 * 60

    public static func wifiSeconds(bytes: Double) -> Double { wifiOverhead + max(bytes, 0) / wifiBytesPerSecond }

    public static func suggestWifi(bluetoothSeconds: Double?) -> Bool {
        guard let b = bluetoothSeconds else { return false }
        return b >= suggestWifiAfter
    }
}
