// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// 录音库转写过个人词表：纠正是有损的（别名写错了会改坏），所以识别器的原文另存在 `raw`，
/// 每次都从原文重新算——应用几次结果都一样，改了词表能重算，删掉词条能还原。
public enum TranscriptCorrection {
    /// 一句纠正后的结果：text 是显示用的；raw 是识别器原文，只有 text 和原文不同时才有
    public struct Line: Equatable, Sendable {
        public var text: String
        public var raw: String?
        public init(text: String, raw: String? = nil) {
            self.text = text
            self.raw = raw
        }
    }

    /// 用词表纠正一句：从 raw（没有就用 text）算起。纠正后和原文一样就不留 raw
    public static func apply(_ corrector: GlossaryCorrector, text: String, raw: String?) -> Line {
        let source = raw ?? text
        let fixed = corrector.correct(source, mode: .transcript).text
        return Line(text: fixed, raw: fixed == source ? nil : source)
    }

    /// 应用词表的规则版本：纠正规则改了就加 1，让已有转写重算一遍
    public static let rulesVersion = 1

    /// 词表的指纹：解析后的词条和别名（注释、空行、顺序之外的空白不算），加上规则版本
    public static func glossaryHash(_ lines: [String]) -> String {
        let entries = lines.compactMap(GlossaryCorrector.Entry.parse)
            .map { ([$0.term] + $0.aliases).joined(separator: "\u{1F}") }
        let text = "v\(rulesVersion)\n" + entries.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 要不要对已有转写重新应用词表：强制，或词表（规则）和上次应用的不一样
    public static func needsBackfill(currentHash: String, lastApplied: String?, force: Bool = false) -> Bool {
        force || currentHash != lastApplied
    }
}
