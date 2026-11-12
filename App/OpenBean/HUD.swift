// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// 听写时屏幕下方的悬浮条：不抢焦点，文字打进当前应用。
@MainActor
final class HUDController {
    private let dictation: Dictation
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    init(dictation: Dictation) { self.dictation = dictation }

    func start() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: HUDView(dictation: dictation))
        panel = p
        observe()
    }

    private func observe() {
        withObservationTracking { _ = dictation.phase } onChange: { [weak self] in
            Task { @MainActor in
                self?.phaseChanged()
                self?.observe()
            }
        }
    }

    private func phaseChanged() {
        guard let p = panel else { return }
        switch dictation.phase {
        case .starting, .listening, .finishing:
            hideTask?.cancel()
            if let s = NSScreen.main {
                p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - 320, y: s.visibleFrame.minY + 60))
            }
            p.orderFrontRegardless()
        case .idle:
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if !Task.isCancelled { p.orderOut(nil) }
            }
        }
    }
}

struct HUDView: View {
    let dictation: Dictation
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(dictation.phase == .listening ? Color.red : Color.secondary).frame(width: 8, height: 8)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            (Text(tail(dictation.finalText)) + Text(dictation.volatileText).foregroundStyle(.secondary))
                .font(.system(size: 17))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 640, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var status: String {
        switch dictation.phase {
        case .starting: return "准备中…"
        case .listening: return "正在听"
        case .finishing: return "收尾中…"
        case .idle: return "已完成"
        }
    }

    /// 只显示最后约 120 个字
    private func tail(_ s: String) -> String { s.count > 120 ? "…" + s.suffix(120) : s }
}
