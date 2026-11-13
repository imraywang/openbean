// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 估算蓝牙同步要多久：录音时长 → 字节数（64 kbps），再除以下载速度。
public enum SyncEstimate {
    /// 还没量过速度时用的默认值（Mac 上实测 15–40 KB/s，取中间偏保守）
    public static let defaultBytesPerSecond: Double = 25_000

    /// 这么长的录音解密后有多少字节（每 20 ms 一片 160 字节）
    public static func audioBytes(durationMs: Double) -> Double { max(durationMs, 0) / 20 * 160 }

    /// 下载这些字节要多少秒；速度不合理（≤ 0）时用默认值
    public static func seconds(bytes: Double, bytesPerSecond: Double) -> Double {
        max(bytes, 0) / (bytesPerSecond > 0 ? bytesPerSecond : defaultBytesPerSecond)
    }

    /// 每个文件的固定开销（秒）：发请求到第一片到达、最后等结束包。短文件的实测速度被它拉低
    /// （几十 KB 的文件约 13 KB/s，几十 MB 的约 40 KB/s），所以分开算：时长 = 开销 + 字节 ÷ 大文件的速度
    public static let perFileOverhead: Double = 2

    /// 一个文件要下多久：短文件以开销为主，长文件以速度为主
    public static func fileSeconds(bytes: Double, bytesPerSecond: Double) -> Double {
        bytes > 0 ? perFileOverhead + seconds(bytes: bytes, bytesPerSecond: bytesPerSecond) : 0
    }

    /// 只用够大的下载来学速度（≥ 1 MB 且 ≥ 20 秒），短文件的开销不会把记住的速度拉低
    public static let learnMinBytes = 1_000_000
    public static let learnMinSeconds: Double = 20

    public static func shouldLearn(bytes: Int, seconds: Double) -> Bool {
        bytes >= learnMinBytes && seconds >= learnMinSeconds
    }

    /// 把新量到的速度并进记住的速度（新值占 3 成，单次波动不会把估算带偏）
    public static func blend(old: Double?, measured: Double) -> Double {
        guard measured > 0 else { return old ?? defaultBytesPerSecond }
        guard let old, old > 0 else { return measured }
        return old * 0.7 + measured * 0.3
    }

    public enum Display: Equatable {
        case underMinute
        case minutes(Int)
        case hours(Int, minutes: Int)
    }

    /// 给人看的粒度：不到 1 分钟、整分钟（向上取整）、1 小时以上按 5 分钟取整
    public static func display(_ seconds: Double) -> Display {
        if seconds < 60 { return .underMinute }
        let m = Int((seconds / 60).rounded(.up))
        if m < 60 { return .minutes(m) }
        let r = Int((Double(m) / 5).rounded()) * 5
        return .hours(r / 60, minutes: r % 60)
    }
}
