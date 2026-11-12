// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 两遍识别的显示文本：
/// - 黑字：SenseVoice 每句定稿；
/// - 灰字：Apple 实时结果里、时间上落在最后一句定稿之后的那些字（按字的音频时间裁掉已定稿部分）。
public struct TwoPassText {
    public private(set) var committed: [String] = []
    public private(set) var committedEnd: Double = 0
    private var appleFinalRuns: [TimedText] = []
    private var appleVolatileRuns: [TimedText] = []

    public init() {}

    public mutating func apple(isFinal: Bool, runs: [TimedText], text: String, audioStart: Double, audioEnd: Double) {
        // 没有逐字时间时退化成整段
        let r = runs.isEmpty ? [TimedText(text: text, start: audioStart, end: audioEnd)] : runs
        if isFinal {
            appleFinalRuns += r
            appleVolatileRuns = []
        } else {
            appleVolatileRuns = r
        }
        prune()
    }

    /// 一句定稿到达；返回要打进光标处的文字
    @discardableResult
    public mutating func commit(text: String, end: Double) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { committed.append(t) }
        committedEnd = max(committedEnd, end)
        prune()
        return t
    }

    private mutating func prune() {
        appleFinalRuns.removeAll { $0.start < committedEnd }
    }

    public var finalText: String { committed.joined() }

    public var pendingText: String {
        (appleFinalRuns + appleVolatileRuns)
            .filter { $0.start >= committedEnd }
            .map(\.text).joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "，,。 "))
    }
}
