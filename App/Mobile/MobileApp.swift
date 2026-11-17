// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

/// iOS 版的总装：和 Mac 版的 AppModel 一样把共用的存储接起来（App/Shared），只是没有语音输入、HUD、快捷键、MCP、自动更新。
/// 演示数据：启动参数 -demo 或环境变量 OPENBEAN_DEMO=1（见 Flavor），不碰蓝牙、不调用大模型
@MainActor
final class MobileModel {
    static let shared = MobileModel()
    /// 演示数据要在建任何存储之前准备好（属性按声明顺序初始化）
    private let demoPrepared: Void = Flavor.isFake ? DemoData.prepare() : ()
    let settings = Settings()
    let device = DeviceController()
    let models = ModelStore()
    lazy var library = LibraryStore(device: device, settings: settings)
    lazy var autoSync = AutoSync(device: device, library: library, settings: settings)
    /// 词表变了就重新应用到已有的转写（iOS 版还没有编辑词表的界面，词表文件在 App 的 Application Support 里）
    lazy var glossaryBackfill = GlossaryBackfill(library: library)
    let background = BackgroundSync()

    /// 用户点过「连接」之后，每次启动都自动连（第一次启动不连：连就会弹蓝牙权限）
    static let connectKey = "connectAtLaunch"
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Log.write("iOS 版启动 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))\(Flavor.isDemo ? " 演示数据" : "")")
        if Flavor.isDemo {
            models.demoSet(.ready)
            device.demoApply(state: .ready, info: DemoData.info(), activity: .idle)
            demoWifi()
            return
        }
        models.check()
        if UserDefaults.standard.bool(forKey: "selftestSummarize") {
            Task { await ModelSelfTest.run() }
            return
        }
        if let file = UserDefaults.standard.string(forKey: "selftestTranscribe") {
            Task { await selfTestTranscribe(file) }
            return
        }
        device.onEvent = { [weak self] e in
            guard let self else { return }
            // 第一次同步还没问过时，放回充电盒也不自己开始同步
            if case .charging = e, !settings.heartMode, !Flavor.defaults.bool(forKey: Self.firstSyncAskedKey) { return }
            autoSync.handle(e)
        }
        library.onListRefreshed = { [weak self] in self?.listRefreshed() }
        device.onConnected = { [weak self] in Task { await self?.library.refreshDeviceList() } }
        device.link.verbose = Flavor.defaults.bool(forKey: LogView.verboseKey)
        if Flavor.defaults.bool(forKey: Self.connectKey) { device.start() }
        glossaryBackfill.start()
        // 「认出我的声音」：补算还没判定过的录音（开着才做）
        library.speakers.models = models
        library.speakers.start()
        IOSHotspotJoiner.cleanUpLeftovers()
        // 已转写的录音补算对话段；开着心力模式时今天和昨天的日记补一遍（没变就不调用大模型）
        library.conversations.backfill()
        library.notes.diary.catchUp()
        // 后台同步：后台下完的录音交给后台处理任务转写、写日记，结果发通知（BackgroundSync.swift）
        background.attach(self)
        // 语音模型还没下好时，下完的录音先不转写（不然每条都报「缺少模型文件」）；模型到位后把积下的一起转写
        let inBackground = library.deferTranscription
        library.deferTranscription = { [models] in models.state != .ready || inBackground() }
        models.onReady = { [weak self] in Task { await self?.transcribeBacklog() } }
        if Flavor.defaults.bool(forKey: Self.connectKey) { downloadSpeechModelIfNeeded() }
        // 模型已经在了、上次留下没转写的（下载时模型还没到位，或 App 中途被结束）：启动时补上
        if models.state == .ready { Task { [weak self] in await self?.transcribeBacklog() } }
        // 心力模式录音的本机音频保留期：启动时和之后每小时看一遍（同步、转写完也会看）
        Task { [weak self] in
            while !Task.isCancelled {
                self?.library.applyAudioRetention()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// 自检：启动参数 -selftestTranscribe <文件名>（相对 App 的 Documents），没有模型先下载，然后离线转写这个文件，
    /// 结果和耗时写进日志。不连蓝牙，不动录音库。模拟器、真机上验证转写链路用
    private func selfTestTranscribe(_ name: String) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : docs.appendingPathComponent(name)
        Log.write("自检：转写 \(url.lastPathComponent)，模型 \(models.state)")
        if models.state != .ready {
            let t0 = Date()
            await models.download()
            Log.write("自检：模型下载 \(models.state)，用了 \(Int(Date().timeIntervalSince(t0))) 秒")
            guard models.state == .ready else { return }
        }
        let modelsDir = AppPaths.models
        let t0 = Date()
        let result = await Task.detached(priority: .userInitiated) {
            Result { try FileTranscriber.transcribe(url: url, models: modelsDir, glossary: GlossaryCorrector(terms: []), progress: { _ in }) }
        }.value
        let secs = Date().timeIntervalSince(t0)
        switch result {
        case let .success(segs):
            let audio = segs.last?.end ?? 0
            Log.write(String(format: "自检：转写完成 %d 句，音频约 %.1f 秒，用了 %.2f 秒：", segs.count, audio, secs)
                      + segs.map(\.text).joined(separator: " / "))
        case let .failure(e):
            Log.write("自检：转写失败（\(String(format: "%.2f", secs)) 秒）：\(e)")
        }
    }

    /// 截图用：启动参数 -demoSync bluetooth（蓝牙同步要很久，出现「改用 Wi‑Fi」提示）| wifi（Wi‑Fi 下载中）| firstSync（第一次同步的询问，带 Wi‑Fi 选项）
    private func demoWifi() {
        switch UserDefaults.standard.string(forKey: "demoSync") {
        case "bluetooth":
            library.demoSet(sync: .downloading(id: 0, done: 0, total: 4, fraction: 0.18, kbps: 35.6), secondsLeft: 2.6 * 3600)
        case "wifi":
            library.demoSet(sync: .wifi(WifiPlatform.text(.downloading(index: 1, count: 4, percent: 42), heart: settings.mode.callsDeviceHeartBean)))
        case "firstSync":
            MobileRouter.shared.firstSync = FirstSyncOffer(count: 6, audioSeconds: 9.5 * 3600, bluetoothSeconds: 2.6 * 3600, wifiSeconds: 4 * 60)
        default:
            break
        }
    }

    /// 录音豆页的「连接」：开始连接循环（之后每次启动自动连）
    func connect() {
        Flavor.defaults.set(true, forKey: Self.connectKey)
        guard !Flavor.isDemo else { return }
        device.start()
        downloadSpeechModelIfNeeded()
    }

    // MARK: 语音模型和积下的转写

    /// 连上录音豆就要用到语音模型：没有就自己开始下载（遵守「仅 Wi‑Fi 下载」；失败了在设置 → 语音识别里能看到并重试）
    func downloadSpeechModelIfNeeded() {
        guard models.state == .missing else { return }
        Log.write("语音模型还没下载，开始下载\(settings.modelWifiOnly ? "（仅 Wi‑Fi）" : "")")
        Task { [weak self] in
            guard let self else { return }
            await models.download(wifiOnly: settings.modelWifiOnly)
            if models.state != .ready { Log.write("语音模型下载没成功：\(models.state)") }
        }
    }

    /// 模型到位后：把已经下到本机、还没转写的录音一条一条转写（短的先来）
    private func transcribeBacklog() async {
        guard settings.autoTranscribe else { return }
        let fm = FileManager.default
        let ids = library.recordings
            .filter { $0.downloaded && !$0.transcribed && fm.fileExists(atPath: library.audioURL($0.id).path) }
            .sorted { $0.durationMs < $1.durationMs }.map(\.id)
        guard !ids.isEmpty else { return }
        Log.write("语音模型已就绪，补转写 \(ids.count) 条")
        for id in ids where library.recordings.first(where: { $0.id == id })?.transcribed == false {
            await library.transcribe(id)
        }
    }

    // MARK: 第一次同步先问

    /// 第一次读到录音豆上有没下载的录音：先问，不自己开始（可能是几小时的量）。问过之后照常自动同步
    static let firstSyncAskedKey = "firstSyncAsked"

    private func listRefreshed() {
        if !Flavor.defaults.bool(forKey: Self.firstSyncAskedKey), !settings.heartMode {
            let pending = library.pendingDownloads()
            guard !pending.isEmpty else { return }
            if MobileRouter.shared.firstSync == nil {
                let seconds = pending.reduce(0.0) { $0 + Double($1.durationMs) / 1000 }
                let offer = FirstSyncOffer(count: pending.count, audioSeconds: seconds,
                                           bluetoothSeconds: library.pendingSyncSeconds ?? 0, wifiSeconds: library.pendingWifiSeconds ?? 0)
                Log.write("第一次同步：录音豆上有 \(pending.count) 条、\(Int(seconds)) 秒，先问用户"
                          + "（预计蓝牙 \(Int(offer.bluetoothSeconds)) 秒、Wi‑Fi \(Int(offer.wifiSeconds)) 秒\(offer.offersWifi ? "，提供 Wi‑Fi" : "")）")
                MobileRouter.shared.firstSync = offer
            }
            return
        }
        autoSync.listRefreshed()
    }

    /// 用户对「第一次同步」的回答。同步：以后照常自动同步；先不：关掉自动同步（设置里能再打开，录音豆页能手动同步）。
    /// 用 Wi‑Fi：这一批经 Wi‑Fi 下（App 在前台），以后照常经蓝牙自动同步；Wi‑Fi 没下完的由蓝牙接着下
    func answerFirstSync(syncNow: Bool, wifi: Bool = false) {
        Flavor.defaults.set(true, forKey: Self.firstSyncAskedKey)
        MobileRouter.shared.firstSync = nil
        Log.write("第一次同步：用户选了\(wifi ? "用 Wi‑Fi 同步" : syncNow ? "现在同步" : "先不同步，自动同步关掉")")
        guard !Flavor.isDemo else { return }
        if wifi {
            let ids = library.pendingDownloads().map(\.id)
            Task { await library.syncViaWifi(ids: ids) }
        } else if syncNow { autoSync.listRefreshed() } else { settings.autoSync = false }
    }
}

/// 第一次连上时录音豆上积着的录音（问用户要不要全部同步）
struct FirstSyncOffer: Equatable {
    let count: Int
    let audioSeconds: Double
    /// 经蓝牙 / Wi‑Fi 传完大约要多久（LibraryStore.pendingSyncSeconds / pendingWifiSeconds：记住的蓝牙速度、Wi‑Fi 实测速度加固定开销）
    let bluetoothSeconds: Double
    let wifiSeconds: Double
    /// 量大（蓝牙要 10 分钟以上、Wi‑Fi 至少快一倍）时多给一个「用 Wi‑Fi 同步」
    var offersWifi: Bool { WifiAdvice.suggest(bluetoothSeconds: bluetoothSeconds, wifiSeconds: wifiSeconds) }
    var audioText: String { Duration.seconds(audioSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) }
    var bluetoothText: String { DeviceTab.minutes(bluetoothSeconds) }
    var wifiText: String { DeviceTab.minutes(wifiSeconds) }
}

@main
struct OpenBeanMobileApp: App {
    @Environment(\.scenePhase) private var phase
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var delegate
    private let model = MobileModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onAppear { model.start() }
        }
        .onChange(of: phase) { _, p in model.background.phaseChanged(p, model: model) }
    }
}

struct RootView: View {
    let model: MobileModel
    @Bindable private var router = MobileRouter.shared

    /// 截图用：启动参数 -tab heart|recordings|recorder|settings
    static var initialTab: MobileTab {
        UserDefaults.standard.string(forKey: "tab").flatMap(MobileTab.init(rawValue:)) ?? .heart
    }

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Heart mode", systemImage: "heart.text.square", value: MobileTab.heart) {
                HeartTab(model: model)
            }
            Tab("Recordings", systemImage: "waveform", value: MobileTab.recordings) {
                RecordingsTab(library: model.library)
            }
            Tab(DeviceWord.title(heart: model.settings.mode.heartMode), systemImage: "circle.circle", value: MobileTab.recorder) {
                DeviceTab(model: model)
            }
            Tab("Settings", systemImage: "gearshape", value: MobileTab.settings) {
                MobileSettingsTab(model: model)
            }
        }
        .alert("Sync the recordings on your recorder?", isPresented: Binding(get: { router.firstSync != nil }, set: { _ in }),
               presenting: router.firstSync) { offer in
            if offer.offersWifi {
                Button("Sync over Wi‑Fi") { model.answerFirstSync(syncNow: true, wifi: true) }
                Button("Sync over Bluetooth") { model.answerFirstSync(syncNow: true) }
            } else {
                Button("Sync now") { model.answerFirstSync(syncNow: true) }
            }
            Button("Not now", role: .cancel) { model.answerFirstSync(syncNow: false) }
        } message: { offer in
            if offer.offersWifi {
                Text("There are \(offer.count) recordings (\(offer.audioText)) on it. Over Bluetooth this takes about \(offer.bluetoothText) and continues in the background. Over Wi‑Fi it takes about \(offer.wifiText): your iPhone joins the recorder's own Wi‑Fi meanwhile (iOS asks once), and OpenBean needs to stay open. If you choose Not now, automatic sync is turned off; you can turn it on in Settings or sync from the recorder page.")
            } else {
                Text("There are \(offer.count) recordings (\(offer.audioText)) on it. Over Bluetooth this takes about \(offer.bluetoothText) and continues in the background. If you choose Not now, automatic sync is turned off; you can turn it on in Settings or sync from the recorder page.")
            }
        }
    }
}

enum MobileTab: String, Hashable {
    case heart, recordings, recorder, settings
}
