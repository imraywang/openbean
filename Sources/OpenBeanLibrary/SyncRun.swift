// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - 心力模式一次同步的进度
//
// 放回充电盒 → 下载 → 转写 → 写日记 → 从心力豆删除。心力模式页顶上的四步条和结束时的系统通知都从这里读。
// 这里只记「发生了什么」（哪几条下完、转写结果、日记结果、设备端删除结果），每一步的状态由这些推出来，
// 所以 App 那边只管在各处报事件，不用自己维护状态机。纯值，方便测试。

public struct SyncRun: Equatable, Sendable {
    /// 四步，按显示顺序
    public enum Step: String, CaseIterable, Sendable, Hashable {
        case download, transcribe, diary, cleanUp
    }

    /// 一步现在的样子
    public enum State: Equatable, Sendable {
        case waiting
        case running
        case done
        /// 没做，也不算错（设置关着、没有新东西、大模型服务不通）
        case skipped
        case failed
    }

    /// 状态旁边的一句说明
    public enum Note: Equatable, Sendable {
        /// 设置里关着
        case settingOff
        /// 没有要做的
        case nothingNew
        /// 大模型服务连不上：日记等服务恢复后补写
        case llmUnreachable
        /// 让给了语音输入，结束后接着下
        case pausedForVoiceTyping
        /// 还有 n 条没下完（下次同步再试）
        case left(Int)
        /// n 条没成功
        case failedCount(Int)
        /// 连接正忙，下次空出来再删
        case deviceBusy
        /// n 条留在了心力豆上（没通过删除前的核对）
        case kept(Int)
    }

    public struct StepProgress: Equatable, Sendable {
        public var step: Step
        public var state: State
        /// 已完成几条（下载了几条、转写了几条、写进日记几条、删了几条）
        public var done: Int
        /// 一共几条；不知道时为 nil
        public var total: Int?
        public var note: Note?

        public init(step: Step, state: State, done: Int = 0, total: Int? = nil, note: Note? = nil) {
            self.step = step
            self.state = state
            self.done = done
            self.total = total
            self.note = note
        }
    }

    /// 开始时的设置（同步途中改了设置也按开始时的算这一次）
    public struct Options: Equatable, Sendable {
        public var autoTranscribe: Bool
        public var writesDiary: Bool
        public var deletesFromRecorder: Bool
        public var audioRetention: AudioRetention

        public init(autoTranscribe: Bool = true, writesDiary: Bool = true, deletesFromRecorder: Bool = true,
                    audioRetention: AudioRetention = .default) {
            self.autoTranscribe = autoTranscribe
            self.writesDiary = writesDiary
            self.deletesFromRecorder = deletesFromRecorder
            self.audioRetention = audioRetention
        }
    }

    /// 日记这一步对一条录音的结果（DiaryService.refreshDays 汇总出来的）
    public enum DiaryResult: Equatable, Sendable {
        /// 写了（或输入没变、不用重写；或这条没有要进日记的话）
        case written
        /// 大模型服务连不上 / 拒绝了 API key
        case serviceUnavailable
        /// 服务通，但没写成
        case failed
    }

    /// 设备端删除对一条录音的结果
    public enum CleanUpResult: Equatable, Sendable {
        case deleted
        /// 没删（核对没过、设置关着、出错）：留在心力豆上
        case kept
        /// 连接正忙，等下次
        case busy
        /// 设备上已经没有这条了（别处删了）
        case gone
    }

    public enum DownloadPhase: Equatable, Sendable {
        case running
        case paused
        case ended
    }

    public var startedAt: Date
    /// 四步都有了结果的时刻
    public var finishedAt: Date?
    public var options: Options
    /// 这次要下载的录音（让给语音输入后接着下、或改用 Wi‑Fi 时会并进来）
    public private(set) var expected: [UInt32] = []
    public private(set) var downloaded: [UInt32] = []
    public private(set) var downloadPhase: DownloadPhase = .running
    public private(set) var transcribed: [UInt32: Bool] = [:]
    public private(set) var diary: [UInt32: DiaryResult] = [:]
    public private(set) var cleanUp: [UInt32: CleanUpResult] = [:]

    public init(ids: [UInt32], options: Options, now: Date = Date()) {
        startedAt = now
        self.options = options
        expected = Self.unique(ids)
    }

    private static func unique(_ ids: [UInt32]) -> [UInt32] {
        var seen = Set<UInt32>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: 事件

    /// 这次同步又要下载一批（接着下、改用 Wi‑Fi）：并进来，下载这一步回到进行中
    public mutating func downloadStarted(_ ids: [UInt32]) {
        expected = Self.unique(expected + ids)
        downloadPhase = .running
    }

    public mutating func recordDownloaded(_ id: UInt32) {
        if !expected.contains(id) { expected.append(id) }
        if !downloaded.contains(id) { downloaded.append(id) }
    }

    public mutating func downloadPaused() { downloadPhase = .paused }
    public mutating func downloadEnded() { downloadPhase = .ended }

    /// 只认这次下载的录音（别的转写、日记、删除与这次同步无关）
    public func involves(_ id: UInt32) -> Bool { downloaded.contains(id) }

    public mutating func recordTranscribed(_ id: UInt32, ok: Bool) {
        guard involves(id) else { return }
        transcribed[id] = ok
    }

    public mutating func recordDiary(_ id: UInt32, _ r: DiaryResult) {
        guard involves(id) else { return }
        diary[id] = r
    }

    public mutating func recordCleanUp(_ id: UInt32, _ r: CleanUpResult) {
        guard involves(id) else { return }
        // 删掉了、留下了、没了是定论，之后再报「忙」不改
        if r == .busy, let old = cleanUp[id], old != .busy { return }
        cleanUp[id] = r
    }

    /// 报完事件后调用：四步都有结果就记下结束时刻，返回是不是刚结束（发通知用，只发一次）
    public mutating func markFinishedIfSettled(now: Date = Date()) -> Bool {
        guard finishedAt == nil, settled else { return false }
        finishedAt = now
        return true
    }

    // MARK: 推出来的状态

    public var isFinished: Bool { finishedAt != nil }

    private var downloadDone: Bool { downloadPhase == .ended }
    private var transcribedOK: [UInt32] { downloaded.filter { transcribed[$0] == true } }
    private var transcribeFailed: Int { downloaded.filter { transcribed[$0] == false }.count }
    private var transcribeSettled: Bool {
        !options.autoTranscribe || (downloadDone && downloaded.allSatisfy { transcribed[$0] != nil })
    }

    public var steps: [StepProgress] { Step.allCases.map(progress) }

    public func progress(_ step: Step) -> StepProgress {
        switch step {
        case .download: return downloadProgress
        case .transcribe: return transcribeProgress
        case .diary: return diaryProgress
        case .cleanUp: return cleanUpProgress
        }
    }

    private var downloadProgress: StepProgress {
        let n = downloaded.count, total = expected.count
        switch downloadPhase {
        case .running: return StepProgress(step: .download, state: .running, done: n, total: total)
        case .paused: return StepProgress(step: .download, state: .running, done: n, total: total, note: .pausedForVoiceTyping)
        case .ended:
            if total == 0 { return StepProgress(step: .download, state: .skipped, note: .nothingNew) }
            if n < total {
                return StepProgress(step: .download, state: .failed, done: n, total: total, note: .left(total - n))
            }
            return StepProgress(step: .download, state: .done, done: n, total: total)
        }
    }

    private var transcribeProgress: StepProgress {
        guard options.autoTranscribe else { return StepProgress(step: .transcribe, state: .skipped, note: .settingOff) }
        let finished = downloaded.filter { transcribed[$0] != nil }.count
        // 下载还在进行时总数按要下的算（每条下完马上转写）
        let total = downloadDone ? downloaded.count : max(expected.count, downloaded.count)
        if downloaded.isEmpty {
            return downloadDone ? StepProgress(step: .transcribe, state: .skipped, note: .nothingNew)
                                : StepProgress(step: .transcribe, state: .waiting, total: total)
        }
        let ok = transcribedOK.count, bad = transcribeFailed
        if transcribeSettled {
            if ok == 0 { return StepProgress(step: .transcribe, state: .failed, done: 0, total: total, note: .failedCount(bad)) }
            return StepProgress(step: .transcribe, state: .done, done: ok, total: total, note: bad > 0 ? .failedCount(bad) : nil)
        }
        return StepProgress(step: .transcribe, state: .running, done: finished, total: total)
    }

    private var diarySettled: Bool {
        !options.writesDiary || (transcribeSettled && transcribedOK.allSatisfy { diary[$0] != nil })
    }

    private var diaryProgress: StepProgress {
        guard options.writesDiary else { return StepProgress(step: .diary, state: .skipped, note: .settingOff) }
        guard options.autoTranscribe else { return StepProgress(step: .diary, state: .skipped, note: .nothingNew) }
        let ids = transcribedOK
        let results = ids.compactMap { diary[$0] }
        if diarySettled {
            if ids.isEmpty { return StepProgress(step: .diary, state: .skipped, note: .nothingNew) }
            if results.contains(.serviceUnavailable) {
                return StepProgress(step: .diary, state: .skipped, done: results.filter { $0 == .written }.count,
                                    total: ids.count, note: .llmUnreachable)
            }
            let bad = results.filter { $0 == .failed }.count
            if bad > 0 { return StepProgress(step: .diary, state: .failed, done: ids.count - bad, total: ids.count, note: .failedCount(bad)) }
            return StepProgress(step: .diary, state: .done, done: ids.count, total: ids.count)
        }
        if ids.isEmpty { return StepProgress(step: .diary, state: .waiting) }
        // 服务不通：一条报了就先显示出来，不等其他的
        if results.contains(.serviceUnavailable) {
            return StepProgress(step: .diary, state: .running, done: results.count, total: transcribeSettled ? ids.count : nil,
                                note: .llmUnreachable)
        }
        return StepProgress(step: .diary, state: .running, done: results.count, total: transcribeSettled ? ids.count : nil)
    }

    /// 转写失败的录音不会去删（删除前要有转写）：算留在心力豆上
    private func cleanUpOutcome(_ id: UInt32) -> CleanUpResult? {
        if let r = cleanUp[id] { return r }
        if !options.autoTranscribe || transcribed[id] == false { return .kept }
        return nil
    }

    /// 从心力豆删了几条
    public var deletedFromRecorder: Int { downloaded.filter { cleanUp[$0] == .deleted }.count }
    /// 留在心力豆上几条（核对没过、出错、没转写成）
    public var keptOnRecorder: Int {
        options.deletesFromRecorder ? downloaded.filter { cleanUpOutcome($0) == .kept }.count : 0
    }

    private var cleanUpSettled: Bool {
        guard options.deletesFromRecorder else { return true }
        guard downloadDone, transcribeSettled else { return false }
        // 只剩「连接正忙」的也算有了结果：下次连接空出来再删，界面上照样更新
        return downloaded.allSatisfy { cleanUpOutcome($0) != nil }
    }

    private var cleanUpProgress: StepProgress {
        guard options.deletesFromRecorder else { return StepProgress(step: .cleanUp, state: .skipped, note: .settingOff) }
        let total = downloaded.count
        if downloadDone && total == 0 { return StepProgress(step: .cleanUp, state: .skipped, note: .nothingNew) }
        let outcomes = downloaded.compactMap(cleanUpOutcome)
        let deleted = deletedFromRecorder, kept = keptOnRecorder
        let busy = outcomes.contains(.busy)
        if cleanUpSettled && !busy {
            return StepProgress(step: .cleanUp, state: .done, done: deleted, total: total, note: kept > 0 ? .kept(kept) : nil)
        }
        if busy { return StepProgress(step: .cleanUp, state: .running, done: deleted, total: total, note: .deviceBusy) }
        if cleanUp.isEmpty { return StepProgress(step: .cleanUp, state: .waiting, total: downloadDone ? total : nil) }
        return StepProgress(step: .cleanUp, state: .running, done: deleted, total: downloadDone ? total : nil)
    }

    /// 四步都有了结果（下载结束、转写和日记都报完、删除都有定论或在等连接）
    public var settled: Bool {
        downloadDone && transcribeSettled && diarySettled && cleanUpSettled
    }

    /// 整次同步有没有带回东西（没下到任何录音时不发「今天的记录已更新」）
    public var broughtSomething: Bool { !downloaded.isEmpty }
}
