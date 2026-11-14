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
            return
        }
        models.check()
        if let file = UserDefaults.standard.string(forKey: "selftestTranscribe") {
            Task { await selfTestTranscribe(file) }
            return
        }
        device.onEvent = { [weak self] e in self?.autoSync.handle(e) }
        library.onListRefreshed = { [weak self] in self?.autoSync.listRefreshed() }
        device.onConnected = { [weak self] in Task { await self?.library.refreshDeviceList() } }
        device.link.verbose = Flavor.defaults.bool(forKey: LogView.verboseKey)
        if Flavor.defaults.bool(forKey: Self.connectKey) { device.start() }
        glossaryBackfill.start()
        // 已转写的录音补算对话段；开着心力模式时今天和昨天的日记补一遍（没变就不调用大模型）
        library.conversations.backfill()
        library.notes.diary.catchUp()
        // 后台同步：后台下完的录音交给后台处理任务转写、写日记，结果发通知（BackgroundSync.swift）
        background.attach(self)
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

    /// 录音豆页的「连接」：开始连接循环（之后每次启动自动连）
    func connect() {
        Flavor.defaults.set(true, forKey: Self.connectKey)
        guard !Flavor.isDemo else { return }
        device.start()
    }
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
    }
}

enum MobileTab: String, Hashable {
    case heart, recordings, recorder, settings
}
