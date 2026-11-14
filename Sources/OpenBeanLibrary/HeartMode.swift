// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - 心力模式
//
// App 只有一个总开关（默认关，走完心力模式介绍才开，见 HeartIntro）：普通模式和心力模式（Heart mode）共用录音库、详情、MCP 和数据，差别全在这里算出来。
// 界面和业务代码都从 `ModeDefaults` 读，不各自写 `if heartMode`。纯值，方便测试；
// MCP 服务（另一个进程）也按这里的键名去读 App 的偏好设置。

/// 录音是在哪种模式下同步进来的（index.json 里的 source；旧录音没有这个字段 = 普通）
public enum RecordingSource: String, Codable, Sendable, Hashable {
    case normal
    case heart

    /// index.json 里的值；没有或不认识的都算普通
    public init(stored: String?) {
        self = stored.flatMap(RecordingSource.init(rawValue:)) ?? .normal
    }
}

/// 心力模式录音的本机音频留多久（转写留着，只删 audio.ogg）
public enum AudioRetention: String, CaseIterable, Sendable, Hashable {
    /// 转写完成后就删
    case afterTranscription
    /// 同步进来 7 天后删（默认）
    case sevenDays
    /// 一直保留
    case forever

    public static let `default`: AudioRetention = .sevenDays

    /// 同步后多久可以删；nil = 不删
    public var maxAge: TimeInterval? {
        switch self {
        case .afterTranscription: return 0
        case .sevenDays: return 7 * 86_400
        case .forever: return nil
        }
    }
}

/// 打开主窗口时落在哪一页
public enum MainLanding: Sendable, Hashable {
    case today, library
}

/// 偏好设置里的键（App 写、MCP 服务读，两边用同一份名字）
public enum ModeKeys {
    public static let heartMode = "heartMode"
    /// 0.5 以前的「每天写一篇日记」开关；只在迁移时读
    public static let legacyDailyDiary = "dailyDiary"
    /// 心力模式介绍走完或跳过过（之后不再自动出现）
    public static let heartIntroSeen = "heartIntroSeen"
    public static let heartRecordingNotes = "heartRecordingNotes"
    public static let heartDeleteFromRecorder = "heartDeleteFromRecorder"
    public static let heartAudioRetention = "heartAudioRetention"
    public static let heartAgentTranscripts = "heartAgentTranscripts"
}

/// 随模式变的取值。存下来的是用户的各项选择（含普通模式下原有的开关），这里算出现在实际生效的值
public struct ModeDefaults: Sendable, Equatable {
    /// 总开关
    public var heartMode: Bool
    /// 普通模式「自动同步」开关（设置 → 录音库）
    public var autoSyncSetting: Bool
    /// 普通模式「每条录音写一篇笔记」开关（设置 → 录音库）
    public var notesSetting: Bool
    /// 心力模式「同时为每条录音写一篇笔记」
    public var heartRecordingNotes: Bool
    /// 心力模式「同步并转写完成后，从心力豆删除这条录音」
    public var heartDeleteFromRecorder: Bool
    /// 心力模式录音的本机音频保留多久
    public var heartAudioRetention: AudioRetention
    /// 允许 Agent（MCP）读取心力模式录音的原文
    public var heartAgentTranscripts: Bool

    /// 各项的出厂值（只改这一处）
    public static let heartRecordingNotesDefault = false
    public static let heartDeleteFromRecorderDefault = true
    public static let heartAgentTranscriptsDefault = false

    /// 注册给 UserDefaults 的出厂值
    public static var registeredDefaults: [String: Any] {
        [ModeKeys.heartMode: false,
         ModeKeys.heartRecordingNotes: heartRecordingNotesDefault,
         ModeKeys.heartDeleteFromRecorder: heartDeleteFromRecorderDefault,
         ModeKeys.heartAudioRetention: AudioRetention.default.rawValue,
         ModeKeys.heartAgentTranscripts: heartAgentTranscriptsDefault]
    }

    public init(heartMode: Bool, autoSyncSetting: Bool = true, notesSetting: Bool = false,
                heartRecordingNotes: Bool = ModeDefaults.heartRecordingNotesDefault,
                heartDeleteFromRecorder: Bool = ModeDefaults.heartDeleteFromRecorderDefault,
                heartAudioRetention: AudioRetention = .default,
                heartAgentTranscripts: Bool = ModeDefaults.heartAgentTranscriptsDefault) {
        self.heartMode = heartMode
        self.autoSyncSetting = autoSyncSetting
        self.notesSetting = notesSetting
        self.heartRecordingNotes = heartRecordingNotes
        self.heartDeleteFromRecorder = heartDeleteFromRecorder
        self.heartAudioRetention = heartAudioRetention
        self.heartAgentTranscripts = heartAgentTranscripts
    }

    /// 打开主窗口落在哪：两种模式都落在心力模式页（开着是今天，关着是介绍心力模式的空状态）
    public var landing: MainLanding { .today }

    /// 放回充电盒 / 连上时自动同步。心力模式下固定开（设置里显示为说明，不是开关）
    public var autoSync: Bool { heartMode || autoSyncSetting }
    /// 「自动同步」开关被心力模式锁住
    public var autoSyncLocked: Bool { heartMode }

    /// 给对话段写段摘要、合成每天的日记（切段本身两种模式都做）
    public var writesDiary: Bool { heartMode }

    /// 转写后自动给每条录音写一篇 Markdown 笔记。心力模式默认只写日记
    public var writesRecordingNotes: Bool { heartMode ? heartRecordingNotes : notesSetting }

    /// 这会儿同步进来的录音记成哪种来源
    public var sourceForSync: RecordingSource { heartMode ? .heart : .normal }

    /// 同步并转写完成后，从设备删除这次同步下载的心力模式录音
    public var deletesFromRecorderAfterSync: Bool { heartMode && heartDeleteFromRecorder }

    /// 心力模式来源的录音本机音频留多久。总开关关着时一律不删（删除不可恢复，只在用户开着心力模式时做）
    public var audioRetention: AudioRetention { heartMode ? heartAudioRetention : .forever }

    /// 界面上把设备叫「心力豆」（Heart bean）而不是「录音豆」：只在心力模式相关的界面里
    public var callsDeviceHeartBean: Bool { heartMode }

    /// 从偏好设置读（App 和 MCP 服务共用）。autoSync / notesEnabled 是 App 原有的键
    public init(defaults d: UserDefaults) {
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        self.init(heartMode: bool(ModeKeys.heartMode, false),
                  autoSyncSetting: bool("autoSync", true),
                  notesSetting: bool("notesEnabled", false),
                  heartRecordingNotes: bool(ModeKeys.heartRecordingNotes, Self.heartRecordingNotesDefault),
                  heartDeleteFromRecorder: bool(ModeKeys.heartDeleteFromRecorder, Self.heartDeleteFromRecorderDefault),
                  heartAudioRetention: AudioRetention(rawValue: d.string(forKey: ModeKeys.heartAudioRetention) ?? "") ?? .default,
                  heartAgentTranscripts: bool(ModeKeys.heartAgentTranscripts, Self.heartAgentTranscriptsDefault))
    }
}

// MARK: - 心力模式介绍（替代原来的静默迁移）

/// 心力模式默认关，只有走完介绍（或之后在心力模式设置里打开开关）才会开。
/// 谁在什么时候看到介绍、里面的选项预先填成什么，都在这里算。纯函数，方便测试
public enum HeartIntro {
    /// 介绍里那几项选择的初始值
    public struct Prefill: Equatable, Sendable {
        /// 同步并转写完成后，从心力豆删除
        public var deleteFromRecorder: Bool
        /// 本机音频留多久
        public var audioRetention: AudioRetention
        /// 以前开着「每天写一篇日记」（0.5 以前的 dailyDiary）：介绍里说一句日记现在归心力模式
        public var hadDailyDiary: Bool

        public init(deleteFromRecorder: Bool = ModeDefaults.heartDeleteFromRecorderDefault,
                    audioRetention: AudioRetention = .default, hadDailyDiary: Bool = false) {
            self.deleteFromRecorder = deleteFromRecorder
            self.audioRetention = audioRetention
            self.hadDailyDiary = hadDailyDiary
        }
    }

    /// 什么时候自动出现
    public enum When: Equatable, Sendable {
        /// 启动时（已经用过 OpenBean 的人：升级后第一次启动）
        case atLaunch
        /// 首次使用向导走完之后（新装的人：不同时弹两个窗口）
        case afterOnboarding
    }

    public enum Decision: Equatable, Sendable {
        /// 心力模式已经开着（这个分支的开发版里打开过）：保持开，不再介绍
        case alreadyOn
        /// 看过了（走完或点了「以后再说」）：不自动出现；心力模式页关着时可以再打开
        case seen
        case show(When, Prefill)
    }

    /// - Parameters:
    ///   - storedHeartMode: 偏好设置里 heartMode 的原始值（没设置过是 nil）
    ///   - introSeen: 走完或跳过过介绍
    ///   - onboardingDone: 首次使用向导走完了
    ///   - legacyDailyDiary: 0.5 以前的「每天写一篇日记」开关
    ///   - storedDelete / storedRetention: 之前存过的心力模式选择（没有就用出厂值）
    public static func decide(storedHeartMode: Bool?, introSeen: Bool, onboardingDone: Bool, legacyDailyDiary: Bool,
                              storedDelete: Bool? = nil, storedRetention: AudioRetention? = nil) -> Decision {
        if storedHeartMode == true { return .alreadyOn }
        if introSeen { return .seen }
        let prefill = Prefill(deleteFromRecorder: storedDelete ?? ModeDefaults.heartDeleteFromRecorderDefault,
                              audioRetention: storedRetention ?? .default,
                              hadDailyDiary: legacyDailyDiary)
        return .show(onboardingDone ? .atLaunch : .afterOnboarding, prefill)
    }

    /// 从偏好设置算（要在 register(defaults:) 之前：注册过默认值后就分不清 heartMode「没设置过」）。
    /// 已经开着的记成看过介绍，以后不再问。心力模式开关本身一律不写：不会因为旧开关自动打开
    @discardableResult
    public static func run(_ d: UserDefaults) -> Decision {
        let stored = d.object(forKey: ModeKeys.heartMode) == nil ? nil : d.bool(forKey: ModeKeys.heartMode)
        let decision = decide(storedHeartMode: stored, introSeen: d.bool(forKey: ModeKeys.heartIntroSeen),
                              onboardingDone: d.bool(forKey: "onboardingDone"),
                              legacyDailyDiary: d.bool(forKey: ModeKeys.legacyDailyDiary),
                              storedDelete: d.object(forKey: ModeKeys.heartDeleteFromRecorder) == nil
                                  ? nil : d.bool(forKey: ModeKeys.heartDeleteFromRecorder),
                              storedRetention: d.string(forKey: ModeKeys.heartAudioRetention).flatMap(AudioRetention.init(rawValue:)))
        if decision == .alreadyOn { d.set(true, forKey: ModeKeys.heartIntroSeen) }
        return decision
    }
}

// MARK: - 本机音频保留期

/// 心力模式录音的本机 audio.ogg 什么时候可以删。纯函数，方便测试。删之前转写必须已经在、而且有内容
public enum AudioRetentionPolicy {
    public enum Keep: Equatable, Sendable, CustomStringConvertible {
        /// 普通模式同步进来的录音：从不按保留期删
        case notHeartSource
        /// 设置是一直保留（或心力模式关着）
        case keepForever
        /// 本机没有音频（已经删过）
        case noAudio
        /// 还没有转写，或转写是空的
        case noTranscript
        /// 录音豆上还有这条、并且等着自动删：设备端删除要用本机音频核对，先留着
        case awaitingRecorderDelete
        /// 还没到时间
        case tooRecent(secondsLeft: TimeInterval)

        public var description: String {
            switch self {
            case .notHeartSource: return "不是心力模式录音"
            case .keepForever: return "设置为一直保留"
            case .noAudio: return "本机没有音频"
            case .noTranscript: return "还没有转写（或转写为空）"
            case .awaitingRecorderDelete: return "录音豆上还有，等它从设备删除后再删本机音频"
            case let .tooRecent(s): return "还没到保留期（还有 \(Int(s / 3600)) 小时）"
            }
        }
    }

    /// nil = 可以删本机音频
    /// - Parameters:
    ///   - syncedAt: 同步进来的时刻；旧数据没有时用录音开始时间
    ///   - awaitingRecorderDelete: 录音豆上还有、并且设置了同步后自动从设备删除
    public static func check(source: RecordingSource, retention: AudioRetention, audioExists: Bool,
                             transcriptLines: Int?, syncedAt: Date, now: Date,
                             awaitingRecorderDelete: Bool) -> Keep? {
        guard source == .heart else { return .notHeartSource }
        guard let maxAge = retention.maxAge else { return .keepForever }
        guard audioExists else { return .noAudio }
        guard let n = transcriptLines, n > 0 else { return .noTranscript }
        if awaitingRecorderDelete { return .awaitingRecorderDelete }
        let age = now.timeIntervalSince(syncedAt)
        if age < maxAge { return .tooRecent(secondsLeft: maxAge - age) }
        return nil
    }
}

// MARK: - 同步后自动从设备删除

/// 心力模式同步后要不要从设备上删掉这条录音。这里只是 App 这一侧的前置条件；
/// 通过后仍要走 OpenBeanKit 的 DeletePolicy（本机音频完整解码、时长核对、设备没在录音、连接空闲）。纯函数，方便测试
public enum RecorderCleanupPolicy {
    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        case settingOff
        case notHeartSource
        /// 不是这次同步下载的（以前下载的、或 App 重启过）
        case notDownloadedThisSync
        /// 下载校验没过，或者缺了片补的静音
        case downloadIncomplete
        /// 还没转写完
        case notTranscribed

        public var description: String {
            switch self {
            case .settingOff: return "设置里没开（或心力模式关着）"
            case .notHeartSource: return "不是心力模式同步的录音"
            case .notDownloadedThisSync: return "不是这次同步下载的"
            case .downloadIncomplete: return "下载不完整（有缺片补了静音）"
            case .notTranscribed: return "还没转写完"
            }
        }
    }

    /// nil = 可以交给 DeletePolicy 去删
    public static func check(mode: ModeDefaults, source: RecordingSource, downloadedThisSync: Bool,
                             downloadComplete: Bool, transcriptExists: Bool) -> Refusal? {
        guard mode.deletesFromRecorderAfterSync else { return .settingOff }
        guard source == .heart else { return .notHeartSource }
        guard downloadedThisSync else { return .notDownloadedThisSync }
        guard downloadComplete else { return .downloadIncomplete }
        guard transcriptExists else { return .notTranscribed }
        return nil
    }
}

// MARK: - Agent 能不能读原文

public enum HeartPrivacy {
    /// MCP 给不给这条录音的转写原文：心力模式录音默认不给，设置里打开「允许读原文」才给；普通录音照旧给
    public static func transcriptVisible(source: RecordingSource, agentMayReadHeartTranscripts: Bool) -> Bool {
        source != .heart || agentMayReadHeartTranscripts
    }
}
