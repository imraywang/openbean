// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import OpenBeanLibrary
import SwiftUI

// MARK: - 今天的同步：四步（同步 → 转写 → 切段 → 写日记），默认收起成一行，点开看每步
//
// 状态都在共用的 SyncRun 里（Mac 的四步条也读它），手机上的四步怎么从它推出来见 OpenBeanLibrary 的 MobileSyncSteps。
// 这次启动后还没同步过：显示录音豆现在的情况（连着 / 没连上 / 盒子里有几条新录音）。

struct HeartSyncSection: View {
    let model: MobileModel
    /// 录音豆上还没同步的录音
    let onDevice: Int

    private var progress: SyncProgress { model.library.progress }
    private var library: LibraryStore { model.library }
    private var device: DeviceController { model.device }

    var body: some View {
        if let run = progress.run, !progress.dismissed {
            Section {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { progress.expanded.toggle() }
                } label: {
                    collapsed(run)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(progress.expanded ? "Hide details" : "Details"))
                if progress.expanded {
                    ForEach(MobileSyncSteps.rows(run), id: \.step) { row in
                        StepRow(row: row, detail: detail(row, run))
                    }
                    if run.progress(.diary).note == .llmUnreachable {
                        Label("The LLM service isn't reachable, so the diary was skipped. It's written once the service is back.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Sync")
            }
        } else {
            Section {
                deviceLine
            } header: {
                Text("Sync")
            }
        }
    }

    /// 收起时的一行：进行中写到了哪一步，完了写摘要
    private func collapsed(_ run: SyncRun) -> some View {
        let failed = run.steps.contains { $0.state == .failed }
        return HStack(spacing: 10) {
            if run.isFinished {
                Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Color.orange : Color.green)
                Text(verbatim: SyncRunText.collapsed(run)).font(.callout).lineLimit(2)
            } else {
                ProgressView().controlSize(.small)
                if let cur = MobileSyncSteps.current(run) {
                    Text(verbatim: Self.title(cur.step) + " · " + Self.status(cur)).font(.callout)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(progress.expanded ? 180 : 0))
        }
        .contentShape(Rectangle())
    }

    /// 每步下面的细节：同步写正在下哪一条、从心力豆删了几条；转写写正在转的进度
    private func detail(_ row: MobileSyncRow, _ run: SyncRun) -> String? {
        switch row.step {
        case .sync:
            if case let .downloading(_, done, total, f, kbps) = library.sync {
                var s = String(localized: "Downloading \(done + 1) of \(total)") + String(format: " · %d%% · %.1f KB/s", Int(f * 100), kbps)
                if let left = library.syncSecondsLeft { s += " · " + String(localized: "about \(DeviceTab.minutes(left)) left") }
                return s
            }
            if case let .wifi(msg) = library.sync { return msg }
            if run.progress(.cleanUp).note == .deviceBusy { return SyncRunText.status(run.progress(.cleanUp)) }
            return SyncRunText.cleanUpSummary(run)
        case .transcribe:
            if let p = library.transcribing.values.first { return String(localized: "Transcribing \(Int(p * 100))%") }
            // 后台下完的录音等后台处理任务（或 App 回到前台）再转写
            if row.progress.state == .running, !library.syncRunning {
                return String(localized: "Runs in the background when iOS allows it, or when you open OpenBean.")
            }
            return nil
        case .segment:
            return row.progress.state == .done ? String(localized: "Split by pauses, on this iPhone") : nil
        case .diary:
            return nil
        }
    }

    /// 一步的状态说明；切段完成时说「切好了几条」，其余和 Mac 的四步条同一套说法
    static func status(_ row: MobileSyncRow) -> String {
        if row.step == .segment, row.progress.state == .done { return String(localized: "\(row.progress.done) split") }
        return SyncRunText.status(row.progress)
    }

    static func title(_ s: MobileSyncStep) -> String {
        switch s {
        case .sync: return String(localized: "Sync")
        case .transcribe: return String(localized: "Transcribe")
        case .segment: return String(localized: "Split into conversations")
        case .diary: return String(localized: "Write diary")
        }
    }

    // MARK: 没同步过时：录音豆现在的情况

    @ViewBuilder private var deviceLine: some View {
        let heart = model.settings.mode.callsDeviceHeartBean
        let started = Flavor.defaults.bool(forKey: MobileModel.connectKey) || Flavor.isDemo
        if !started {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(DeviceWord.pick(heart, "Connect your Heart bean", "Connect your recorder")).fontWeight(.medium)
                    Text("Take it out of its case. OpenBean finds it over Bluetooth and stays connected in the background.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Connect") { model.connect() }
                }
            } icon: { Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(Color.accentColor) }
        } else if !device.isReady {
            let p = device.problem
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p?.title ?? (heart ? String(localized: "The Heart bean isn't connected") : String(localized: "The recorder isn't connected")))
                        .fontWeight(.medium)
                    Text(p?.advice ?? String(localized: "It connects by itself when it's out of its case and near this iPhone."))
                        .font(.callout).foregroundStyle(.secondary)
                    if onDevice > 0 {
                        Text(heart ? String(localized: "\(onDevice) new recordings are on the Heart bean.")
                             : String(localized: "\(onDevice) new recordings are on the recorder."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } icon: { Image(systemName: p?.symbol ?? "antenna.radiowaves.left.and.right.slash").foregroundStyle(.orange) }
        } else if onDevice > 0 {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(heart ? String(localized: "\(onDevice) new recordings on the Heart bean") : String(localized: "\(onDevice) new recordings on the recorder"))
                        .fontWeight(.medium)
                    Text(heart ? "They sync when the Heart bean goes back in its case." : "They sync when the recorder goes back in its case.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor) }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: device.deviceName + (device.battery.map { " · \($0)%" } ?? "")).fontWeight(.medium)
                    Text(heart ? "Connected. Syncs when the Heart bean goes back in its case." : "Connected. Syncs when the recorder goes back in its case.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }
}

/// 展开后的一步：图标、名字、状态、细节
private struct StepRow: View {
    let row: MobileSyncRow
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: HeartSyncSection.title(row.step)).font(.body.weight(.medium))
                    Spacer()
                    Text(verbatim: HeartSyncSection.status(row))
                        .font(.callout).foregroundStyle(tint).monospacedDigit().multilineTextAlignment(.trailing)
                }
                if let detail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch row.progress.state {
        case .failed: return .red
        case .skipped where row.progress.note == .llmUnreachable: return .orange
        default: return .secondary
        }
    }

    @ViewBuilder private var icon: some View {
        switch row.progress.state {
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running:
            if row.progress.note == .deviceBusy { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(row.progress.note == .llmUnreachable ? Color.orange : Color.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - 日记：概述、要点、定了的事、待办、提到的人

struct DiarySections: View {
    let model: MobileModel
    let day: Date
    let file: DayFile?
    let conversations: [DayItem]
    @Binding var todos: DayTodoState

    private var diaryService: DiaryService { model.library.notes.diary }

    var body: some View {
        if let file, let d = file.diary {
            let byRef = Dictionary(file.conversations.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
            if let o = d.overview, !o.isEmpty {
                Section("Diary") {
                    Text(o).font(.body).lineSpacing(3).textSelection(.enabled)
                }
            }
            if !d.highlights.isEmpty {
                Section("Highlights") {
                    ForEach(Array(d.highlights.enumerated()), id: \.offset) { _, item in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                times(item.refs, byRef)
                            }
                        } icon: { Image(systemName: "lightbulb").foregroundStyle(.secondary) }
                    }
                }
            }
            if !d.decisions.isEmpty {
                Section("Decided") {
                    ForEach(Array(d.decisions.enumerated()), id: \.offset) { _, item in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                times(item.refs, byRef)
                            }
                        } icon: { Image(systemName: "checkmark.seal").foregroundStyle(.secondary) }
                    }
                }
            }
            todoSection(d.todos)
            if !d.people.isEmpty {
                Section("People mentioned") {
                    // 名字照转写写，不合并不同写法；后面是出现在哪几段
                    Text(verbatim: d.people.map { p in
                        let t = p.refs.compactMap { byRef[$0].map(Self.time) }.joined(separator: ", ")
                        return t.isEmpty ? p.name : "\(p.name) (\(t))"
                    }.joined(separator: " · "))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } else if model.settings.mode.writesDiary {
            Section("Diary") {
                if diaryService.working.contains(diaryService.key(day)) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing the diary for this day…").foregroundStyle(.secondary)
                    }
                } else if file?.status == .brief {
                    Text("Too little was said on this day for a diary; the conversations are listed below.")
                        .foregroundStyle(.secondary)
                } else if let p = diaryService.problem(day) {
                    // 没写成：说清楚原因和接下来会怎样，能手动重试
                    Label(Self.problemText(p), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button(p.kind == .unreachable ? "Write the diary for this day" : "Try again now") { diaryService.requestDay(day) }
                } else if !conversations.isEmpty {
                    Text("No diary for this day yet.").foregroundStyle(.secondary)
                    Button("Write the diary for this day") { diaryService.requestDay(day) }
                }
            }
            // 没有日记时，待办来自各段的段摘要（同一条录音切出的几段可能列了同一条，只留一次）
            todoSection(Self.segmentTodos(conversations))
        }
    }

    /// 日记没写成的原因（心力模式页）
    static func problemText(_ p: DiaryService.DayProblem) -> String {
        let why = p.reason == "truncated" ? String(localized: "the model's reply was cut off")
            : p.reason == "refused" ? String(localized: "the model declined to summarise this text")
            : String(localized: "the model's reply couldn't be used")
        switch p.kind {
        case .unreachable:
            return String(localized: "The diary wasn't written: the model service couldn't be reached. It will be tried again after the next sync.")
        case let .retrying(at):
            return String(localized: "The diary wasn't written: \(why). Trying again automatically after \(at.formatted(date: .omitted, time: .shortened)).")
        case .gaveUp:
            return String(localized: "The diary wasn't written: \(why), \(p.failures) times. OpenBean won't try again on its own until this day's recordings change.")
        }
    }

    @ViewBuilder private func todoSection(_ items: [DiaryItem]) -> some View {
        if !items.isEmpty {
            let current = items.map(\.text)
            let done = current.filter(todos.isDone).count
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                    let on = todos.isDone(t.text)
                    Button {
                        todos = todos.setting(t.text, done: !on, current: current)
                        TodoFile.write(todos, diaryService.key(day))
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Color.accentColor : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.text).strikethrough(on).foregroundStyle(on ? .secondary : .primary)
                                if let owner = t.owner, !owner.isEmpty {
                                    Text(verbatim: owner).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            } header: {
                HStack {
                    Text("To-dos")
                    Spacer()
                    Text("\(done) of \(items.count) done").textCase(nil).monospacedDigit()
                }
            }
        }
    }

    static func segmentTodos(_ items: [DayItem]) -> [DiaryItem] {
        var seen = Set<String>()
        return items.flatMap { item in
            (item.conversation.summary?.todos ?? []).filter { seen.insert($0).inserted }.map {
                DiaryItem(text: $0, refs: [ConversationRef(recording: item.key.recording, index: item.key.index)])
            }
        }
    }

    private static func time(_ c: DayConversation) -> String {
        (c.wallApprox ? "~" : "") + c.wallStart.formatted(date: .omitted, time: .shortened)
    }

    /// 出处：是哪几段说的（时刻）
    @ViewBuilder private func times(_ refs: [ConversationRef], _ byRef: [ConversationRef: DayConversation]) -> some View {
        let t = refs.compactMap { byRef[$0].map(Self.time) }
        if !t.isEmpty {
            Text(verbatim: t.joined(separator: ", ")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 待办勾选存在哪

/// 一天的待办勾选状态：Library/days/<日期>/todos.json（和 day.json 放在一起）
enum TodoFile {
    static func url(_ key: String) -> URL {
        DayFile.folder(library: AppPaths.library, date: key).appendingPathComponent(DayTodoState.fileName)
    }

    static func read(_ key: String) -> DayTodoState {
        guard let d = try? Data(contentsOf: url(key)), let s = try? JSONDecoder().decode(DayTodoState.self, from: d) else { return DayTodoState() }
        return s
    }

    static func write(_ s: DayTodoState, _ key: String) {
        let u = url(key)
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(s).write(to: u, options: .atomic)
        } catch {
            Log.write("存待办勾选失败 \(key)：\(error)")
        }
    }
}
