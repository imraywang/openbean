// SPDX-License-Identifier: Apache-2.0

// MARK: - 语音输入不碰别人的录音
//
// 快捷键 / 菜单开始语音输入时，录音豆可能正在录一段别的录音（按键设成只录音后按键开始的、设备页开始的、
// 或者 App 连上之前用户按键录的会议）。这时发开始命令没意义，结束语音输入时的暂停 + 结束（18/82 00）
// 还会把那段录音截断。所以：录音豆在录、又不是这次语音输入自己开始的，就不开始；
// 结束录音只发给 App 自己开始、且开始前确认没在录的那段。纯函数，方便测试。

public enum DictationStartPolicy {
    public enum Refusal: Equatable, Sendable {
        /// App 知道有一段「只录音」正在录
        case recordOnlyRunning
        /// 查设备：录音豆正在录音
        case recorderRecording
    }

    public enum Decision: Equatable, Sendable {
        /// 这次语音输入正在进行：再按一下就是结束它（暂停录音）
        case stopDictation
        /// 先查录音豆的录音状态，再用 `afterCheck` 决定
        case checkRecorder
        case start
        /// 录音豆已经在录（不是这次语音输入开始的）：旁听正在录的那段（只发实时请求 1A/07，不发开始 / 暂停 / 结束）
        case listenIn
        case refuse(Refusal)
    }

    /// 按下快捷键 / 菜单时，不查设备能先决定的部分。
    /// - dictating: 有一次语音输入正在进行（App 或录音豆按键开始的）
    public static func onToggle(dictating: Bool) -> Decision {
        dictating ? .stopDictation : .checkRecorder
    }

    /// 查完设备之后：设备明确说在录，就旁听（不开始新录音，也绝不暂停 / 结束 / 删除那段录音，见 PROTOCOL §11）。
    /// - recordOnlyRunning: App 记着有一段「只录音」在录
    /// - recorderRecording: 设备报告的录音状态；nil = 没读到
    ///
    /// 读不到状态时：App 记着有只录音在录就不开始（旁听要先确认在录：没在录时发实时请求会怎样没测过）；
    /// 否则照常开始（这时开始前状态不明，结束时只暂停、不发结束，见 `mayStopFile`）。
    /// App 记着只录音、设备却明确说没在录：那条记录是旧的（错过了停止事件），可以开始。
    public static func afterCheck(recordOnlyRunning: Bool, recorderRecording: Bool?) -> Decision {
        if recorderRecording == true { return .listenIn }
        if recordOnlyRunning, recorderRecording != false { return .refuse(.recordOnlyRunning) }
        return .start
    }

    /// 结束语音输入时能不能发「结束录音」（18/82 00，会把文件收尾）：只有这次是 App 自己发的暂停、
    /// App 自己发的开始、而且开始前确认录音豆没在录。其余情况只暂停（或什么都不发）。
    public static func mayStopFile(pausedByApp: Bool, startedByApp: Bool, recordingBeforeStart: Bool?) -> Bool {
        pausedByApp && startedByApp && recordingBeforeStart == false
    }
}

// MARK: - 旁听之后断开重连
//
// 旁听（对正在录的文件开实时流）结束后，录音豆会一直外发实时音频（约 50 帧/秒），主机发什么都停不下来，
// 只有断开蓝牙才停（PROTOCOL §11）。所以旁听结束后 App 故意断开、马上重连。真机三次重连 2.9–3.5 秒；
// 直连偶尔失败，退回扫描（见过约 17 秒）。

public enum RelinkPolicy {
    /// 故意断开后等断开回调最多多久（秒）；等不到也接着重连
    public static let disconnectWait: Double = 3
    /// 自己重试几次（每次是一轮「直连，失败就扫描」），之后交给常规的重连循环（一直重试、退避到 30 秒）
    public static let attempts = 3
    /// 新的语音输入等重连最多等多久（秒）：一次直连 8 秒 + 扫描 6 秒，再留一次重试的余量
    public static let waitForLink: Double = 35

    public enum Step: Equatable, Sendable {
        /// 等这么多秒再试一次
        case retry(after: Double)
        /// 不自己试了：交给常规重连循环（界面照常显示「正在搜索」）
        case handOver
    }

    /// 第 `failures` 次（从 1 起）重连失败之后怎么办
    public static func next(afterFailures failures: Int) -> Step {
        guard failures < attempts else { return .handOver }
        return .retry(after: failures == 1 ? 0.5 : 2)
    }

    /// 旁听结束时要不要断开重连：只要这次真的发过实时请求、而且连接还在（已经断了的，录音豆自然停了）
    public static func shouldRelink(requestedStream: Bool, connected: Bool) -> Bool {
        requestedStream && connected
    }
}
