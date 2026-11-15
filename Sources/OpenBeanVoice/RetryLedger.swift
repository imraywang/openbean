// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 自动整理失败后的重试记录：同一份输入（signature 相同）连续失败就退避，失败到上限就不再自动试，
/// 免得每次同步、每次打开 App 都把同一个必然失败的请求再发一遍（云端每次都花钱）。
///
/// - 只记「模型的回复不能用」这类失败；服务不通（没发出请求）不记。
/// - 输入变了（转写改了、段摘要变了）signature 就不同，重新开始计数。
/// - 用户手动重试时 `reset`，立刻再试一次。
public struct RetryLedger: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var signature: String
        public var failures: Int
        public var last: Date
        /// 最后一次失败的原因（写日志、界面用的简短说法，不含内容）
        public var reason: String
    }

    public enum State: Equatable, Sendable {
        /// 可以试
        case allowed
        /// 退避中，到这个时间之后再试
        case waiting(until: Date, failures: Int, reason: String)
        /// 失败次数到了上限，不再自动试（等内容变化或手动重试）
        case gaveUp(failures: Int, reason: String)
    }

    /// 第 n 次失败之后等多久再自动试（第 1 次 10 分钟、第 2 次 1 小时）；失败 maxFailures 次后不再自动试
    public static let delays: [TimeInterval] = [10 * 60, 60 * 60]
    public static let maxFailures = 3

    public var entries: [String: Entry] = [:]

    public init() {}

    public func state(_ key: String, signature: String, now: Date = Date()) -> State {
        guard let e = entries[key], e.signature == signature else { return .allowed }
        if e.failures >= Self.maxFailures { return .gaveUp(failures: e.failures, reason: e.reason) }
        let wait = Self.delays[min(e.failures, Self.delays.count) - 1]
        let until = e.last.addingTimeInterval(wait)
        return now >= until ? .allowed : .waiting(until: until, failures: e.failures, reason: e.reason)
    }

    public mutating func failed(_ key: String, signature: String, reason: String, now: Date = Date()) {
        var e = entries[key].flatMap { $0.signature == signature ? $0 : nil }
            ?? Entry(signature: signature, failures: 0, last: now, reason: reason)
        e.failures += 1
        e.last = now
        e.reason = reason
        entries[key] = e
    }

    public mutating func succeeded(_ key: String) { entries[key] = nil }

    public mutating func reset(_ key: String) { entries[key] = nil }

    /// 去掉很久以前的记录（30 天），免得越积越多
    public mutating func prune(now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.last) < 30 * 86_400 }
    }

    /// 这个错误算不算「模型的回复不能用」（要记进退避）；网络错误、服务不通不算
    public static func counts(_ error: Error) -> Bool {
        if error is Summarizer.Failure { return true }
        if let e = error as? LLMBackendError {
            switch e {
            case .contextExceeded, .outputTruncated, .refused, .unsupportedLanguage: return true
            case .unavailable, .rateLimited: return false
            }
        }
        if case LLMService.Failure.badResponse = error { return true }
        return false
    }

    /// 写进记录的简短原因
    public static func reason(_ error: Error) -> String {
        if let e = error as? LLMBackendError, e == .outputTruncated { return "truncated" }
        if let e = error as? Summarizer.Failure, case .unusable = e { return "unusable" }
        if let e = error as? LLMBackendError, e == .refused { return "refused" }
        return "unusable"
    }
}
