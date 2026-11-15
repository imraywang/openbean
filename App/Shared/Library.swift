// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation
import Observation
import SwiftUI
import OpenBeanKit
import OpenBeanLibrary
import OpenBeanVoice
import UniformTypeIdentifiers

struct Recording: Codable, Identifiable, Hashable {
    var id: UInt32
    var start: Date
    var end: Date?
    var durationMs: UInt32
    var title: String?
    var onDevice: Bool
    var downloaded = false
    var transcribed = false
    /// 由语音输入产生的片段
    var isDictation = false
    /// 在哪种模式下同步进来的（index.json 的 source；旧录音没有 = 普通）
    var source: RecordingSource?
    /// 同步（下载完成）的时刻：心力模式的音频保留期从这里算；旧录音没有，按开始时间算
    var syncedAt: Date?
    /// 本机音频按心力模式的保留设置删掉的时刻（转写、摘要还在）
    var audioDeletedAt: Date?

    var recordingSource: RecordingSource { source ?? .normal }
    var audioRemoved: Bool { audioDeletedAt != nil }

    var duration: TimeInterval { Double(durationMs) / 1000 }
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return start.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 转写的一句（transcript.json 的一项），定义在 OpenBeanVoice（带可选的 raw，见 TranscriptCorrection）
typealias TranscriptSegment = OpenBeanVoice.TranscriptSegment

/// 录音库：本机索引 + 从录音豆同步 + 离线转写 + 导出
@MainActor @Observable
final class LibraryStore {
    enum SyncState: Equatable {
        case idle
        case listing
        case downloading(id: UInt32, done: Int, total: Int, fraction: Double, kbps: Double)
        case wifi(String)
        case paused
        case failed(String)
    }

    private(set) var recordings: [Recording] = []
    private(set) var sync: SyncState = .idle
    /// 蓝牙同步估计还要多少秒（只在下载中有值）
    private(set) var syncSecondsLeft: Double?
    /// 记住的蓝牙下载速度（字节/秒）：只用 1 MB 以上的下载来学（SyncEstimate.shouldLearn），估算同步时长用。
    /// 换了个键：旧键 bluetoothBytesPerSecond 混进了短文件的速度（握手和请求开销占大头），偏低一倍
    private var bluetoothRate: Double {
        get { let v = UserDefaults.standard.double(forKey: "bluetoothBytesPerSecondLarge"); return v > 0 ? v : SyncEstimate.defaultBytesPerSecond }
        set { UserDefaults.standard.set(newValue, forKey: "bluetoothBytesPerSecondLarge") }
    }
    /// 把一条录音经蓝牙下完大约要多少秒（和 pendingSyncSeconds 同一套算法：每个文件的固定开销 + 字节 ÷ 速度）
    func downloadSeconds(_ r: Recording) -> Double { estimate(durationMs: r.durationMs, rate: bluetoothRate) }

    /// 把还没下载的录音都经蓝牙下完大约要多少秒；没有要下的返回 nil
    var pendingSyncSeconds: Double? {
        let p = pendingDownloads()
        return p.isEmpty ? nil : p.reduce(0.0) { $0 + estimate(durationMs: $1.durationMs, rate: bluetoothRate) }
    }
    private(set) var transcribing: [UInt32: Double] = [:]
    private var transcripts: [UInt32: [TranscriptSegment]] = [:]
    @ObservationIgnored private var markCache: [UInt32: [Double]] = [:]
    /// 录音库的筛选（侧栏「录音」下面的二级项）：全部，和三种「要处理的」
    enum Filter: String, CaseIterable, Identifiable {
        case all, onRecorder, untranscribed, todos
        var id: String { rawValue }
        /// 侧栏里的二级项（不含「全部」：点「录音」本身就是全部）
        static let actionable: [Filter] = [.onRecorder, .untranscribed, .todos]
        /// heart：心力模式开着时把设备叫「心力豆」
        func label(heart: Bool) -> LocalizedStringKey {
            switch self {
            case .all: return "Recordings"
            case .onRecorder: return DeviceWord.pick(heart, "On Heart bean", "On recorder")
            case .untranscribed: return "Not transcribed"
            case .todos: return "Has to-dos"
            }
        }
        var icon: String {
            switch self {
            case .all: return "waveform"
            case .onRecorder: return "arrow.down.circle"
            case .untranscribed: return "text.bubble"
            case .todos: return "checklist"
            }
        }
    }

    var filter: Filter = .all
    /// 主窗口里选中的录音（openbean://open/<id> 也会改它）
    var selection: UInt32?
    private var peaksCache: [UInt32: [Float]] = [:]

    private let device: DeviceController
    let settings: Settings
    /// 摘要和知识库笔记
    let notes: NoteService
    /// 按停顿切的对话段（segments.json）
    let conversations = ConversationStore()
    /// 心力模式下一次同步的进度（心力模式页顶上的四步条、结束时的通知）
    let progress = SyncProgress()
    /// 这次同步按开始时的设置算：转写、写日记、从设备删除、本机音频保留
    private var runOptions: SyncRun.Options {
        let m = settings.mode
        return SyncRun.Options(autoTranscribe: settings.autoTranscribe, writesDiary: m.writesDiary,
                               deletesFromRecorder: m.deletesFromRecorderAfterSync, audioRetention: m.audioRetention)
    }
    private let work = DispatchQueue(label: "openbean.library", qos: .userInitiated)
    private var resumeAfterDictation = false
    /// syncAll 正在跑（防止手动和自动同步叠在一起）
    private(set) var syncRunning = false
    /// 每次成功读到设备上的文件列表后调用（自动同步用）
    @ObservationIgnored var onListRefreshed: () -> Void = {}
    /// 下完一条要不要先不转写（iOS：App 在后台时交给后台处理任务）。Mac 不设，总是马上转写
    @ObservationIgnored var deferTranscription: () -> Bool = { false }

    private var indexURL: URL { AppPaths.library.appendingPathComponent("index.json") }
    func folder(_ id: UInt32) -> URL {
        let u = AppPaths.library.appendingPathComponent(String(id))
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func audioURL(_ id: UInt32) -> URL { folder(id).appendingPathComponent("audio.ogg") }
    func transcriptURL(_ id: UInt32) -> URL { folder(id).appendingPathComponent("transcript.json") }
    func marksURL(_ id: UInt32) -> URL { folder(id).appendingPathComponent(RecordingMarks.fileName) }

    /// 重点标记（秒，相对录音开头）：下载时从音频分片的 flags 取出来的（marks.json）；没有就是空
    func marks(_ id: UInt32) -> [Double] {
        if let m = markCache[id] { return m }
        let m = RecordingMarks.read(marksURL(id))?.marks ?? []
        markCache[id] = m
        return m
    }

    init(device: DeviceController, settings: Settings) {
        self.device = device
        self.settings = settings
        notes = NoteService(settings: settings)
        load()
        notes.library = self
        conversations.library = self
        notes.onDiaryResult = { [weak self] id, r in self?.progress.diary(id, r) }
        #if os(iOS)
        loadSynced()
        #endif
    }

    var visible: [Recording] { recordings.filter { includes($0, in: filter) } }

    /// 按设置里的「一天从几点开始」分天（「今天」页、录音列表、语音输入记录共用）
    var dayBoundary: DayBoundary { DayBoundary(startHour: settings.dayStartHour) }

    /// 某个筛选下有几条（侧栏的数字）
    func count(_ f: Filter) -> Int { recordings.reduce(0) { $0 + (includes($1, in: f) ? 1 : 0) } }

    /// 语音输入片段不进录音库；「有待办」= 还有没勾掉的待办，只看已经在缓存里的摘要（NoteService.preload 在后台读盘）
    func includes(_ r: Recording, in f: Filter) -> Bool {
        guard !r.isDictation else { return false }
        switch f {
        case .all: return true
        case .onRecorder: return !r.downloaded
        case .untranscribed: return r.downloaded && !r.transcribed
        case .todos: return !notes.openTodos(r.id).isEmpty
        }
    }

    /// 转写的第一句，列表里当摘要
    func snippet(_ id: UInt32) -> String? {
        guard recordings.first(where: { $0.id == id })?.transcribed == true else { return nil }
        return transcript(id).first?.text
    }

    /// 波形：每条录音约 600 个峰值（0…1），算一次缓存成 peaks.json
    func peaks(_ id: UInt32) -> [Float]? { peaksCache[id] }

    func loadPeaks(_ id: UInt32) async {
        #if DEMO || DEBUG || os(iOS)
        // 演示版、预览没有音频文件，只有造好的 peaks.json
        if Flavor.isFake {
            if peaksCache[id] == nil, let d = try? Data(contentsOf: folder(id).appendingPathComponent("peaks.json")),
               let p = try? JSONDecoder().decode([Float].self, from: d) { peaksCache[id] = p }
            return
        }
        #endif
        guard peaksCache[id] == nil, FileManager.default.fileExists(atPath: audioURL(id).path) else { return }
        let cache = folder(id).appendingPathComponent("peaks.json")
        if let d = try? Data(contentsOf: cache), let p = try? JSONDecoder().decode([Float].self, from: d) {
            peaksCache[id] = p; return
        }
        let url = audioURL(id)
        let p: [Float] = await withCheckedContinuation { c in
            work.async { c.resume(returning: (try? Self.computePeaks(url)) ?? []) }
        }
        peaksCache[id] = p
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: cache) }
    }

    nonisolated private static func computePeaks(_ url: URL, count: Int = 600) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let total = Int(f.length)
        guard total > 0 else { return [] }
        let per = max(total / count, 1)
        var out: [Float] = []
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(per))!
        while out.count < count {
            try f.read(into: buf, frameCount: AVAudioFrameCount(per))
            if buf.frameLength == 0 { break }
            let ch = buf.floatChannelData![0]
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            out.append(sqrt(sum / Float(buf.frameLength)))
        }
        // 归一化：以 98 分位为满幅，避免一两下爆音把整体压扁
        let ref = out.sorted()[min(out.count - 1, Int(Double(out.count) * 0.98))]
        return out.map { min($0 / max(ref, 1e-4), 1) }
    }

    #if DEMO || DEBUG || os(iOS)
    /// 演示版、预览：直接摆出同步和转写进度
    /// 预览：假装每条下载了的录音都转写过（「未转写」筛选为空）
    func demoTranscribeAll() {
        for i in recordings.indices where recordings[i].downloaded { recordings[i].transcribed = true }
    }

    func demoSet(sync: SyncState, secondsLeft: Double? = nil, transcribing: [UInt32: Double] = [:]) {
        self.sync = sync
        syncSecondsLeft = secondsLeft
        self.transcribing = transcribing
    }
    #endif

    // MARK: 索引

    private func load() {
        guard let d = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Recording].self, from: d) else { return }
        recordings = list.sorted { $0.start > $1.start }
    }

    private func save() {
        let list = recordings
        let url = indexURL
        work.async { try? JSONEncoder().encode(list).write(to: url, options: .atomic) }
    }

    private func update(_ id: UInt32, _ change: (inout Recording) -> Void) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[i])
        save()
    }

    func rename(_ id: UInt32, to title: String) { update(id) { $0.title = title } }

    /// 听写开始时登记，让录音库把它归为听写片段
    func markDictation(_ id: UInt32) {
        if recordings.contains(where: { $0.id == id }) {
            update(id) { $0.isDictation = true }
        } else {
            recordings.insert(Recording(id: id, start: Date(timeIntervalSince1970: TimeInterval(id)), end: nil,
                                        durationMs: 0, title: nil, onDevice: true, isDictation: true), at: 0)
            save()
        }
    }

    func transcript(_ id: UInt32) -> [TranscriptSegment] {
        if let t = transcripts[id] { return t }
        guard let d = try? Data(contentsOf: transcriptURL(id)),
              let t = try? JSONDecoder().decode([TranscriptSegment].self, from: d) else { return [] }
        transcripts[id] = t
        return t
    }

    func matches(_ r: Recording, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if r.displayTitle.localizedCaseInsensitiveContains(q) { return true }
        return r.transcribed && transcript(r.id).contains { $0.text.localizedCaseInsensitiveContains(q) }
    }

    /// 转写文件被词表回填改过：丢掉缓存（列表摘要、搜索、导出、详情都会读新文字），笔记按规则刷新
    func transcriptRewritten(_ id: UInt32) {
        transcripts[id] = nil
        conversations.refresh(id)
        notes.transcriptChanged(id)
    }

    /// 删除本机副本（不动设备上的录音）
    func deleteLocal(_ id: UInt32) {
        try? FileManager.default.removeItem(at: folder(id))
        transcripts[id] = nil
        markCache[id] = nil
        conversations.forget(id)
        notes.forget(id)
        if let i = recordings.firstIndex(where: { $0.id == id }) {
            if recordings[i].onDevice {
                recordings[i].downloaded = false
                recordings[i].transcribed = false
            } else {
                recordings.remove(at: i)
            }
        }
        save()
    }

    // MARK: 同步

    /// `quiet`：顺手看一眼（打开主窗口时）。工具栏不闪「正在检查…」，一分钟内看过就不再看，出错也不报
    func refreshDeviceList(quiet: Bool = false) async {
        guard device.isReady, device.activity == .idle, let s = device.session else { return }
        if quiet {
            guard sync == .idle, !quietListing, Date().timeIntervalSince(lastListed) > 60 else { return }
            quietListing = true
            defer { quietListing = false }
            guard let files = try? await s.listFiles() else { return }
            lastListed = Date()
            if let newest = files.first?.id { device.newestFileId = max(device.newestFileId ?? 0, newest) }
            merge(files)
            onListRefreshed()
            return
        }
        sync = .listing
        do {
            let files = try await s.listFiles()
            lastListed = Date()
            if let newest = files.first?.id { device.newestFileId = max(device.newestFileId ?? 0, newest) }
            merge(files)
            sync = .idle
            onListRefreshed()
        } catch {
            sync = .failed("\(error)")
        }
    }
    @ObservationIgnored private var lastListed = Date.distantPast
    @ObservationIgnored private var quietListing = false

    private func merge(_ files: [RecordingFile]) {
        // 续航统计：离线录的音只能事后从列表里知道（新出现或变长的文件各写一行，见 DeviceFileLog）
        let known = Dictionary(recordings.map { ($0.id, $0.durationMs) }, uniquingKeysWith: { a, _ in a })
        DeviceFileLog.lines(known: known, files: files, recorder: device.battery).forEach(Log.write)
        let ids = Set(files.map(\.id))
        for f in files {
            if let i = recordings.firstIndex(where: { $0.id == f.id }) {
                recordings[i].onDevice = true
                recordings[i].durationMs = f.durationMs
                recordings[i].end = f.endTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            } else {
                recordings.append(Recording(id: f.id, start: f.startDate ?? Date(), end: f.endTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                            durationMs: f.durationMs, title: nil, onDevice: true))
            }
        }
        for i in recordings.indices where !ids.contains(recordings[i].id) {
            recordings[i].onDevice = false
        }
        // 设备上和本机都没有的条目（例如启动听写后很快取消）去掉
        recordings.removeAll { !$0.onDevice && !$0.downloaded }
        recordings.sort { $0.start > $1.start }
        save()
    }

    /// 下载所有还没下载的录音（蓝牙）。听写开始时会让出连接，结束后自动继续
    /// （正在下的这一条还要 10 分钟以上时不让，见 `dictationBlockMessage`）。
    ///
    /// 每一条边收边写进 `<id>/download.part`，收完校验（文件头 id、连续、结束包、片数）再原子换成 audio.ogg；
    /// 没下完的临时文件留着，下次接着用（收过的不再写）。下载期间不让 Mac 空闲睡眠。
    func syncAll(ids: [UInt32]? = nil) async {
        guard case .idle = device.activity, !syncRunning, !wifiRunning else { return }
        syncRunning = true
        lastFailure = nil
        defer {
            syncRunning = false; syncSecondsLeft = nil; currentSecondsLeft = nil
            // 连接空出来了：转写已经完成的心力模式录音可以从设备删了
            Task { await self.afterSyncHousekeeping() }
        }
        await refreshDeviceList()
        let pending = pendingDownloads(ids: ids)
        guard !pending.isEmpty else { sync = .idle; return }
        guard device.beginSync(), let s = device.session else { return }
        defer { device.endSync() }
        // 心力模式：四步条从这里开始（让给语音输入后接着下时并进同一次）；改用 Wi‑Fi 时由 Wi‑Fi 那边接着报
        let tracked = settings.mode.heartMode
        if tracked { progress.begin(pending.map(\.id), options: runOptions) }
        defer { if tracked && sync != .paused && !wifiSwitchRequested { progress.downloadEnded() } }
        // 接电源时下载期间不睡；合盖、用电池时系统照样会睡，醒来后这次下载按「Mac 睡眠」中断，重连后再试
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Downloading recordings from the recorder")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        observeSleep()
        Log.write("同步 \(pending.count) 条录音 recorder=\(DeviceController.field(device.battery))")
        #if os(iOS)
        // 每一轮先听一下录音豆是不是还在发上一次请求的数据（进程被系统结束后重新拉起时，系统交还的连接上常常还在发）
        var needsQuiet = true
        #endif
        for (n, r) in pending.enumerated() {
            if device.syncShouldYield { pauseForDictation(); return }
            if wifiSwitchRequested { sync = .idle; return }
            sync = .downloading(id: r.id, done: n, total: pending.count, fraction: 0, kbps: 0)
            // 排在后面的录音要多久；加上这一条没下完的部分就是剩余时间
            let known = bluetoothRate
            let rest = pending[(n + 1)...].reduce(0.0) { $0 + estimate(durationMs: $1.durationMs, rate: known) }
            currentSecondsLeft = estimate(durationMs: r.durationMs, rate: known)
            syncSecondsLeft = rest + currentSecondsLeft!
            let file = RecordingFile(id: r.id, endTime: nil, durationMs: r.durationMs)
            do {
                var attempt = 0
                var result: DownloadResult
                var saved: Bool
                repeat {
                attempt += 1
                #if os(iOS)
                if needsQuiet {
                    guard await waitForQuietStream() else { streamBusy(r); return }
                }
                // 第二次（录音豆已经安静了）续传首片还不对：设备是真不认 offset，允许从头要（已收的片不重写）
                var behavior = DownloadBehavior.backgroundSafe
                if attempt > 1 { behavior.fallbackToStart = true }
                #else
                let behavior = DownloadBehavior.standard
                #endif
                let spool = try FrameSpool(url: partialURL(r.id), keepExisting: true)
                if spool.count > 0 { Log.write("\(r.id) 有上次没下完的 \(spool.count) 片（\(spool.received.summary)）") }
                // 有从第 0 片起连续的前缀就带 offset 续传（线上字节 = 片数 × 166）；续传首片不对时自动退回从头
                // download 在后台执行器上回调，这里切回主线程再碰界面状态
                result = try await s.download(file, spool: spool, behavior: behavior, log: { Log.write($0) }, shouldCancel: { [weak self] in
                    await MainActor.run { self.map { $0.device.syncShouldYield || $0.systemSleeping || $0.wifiSwitchRequested } ?? true }
                }) { [weak self] p in
                    await MainActor.run {
                        guard let self else { return }
                        self.sync = .downloading(id: r.id, done: n, total: pending.count,
                                                 fraction: p.expected > 0 ? min(1, Double(p.received) / Double(p.expected)) : 0,
                                                 kbps: Double(p.thisAttempt) / 1024 / max(p.elapsed, 0.1))
                        // 这一条下了 5 秒以上才信它自己的速度，之前用记住的速度
                        let rate = p.elapsed >= 5 && p.thisAttempt > 0 ? Double(p.thisAttempt) / p.elapsed : known
                        self.currentSecondsLeft = SyncEstimate.seconds(bytes: Double(max(p.expected - p.received, 0)), bytesPerSecond: rate)
                        self.syncSecondsLeft = rest + self.currentSecondsLeft!
                    }
                }
                Log.write("下载 \(r.id)：\(result.summary)")
                saved = await finishDownload(result, spool: spool, id: r.id, via: "蓝牙")
                #if os(iOS)
                needsQuiet = !saved && TransferRecovery.needsQuiet(result.stop)
                #endif
                } while Self.retrySameFile(saved: saved, stop: result.stop, attempt: attempt) && !device.syncShouldYield
                if saved, SyncEstimate.shouldLearn(bytes: result.bytesThisAttempt, seconds: result.seconds) {
                    bluetoothRate = SyncEstimate.blend(old: bluetoothRate, measured: Double(result.bytesThisAttempt) / result.seconds)
                }
                if device.syncShouldYield { pauseForDictation(); return }
                if wifiSwitchRequested { sync = .idle; return }
                if !saved {
                    #if os(iOS)
                    // 录音豆还在忙（设备报错、片号对不上、头是别的文件）：已收的留着，等一会儿再来，后面的这次也先不下
                    if Self.deviceBusyStops.contains(result.stop) { streamBusy(r); return }
                    #endif
                    lastFailure = result.stop.isInterruption ? .interrupted : .failed
                    lastFailureLong = estimate(durationMs: r.durationMs, rate: known) > SyncPolicy.longFile
                    // 连接没了（断开、Mac 睡过）：后面的也下不了，等重连
                    if result.stop == .disconnected || result.stop == .clockJump || result.stop == .cancelled {
                        sync = .failed(settings.mode.callsDeviceHeartBean
                                       ? String(localized: "The connection dropped. Sync continues when the Heart bean reconnects.")
                                       : String(localized: "The connection dropped. Sync continues when the recorder reconnects."))
                        return
                    }
                }
            } catch {
                Log.write("下载 \(r.id) 出错：\(error)")
                lastFailure = .failed
                lastFailureLong = estimate(durationMs: r.durationMs, rate: known) > SyncPolicy.longFile
                sync = .failed("\(error)")
                return
            }
        }
        sync = .idle
    }

    /// 录音豆多半还在发上一次请求的数据时会出现的几种停法
    static let deviceBusyStops: Set<DownloadStop> = [.deviceError, .resumeMismatch, .wrongFile]

    /// 同一个文件这一轮要不要再试一次（iOS：录音豆忙时先等它安静再试；Mac 一律不再试，和原来一样）
    static func retrySameFile(saved: Bool, stop: DownloadStop, attempt: Int) -> Bool {
        #if os(iOS)
        return !saved && deviceBusyStops.contains(stop) && attempt < TransferRecovery.attemptsPerFile
        #else
        return false
        #endif
    }

    #if os(iOS)
    /// 上次为了让录音豆停下而断开的时刻（StreamQuiet 用，免得反复断开）
    @ObservationIgnored private var lastStreamRelink: Date?

    /// 发请求前等录音豆不再发上一次的数据（规则见 OpenBeanKit 的 StreamQuiet）。返回 false：这一轮不下了
    /// （断开重连了，重连后自动同步会再来；或等太久、要让出连接）
    private func waitForQuietStream() async -> Bool {
        let t0 = Date()
        var said = false
        while true {
            let now = Date()
            let stray = device.link.straySliceAge(now: now)
            let step = StreamQuiet.next(sinceLastStray: stray.age, listened: now.timeIntervalSince(t0),
                                        sinceRelink: lastStreamRelink.map { now.timeIntervalSince($0) })
            switch step {
            case .proceed:
                if said { Log.write(String(format: "录音豆安静了（等了 %.0f 秒），接着请求", now.timeIntervalSince(t0))) }
                return true
            case .wait:
                if !said, let a = stray.age, a < StreamQuiet.quietWindow {
                    said = true
                    Log.write("录音豆还在发上一次请求的数据（没人在收的分片累计 \(stray.count) 包），等它停下再请求")
                }
                if device.syncShouldYield || device.session == nil { return false }
                try? await Task.sleep(nanoseconds: 500_000_000)
            case .relink:
                Log.write(String(format: "录音豆等了 %.0f 秒还在发：断开重连一次让它停下，重连后再同步", now.timeIntervalSince(t0)))
                lastStreamRelink = now
                device.link.disconnect()
                return false
            case .giveUp:
                Log.write(String(format: "录音豆发了 %.0f 秒还没停，这次先不下，稍后再试", now.timeIntervalSince(t0)))
                return false
            }
        }
    }

    /// 录音豆忙、这一轮不下了：按「中断」算（重连或过一会儿再试），已收的留着
    private func streamBusy(_ r: Recording) {
        lastFailure = .interrupted
        lastFailureLong = estimate(durationMs: r.durationMs, rate: bluetoothRate) > SyncPolicy.longFile
        sync = .failed(settings.mode.callsDeviceHeartBean
                       ? String(localized: "The Heart bean is still busy sending. Sync continues shortly from where it stopped.")
                       : String(localized: "The recorder is still busy sending. Sync continues shortly from where it stopped."))
    }
    #endif

    /// 一个文件经蓝牙下完大约要多少秒：固定开销 + 字节 ÷ 大文件的速度
    private func estimate(durationMs: UInt32, rate: Double) -> Double {
        SyncEstimate.fileSeconds(bytes: SyncEstimate.audioBytes(durationMs: Double(durationMs)), bytesPerSecond: rate)
    }

    /// 下载中的临时文件：每片一条记录（seq + 解密后的 160 字节），没下完的留着下次接着用
    func partialURL(_ id: UInt32) -> URL { folder(id).appendingPathComponent("download.part") }

    /// 一次下载结束：能用就写成 audio.ogg（缺的零星几片补静音）并删掉临时文件；不能用的删掉；没下完的留着。
    /// 返回有没有存下来
    private func finishDownload(_ result: DownloadResult, spool: FrameSpool, id: UInt32, via: String) async -> Bool {
        spool.close()
        switch result.check.verdict {
        case .complete, .completeWithGaps:
            let dest = audioURL(id)
            let first = result.check.firstSeq, count = result.check.expectedFrames
            // 几百 MB 的封装不放在主线程
            let written = await Task.detached { try? spool.writeOgg(to: dest, first: first, count: count) }.value
            guard let written else {
                Log.write("保存 \(id) 失败（写 audio.ogg 出错），临时文件留着")
                return false
            }
            // 重点标记（单元 flags 里的 01）和音频一起存：续传拼接过的也只在 spool 的标记文件里各记一次
            let marks = RecordingMarks(marks: spool.marks.map { SliceFlags.seconds(seq: $0, firstSeq: first) })
            do { try marks.encoded().write(to: marksURL(id), options: .atomic) } catch { Log.write("写标记失败 \(id)：\(error)") }
            markCache[id] = marks.marks
            if !marks.marks.isEmpty { Log.write("\(id) 有 \(marks.marks.count) 个重点标记：\(marks.marks.map { String(format: "%.2f", $0) }.joined(separator: "、")) 秒") }
            spool.remove()
            let source = settings.mode.sourceForSync
            update(id) {
                $0.downloaded = true
                $0.source = source
                $0.syncedAt = Date()
                $0.audioDeletedAt = nil
            }
            // 心力模式同步后自动从设备删除：只认这次同步下载、校验完整（没有补静音）的
            if source == .heart {
                syncedThisRun[id] = (result.check.verdict == .complete && written.filled == 0)
                progress.downloaded(id)
            }
            Log.write("已下载 \(id)（\(result.receivedBytes / 1024) KB，\(Int(result.seconds)) 秒，\(via)）"
                      + (written.filled > 0 ? "，缺 \(written.filled) 片已补静音" : ""))
            if settings.autoTranscribe {
                // iOS 在后台下载时先不转写（蓝牙回调里不做重活），交给后台处理任务（BackgroundSync）；Mac 上这个一直是 false
                if deferTranscription() { Log.write("\(id) 先不转写：App 在后台，交给后台处理任务") }
                else { Task { await transcribe(id) } }
            }
            return true
        case let .rejected(why):
            #if os(iOS)
            // 设备忙（err=4）、头不对、片号对不上、被打断：不是数据坏了，已收的连续前缀留着下次续传
            if TransferRecovery.keepsPartial(stop: result.stop, verdict: result.check.verdict) {
                Log.write("下载 \(id) 这次没成：\(why)（\(result.stop.label)）；不是数据坏了，临时文件留着（\(spool.count) 片），稍后续传")
                return false
            }
            #endif
            Log.write("下载 \(id) 的数据不能用：\(why)；临时文件删掉")
            spool.remove()
            return false
        case let .incomplete(why):
            Log.write("下载不完整 \(id)：\(why)；已收 \(result.receivedBytes / 1024) KB，临时文件留在 \(spool.url.lastPathComponent)")
            return false
        }
    }

    // MARK: 同步和 Mac 睡眠

    /// 系统要睡了：正在进行的下载马上停（按中断算），醒来后连上再试
    private var systemSleeping = false
    private var sleepObservers: [NSObjectProtocol] = []

    private func observeSleep() {
        #if os(macOS)
        guard sleepObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.systemSleeping = true
                if self.syncRunning { Log.write("Mac 要睡眠，停止这次下载") }
            }
        })
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemSleeping = false }
        })
        #endif
    }

    // MARK: 同步和语音输入

    /// 正在下的这一条还要多少秒（不在下载时为 nil）
    private(set) var currentSecondsLeft: Double?
    /// 最近一次同步没完成的原因（自动同步据此决定多久后重试）；完成或让给语音输入时为 nil
    private(set) var lastFailure: SyncPolicy.Failure?
    /// 没完成的那一条是不是长文件（估计 10 分钟以上）
    private(set) var lastFailureLong = false

    #if os(macOS)
    /// 语音输入要开始时问一句：正在下的这一条还要 10 分钟以上、又不能续传时不让，返回给用户看的提示
    func dictationBlockMessage() -> String? {
        guard case .downloading = sync, syncRunning else { return nil }
        guard case let .keepSyncing(left) = SyncPolicy.dictation(remaining: currentSecondsLeft,
                                                                  resumable: ResumeSupport.current.isSupported) else { return nil }
        Log.write("语音输入没开始：正在同步长录音，这一条约剩 \(Int(left)) 秒（不能续传，让出就要从头下）")
        return String(localized: "Syncing a long recording, about \(SyncStatus.phrase(left)) left. Voice typing is available when it finishes.")
    }
    #endif

    // MARK: 改用 Wi‑Fi

    private var wifiSwitchRequested = false

    /// 蓝牙预计要很久时可以改用 Wi‑Fi：正在下的停下（收过的留在临时文件里），剩下的经 Wi‑Fi 下
    func switchToWifi() async {
        let ids = pendingDownloads().map(\.id)
        guard !ids.isEmpty else { return }
        if syncRunning {
            wifiSwitchRequested = true
            Log.write("改用 Wi‑Fi：先停蓝牙同步")
            for _ in 0..<100 where syncRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            wifiSwitchRequested = false
            guard !syncRunning else { Log.write("蓝牙同步 10 秒内没停下，不改用 Wi‑Fi"); return }
        }
        await syncViaWifi(ids: ids)
    }

    /// 经 Wi‑Fi 下完还没下载的录音大约要多久（秒）；没有要下的返回 nil
    var pendingWifiSeconds: Double? {
        let p = pendingDownloads()
        return p.isEmpty ? nil : WifiAdvice.estimate(durationsMs: p.map { Double($0.durationMs) }, bluetoothBytesPerSecond: bluetoothRate).wifi
    }

    /// 录音豆上还没下载的录音（短的先下）
    func pendingDownloads(ids: [UInt32]? = nil) -> [Recording] {
        recordings.filter { r in
            r.onDevice && !r.downloaded && r.durationMs > 0 && (ids?.contains(r.id) ?? !r.isDictation)
        }.sorted { $0.durationMs < $1.durationMs }
    }

    private func pauseForDictation() {
        sync = .paused
        progress.downloadPaused()
        resumeAfterDictation = true
        Log.write("同步让给听写")
    }

    /// 听写结束后调用
    func resumeIfNeeded() {
        guard resumeAfterDictation else { return }
        resumeAfterDictation = false
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await syncAll()
        }
    }


    // MARK: 删除录音豆上的录音

    /// 正在从录音豆删除的录音
    private(set) var deletingFromRecorder: UInt32?

    /// 右键菜单里要不要出现「从录音豆删除」：只是粗判，真正的检查在 deleteFromRecorder 里
    func mayDeleteFromRecorder(_ r: Recording) -> Bool {
        r.onDevice && r.downloaded && FileManager.default.fileExists(atPath: audioURL(r.id).path)
    }

    /// 连接空闲（没在同步、听写、删除）
    var recorderIdle: Bool {
        device.isReady && device.activity == .idle && !syncRunning && deletingFromRecorder == nil
    }

    /// 从录音豆删除（本机副本保留）。逐条删，遇到第一个错误就停；全部成功返回 nil，否则返回出错说明。
    func deleteFromRecorder(_ ids: [UInt32]) async -> String? {
        for id in ids {
            do { try await deleteOneFromRecorder(id) } catch { return "\(error)" }
        }
        return nil
    }

    private func deleteOneFromRecorder(_ id: UInt32) async throws {
        guard let r = recordings.first(where: { $0.id == id }) else { throw DeleteError.refused(.notOnRecorder) }
        // 把本机音频完整解码一遍核对时长（长录音要几秒；不占 work 队列，那里可能在转写）
        let url = audioURL(id)
        let local: Double? = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: LocalAudio.decodedSeconds(url)) }
        }
        // 先用本机已知的状态粗查一遍；录音状态和时长到了设备上还会用最新的再查
        if let refusal = DeletePolicy.check(onRecorder: r.onDevice, downloaded: r.downloaded, localSeconds: local,
                                            expectedSeconds: r.duration, recorderRecording: device.info?.recording,
                                            busy: !recorderIdle) {
            throw DeleteError.refused(refusal)
        }
        // 删除期间占住连接，同步和自动同步不会插进来
        guard device.beginSync(), let s = device.session else { throw DeleteError.refused(.busy) }
        defer { device.endSync() }
        deletingFromRecorder = id
        defer { deletingFromRecorder = nil }
        Log.write("从录音豆删除 \(id)（本机 \(String(format: "%.2f", local ?? 0)) 秒）")
        do {
            let after = try await s.deleteFile(id: id) { f in
                if let refusal = DeletePolicy.check(onRecorder: true, downloaded: true, localSeconds: local,
                                                    expectedSeconds: f.durationSeconds, recorderRecording: false, busy: false) {
                    throw DeleteError.refused(refusal)
                }
            }
            merge(after)
            Log.write("已从录音豆删除 \(id)，设备上还有 \(after.count) 条")
        } catch {
            Log.write("从录音豆删除 \(id) 失败：\(error)")
            // 失败时设备上的状态不一定清楚（例如回包超时），重新读一遍列表
            if let files = try? await s.listFiles() { merge(files) }
            throw error
        }
    }

    // MARK: 心力模式：同步后从设备删除、本机音频保留期

    /// 这次运行里同步下载的心力模式录音 → 下载校验完整（没有补静音）。Mac 只在内存里：App 重启后就不再自动删这些。
    /// iOS 存进文件：后台下完以后 App 常被系统结束，转写在下一次启动（后台处理任务）里才做完，删除设备上的录音要靠这份记录
    @ObservationIgnored private var syncedThisRun: [UInt32: Bool] = [:] {
        didSet {
            #if os(iOS)
            if let d = try? JSONEncoder().encode(syncedThisRun.map { SyncedEntry(id: $0.key, complete: $0.value) }) {
                try? d.write(to: Self.syncedURL, options: .atomic)
            }
            #endif
        }
    }
    #if os(iOS)
    private struct SyncedEntry: Codable { var id: UInt32; var complete: Bool }
    private static var syncedURL: URL { AppPaths.library.appendingPathComponent("heart-synced.json") }
    private func loadSynced() {
        guard let d = try? Data(contentsOf: Self.syncedURL),
              let list = try? JSONDecoder().decode([SyncedEntry].self, from: d) else { return }
        syncedThisRun = Dictionary(list.map { ($0.id, $0.complete) }, uniquingKeysWith: { a, _ in a })
    }
    #endif
    @ObservationIgnored private var housekeeping = false
    @ObservationIgnored private var housekeepingAgain = false

    /// 同步结束、转写完成后：先从设备删掉符合条件的心力模式录音，再按保留期删本机音频（设备端删除要用本机音频核对，所以先删设备）。
    /// 正在做时又被叫到（例如删除期间又一条转写完了）：做完再来一遍
    func afterSyncHousekeeping() async {
        guard !housekeeping else { housekeepingAgain = true; return }
        housekeeping = true
        defer { housekeeping = false }
        repeat {
            housekeepingAgain = false
            await cleanUpRecorder()
            applyAudioRetention()
        } while housekeepingAgain
    }

    /// 同步并转写完成的心力模式录音，从设备上删掉。每条先过 RecorderCleanupPolicy，再走 deleteOneFromRecorder 里的
    /// DeletePolicy（本机音频完整解码、时长核对、设备没在录音、连接空闲）。任何一项不过就不删，写日志
    private func cleanUpRecorder() async {
        let mode = settings.mode
        let queue = syncedThisRun.sorted(by: { $0.key < $1.key })
        // 连接正忙：这条和后面还没轮到的都等下次（四步条上显示「等心力豆空出来」）
        func busy(from i: Int) {
            for (id, _) in queue[i...] { progress.cleanUp(id, .busy) }
        }
        for (i, (id, complete)) in queue.enumerated() {
            guard let r = recordings.first(where: { $0.id == id }) else { syncedThisRun[id] = nil; progress.cleanUp(id, .gone); continue }
            guard r.onDevice else { syncedThisRun[id] = nil; progress.cleanUp(id, .gone); continue }
            if let refusal = RecorderCleanupPolicy.check(mode: mode, source: r.recordingSource, downloadedThisSync: true,
                                                         downloadComplete: complete,
                                                         transcriptExists: r.transcribed && FileManager.default.fileExists(atPath: transcriptURL(id).path)) {
                switch refusal {
                case .notTranscribed:
                    continue // 转写完了会再叫一次
                default:
                    Log.write("心力模式：\(id) 不从设备删除：\(refusal)")
                    syncedThisRun[id] = nil
                    progress.cleanUp(id, .kept)
                    continue
                }
            }
            // 连接忙（同步、语音输入、别的删除）：留着，下次同步结束或转写完再试
            guard recorderIdle else { Log.write("心力模式：\(id) 暂不从设备删除：连接正忙，稍后再试"); busy(from: i); return }
            do {
                try await deleteOneFromRecorder(id)
                Log.write("心力模式：同步并转写完成，已从设备删除 \(id)")
                syncedThisRun[id] = nil
                progress.cleanUp(id, .deleted)
            } catch DeleteError.refused(.busy) {
                Log.write("心力模式：\(id) 暂不从设备删除：连接正忙，稍后再试")
                busy(from: i)
                return
            } catch {
                Log.write("心力模式：\(id) 不从设备删除：\(error)")
                syncedThisRun[id] = nil
                progress.cleanUp(id, .kept)
            }
        }
    }

    /// 按设置删心力模式录音的本机音频（只删 audio.ogg 和它的波形缓存；转写、摘要、对话段、日记都留着）
    func applyAudioRetention(now: Date = Date()) {
        let mode = settings.mode
        let fm = FileManager.default
        for r in recordings where r.downloaded && !r.isDictation && r.recordingSource == .heart && !r.audioRemoved {
            let audio = audioURL(r.id)
            let lines: Int? = r.transcribed && fm.fileExists(atPath: transcriptURL(r.id).path) ? transcript(r.id).count : nil
            // 设备上还有、又会自动删：先等设备端删完（要用本机音频核对）
            let awaiting = mode.deletesFromRecorderAfterSync && r.onDevice && syncedThisRun[r.id] != nil
            if let keep = AudioRetentionPolicy.check(source: r.recordingSource, retention: mode.audioRetention,
                                                     audioExists: fm.fileExists(atPath: audio.path), transcriptLines: lines,
                                                     syncedAt: r.syncedAt ?? r.start, now: now, awaitingRecorderDelete: awaiting) {
                if case .noAudio = keep { continue }
                if case .tooRecent = keep { continue }
                if case .keepForever = keep { continue }
                Log.write("心力模式：\(r.id) 的本机音频先留着：\(keep)")
                continue
            }
            do {
                try fm.removeItem(at: audio)
                try? fm.removeItem(at: folder(r.id).appendingPathComponent("peaks.json"))
                peaksCache[r.id] = nil
                update(r.id) { $0.audioDeletedAt = now }
                Log.write("心力模式：按设置（\(mode.audioRetention.rawValue)）删了 \(r.id) 的本机音频，转写留着")
            } catch {
                Log.write("心力模式：删 \(r.id) 的本机音频失败：\(error)")
            }
        }
    }

    // MARK: 删除语音输入用过的设备文件

    /// 语音输入结束后删掉这次用的设备文件。只删 App 为语音输入新建的文件（规则见 DictationDeletePolicy），
    /// 不需要本机副本。失败只写日志，不打扰用户；删成功后 merge 会把这条去掉（设备上没有、本机也没下载）。
    func deleteDictationFile(_ e: DictationDeletePolicy.Evidence) async {
        guard settings.deleteDictationAudio else { return }
        let id = e.fileId
        // 先只看证据（设备时长、录音状态到了设备上再用最新的查），证据不够就不占连接
        if let refusal = DictationDeletePolicy.check(e, deviceSeconds: 0, sessionSeconds: 0, recorderRecording: false, busy: false) {
            Log.write("语音输入文件 \(id) 不删：\(refusal)")
            return
        }
        guard recorderIdle, device.beginSync(), let s = device.session else {
            Log.write("语音输入文件 \(id) 不删：\(DictationDeletePolicy.Refusal.busy)")
            return
        }
        defer { device.endSync() }
        deletingFromRecorder = id
        defer { deletingFromRecorder = nil }
        do {
            let after = try await s.deleteFile(id: id) { f in
                // 列表刚读完再问一次录音状态：这期间按了录音豆的键，录音豆可能正在续写这个文件
                let recording = try await s.deviceInfo()?.recording
                let secs = Date().timeIntervalSince(e.startedAt)
                if let refusal = DictationDeletePolicy.check(e, deviceSeconds: f.durationSeconds, sessionSeconds: secs,
                                                             recorderRecording: recording, busy: false) {
                    throw refusal
                }
            }
            merge(after)
            Log.write("已从录音豆删除语音输入文件 \(id)，设备上还有 \(after.count) 条")
        } catch {
            Log.write("语音输入文件 \(id) 没删：\(error)")
            if let files = try? await s.listFiles() { merge(files) }
        }
    }

    /// 以前留在录音豆上的语音输入文件：资料库标了语音输入、设备上还在、没下载。
    /// 这些没法证明是 App 新建的（可能续写过），只在用户确认后手动清理。
    var leftoverDictationFiles: [Recording] {
        recordings.filter { DictationDeletePolicy.isLeftover(isDictation: $0.isDictation, onRecorder: $0.onDevice, downloaded: $0.downloaded) }
    }

    /// 逐条删除旧的语音输入文件，返回成功和失败的条数。调用前要先让用户确认。
    func deleteLeftoverDictation(_ ids: [UInt32]) async -> (deleted: Int, failed: Int) {
        var ok = 0, failed = 0
        for id in ids {
            do {
                guard let r = recordings.first(where: { $0.id == id }),
                      DictationDeletePolicy.isLeftover(isDictation: r.isDictation, onRecorder: r.onDevice, downloaded: r.downloaded)
                else { throw DeleteError.refused(.notOnRecorder) }
                guard recorderIdle, device.beginSync(), let s = device.session else { throw DeleteError.refused(.busy) }
                defer { device.endSync() }
                deletingFromRecorder = id
                defer { deletingFromRecorder = nil }
                do {
                    merge(try await s.deleteFile(id: id) { _ in })
                } catch {
                    if let files = try? await s.listFiles() { merge(files) }
                    throw error
                }
                ok += 1
                Log.write("已从录音豆删除旧的语音输入文件 \(id)")
            } catch {
                failed += 1
                Log.write("旧的语音输入文件 \(id) 没删：\(error)")
            }
        }
        return (ok, failed)
    }

    // MARK: Wi‑Fi 快速同步

    /// 正在经 Wi‑Fi 同步（加入热点到离开热点）：自动同步、手动蓝牙同步都不插进来
    private(set) var wifiRunning = false
    /// App 要停（iOS 切到后台、锁屏）：停在当前文件，已收的留着
    @ObservationIgnored private var wifiCancel = false

    /// 经录音豆的 Wi‑Fi 热点下载（流程两端共用：OpenBeanKit 的 WifiSyncFlow；加入 / 离开热点按平台：WifiPlatform）。
    /// Mac 会暂时断网约一分钟；iPhone 的 Wi‑Fi 暂时连到录音豆。和蓝牙一样边收边落盘、按同样的规则校验完整性，
    /// 每个文件下完马上保存；被打断时已收的片留在临时文件里，之后蓝牙或 Wi‑Fi 都从那里接着下
    func syncViaWifi(ids: [UInt32]) async {
        guard !wifiRunning, !syncRunning else { return }
        let targets = recordings.filter { ids.contains($0.id) && $0.onDevice && !$0.downloaded }
        guard !targets.isEmpty, device.beginSync(), let s = device.session else { return }
        // Mac 在这里查 Wi‑Fi 接口名（和拆分前一样，在请求开热点之前）
        let joiner = WifiPlatform.makeJoiner()
        wifiRunning = true
        wifiCancel = false
        defer { device.endSync() }
        let tracked = settings.mode.heartMode
        if tracked { progress.begin(targets.map(\.id), options: runOptions) }
        defer { if tracked { progress.downloadEnded() } }
        let release = WifiPlatform.hold { [weak self] in self?.wifiCancel = true }
        Log.write("Wi‑Fi 同步 \(targets.count) 条")
        #if os(iOS)
        device.pauseReconnect()
        defer { device.resumeReconnect() }
        #endif
        let heart = settings.mode.callsDeviceHeartBean
        let link = device.link
        var flow = WifiSyncFlow(openHotspot: {
            let open = Cmd.openSoftAP(ssid: WifiSyncFlow.defaultSSID, password: WifiSyncFlow.defaultPassword)
            let hex = { (b: [UInt8]) in b.map { String(format: "%02X", $0) }.joined(separator: " ") }
            // 录音豆有时先回一个不带地址的确认（09 FF 00 00 01 1A 05 0A 00 32），地址在后面的 1A/05 里，
            // 有时（热点已经开着）只回确认。所以只认带地址的那一包；等不到就按热点已经开着、用实测的固定地址去连
            do {
                let ack = try await link.request(open, timeout: 20, label: "Wi‑Fi") {
                    guard $0.type == 0x1A, $0.id == 0x05 else { return false }
                    if SoftAPEndpoint(frame: $0.raw) != nil { return true }
                    Log.write("Wi‑Fi 同步：1A/05 回包不带地址：\(hex($0.raw))，接着等带地址的")
                    return false
                }
                if let ep = SoftAPEndpoint(frame: ack.raw) { return ep }
            } catch {
                Log.write("Wi‑Fi 同步：20 秒没等到带地址的回包（\(error)）")
            }
            let fallback = SoftAPEndpoint(ip: "192.168.43.1", port: 443)
            Log.write("Wi‑Fi 同步：按热点已经开着处理，用固定地址 \(fallback) 去连")
            return fallback
        }, joiner: joiner, makeTransport: { ep in
            let w = WifiExport(endpoint: ep, crypto: s.crypto)
            w.connectAttempts = WifiPlatform.connectAttempts
            w.log = { Log.write("Wi‑Fi: \($0)") }
            return w
        }, ssid: WifiSyncFlow.defaultSSID, password: WifiSyncFlow.defaultPassword)
        flow.log = { Log.write("Wi‑Fi 同步：\($0)") }
        let report = await flow.run(files: targets.map { RecordingFile(id: $0.id, endTime: nil, durationMs: $0.durationMs) },
                                    spool: { [weak self] id in
            try await MainActor.run { () throws -> FrameSpool in
                guard let self else { throw CancellationError() }
                return try FrameSpool(url: self.partialURL(id), keepExisting: true)
            }
        }, shouldCancel: { [weak self] in
            await MainActor.run { self?.wifiCancel ?? true }
        }, step: { [weak self] st in
            await MainActor.run { self?.sync = .wifi(WifiPlatform.text(st, heart: heart)) }
        }, fileDone: { [weak self] id, result, spool in
            _ = await self?.finishDownload(result, spool: spool, id: id, via: "Wi‑Fi")
        })
        release()
        wifiRunning = false
        #if os(iOS)
        device.resumeReconnect()
        #endif
        let leftAt = Date()
        if let failure = report.failure {
            Log.write("Wi‑Fi 同步没走完（停在 \(report.stage)）：\(failure)")
            sync = .failed(WifiPlatform.failureText(failure, heart: heart))
        } else {
            sync = .idle
            Task { await self.afterSyncHousekeeping() }
        }
        // 录音豆关了热点以后蓝牙会自己连回来（之后没下完的由自动同步经蓝牙续传）；记下用了多久
        if report.endpoint != nil {
            if WifiPlatform.waitsForBluetooth {
                let shown = sync
                if !syncRunning, report.failure == nil { sync = .wifi(WifiPlatform.text(.waitingForBluetooth, heart: heart)) }
                await logBluetoothReturn(since: leftAt)
                if case .wifi = sync, !syncRunning { sync = shown }
                // 蓝牙可能在 Wi‑Fi 还没收完尾时就连回来了（那时自动同步看到「正在同步」没跑）：剩下的现在交给它
                let left = pendingDownloads(ids: targets.map(\.id))
                if !left.isEmpty, device.isReady {
                    Log.write("Wi‑Fi 同步：还有 \(left.count) 条没下完，交给蓝牙自动同步（从临时文件接着下）")
                    onListRefreshed()
                }
            } else {
                Task { await self.logBluetoothReturn(since: leftAt) }
            }
        }
    }

    /// 等蓝牙连回来（最多 60 秒）并写日志
    private func logBluetoothReturn(since t0: Date) async {
        Log.write("Wi‑Fi 同步：等蓝牙重连")
        // 刚离开热点时蓝牙多半还没断开（DeviceController 还没发现），先等它断开过
        var sawDrop = !device.isReady
        while Date().timeIntervalSince(t0) < 60 {
            if !device.isReady { sawDrop = true }
            if sawDrop, device.isReady {
                Log.write(String(format: "Wi‑Fi 同步：蓝牙重连用了 %.1f 秒（从离开热点算）", Date().timeIntervalSince(t0)))
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        Log.write(sawDrop ? "Wi‑Fi 同步：离开热点 60 秒蓝牙还没连回来（连接循环会接着重连）"
                          : "Wi‑Fi 同步：离开热点 60 秒蓝牙一直显示已连接（没看到断开）")
    }

    // MARK: 转写

    func transcribe(_ id: UInt32) async {
        guard transcribing[id] == nil, FileManager.default.fileExists(atPath: audioURL(id).path) else { return }
        transcribing[id] = 0
        let url = audioURL(id)
        let models = AppPaths.models
        let glossary = GlossaryCorrector(terms: AppPaths.readGlossary())
        let result: Result<[TranscriptSegment], Error> = await withCheckedContinuation { c in
            work.async {
                c.resume(returning: Result {
                    try FileTranscriber.transcribe(url: url, models: models, glossary: glossary) { p in
                        DispatchQueue.main.async { [weak self] in self?.transcribing[id] = p }
                    }
                })
            }
        }
        transcribing[id] = nil
        switch result {
        case let .success(segs):
            transcripts[id] = segs
            if let d = try? JSONEncoder().encode(segs) { try? d.write(to: transcriptURL(id), options: .atomic) }
            update(id) { $0.transcribed = true }
            Log.write("已转写 \(id)：\(segs.count) 句")
            progress.transcribed(id, ok: true)
            // 先切段再写笔记：笔记按段分节
            conversations.refresh(id)
            notes.afterTranscription(id)
            Task { await afterSyncHousekeeping() }
        case let .failure(e):
            Log.write("转写失败 \(id)：\(e)")
            progress.transcribed(id, ok: false)
        }
    }

    // MARK: 导出

    func markdown(_ id: UInt32) -> String {
        guard let r = recordings.first(where: { $0.id == id }) else { return "" }
        var s = "# \(r.displayTitle)\n\n"
        s += "\(r.start.formatted(date: .long, time: .shortened)) · \(Self.clock(r.duration))\n\n"
        if let sum = notes.summary(id) {
            s += "## Summary\n\n\(sum.summary)\n\n"
            if !sum.keyPoints.isEmpty { s += "## Key points\n\n" + sum.keyPoints.map { "- \($0)\n" }.joined() + "\n" }
            if !sum.actionItems.isEmpty { s += "## Action items\n\n" + sum.actionItems.map { "- [ ] \($0)\n" }.joined() + "\n" }
            s += "## Transcript\n\n"
        }
        for seg in transcript(id) { s += "**[\(Self.clock(seg.start))]** \(seg.text)\n\n" }
        return s
    }

    #if os(macOS)
    func exportMarkdown(_ id: UInt32) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = r.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(id).write(to: url, atomically: true, encoding: .utf8)
    }

    /// 在访达里显示：有音频选中音频，音频按设置删了就选中录音文件夹
    func showInFinder(_ r: Recording) {
        let audio = audioURL(r.id)
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: audio.path) ? audio : folder(r.id)])
    }

    func exportAudio(_ id: UInt32) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ogg") ?? .audio]
        panel.nameFieldStringValue = r.displayTitle.replacingOccurrences(of: "/", with: "-") + ".ogg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.copyItem(at: audioURL(id), to: url)
    }
    #endif

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 离线转写一个音频文件：解码 → 16 kHz → 测音量定增益 → VAD 切句 → SenseVoice
enum FileTranscriber {
    static func transcribe(url: URL, models: URL, glossary: GlossaryCorrector,
                           progress: (Double) -> Void) throws -> [TranscriptSegment] {
        let recognizer = try SentenceRecognizer(modelsDir: models, minSilence: 0.6)
        // 整个文件都在手里：先走一遍测音量，小声的录音给 VAD 一个固定增益（不然整段会被当成静音）
        let level = try AudioFile16k.stats(url)
        recognizer.vadGainDb = level.gain
        if level.gain > 0 {
            Log.write(String(format: "转写音量：说话 %.1f dBFS，底噪 %.1f dBFS，切句前放大 %.1f dB",
                             level.speech, level.noise, level.gain))
        }
        var out: [TranscriptSegment] = []
        try AudioFile16k.read(url) { samples, p in
            out += recognizer.accept(samples).map { seg($0, glossary) }
            progress(p)
        }
        out += recognizer.flush().map { seg($0, glossary) }
        if recognizer.usedFallback { Log.write("转写没切出句子，整段直接识别") }
        return out.filter { !$0.text.isEmpty }
    }

    /// 每句先按个人词表纠正专有名词（转写模式，更保守）；改过的句子留下原文
    private static func seg(_ s: SentenceRecognizer.Sentence, _ glossary: GlossaryCorrector) -> TranscriptSegment {
        let l = TranscriptCorrection.apply(glossary, text: s.text, raw: nil)
        if let raw = l.raw { Log.write("词表纠正：\(raw) → \(l.text)") }
        return TranscriptSegment(start: s.start, end: s.end, text: l.text, raw: l.raw)
    }
}
