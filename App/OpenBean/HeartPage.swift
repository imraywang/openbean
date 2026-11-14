// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import SwiftUI

// MARK: - 心力模式页（侧栏第一项）
//
// 开着：今天的内容（标题「今天」、日期、前后翻天），右上角齿轮切到心力模式的设置。
// 关着：一个空状态和「设置心力模式…」按钮（打开心力模式介绍，走完才开）；其他页面照普通模式工作。
// 两种模式下打开主窗口都落在这一页。心力模式的开关只在介绍的最后一步和设置里最上面的开关。

struct HeartPage: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let settings = model.settings, nav = model.nav
        Group {
            if !settings.heartMode {
                HeartOffView {
                    openWindow(id: "heart-intro")
                    bringToFront("heart-intro")
                }
                .navigationTitle("Heart mode")
            } else if nav.showsSettings(.heart) {
                HeartSettings(settings: settings, notes: model.library.notes, nav: nav)
                    .navigationTitle("Heart mode")
            } else {
                TodayView(model: model)
            }
        }
        .toolbar {
            if settings.heartMode {
                ToolbarItem(placement: .primaryAction) {
                    ModuleSettingsToggle(nav: nav, section: .heart, help: Text("Heart mode settings"))
                }
            }
        }
        .onChange(of: settings.heartMode) { _, now in
            Log.write(now ? "打开心力模式" : "关闭心力模式")
            if now {
                nav.day = nil
                model.library.notes.diary.catchUp()
            } else {
                nav.showingSettings.remove(.heart)
            }
        }
    }
}

/// 心力模式关着时整页一个空状态；按钮打开心力模式介绍
struct HeartOffView: View {
    let setUp: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Heart mode is off", systemImage: "heart")
        } description: {
            Text("Wear it all day, put it back in its case, and it's sorted into today's record automatically. Recording and voice typing work as usual.")
        } actions: {
            Button("Set up Heart mode…", action: setUp)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

/// 「今天」标题旁的小标识：心力模式开着
struct HeartOnBadge: View {
    var body: some View {
        Label("Heart mode on", systemImage: "heart.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}

/// 模块页工具栏右上角的齿轮：在页面内容和这个模块的设置之间切换（按下去的样子 = 正在看设置）
struct ModuleSettingsToggle: View {
    let nav: Navigator
    let section: MainSection
    let help: Text

    var body: some View {
        Toggle(isOn: Binding(get: { nav.showsSettings(section) },
                             set: { _ in withAnimation(.easeOut(duration: 0.15)) { nav.toggleSettings(section) } })) {
            Label("Settings", systemImage: "gearshape")
        }
        .toggleStyle(.button)
        .help(help)
    }
}

// MARK: - 语音输入页：记录，或语音输入的设置（快捷键、打字、润色、词表）

struct DictationPage: View {
    let model: AppModel

    var body: some View {
        let nav = model.nav
        Group {
            if nav.showsSettings(.dictation) {
                VoiceTypingSettings(settings: model.settings, nav: nav)
            } else {
                DictationHistoryView(log: model.log, settings: model.settings, library: model.library) {
                    nav.open(.voiceTyping(cleanUp: false))
                }
            }
        }
        .navigationTitle("Voice typing")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModuleSettingsToggle(nav: nav, section: .dictation, help: Text("Voice typing settings"))
            }
        }
    }
}

// MARK: - 设备的叫法

/// 心力模式开着时界面上把设备叫「心力豆」（Heart bean），关着叫「录音豆」（recorder）。
/// 中文目录里是两个键：英文原文分别写 Heart bean 和 recorder。带插值的句子在调用处成对写 String(localized:)
enum DeviceWord {
    static func title(heart: Bool) -> LocalizedStringKey { pick(heart, "Heart bean", "Recorder") }
    static func showDetails(heart: Bool) -> LocalizedStringKey { pick(heart, "Show Heart bean details", "Show recorder details") }
    /// 两种叫法里挑一个（参数写字面量，两个都进字符串目录）
    static func pick(_ heart: Bool, _ heartKey: LocalizedStringKey, _ normalKey: LocalizedStringKey) -> LocalizedStringKey {
        heart ? heartKey : normalKey
    }
}

/// 设置页里可以翻到的一组：出现时如果导航指定了它，就滚过去
struct ScrollToSettingsAnchor: ViewModifier {
    let nav: Navigator
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content.onChange(of: nav.settingsAnchor, initial: true) { _, anchor in
            guard let anchor else { return }
            // 等这一页排好版再滚
            DispatchQueue.main.async {
                withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                nav.settingsAnchor = nil
            }
        }
    }
}
