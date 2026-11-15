// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - 下载被打断以后怎么接着下（iOS；纯值，测试见 TransferRecoveryTests）
//
// 录音豆没有「停止传输」命令：请求一个文件后它一直发到文件末尾，主机不收也照发（PROTOCOL.md）。
// iOS 上下载常被打断（App 被挂起、进程被系统结束后在后台重新拉起），而系统会把蓝牙连接原样交还，
// 所以新进程连上时录音豆往往还在发上一次请求的数据。这时马上发新请求：续传回来的片号对不上，
// 再从头要就得到文件头 err=4（设备忙）。真机日志：2026-11-15 06:39:42、06:50:49。
//
// 做法：发新请求前先等录音豆安静下来（StreamQuiet）；等一会儿还在发就断开一次（PROTOCOL.md：断开能让实时流停下，
// 普通传输是否也停在真机上还没确认），还在发就继续等到它发完，等太久这次先不下、稍后再试。
// 被打断、设备忙、片号对不上都不算数据坏了：已经收好的连续前缀留着（keepsPartial）。

public enum StreamQuiet {
    /// 连着这么多秒没有没人在收的分片，就当录音豆停了
    public static let quietWindow: Double = 3
    /// 等了这么久还在发：断开重连一次
    public static let relinkAfter: Double = 8
    /// 最多等多久（一个长文件剩下的部分按 40 KB/s 发完要十几分钟）；再久这次就不下了，稍后再试
    public static let maxWait: Double = 20 * 60
    /// 最近断开过（这么多秒内）就不再断开，只等
    public static let relinkCooldown: Double = 5 * 60

    public enum Step: Equatable, Sendable {
        /// 安静了，可以发请求
        case proceed
        /// 还在发（或还没听够），再等等
        case wait
        /// 断开重连一次，让录音豆停下
        case relink
        /// 等太久了：这次不下，稍后再试
        case giveUp
    }

    /// `sinceLastStray`：离上次收到没人在收的分片过了多少秒（没收到过为 nil）；`listened`：已经听了多少秒；
    /// `sinceRelink`：离上次为这事断开过了多少秒（没断开过为 nil）
    public static func next(sinceLastStray: Double?, listened: Double, sinceRelink: Double?) -> Step {
        // 听够一个窗口、期间没有分片：录音豆没在发
        let quietFor = min(sinceLastStray ?? .infinity, listened)
        if quietFor >= quietWindow { return .proceed }
        if listened >= maxWait { return .giveUp }
        let streaming = sinceLastStray.map { $0 < quietWindow } ?? false
        let relinkedRecently = sinceRelink.map { $0 < relinkCooldown } ?? false
        if streaming, listened >= relinkAfter, !relinkedRecently { return .relink }
        return .wait
    }
}

public enum TransferRecovery {
    /// 这次没下完时临时文件（download.part）要不要留着。只有拿到的数据本身不能用（解不开、不像 Opus）才删；
    /// 设备报错（err=4 设备忙）、头是别的文件、续传首片对不上、各种中断：都是录音豆还在忙或连接的事，已收的前缀照样有效
    public static func keepsPartial(stop: DownloadStop, verdict: DownloadCheck.Verdict) -> Bool {
        guard case .rejected = verdict else { return true }
        switch stop {
        case .deviceError, .wrongFile, .resumeMismatch, .disconnected, .clockJump, .cancelled, .idle: return true
        case .done, .reachedExpected, .writeFailed: return false
        }
    }

    /// 停下的原因是不是「录音豆可能还在发」：下一次请求前要先等它安静
    public static func needsQuiet(_ stop: DownloadStop) -> Bool {
        switch stop {
        case .done, .reachedExpected, .disconnected: return false
        case .idle, .clockJump, .cancelled, .wrongFile, .deviceError, .writeFailed, .resumeMismatch: return true
        }
    }

    /// 同一个文件在这一轮同步里最多试几次（中间先等录音豆安静）
    public static let attemptsPerFile = 2
}
