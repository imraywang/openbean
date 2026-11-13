// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 摘要和笔记什么时候可以改用户的东西（App 的 NoteService 和每日日记共用，单独放出来好测）
public enum NoteRules {
    /// 新摘要的标题要不要当录音的标题：生成的标题不空，而且用户没自己起过名——录音没有标题，
    /// 或者现在的标题就是上次摘要给的。开不开每日日记都一样（开着时标题来自段摘要合成的整条摘要）
    public static func applyTitle(generated: String, current: String?, lastApplied: String?) -> Bool {
        guard !generated.isEmpty else { return false }
        guard let current, !current.isEmpty else { return true }
        return current == lastApplied
    }

    /// 写笔记的方式（和 NoteService.WriteMode 一一对应）
    public enum Mode: Sendable {
        case auto, ask, replace, newFile, refresh
    }

    /// 已经有一份 OpenBean 写的笔记时怎么办
    public enum Existing: Equatable, Sendable {
        /// 原地覆盖（标题变了时跟着改名）
        case overwrite
        /// 不动它，另写一份新文件
        case newFile
        /// 用户改过，先问（手动保存）
        case ask
        /// 不写（刷新时遇到改过的）
        case skip
    }

    /// 用户改过这份笔记（文件修改时间晚于写入时记下的 2 秒以上）就不覆盖：自动写另存一份，手动保存先问，刷新不写；
    /// 「另存」总是新文件；没改过就覆盖
    public static func existing(edited: Bool, mode: Mode) -> Existing {
        switch (edited, mode) {
        case (_, .newFile), (true, .auto): return .newFile
        case (true, .ask): return .ask
        case (true, .refresh): return .skip
        default: return .overwrite
        }
    }

    public static func edited(modified: Date, writtenAt: Date) -> Bool {
        modified.timeIntervalSince(writtenAt) > 2
    }
}
