// SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI

/// 听写时屏幕底部的小胶囊：准备中 → 正在听（声波 + 实时文字）→ 整理中 → 完成，然后淡出。
/// 不抢焦点（文字要打进当前应用），但胶囊上的停止按钮可以点。
@MainActor
final class HUDController {
    enum Mode: Equatable {
        case hidden, starting, listening, finishing
        case done(count: Int, clipboard: Bool)
        case error(String)
    }

    @MainActor @Observable
    final class State {
        var mode: Mode = .hidden
        var visible = false
    }

    private let dictation: Dictation
    private let state = State()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private static let size = NSSize(width: 520, height: 72)

    init(dictation: Dictation) { self.dictation = dictation }

    func start() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: HUDView(dictation: dictation, state: state) { [weak self] in
            guard let self else { return }
            Task { await self.dictation.toggle() }
        })
        panel = p
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = dictation.phase
            _ = dictation.lastError
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        let before = state.mode
        switch dictation.phase {
        case .starting: show(.starting)
        case .listening: show(.listening)
        case .finishing: show(.finishing)
        case .idle:
            if let e = dictation.lastError, before != .hidden {
                show(.error(e)); hide(after: 3)
            } else if before == .finishing || before == .listening {
                show(.done(count: dictation.deliveredByClipboard ? dictation.finalText.count : dictation.typedCount,
                           clipboard: dictation.deliveredByClipboard))
                hide(after: 1.6)
            }
        }
    }

    private func show(_ mode: Mode) {
        hideTask?.cancel()
        guard let p = panel else { return }
        if !p.isVisible, let s = NSScreen.main {
            // 底部居中，Dock 上方
            p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - Self.size.width / 2, y: s.visibleFrame.minY + 24))
            p.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            state.mode = mode
            state.visible = true
        }
    }

    #if DEMO || DEBUG
    /// 演示版：直接摆出悬浮条的某个状态（不自动隐藏）；返回悬浮条窗口，截图用
    func demoShow(_ mode: Mode) {
        if mode == .hidden {
            hideTask?.cancel()
            state.visible = false
            state.mode = .hidden
            panel?.orderOut(nil)
        } else {
            show(mode)
        }
    }

    var demoPanel: NSPanel? { panel }
    #endif

    private func hide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { state.visible = false }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            state.mode = .hidden
            panel?.orderOut(nil)
        }
    }
}

// MARK: - 视图

struct HUDView: View {
    let dictation: Dictation
    let state: HUDController.State
    let stop: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            capsule
                .scaleEffect(state.visible ? 1 : 0.92)
                .opacity(state.visible ? 1 : 0)
                .offset(y: state.visible ? 0 : 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            leading.frame(width: state.mode == .listening ? 26 : 34, height: 26)
            middle
            trailing
        }
        .padding(.leading, 14)
        .padding(.trailing, showsStop ? 6 : 16)
        .frame(height: 44)
        // 正在听时固定宽度；其他状态按内容收缩
        .modifier(CapsuleWidth(fixed: state.mode == .listening ? 236 : nil))
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.mode)
    }

    private var showsStop: Bool { state.mode == .listening || state.mode == .starting }

    @ViewBuilder private var leading: some View {
        switch state.mode {
        case .starting:
            BreathingDots()
        case .listening:
            MicPulse(level: dictation.level)
        case .finishing:
            ProgressView().controlSize(.small).tint(.white)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .error:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(.orange)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var middle: some View {
        switch state.mode {
        case .starting:
            label("Getting ready…", secondary: true)
        case .listening:
            // 说话时不显示文字：只用声波表示「正在收音」
            Waveform(level: dictation.level, bars: 15)
                .frame(maxWidth: .infinity)
        case .finishing:
            label(dictation.polishing > 0 ? "Polishing…" : "Wrapping up…", secondary: true)
        case let .done(count, clipboard):
            if count == 0 {
                label("Nothing heard", secondary: true)
            } else if clipboard {
                label("\(count) characters copied to the clipboard", secondary: false)
            } else {
                label("Typed \(count) characters", secondary: false)
            }
        case let .error(e):
            Text(e).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).frame(maxWidth: 360)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if state.mode == .listening, let since = dictation.listeningSince {
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text(clock(ctx.date.timeIntervalSince(since)))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        if showsStop {
            Button(action: stop) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.14))
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.white).frame(width: 10, height: 10)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Stop")
        }
    }

    private func label(_ key: LocalizedStringKey, secondary: Bool) -> some View {
        Text(key).font(.system(size: 14, weight: secondary ? .regular : .medium))
            .foregroundStyle(.white.opacity(secondary ? 0.6 : 0.95))
            .lineLimit(1)
    }

    private func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

private struct CapsuleWidth: ViewModifier {
    let fixed: CGFloat?
    func body(content: Content) -> some View {
        if let fixed {
            content.frame(width: fixed)
        } else {
            content.frame(minWidth: 168, maxWidth: 500).fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// 跟着音量跳的声波：中间高两边低，各自带一点抖动
struct Waveform: View {
    let level: Float
    var bars = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let x = Double(i) / Double(max(bars - 1, 1)) * 2 - 1      // -1…1
                    let weight = 0.35 + 0.65 * (1 - x * x)                       // 中间高
                    let wobble = 0.7 + 0.3 * sin(t * 9 + Double(i) * 1.1)
                    let h = 3 + 19 * CGFloat(level) * CGFloat(weight * wobble)
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 3, height: h)
                }
            }
            .animation(.linear(duration: 0.08), value: level)
        }
    }
}

/// 正在收音：麦克风，外圈随音量扩散
struct MicPulse: View {
    let level: Float
    var body: some View {
        ZStack {
            Circle().fill(Color.red.opacity(0.35))
                .scaleEffect(1 + CGFloat(level) * 0.55)
            Circle().fill(Color.red)
            Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: level)
    }
}

/// 准备中：三个呼吸的点
struct BreathingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.9)))
                }
            }
        }
    }
}
