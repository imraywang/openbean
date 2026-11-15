// SPDX-License-Identifier: Apache-2.0

import BackgroundTasks
import OpenBeanKit
import OpenBeanLibrary
import SwiftUI
import UIKit
import UserNotifications

// MARK: - 后台同步
//
// 手机在口袋里、App 在后台或被挂起：录音豆放回盒子，同步照样开始；传完后转写、切段、写日记，最后发一条通知。
//
// 1. 连接常驻（DeviceController + Link，iOS 分支）：Info.plist 声明 bluetooth-central；CBCentralManager 带状态恢复标识
//    （ConnectPlan.restoreIdentifier），App 被系统结束后，录音豆有事件时系统在后台把 App 拉起来、交还连接；
//    对认识的设备挂一个不超时的 connect，后台扫描只扫录音豆的服务 UUID（见 ConnectPlan）。
// 2. 触发：录音豆放回盒子（01/04 充电事件）→ AutoSync 开始蓝牙下载（和 Mac 同一套）。下载期间蓝牙数据一直在来，
//    App 一直有执行时间；这里另外向系统要一段后台时间，盖住开始前的防抖、读列表和文件之间的停顿。
//    被系统中断（断开、挂起、被结束）：收过的片留在 download.part，下次连上时 AutoSync 再触发，按「片数 × 166」续传。
// 3. 后台下完的录音先不转写（LibraryStore.deferTranscription），转写、切段、写日记放进 BGProcessingTask
//    （不要求接电、不要求联网，理由见 OpenBeanLibrary 的 ProcessingRequest）；App 回到前台时把没做完的补上。
// 4. 通知：一次同步有了结果（共用的 SyncProgress → Notifier）；要用户处理的事（没有语音识别模型、同步接连失败）另发一条。
//    点通知回到心力模式的今天（或该去处理的那一页）。权限在心力模式引导的最后一步请求。
// 什么时候做什么由 OpenBeanLibrary 的 HeartPipeline 决定（有单元测试），这里只负责执行。

@MainActor
final class BackgroundSync {
    nonisolated static let processingID = "dev.openbean.ios.process"

    private weak var model: MobileModel?
    private var pipeline = HeartPipeline(app: .active)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    /// 系统交给我们的后台处理任务（正在跑时）
    private var processingTask: BGProcessingTask?
    private var processing: Task<Void, Never>?
    private var stopRequested = false
    private var lastSyncRunning = false

    // MARK: 接上

    /// 启动时（非演示数据）接上：下载完先不转写的判断、同步开始 / 结束、设备事件
    func attach(_ model: MobileModel) {
        guard self.model == nil else { return }
        self.model = model
        pipeline = HeartPipeline(app: UIApplication.shared.applicationState == .background ? .background : .active,
                                 speechModelReady: model.models.state == .ready)
        model.library.deferTranscription = { UIApplication.shared.applicationState == .background }
        let forward = model.device.onEvent
        model.device.onEvent = { [weak self] e in
            self?.deviceEvent(e)
            forward(e)
        }
        observeSync()
        Log.write("后台同步：已接上（\(pipeline.app == .background ? "后台启动" : "前台启动")，待转写 \(work().untranscribed) 条）")
        // 后台启动时上次可能有没做完的
        if pipeline.app == .background { send(.enteredBackground(work: work())) }
    }

    /// 前后台切换（App 的 scenePhase）
    func phaseChanged(_ phase: ScenePhase, model: MobileModel) {
        guard self.model != nil else { return }
        switch phase {
        case .background:
            Log.write("进入后台")
            send(.enteredBackground(work: work()))
        case .active:
            Log.write("回到前台")
            send(.becameActive(work: work()))
        default:
            break
        }
    }

    /// 录音豆放回盒子：在后台时先要一段时间，盖住自动同步开始前的几秒（防抖、读设备信息和列表）
    private func deviceEvent(_ e: DeviceEvent) {
        guard case let .charging(recorder, _) = e, recorder, UIApplication.shared.applicationState == .background else { return }
        Log.write("后台收到充电事件（录音豆放回盒子），申请后台时间等自动同步开始")
        hold()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, self.pipeline.phase != .syncing else { return }
            self.release()
        }
    }

    /// 同步开始 / 结束（LibraryStore.syncRunning 变化）
    private func observeSync() {
        guard let library = model?.library else { return }
        withObservationTracking { _ = library.syncRunning } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncChanged()
                self.observeSync()
            }
        }
    }

    private func syncChanged() {
        guard let library = model?.library, library.syncRunning != lastSyncRunning else { return }
        lastSyncRunning = library.syncRunning
        if library.syncRunning {
            send(.syncStarted)
        } else {
            var failed = library.lastFailure != nil
            if case .failed = library.sync { failed = true }
            send(.syncEnded(failed: failed, work: work()))
        }
    }

    // MARK: 状态机

    /// 下载了还没转写的录音（转写开着时才算；语音输入片段、本机音频已删的不算），老的先做
    private func pendingIDs() -> [UInt32] {
        guard let m = model, m.settings.autoTranscribe else { return [] }
        let fm = FileManager.default
        return m.library.recordings
            .filter { $0.downloaded && !$0.transcribed && !$0.isDictation && !$0.audioRemoved
                && fm.fileExists(atPath: m.library.audioURL($0.id).path) }
            .sorted { $0.start < $1.start }
            .map(\.id)
    }

    private func work() -> HeartWork {
        guard let m = model else { return .none }
        let ids = Set(pendingIDs())
        let secs = m.library.recordings.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.duration }
        return HeartWork(untranscribed: ids.count, seconds: secs)
    }

    private func send(_ e: HeartPipeline.Event) {
        if let m = model { pipeline.speechModelReady = m.models.state == .ready }
        let before = pipeline.phase
        let actions = pipeline.handle(e)
        if before != pipeline.phase || !actions.isEmpty {
            Log.write("后台流程：\(e) → \(pipeline.phase)，\(actions.isEmpty ? "不用做什么" : actions.map { "\($0)" }.joined(separator: "、"))")
        }
        for a in actions { perform(a) }
    }

    private func perform(_ a: HeartPipeline.Action) {
        switch a {
        case .holdBackgroundTime: hold()
        case .releaseBackgroundTime: release()
        case let .scheduleProcessing(r): schedule(r)
        case .cancelProcessing: BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID)
        case .processNow: startProcessing()
        case .stopProcessing: stopProcessing()
        case let .notify(what): notify(what)
        }
    }

    // MARK: 后台时间（下载期间）

    private func hold() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "OpenBean sync") { [weak self] in
            Log.write("后台时间用完（还剩 \(Int(UIApplication.shared.backgroundTimeRemaining)) 秒）；下载靠蓝牙数据继续，中断了下次连上时续传")
            self?.release()
        }
    }

    private func release() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: 后台处理任务（转写、切段、写日记）

    /// 必须在 App 启动结束前登记（MobileAppDelegate）
    nonisolated static func registerTasks() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in MobileModel.shared.background.launched(task) }
        }
        if !ok { Log.write("后台处理任务登记失败（Info.plist 的 BGTaskSchedulerPermittedIdentifiers？）") }
    }

    private func schedule(_ r: ProcessingRequest) {
        let req = BGProcessingTaskRequest(identifier: Self.processingID)
        req.requiresExternalPower = r.requiresExternalPower
        req.requiresNetworkConnectivity = r.requiresNetwork
        do {
            try BGTaskScheduler.shared.submit(req)
            Log.write("已排后台处理任务（待转写 \(work().untranscribed) 条，要求接电=\(r.requiresExternalPower)，要求联网=\(r.requiresNetwork)）")
        } catch {
            // 模拟器上一直是 unavailable；真机上没开后台 App 刷新时也会失败：回到前台时照样补做
            Log.write("排后台处理任务失败：\(error)；回到前台时再做")
        }
    }

    private func launched(_ task: BGProcessingTask) {
        Log.write("系统开始跑后台处理任务（待转写 \(work().untranscribed) 条）")
        if model == nil {
            // 被系统直接拉起来跑任务：先把 App 的各个部分接上
            MobileModel.shared.start()
        }
        processingTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Log.write("后台处理任务时间到")
                self.send(.processingExpired(work: self.work()))
                self.completeTask(success: false)
            }
        }
        send(.processingLaunched(work: work()))
        if processing == nil { completeTask(success: true) }
    }

    private func completeTask(success: Bool) {
        guard let t = processingTask else { return }
        processingTask = nil
        t.setTaskCompleted(success: success)
    }

    private func startProcessing() {
        guard processing == nil, let m = model else { return }
        stopRequested = false
        processing = Task { [weak self] in
            await self?.process(m)
            guard let self else { return }
            self.processing = nil
            let left = self.work()
            self.completeTask(success: !self.stopRequested && left.isEmpty)
            self.send(.processingFinished(work: left))
        }
    }

    private func stopProcessing() {
        stopRequested = true
        completeTask(success: false)
    }

    /// 一条一条转写（每条转写完会切段、排进写段摘要和日记的队列），最后等日记写完。
    /// 转写本身中途停不下来：叫停时做完手上这一条
    private func process(_ m: MobileModel) async {
        let ids = pendingIDs()
        guard !ids.isEmpty else { return }
        let t0 = Date()
        let inBackground = UIApplication.shared.applicationState == .background
        // 这次进程里没有同步记录的（同步在上一次进程里，App 中途被系统结束了）：共用的同步通知发不出来，这里补一条
        let orphans = ids.filter { !(m.library.progress.run?.involves($0) ?? false) }
        Log.write("开始处理 \(ids.count) 条（\(inBackground ? "后台" : "前台")）")
        var done = 0
        for id in ids {
            if stopRequested { break }
            // 别处（启动时的补转写）可能已经转写了这条
            if m.library.recordings.first(where: { $0.id == id })?.transcribed != true { await m.library.transcribe(id) }
            if m.library.recordings.first(where: { $0.id == id })?.transcribed == true { done += 1 }
        }
        if !stopRequested { await m.library.notes.drain() }
        Log.write(String(format: "处理完 %d / %d 条，用了 %.0f 秒%@", done, ids.count, Date().timeIntervalSince(t0),
                         stopRequested ? "（中途叫停）" : ""))
        let orphanDone = orphans.filter { id in m.library.recordings.first(where: { $0.id == id })?.transcribed == true }.count
        if orphanDone > 0, m.settings.heartMode, UIApplication.shared.applicationState == .background {
            HeartNotices.post(id: "heart-processed-\(Int(Date().timeIntervalSince1970))",
                              title: String(localized: "Today's record is updated"),
                              body: String(localized: "\(orphanDone) recordings synced and transcribed."), route: .today)
        }
    }

    // MARK: 要处理的事

    private func notify(_ what: HeartAttention) {
        let heart = model?.settings.heartMode ?? true
        switch what {
        case .speechModelMissing:
            HeartNotices.post(id: "heart-attention-model", title: String(localized: "Recordings are waiting to be transcribed"),
                              body: String(localized: "Download the speech recognition model in OpenBean's Settings to transcribe them on this iPhone."),
                              route: .settings)
        case .syncKeepsFailing:
            HeartNotices.post(id: "heart-attention-sync",
                              title: heart ? String(localized: "Heart bean sync keeps stopping") : String(localized: "Recorder sync keeps stopping"),
                              body: heart
                                  ? String(localized: "Open OpenBean with the Heart bean nearby to finish syncing. What's already received is kept.")
                                  : String(localized: "Open OpenBean with the recorder nearby to finish syncing. What's already received is kept."),
                              route: .recorder)
        }
    }
}

// MARK: - 本地通知

@MainActor
enum HeartNotices {
    /// 点了通知去哪
    enum Route: String { case today, recorder, settings }

    static func post(id: String, title: String, body: String, route: Route) {
        guard Notifier.enabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                Log.write("没发通知（\(title)）：没有通知权限")
                return
            }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.userInfo = ["route": route.rawValue]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { e in
                if let e { Log.write("发通知失败：\(e)") } else { Log.write("已发通知：\(title)") }
            }
        }
    }
}

// MARK: - 去哪一页

/// 点通知、深链接要切到的页面。RootView 的 TabView 绑在 tab 上；todayRequests 变了心力模式页回到今天
@MainActor @Observable
final class MobileRouter {
    static let shared = MobileRouter()
    var tab: MobileTab = RootView.initialTab
    private(set) var todayRequests = 0
    /// 第一次连上时问要不要全部同步（RootView 弹出）
    var firstSync: FirstSyncOffer?

    func open(_ route: HeartNotices.Route) {
        switch route {
        case .today:
            tab = .heart
            todayRequests += 1
        case .recorder: tab = .recorder
        case .settings: tab = .settings
        }
    }
}

// MARK: - App 代理：后台启动、后台任务登记、点通知

final class MobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundSync.registerTasks()
        MainActor.assumeIsolated {
            if application.applicationState == .background {
                Log.write("App 在后台启动（蓝牙状态恢复或后台处理任务）：\(launchOptions.map { $0.keys.map(\.rawValue).joined(separator: "、") } ?? "无启动参数")")
            }
            // 后台启动时不一定有界面（RootView 的 onAppear 不会来）：这里就把连接、自动同步接上，
            // CBCentralManager 也要在启动结束前用同一个恢复标识建好
            MobileModel.shared.start()
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["route"] as? String
        await MainActor.run {
            // 同步结果的通知（共用的 Notifier 发的，没带 route）也回到今天
            MobileRouter.shared.open(raw.flatMap(HeartNotices.Route.init(rawValue:)) ?? .today)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }
}
