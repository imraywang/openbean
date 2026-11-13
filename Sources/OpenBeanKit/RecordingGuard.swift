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
        case refuse(Refusal)
    }

    /// 按下快捷键 / 菜单时，不查设备能先决定的部分。
    /// - dictating: 有一次语音输入正在进行（App 或录音豆按键开始的）
    public static func onToggle(dictating: Bool) -> Decision {
        dictating ? .stopDictation : .checkRecorder
    }

    /// 查完设备之后：在录就不开始。
    /// - recordOnlyRunning: App 记着有一段「只录音」在录
    /// - recorderRecording: 设备报告的录音状态；nil = 没读到
    ///
    /// 读不到状态时：App 记着有只录音在录就不开始；否则照常开始（这时开始前状态不明，结束时只暂停、不发结束，
    /// 见 `mayStopFile`）。App 记着只录音、设备却明确说没在录：那条记录是旧的（错过了停止事件），可以开始。
    public static func afterCheck(recordOnlyRunning: Bool, recorderRecording: Bool?) -> Decision {
        if recorderRecording == true { return .refuse(recordOnlyRunning ? .recordOnlyRunning : .recorderRecording) }
        if recordOnlyRunning, recorderRecording != false { return .refuse(.recordOnlyRunning) }
        return .start
    }

    /// 结束语音输入时能不能发「结束录音」（18/82 00，会把文件收尾）：只有这次是 App 自己发的暂停、
    /// App 自己发的开始、而且开始前确认录音豆没在录。其余情况只暂停（或什么都不发）。
    public static func mayStopFile(pausedByApp: Bool, startedByApp: Bool, recordingBeforeStart: Bool?) -> Bool {
        pausedByApp && startedByApp && recordingBeforeStart == false
    }
}
