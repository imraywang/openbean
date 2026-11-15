// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - iOS 版心力模式：同步以后的事怎么排（纯值，App/Mobile/BackgroundSync.swift 用，测试见 HeartBackgroundTests）
//
// 手机在口袋里：录音豆放回盒子 → 蓝牙下载（下载期间靠蓝牙数据保持运行）→ 下完以后转写、切段、写日记放进
// BGProcessingTask（App 回到前台时把没做完的补上）→ 一次同步有了结果发一条通知；要用户处理的事另发一条。
// 这里只决定「现在该做什么」，真正去做的是 App 里的 BackgroundSync。Mac 版不用这些。

/// 同步以后还有多少事没做
public struct HeartWork: Equatable, Sendable {
    /// 下载了、还没转写的录音（不含语音输入片段）
    public var untranscribed: Int
    /// 未转写的这些一共多少秒（日志用）
    public var seconds: Double

    public init(untranscribed: Int = 0, seconds: Double = 0) {
        self.untranscribed = untranscribed
        self.seconds = seconds
    }

    public var isEmpty: Bool { untranscribed == 0 }
    public static let none = HeartWork()
}

/// 后台处理任务（BGProcessingTask）的要求
public struct ProcessingRequest: Equatable, Sendable {
    /// 要不要接着电源才跑。不要求：录音豆一般是傍晚放回盒子，那时候想看到当天的日记，而不是第二天早上；
    /// 转写一条存一条，系统中途叫停只丢正在转的那一条；系统不给跑时，回到前台也会补上
    public var requiresExternalPower: Bool
    /// 要不要有网才跑。不要求：转写在本机做不用网；写日记时服务连不上会记「跳过」，之后补写
    public var requiresNetwork: Bool

    public init(requiresExternalPower: Bool = false, requiresNetwork: Bool = false) {
        self.requiresExternalPower = requiresExternalPower
        self.requiresNetwork = requiresNetwork
    }

    public static let standard = ProcessingRequest()
}

/// 要用户处理才能继续的事（各发一条通知，同一件事 12 小时内不重复发）
public enum HeartAttention: String, Equatable, Sendable, CaseIterable {
    /// 语音识别模型还没下载：录音下来了但转写不了
    case speechModelMissing
    /// 自动同步接连失败（连接一直断、设备一直不回）
    case syncKeepsFailing
}

/// 心力模式在 iOS 上的后台流程。事件进来，返回要做的动作
public struct HeartPipeline: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// 没事（等录音豆放回盒子）
        case idle
        /// 正在经蓝牙下载
        case syncing
        /// 下完了，转写等都排进了后台处理任务，等系统叫
        case waitingToProcess
        /// 正在转写、切段、写日记
        case processing
    }

    public enum AppState: Equatable, Sendable { case active, background }

    public enum Event: Equatable, Sendable {
        /// 开始下载
        case syncStarted
        /// 下载结束。`failed`：没下完（断了、出错），续传点留在临时文件里，下次接着下
        case syncEnded(failed: Bool, work: HeartWork)
        /// App 回到前台
        case becameActive(work: HeartWork)
        /// App 进了后台
        case enteredBackground(work: HeartWork)
        /// 系统开始跑后台处理任务
        case processingLaunched(work: HeartWork)
        /// 系统要收回后台处理任务的时间
        case processingExpired(work: HeartWork)
        /// 一轮处理做完（不管是前台还是后台任务里做的）
        case processingFinished(work: HeartWork)
    }

    public enum Action: Equatable, Sendable {
        /// 向系统要一段后台时间（下载期间蓝牙数据短暂停顿时不被挂起）
        case holdBackgroundTime
        case releaseBackgroundTime
        /// 排一个后台处理任务
        case scheduleProcessing(ProcessingRequest)
        /// 取消排着的后台处理任务（前台已经在做了）
        case cancelProcessing
        /// 现在就转写、切段、写日记
        case processNow
        /// 停下处理（后台任务时间到了：做完手上这条就停）
        case stopProcessing
        /// 发一条「要你处理」的通知
        case notify(HeartAttention)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var app: AppState
    /// 自动同步接连失败几次（成功一次清零）
    public private(set) var failures = 0
    /// 每件要处理的事上次通知的时刻
    public private(set) var notified: [HeartAttention: Date] = [:]
    /// 语音识别模型在不在（App 里随时更新）
    public var speechModelReady: Bool

    /// 接连失败几次算「要处理」
    public static let failuresBeforeNotice = 3
    /// 同一件事两次通知至少隔多久
    public static let noticeInterval: TimeInterval = 12 * 3600

    public init(app: AppState, speechModelReady: Bool = true) {
        self.app = app
        self.speechModelReady = speechModelReady
    }

    public mutating func handle(_ e: Event, now: Date = Date()) -> [Action] {
        switch e {
        case .syncStarted:
            let was = phase
            phase = .syncing
            // 下载期间手上的处理不停（前台做的转写照常），但后台任务里的处理让给下载：两样都要 CPU
            var out: [Action] = []
            if app == .background { out.append(.holdBackgroundTime) }
            if was == .processing && app == .background { out.append(.stopProcessing) }
            return out

        case let .syncEnded(failed, work):
            var out: [Action] = [.releaseBackgroundTime]
            if failed {
                failures += 1
                if failures >= Self.failuresBeforeNotice, let n = notice(.syncKeepsFailing, now: now) { out.append(n) }
            } else {
                failures = 0
            }
            out += afterWorkChanged(work, now: now)
            return out

        case let .becameActive(work):
            app = .active
            // 前台：排着的后台任务取消，直接做
            if work.isEmpty {
                if phase == .waitingToProcess { phase = .idle; return [.cancelProcessing] }
                return []
            }
            guard speechModelReady else { return [] }
            if phase == .syncing { return [.cancelProcessing] }
            phase = .processing
            return [.cancelProcessing, .processNow]

        case let .enteredBackground(work):
            app = .background
            switch phase {
            case .syncing:
                return [.holdBackgroundTime]
            case .processing:
                // 前台做到一半：停在这一条，剩下的交给后台任务
                phase = work.isEmpty ? .idle : .waitingToProcess
                return work.isEmpty ? [.stopProcessing] : [.stopProcessing, .scheduleProcessing(.standard)]
            case .idle, .waitingToProcess:
                return afterWorkChanged(work, now: now)
            }

        case let .processingLaunched(work):
            guard !work.isEmpty, speechModelReady else {
                phase = phase == .syncing ? .syncing : .idle
                return []
            }
            // 还在下载（蓝牙数据还在来）：先让下载跑完，下完会再排
            if phase == .syncing { return [.scheduleProcessing(.standard)] }
            phase = .processing
            return [.processNow]

        case let .processingExpired(work):
            guard phase == .processing else { return [] }
            phase = work.isEmpty ? .idle : .waitingToProcess
            return work.isEmpty ? [.stopProcessing] : [.stopProcessing, .scheduleProcessing(.standard)]

        case let .processingFinished(work):
            if phase == .syncing { return [] }
            phase = .idle
            return afterWorkChanged(work, now: now)
        }
    }

    /// 有没做完的事时：前台马上做，后台排任务；没有语音识别模型时提醒一次
    private mutating func afterWorkChanged(_ work: HeartWork, now: Date) -> [Action] {
        guard !work.isEmpty else {
            if phase == .waitingToProcess { phase = .idle; return [.cancelProcessing] }
            if phase != .processing { phase = .idle }
            return []
        }
        guard speechModelReady else {
            if phase != .processing { phase = .idle }
            return notice(.speechModelMissing, now: now).map { [$0] } ?? []
        }
        if phase == .processing { return [] }
        if app == .active {
            phase = .processing
            return [.processNow]
        }
        phase = .waitingToProcess
        return [.scheduleProcessing(.standard)]
    }

    /// 启动一会儿以后判断这次是不是系统在后台拉起来的：没有在前台的界面、App 也还在后台。
    /// （启动那一刻 applicationState 总是 background，那时判断会把每次正常打开都当成后台启动）
    public static func launchedInBackground(sceneInForeground: Bool, applicationInBackground: Bool) -> Bool {
        !sceneInForeground && applicationInBackground
    }

    private mutating func notice(_ a: HeartAttention, now: Date) -> Action? {
        if let last = notified[a], now.timeIntervalSince(last) < Self.noticeInterval { return nil }
        notified[a] = now
        return .notify(a)
    }
}

// MARK: - iOS 心力模式页顶上的四步：同步 → 转写 → 切段 → 写日记

/// 共用的 SyncRun 记的是下载、转写、写日记、清理心力豆四步；手机上按用户能感知的四步显示：
/// 同步（下载；清理心力豆的结果写在它的详情里）、转写、切段（转写完马上做，在本机、不花钱，所以跟着转写走）、写日记
public enum MobileSyncStep: String, CaseIterable, Sendable {
    case sync, transcribe, segment, diary
}

public struct MobileSyncRow: Equatable, Sendable {
    public var step: MobileSyncStep
    public var progress: SyncRun.StepProgress
}

public enum MobileSyncSteps {
    public static func rows(_ r: SyncRun) -> [MobileSyncRow] {
        let t = r.progress(.transcribe)
        return [
            MobileSyncRow(step: .sync, progress: r.progress(.download)),
            MobileSyncRow(step: .transcribe, progress: t),
            MobileSyncRow(step: .segment, progress: segment(t)),
            MobileSyncRow(step: .diary, progress: r.progress(.diary)),
        ]
    }

    /// 切段跟着转写：转写好一条就切好一条。转写失败的那几条没法切，不另算失败（转写那一步已经写了）
    static func segment(_ t: SyncRun.StepProgress) -> SyncRun.StepProgress {
        switch t.state {
        case .failed:
            return SyncRun.StepProgress(step: .transcribe, state: t.done > 0 ? .done : .skipped, done: t.done, total: nil,
                                        note: t.done > 0 ? nil : .nothingNew)
        case .done:
            return SyncRun.StepProgress(step: .transcribe, state: .done, done: t.done, total: nil, note: nil)
        default:
            return SyncRun.StepProgress(step: .transcribe, state: t.state, done: t.done, total: t.total, note: t.note)
        }
    }

    /// 收起时显示哪一步：第一个还没完的；都完了是 nil
    public static func current(_ r: SyncRun) -> MobileSyncRow? {
        rows(r).first { $0.progress.state == .running || $0.progress.state == .waiting }
    }
}

// MARK: - 一天的待办勾选状态（iOS：days/<日期>/todos.json）

/// 勾掉了哪些待办（按原文记）。只留还在这天日记里的，日记重写后文字变了的旧勾选自然丢掉
public struct DayTodoState: Codable, Equatable, Sendable {
    public var done: [String]

    public init(done: [String] = []) { self.done = done }

    public static let fileName = "todos.json"

    public func isDone(_ text: String) -> Bool { done.contains(text) }

    /// 勾上或取消，只保留 `current` 里还有的
    public func setting(_ text: String, done on: Bool, current: [String]) -> DayTodoState {
        var s = Set(done)
        if on { s.insert(text) } else { s.remove(text) }
        return DayTodoState(done: current.filter { s.contains($0) })
    }
}
