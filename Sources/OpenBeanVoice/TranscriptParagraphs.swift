// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把转写的一句一句按停顿并成段落，只用于显示（不改 transcript.json）。
public enum TranscriptParagraphs {
    /// 返回每段包含的句子下标范围。前后两句之间停顿超过 `gap` 秒，或这一段已经有 `maxChars` 个字，就另起一段。
    public static func group(_ segments: [TranscriptSegment], gap: Double = 2.0, maxChars: Int = 280) -> [Range<Int>] {
        guard !segments.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var start = 0
        var chars = segments[0].text.count
        for i in 1..<segments.count {
            let pause = segments[i].start - segments[i - 1].end
            if pause > gap || chars >= maxChars {
                out.append(start..<i)
                start = i
                chars = 0
            }
            chars += segments[i].text.count
        }
        out.append(start..<segments.count)
        return out
    }

    /// 两句拼在一段里时中间要不要空格：前一句以拉丁字母、数字或西文标点结尾，后一句以拉丁字母或数字开头时才加
    public static func joiner(after previous: String, before next: String) -> String {
        guard let a = previous.unicodeScalars.last, let b = next.unicodeScalars.first else { return "" }
        let latinEnd = a.isASCII && (CharacterSet.alphanumerics.contains(a) || ".,!?;:)\"'".unicodeScalars.contains(a))
        let latinStart = b.isASCII && CharacterSet.alphanumerics.contains(b)
        return latinEnd && latinStart ? " " : ""
    }
}
