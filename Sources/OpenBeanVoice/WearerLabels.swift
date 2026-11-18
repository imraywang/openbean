// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary

/// 段摘要和日记什么时候用「认出我的声音」的标签（TranscriptSegment.isWearer）。
///
/// - 标签能用：开关开着，并且这条录音按声纹判定过（SpeakerScan.outcome == .labelled）。没戴（notWorn）、
///   学习中、没有音频、没扫过的录音都当作没有标签：提示词和以前一样。
/// - 段摘要比标签旧：标签能用、摘要写过，但写的时候没带标签（Conversation.wearer 为 nil），或带的是更早一次扫描的标签，
///   或是按旧的做法（WearerStats.format）写的。
///   这种段不自动重写（那要把以前的转写再发给大模型一遍），只在用户手动写某天的日记时重写那一天的。
public enum WearerLabels {
    public static func usable(enabled: Bool, scan: SpeakerScan?) -> Bool {
        enabled && scan?.outcome == .labelled
    }

    public static func summaryIsStale(_ c: Conversation, enabled: Bool, scan: SpeakerScan?) -> Bool {
        guard usable(enabled: enabled, scan: scan), let scan, c.summary != nil else { return false }
        guard let w = c.wearer else { return true }
        // 旧做法写的带标签摘要（只标本人的句子、要点没有说话人）也算旧的
        return w.labelsAt < scan.at || w.format < WearerStats.currentFormat
    }

    /// 这段（只算不是语音输入的句子）佩戴者说了多少；标签不能用时 nil
    public static func stats(_ c: Conversation, segments: [TranscriptSegment], enabled: Bool, scan: SpeakerScan?) -> WearerStats? {
        guard usable(enabled: enabled, scan: scan), let scan else { return nil }
        let idx = c.spokenLines.filter { segments.indices.contains($0) }
        return WearerStats.measure(idx.map { (segments[$0].start, segments[$0].end, segments[$0].isWearer) }, labelsAt: scan.at)
    }
}
