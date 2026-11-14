// SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import OpenBeanLibrary
import UserNotifications

// MARK: - 心力模式一次同步的进度（心力模式页顶上的四步条 + 结束时一条系统通知）
//
// 状态都在 OpenBeanLibrary 的 SyncRun 里推；这里只是把它放进可观察的对象，转发各处报来的事件，
// 并在整次同步有了结果时发一条通知。只记心力模式下的同步（普通模式不写日记、不删设备上的录音）。
//
// 事件从哪来：
// - 下载：LibraryStore.syncAll / syncViaWifi 开始时 begin，每条存成 audio.ogg 时 downloaded，结束时 ended，让给语音输入时 paused
// - 转写：LibraryStore.transcribe 成功或失败
// - 写日记：NoteService.afterTranscription 里 DiaryService.refreshDays 的汇总结果（服务不通单独算）
// - 清理：LibraryStore.cleanUpRecorder 对每条的结论（删了、留着、连接正忙、设备上已经没了）

@MainActor @Observable
final class SyncProgress {
    /// 最近一次（或正在进行的）同步；App 启动后还没同步过是 nil
    private(set) var run: SyncRun?
    /// 结束后用户点开了详情
    var expanded = false
    /// 结束后用户把摘要关掉了
    var dismissed = false
    /// 发通知（App 里是 Notifier.post；预览、测试里换掉）
    @ObservationIgnored var notify: (SyncRun) -> Void = { Notifier.post($0) }

    init(run: SyncRun? = nil) {
        self.run = run
    }

    /// 开始下载一批。上一次还没结束（例如让给语音输入后接着下、改用 Wi‑Fi）就并进去，否则开新的一次
    func begin(_ ids: [UInt32], options: SyncRun.Options) {
        guard !ids.isEmpty else { return }
        if var r = run, !r.isFinished {
            r.downloadStarted(ids)
            run = r
        } else {
            run = SyncRun(ids: ids, options: options)
            expanded = false
            dismissed = false
        }
    }

    func downloaded(_ id: UInt32) { change { $0.recordDownloaded(id) } }
    func downloadPaused() { change { $0.downloadPaused() } }
    func downloadEnded() { change { $0.downloadEnded() } }
    func transcribed(_ id: UInt32, ok: Bool) { change { $0.recordTranscribed(id, ok: ok) } }
    func diary(_ id: UInt32, _ r: SyncRun.DiaryResult) { change { $0.recordDiary(id, r) } }
    func cleanUp(_ id: UInt32, _ r: SyncRun.CleanUpResult) { change { $0.recordCleanUp(id, r) } }

    private func change(_ f: (inout SyncRun) -> Void) {
        guard var r = run else { return }
        f(&r)
        let justFinished = r.markFinishedIfSettled()
        run = r
        if justFinished {
            let steps = r.steps.map { "\($0.step.rawValue)=\($0.state) \($0.done)/\($0.total.map(String.init) ?? "-")" }
            Log.write("心力模式同步有了结果：\(steps.joined(separator: "，"))，从设备删 \(r.deletedFromRecorder) 条，留 \(r.keptOnRecorder) 条")
            if r.broughtSomething { notify(r) }
        }
    }

    #if DEMO || DEBUG
    /// 演示版、预览：直接摆一个状态
    func demoSet(_ r: SyncRun?, expanded: Bool = false) {
        run = r
        self.expanded = expanded
        dismissed = false
    }
    #endif
}

// MARK: - 文案（四步条、通知共用）

enum SyncRunText {
    static func title(_ s: SyncRun.Step) -> String {
        switch s {
        case .download: return String(localized: "Download")
        case .transcribe: return String(localized: "Transcribe")
        case .diary: return String(localized: "Write diary")
        case .cleanUp: return String(localized: "Clean up Heart bean")
        }
    }

    /// 一步的状态说明，例如「2 / 3」「已删 3 条」「跳过：大模型服务连不上」
    static func status(_ p: SyncRun.StepProgress) -> String {
        switch p.state {
        case .waiting:
            return String(localized: "Waiting")
        case .running:
            switch p.note {
            case .pausedForVoiceTyping: return String(localized: "Paused for voice typing")
            case .deviceBusy: return String(localized: "Waiting until the Heart bean is free")
            case .llmUnreachable: return String(localized: "LLM service not reachable")
            default:
                if let t = p.total, t > 0 { return String(localized: "\(p.done) of \(t)") }
                return String(localized: "Working…")
            }
        case .done:
            let main: String
            switch p.step {
            case .download: main = String(localized: "\(p.done) downloaded")
            case .transcribe: main = String(localized: "\(p.done) transcribed")
            case .diary: main = String(localized: "Diary updated")
            case .cleanUp: main = String(localized: "\(p.done) deleted")
            }
            switch p.note {
            case let .failedCount(n): return main + " · " + String(localized: "\(n) failed")
            case let .kept(n): return main + " · " + String(localized: "\(n) kept")
            default: return main
            }
        case .skipped:
            switch p.note {
            case .settingOff: return String(localized: "Off in settings")
            case .llmUnreachable: return String(localized: "Skipped: LLM service not reachable")
            default: return String(localized: "Nothing new")
            }
        case .failed:
            switch p.note {
            case let .left(n): return String(localized: "\(n) left, tries again later")
            case let .failedCount(n): return String(localized: "\(n) failed")
            default: return String(localized: "Failed")
            }
        }
    }

    /// 清理之后的一句：从心力豆删了几条、本机音频留多久
    static func cleanUpSummary(_ r: SyncRun) -> String? {
        guard r.options.deletesFromRecorder, r.progress(.cleanUp).state == .done else { return nil }
        var parts: [String] = []
        let d = r.deletedFromRecorder, k = r.keptOnRecorder
        if d > 0 { parts.append(String(localized: "Deleted \(d) recordings from the Heart bean.")) }
        if k > 0 { parts.append(String(localized: "\(k) stayed on the Heart bean because they couldn't be checked against the copy on this Mac.")) }
        if d > 0 { parts.append(retention(r.options.audioRetention)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func retention(_ r: AudioRetention) -> String {
        switch r {
        case .afterTranscription: return String(localized: "Audio on this Mac is removed once it's transcribed.")
        case .sevenDays: return String(localized: "Audio on this Mac is kept for 7 days.")
        case .forever: return String(localized: "Audio on this Mac is kept.")
        }
    }

    /// 结束后收起成一行：「14:32 同步 · 3 条录音 · 日记已更新 · 从心力豆删了 3 条」
    static func collapsed(_ r: SyncRun) -> String {
        var parts = [String(localized: "Synced at \((r.finishedAt ?? r.startedAt).formatted(date: .omitted, time: .shortened))")]
        let n = r.progress(.download).done
        parts.append(String(localized: "\(n) recordings"))
        let diary = r.progress(.diary)
        switch (diary.state, diary.note) {
        case (.done, _): parts.append(String(localized: "Diary updated"))
        case (.skipped, .llmUnreachable?): parts.append(String(localized: "Diary skipped"))
        case (.failed, _): parts.append(String(localized: "Diary not written"))
        default: break
        }
        if r.deletedFromRecorder > 0 { parts.append(String(localized: "\(r.deletedFromRecorder) deleted from the Heart bean")) }
        return parts.joined(separator: " · ")
    }

    /// 系统通知的正文
    static func notificationBody(_ r: SyncRun) -> String {
        var parts: [String] = []
        let t = r.progress(.transcribe)
        if t.state == .done { parts.append(String(localized: "\(t.done) recordings synced and transcribed.")) }
        else { parts.append(String(localized: "\(r.progress(.download).done) recordings synced.")) }
        let diary = r.progress(.diary)
        switch (diary.state, diary.note) {
        case (.done, _): parts.append(String(localized: "Today's diary is updated."))
        case (.skipped, .llmUnreachable?): parts.append(String(localized: "The LLM service isn't reachable; the diary is written once it's back."))
        case (.failed, _): parts.append(String(localized: "The diary couldn't be written; OpenBean tries again later."))
        default: break
        }
        if let c = cleanUpSummary(r) { parts.append(c) }
        return parts.joined(separator: " ")
    }
}

// MARK: - 系统通知

/// 心力模式同步结束时的一条通知。权限在心力模式介绍的最后一步（打开心力模式时）请求；
/// 没给权限就什么也不发（四步条照样显示），不再追问
@MainActor
enum Notifier {
    /// 正式运行时才发：预览、演示版、单元测试里没有通知中心可用
    static var enabled: Bool {
        #if DEMO || DEBUG
        if Flavor.isFake { return false }
        #endif
        return Bundle.main.bundleIdentifier != nil
    }

    static func requestPermission() {
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.write("通知权限：\(granted ? "允许" : "没允许")\(error.map { "（\($0.localizedDescription)）" } ?? "")")
        }
    }

    static func post(_ r: SyncRun) {
        guard enabled else { return }
        let title = String(localized: "Today's record is updated")
        let body = SyncRunText.notificationBody(r)
        let id = "heart-sync-\(Int(r.startedAt.timeIntervalSince1970))"
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                Log.write("同步结果没发通知：没有通知权限")
                return
            }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            let req = UNNotificationRequest(identifier: id, content: c, trigger: nil)
            UNUserNotificationCenter.current().add(req) { e in if let e { Log.write("发通知失败：\(e)") } }
        }
    }
}

/// 点通知：打开主窗口的心力模式页
final class NotificationOpener: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationOpener()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            let m = AppModel.shared
            m.nav.goHome(m.settings.mode)
            m.openMain?()
        }
    }

    /// App 在前台时也显示横幅（菜单栏 App 常常算在前台）
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }
}
