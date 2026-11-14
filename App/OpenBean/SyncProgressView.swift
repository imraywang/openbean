// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import SwiftUI

// MARK: - 心力模式页顶上的四步条：下载 → 转写 → 写日记 → 清理心力豆
//
// 同步进行中：四步各自显示等待 / 进行中（带 2 / 3 这样的数）/ 完成 / 跳过或失败，下面一行说明要紧的事
// （大模型服务连不上所以日记跳过了；从心力豆删了几条、本机音频留多久）。
// 整次有了结果：收起成一行摘要，可以展开看四步，也可以关掉。App 启动后还没同步过就什么都不显示。

struct HeartSyncStrip: View {
    let progress: SyncProgress
    /// 「大模型服务设置…」
    var openLLMSettings: () -> Void = {}

    var body: some View {
        if let run = progress.run, !progress.dismissed {
            VStack(alignment: .leading, spacing: 10) {
                if run.isFinished {
                    collapsedLine(run)
                }
                if !run.isFinished || progress.expanded {
                    steps(run)
                    notes(run)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
            .animation(.easeOut(duration: 0.2), value: progress.expanded)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Sync progress"))
        }
    }

    private func collapsedLine(_ run: SyncRun) -> some View {
        HStack(spacing: 8) {
            Image(systemName: run.steps.contains { $0.state == .failed } ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(run.steps.contains { $0.state == .failed } ? Color.orange : Color.green)
            Text(verbatim: SyncRunText.collapsed(run))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            Button { progress.expanded.toggle() } label: {
                if progress.expanded { Text("Hide details") } else { Text("Details") }
            }
            .buttonStyle(.link).font(.callout)
            Button { progress.dismissed = true } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Hide")
            .accessibilityLabel(Text("Hide"))
        }
    }

    private func steps(_ run: SyncRun) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(run.steps.enumerated()), id: \.offset) { i, p in
                if i > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                }
                StepCell(progress: p)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func notes(_ run: SyncRun) -> some View {
        let diary = run.progress(.diary)
        if diary.note == .llmUnreachable {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("The LLM service isn't reachable, so the diary was skipped. It's written once the service is back.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("LLM service settings…", action: openLLMSettings).buttonStyle(.link).font(.callout)
            }
        }
        if let line = SyncRunText.cleanUpSummary(run) {
            Label { Text(verbatim: line).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

/// 四步里的一步：图标（等待 / 转圈 / 勾 / 跳过 / 失败）、名字、状态说明
private struct StepCell: View {
    let progress: SyncRun.StepProgress

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            icon.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: SyncRunText.title(progress.step)).font(.callout.weight(.medium))
                Text(verbatim: SyncRunText.status(progress))
                    .font(.caption).foregroundStyle(tint)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch progress.state {
        case .failed: return .red
        case .skipped where progress.note == .llmUnreachable: return .orange
        default: return .secondary
        }
    }

    @ViewBuilder private var icon: some View {
        switch progress.state {
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running:
            if progress.note == .deviceBusy || progress.note == .pausedForVoiceTyping {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(progress.note == .llmUnreachable ? Color.orange : Color.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

#if DEMO || DEBUG
// MARK: - 演示版、预览用的几种同步状态（openbean-demo://demo/sync/<名字>，预览「四步条 · …」）

enum DemoSyncRun {
    static let names = ["downloading", "transcribing", "diary", "llm-down", "cleanup-busy", "cleaned", "failed", "finished", "finished-expanded"]

    /// 名字对应的一次同步；nil = 没同步过（四步条不显示）
    static func make(_ name: String) -> SyncRun? {
        let opts = SyncRun.Options()
        var r = SyncRun(ids: [1, 2, 3], options: opts, now: Date().addingTimeInterval(-240))
        func fullyTranscribed() {
            for id: UInt32 in [1, 2, 3] { r.recordDownloaded(id) }
            r.downloadEnded()
            for id: UInt32 in [1, 2, 3] { r.recordTranscribed(id, ok: true) }
        }
        switch name {
        case "downloading":
            r.recordDownloaded(1)
        case "transcribing":
            r.recordDownloaded(1); r.recordDownloaded(2)
            r.recordTranscribed(1, ok: true)
        case "diary":
            fullyTranscribed()
            r.recordDiary(1, .written)
        case "llm-down":
            fullyTranscribed()
            for id: UInt32 in [1, 2, 3] { r.recordDiary(id, .serviceUnavailable) }
            r.recordCleanUp(1, .deleted)
        case "cleanup-busy":
            fullyTranscribed()
            for id: UInt32 in [1, 2, 3] { r.recordDiary(id, .written) }
            r.recordCleanUp(1, .deleted)
            r.recordCleanUp(2, .busy); r.recordCleanUp(3, .busy)
        case "cleaned", "finished", "finished-expanded":
            fullyTranscribed()
            for id: UInt32 in [1, 2, 3] { r.recordDiary(id, .written) }
            r.recordCleanUp(1, .deleted); r.recordCleanUp(2, .deleted); r.recordCleanUp(3, .kept)
            if name != "cleaned" { _ = r.markFinishedIfSettled(now: Date().addingTimeInterval(-60)) }
        case "failed":
            r.recordDownloaded(1)
            r.downloadEnded()
            r.recordTranscribed(1, ok: true)
        default:
            return nil
        }
        return r
    }

    /// 摆到 SyncProgress 上
    @MainActor static func apply(_ name: String, to p: SyncProgress) {
        p.demoSet(make(name), expanded: name == "finished-expanded")
    }
}
#endif
