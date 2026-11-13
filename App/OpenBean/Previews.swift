// SPDX-License-Identifier: Apache-2.0

// Xcode 预览（只在 Debug 构建里；Release 和 bin/release 编不进来）。
// 数据和演示版是同一套（Demo.swift 的 DemoData）：预览进程里 Flavor.isPreview 为真，
// 数据目录换成 ~/Library/Application Support/openbean-preview，设置写在 dev.openbean.preview 域，
// 不建蓝牙连接、不加载语音模型、不读钥匙串、不注册快捷键（App 的启动流程在预览里直接跳过）。
// 每个预览各建一份 AppModel，互不影响。深色：本文件里成对的「· 深色」预览，或画布的 Color Scheme Variants。
// 菜单栏菜单、悬浮条所在的面板、整窗工具栏的真实样子还是要用 bin/ui-shots 截图。
#if DEBUG
import SwiftUI

@MainActor
enum PreviewFixtures {
    /// 一份摆好状态的 AppModel。state 同 openbean-demo://demo/state/<名字>；select 同 demo/select/<名字>
    static func model(_ state: String = "connected", section: MainSection = .overview, tab: SettingsTab = .voice,
                      select: String? = nil, models: ModelStore.State = .ready, trusted: Bool = true) -> AppModel {
        // 不在 Xcode 预览里（例如单元测试里误用）就停下，免得读到真实数据目录
        precondition(Flavor.isFake, "PreviewFixtures 只能在 Xcode 预览里用")
        DemoState.trustedValue = trusted
        let m = AppModel()
        m.models.demoSet(models)
        DemoController.apply(state: state, to: m)
        m.nav.section = section
        m.nav.settingsTab = tab
        m.library.selection = select.flatMap { DemoController.pick($0, in: m.library) }
        return m
    }

    /// 选中的那条录音（详情预览用）
    static func recording(_ what: String, in m: AppModel) -> Recording {
        let id = DemoController.pick(what, in: m.library)
        return m.library.recordings.first { $0.id == id } ?? m.library.recordings[0]
    }
}

/// 主窗口大小、浅色或深色
private struct PreviewFrame<Content: View>: View {
    var dark = false
    var width: CGFloat = 1180
    var height: CGFloat = 760
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(width: width, height: height).preferredColorScheme(dark ? .dark : .light)
    }
}

// MARK: - 主窗口（侧栏 + 页面）

#Preview("主窗口 · 概览") { PreviewFrame { MainView(model: PreviewFixtures.model()) } }
#Preview("主窗口 · 概览 · 深色") { PreviewFrame(dark: true) { MainView(model: PreviewFixtures.model()) } }
#Preview("主窗口 · 概览 · 最小尺寸") { PreviewFrame(width: 960, height: 600) { MainView(model: PreviewFixtures.model()) } }
#Preview("主窗口 · 概览 · 正在同步") { PreviewFrame { MainView(model: PreviewFixtures.model("syncing")) } }
#Preview("主窗口 · 概览 · 没连上") { PreviewFrame { MainView(model: PreviewFixtures.model("searching")) } }
#Preview("主窗口 · 录音库 · 有摘要") {
    PreviewFrame { MainView(model: PreviewFixtures.model(section: .library, select: "summary")) }
}
#Preview("主窗口 · 录音库 · 有摘要 · 深色") {
    PreviewFrame(dark: true) { MainView(model: PreviewFixtures.model(section: .library, select: "summary")) }
}
#Preview("主窗口 · 录音库 · 没转写") {
    PreviewFrame { MainView(model: PreviewFixtures.model(section: .library, select: "untranscribed")) }
}
#Preview("主窗口 · 录音库 · 在录音豆上") {
    PreviewFrame { MainView(model: PreviewFixtures.model(section: .library, select: "ondevice")) }
}
#Preview("主窗口 · 录音库 · 正在同步") {
    PreviewFrame { MainView(model: PreviewFixtures.model("syncing", section: .library, select: "summary")) }
}
#Preview("主窗口 · 录音库 · 正在同步 · 深色") {
    PreviewFrame(dark: true) { MainView(model: PreviewFixtures.model("syncing", section: .library, select: "summary")) }
}
#Preview("主窗口 · 录音豆 · 同步失败") { PreviewFrame { MainView(model: PreviewFixtures.model("sync-failed", section: .recorder)) } }
#Preview("主窗口 · 录音豆 · 没连上") { PreviewFrame { MainView(model: PreviewFixtures.model("searching", section: .recorder)) } }
#Preview("主窗口 · 语音输入记录") { PreviewFrame { MainView(model: PreviewFixtures.model(section: .dictation)) } }

// MARK: - 单独的页面和部件（不带侧栏，改单个视图时更快）

#Preview("概览") { PreviewFrame(width: 960) { NavigationStack { OverviewView(model: PreviewFixtures.model()) } } }
#Preview("概览 · 深色") {
    PreviewFrame(dark: true, width: 960) { NavigationStack { OverviewView(model: PreviewFixtures.model()) } }
}

#Preview("录音列表") {
    @Previewable @State var query = ""
    let m = PreviewFixtures.model(select: "summary")
    RecordingList(library: m.library, nav: m.nav,
                  selection: Binding(get: { m.library.selection }, set: { m.library.selection = $0 }), query: $query)
        .frame(width: 300, height: 700)
}

#Preview("录音详情 · 有摘要") {
    let m = PreviewFixtures.model()
    PreviewFrame(width: 860) { RecordingDetail(recording: PreviewFixtures.recording("summary", in: m), library: m.library, device: m.device) }
}
#Preview("录音详情 · 有摘要 · 深色") {
    let m = PreviewFixtures.model()
    PreviewFrame(dark: true, width: 860) {
        RecordingDetail(recording: PreviewFixtures.recording("summary", in: m), library: m.library, device: m.device)
    }
}
#Preview("录音详情 · 没转写") {
    let m = PreviewFixtures.model()
    PreviewFrame(width: 860, height: 500) {
        RecordingDetail(recording: PreviewFixtures.recording("untranscribed", in: m), library: m.library, device: m.device)
    }
}
#Preview("录音详情 · 在录音豆上") {
    let m = PreviewFixtures.model()
    PreviewFrame(width: 860, height: 400) {
        RecordingDetail(recording: PreviewFixtures.recording("ondevice", in: m), library: m.library, device: m.device)
    }
}

// MARK: - 录音豆页的各种状态

@MainActor private func device(_ state: String, dark: Bool = false) -> some View {
    let m = PreviewFixtures.model(state)
    return PreviewFrame(dark: dark, width: 760, height: 700) { DeviceView(device: m.device, dictation: m.dictation, library: m.library) }
}

#Preview("录音豆 · 已连接") { device("connected") }
#Preview("录音豆 · 已连接 · 深色") { device("connected", dark: true) }
#Preview("录音豆 · 正在同步") { device("syncing") }
#Preview("录音豆 · 正在语音输入") { device("dictating") }
#Preview("录音豆 · 正在录音") { device("recording") }
#Preview("录音豆 · 低电量") { device("low-battery") }
#Preview("录音豆 · 充电") { device("charging") }
#Preview("录音豆 · 搜索中") { device("searching") }
#Preview("录音豆 · 连接失败") { device("failed") }
#Preview("录音豆 · 蓝牙关闭") { device("bluetooth-off") }
#Preview("录音豆 · 没有蓝牙权限") { device("no-permission") }
#Preview("录音豆 · 连接断了") { device("lost") }

// MARK: - 设置

// 设置窗口的内容（预览里没有窗口的工具栏，分页标签画在内容上方；真实窗口的样子见 bin/ui-shots 的 25–29）
@MainActor private func settings(_ tab: SettingsTab, dark: Bool = false) -> some View {
    SettingsWindow(model: PreviewFixtures.model(tab: tab)).preferredColorScheme(dark ? .dark : .light)
}

#Preview("设置 · 语音输入") { settings(.voice) }
#Preview("设置 · 语音输入 · 深色") { settings(.voice, dark: true) }
#Preview("设置 · 润色") { settings(.polish) }
#Preview("设置 · 润色 · 深色") { settings(.polish, dark: true) }
#Preview("设置 · 录音库") { settings(.library) }
#Preview("设置 · 录音库 · 深色") { settings(.library, dark: true) }
#Preview("设置 · Agent") { settings(.agent) }
#Preview("设置 · Agent · 深色") { settings(.agent, dark: true) }
#Preview("设置 · 关于") { settings(.about) }
#Preview("设置 · 关于 · 深色") { settings(.about, dark: true) }

// MARK: - 首次使用向导（第一次用：没找到录音豆、没下载模型、没有辅助功能权限）

@MainActor private func onboarding(_ step: Int, dark: Bool = false) -> some View {
    OnboardingView(model: PreviewFixtures.model("searching", models: .missing, trusted: false), step: step)
        .preferredColorScheme(dark ? .dark : .light)
}

#Preview("向导 1 · 欢迎") { onboarding(0) }
#Preview("向导 1 · 欢迎 · 深色") { onboarding(0, dark: true) }
#Preview("向导 2 · 连接录音豆") { onboarding(1) }
#Preview("向导 3 · 下载模型") { onboarding(2) }
#Preview("向导 4 · 辅助功能") { onboarding(3) }
#Preview("向导 5 · 试一试") { onboarding(4) }

// MARK: - 语音输入悬浮条（固定深色；放在灰底上看）

private struct HUDStates: View {
    struct Item: Identifiable { let id: String; let dictation: Dictation; let state: HUDController.State }
    let items: [Item]

    init() {
        let m = PreviewFixtures.model()
        let modes: [(String, HUDController.Mode, Int)] = [
            ("准备中", .starting, 0), ("收音中", .listening, 0), ("润色中", .finishing, 2), ("整理中", .finishing, 0),
            ("已打字", .done(count: 86, clipboard: false), 0), ("已拷贝", .done(count: 86, clipboard: true), 0),
            ("没听到", .done(count: 0, clipboard: false), 0),
            ("出错", .error(String(localized: "The recorder is recording. Stop it first.")), 0),
        ]
        items = modes.map { name, mode, polishing in
            let d = Dictation(device: m.device, settings: m.settings)
            d.demoSet(phase: .idle, level: 0.6, since: Date().addingTimeInterval(-23), polishing: polishing)
            let s = HUDController.State()
            s.mode = mode
            s.visible = true
            return Item(id: name, dictation: d, state: s)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack {
                    Text(verbatim: item.id).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    HUDView(dictation: item.dictation, state: item.state) {}.frame(width: 520, height: 72)
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.35))
    }
}

#Preview("语音输入悬浮条 · 各状态") { HUDStates() }

// MARK: - 菜单栏图标（各状态；点开的菜单预览不了，见文件开头）

#Preview("菜单栏图标 · 各状态") {
    let states = ["connected", "syncing", "dictating", "searching"]
    HStack(spacing: 24) {
        ForEach(states, id: \.self) { s in
            let m = PreviewFixtures.model(s)
            VStack(spacing: 6) {
                MenuIcon(device: m.device, dictation: m.dictation)
                Text(verbatim: s).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    .padding(16)
}
#endif
