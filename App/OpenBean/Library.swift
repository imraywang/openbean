// SPDX-License-Identifier: Apache-2.0

import AppKit
import AVFoundation
import Foundation
import Observation
import OpenBeanKit
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
    /// 记住的蓝牙下载速度（字节/秒），每次下载完更新；估算同步时长用
    private var bluetoothRate: Double {
        get { let v = UserDefaults.standard.double(forKey: "bluetoothBytesPerSecond"); return v > 0 ? v : SyncEstimate.defaultBytesPerSecond }
        set { UserDefaults.standard.set(newValue, forKey: "bluetoothBytesPerSecond") }
    }
    /// 把还没下载的录音都经蓝牙下完大约要多少秒；没有要下的返回 nil
    var pendingSyncSeconds: Double? {
        let ms = pendingDownloads().reduce(0.0) { $0 + Double($1.durationMs) }
        return ms > 0 ? SyncEstimate.seconds(bytes: SyncEstimate.audioBytes(durationMs: ms), bytesPerSecond: bluetoothRate) : nil
    }
    private(set) var transcribing: [UInt32: Double] = [:]
    private var transcripts: [UInt32: [TranscriptSegment]] = [:]
    enum Filter: String, CaseIterable, Identifiable {
        case all, transcribed, onRecorder, dictation
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return String(localized: "All recordings")
            case .transcribed: return String(localized: "Transcribed")
            case .onRecorder: return String(localized: "Only on recorder")
            case .dictation: return String(localized: "Dictation clips")
            }
        }
    }

    var filter: Filter = .all
    /// 主窗口里选中的录音（openbean://open/<id> 也会改它）
    var selection: UInt32?
    private var peaksCache: [UInt32: [Float]] = [:]

    private let device: DeviceController
    private let settings: Settings
    /// 摘要和知识库笔记
    let notes: NoteService
    private let work = DispatchQueue(label: "openbean.library", qos: .userInitiated)
    private var resumeAfterDictation = false
    /// syncAll 正在跑（防止手动和自动同步叠在一起）
    private(set) var syncRunning = false
    /// 每次成功读到设备上的文件列表后调用（自动同步用）
    @ObservationIgnored var onListRefreshed: () -> Void = {}

    private var indexURL: URL { AppPaths.library.appendingPathComponent("index.json") }
    func folder(_ id: UInt32) -> URL {
        let u = AppPaths.library.appendingPathComponent(String(id))
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func audioURL(_ id: UInt32) -> URL { folder(id).appendingPathComponent("audio.ogg") }
    func transcriptURL(_ id: UInt32) -> URL { folder(id).appendingPathComponent("transcript.json") }

    init(device: DeviceController, settings: Settings) {
        self.device = device
        self.settings = settings
        notes = NoteService(settings: settings)
        load()
        notes.library = self
    }

    var visible: [Recording] {
        recordings.filter { r in
            switch filter {
            case .all: return !r.isDictation
            case .transcribed: return r.transcribed && !r.isDictation
            case .onRecorder: return !r.downloaded && !r.isDictation
            case .dictation: return r.isDictation
            }
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
        notes.transcriptChanged(id)
    }

    /// 删除本机副本（不动设备上的录音）
    func deleteLocal(_ id: UInt32) {
        try? FileManager.default.removeItem(at: folder(id))
        transcripts[id] = nil
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

    func refreshDeviceList() async {
        guard device.isReady, device.activity == .idle, let s = device.session else { return }
        sync = .listing
        do {
            let files = try await s.listFiles()
            merge(files)
            sync = .idle
            onListRefreshed()
        } catch {
            sync = .failed("\(error)")
        }
    }

    private func merge(_ files: [RecordingFile]) {
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

    /// 下载所有还没下载的录音（蓝牙）。听写开始时会让出连接，结束后自动继续。
    func syncAll(ids: [UInt32]? = nil) async {
        guard case .idle = device.activity, !syncRunning else { return }
        syncRunning = true
        defer { syncRunning = false; syncSecondsLeft = nil }
        await refreshDeviceList()
        let pending = pendingDownloads(ids: ids)
        guard !pending.isEmpty else { sync = .idle; return }
        guard device.beginSync(), let s = device.session else { return }
        defer { device.endSync() }
        Log.write("同步 \(pending.count) 条录音 recorder=\(DeviceController.field(device.battery))")
        for (n, r) in pending.enumerated() {
            if device.syncShouldYield { pauseForDictation(); return }
            sync = .downloading(id: r.id, done: n, total: pending.count, fraction: 0, kbps: 0)
            // 排在后面的录音还有多少字节；加上这一条没下完的部分就是剩余量
            let restBytes = SyncEstimate.audioBytes(durationMs: pending[(n + 1)...].reduce(0.0) { $0 + Double($1.durationMs) })
            let known = bluetoothRate
            syncSecondsLeft = SyncEstimate.seconds(bytes: restBytes + SyncEstimate.audioBytes(durationMs: Double(r.durationMs)), bytesPerSecond: known)
            let file = RecordingFile(id: r.id, endTime: nil, durationMs: r.durationMs)
            do {
                // pull 在后台执行器上回调，这里切回主线程再碰界面状态
                let t = try await s.pull(file, shouldCancel: { [weak self] in
                    await MainActor.run { self?.device.syncShouldYield ?? true }
                }) { [weak self] got, expected, elapsed in
                    await MainActor.run {
                        self?.sync = .downloading(id: r.id, done: n, total: pending.count,
                                                  fraction: expected > 0 ? Double(got) / Double(expected) : 0,
                                                  kbps: Double(got) / 1024 / max(elapsed, 0.1))
                        // 这一条下了 5 秒以上才信它自己的速度，之前用记住的速度
                        let rate = elapsed >= 5 && got > 0 ? Double(got) / elapsed : known
                        self?.syncSecondsLeft = SyncEstimate.seconds(bytes: restBytes + Double(max(expected - got, 0)), bytesPerSecond: rate)
                    }
                }
                if device.syncShouldYield { pauseForDictation(); return }
                guard t.decrypted, Double(t.audio.count) >= Double(file.audioBytes) * 0.95 || t.gotDone else {
                    Log.write("下载不完整 \(r.id)：\(t.audio.count)/\(file.audioBytes)")
                    continue
                }
                try saveAudio(t.audio, id: r.id)
                if t.seconds >= 3 { bluetoothRate = SyncEstimate.blend(old: bluetoothRate, measured: Double(t.audio.count) / t.seconds) }
                Log.write("已下载 \(r.id)（\(t.audio.count / 1024) KB，\(Int(t.seconds)) 秒）")
                if settings.autoTranscribe { Task { await transcribe(r.id) } }
            } catch {
                sync = .failed("\(error)")
                return
            }
        }
        sync = .idle
    }

    /// 录音豆上还没下载的录音（短的先下）
    func pendingDownloads(ids: [UInt32]? = nil) -> [Recording] {
        recordings.filter { r in
            r.onDevice && !r.downloaded && r.durationMs > 0 && (ids?.contains(r.id) ?? !r.isDictation)
        }.sorted { $0.durationMs < $1.durationMs }
    }

    private func pauseForDictation() {
        sync = .paused
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

    private func saveAudio(_ opus: [UInt8], id: UInt32) throws {
        let ogg = OggOpus.mux(frames: OggOpus.frames(from: opus))
        try Data(ogg).write(to: audioURL(id), options: .atomic)
        update(id) { $0.downloaded = true }
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

    /// 经录音豆的 Wi‑Fi 热点下载（Mac 会暂时断网约一分钟）
    func syncViaWifi(ids: [UInt32]) async {
        let targets = recordings.filter { ids.contains($0.id) && $0.onDevice && !$0.downloaded }
        guard !targets.isEmpty, device.beginSync(), let s = device.session else { return }
        defer { device.endSync() }
        do {
            let done = try await WifiSync.run(session: s, link: device.link, files: targets.map {
                RecordingFile(id: $0.id, endTime: nil, durationMs: $0.durationMs)
            }) { [weak self] msg in
                await MainActor.run { self?.sync = .wifi(msg) }
            }
            for (id, audio) in done {
                try saveAudio(audio, id: id)
                if settings.autoTranscribe { Task { await transcribe(id) } }
            }
            sync = .idle
        } catch {
            sync = .failed("\(error)")
        }
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
            notes.afterTranscription(id)
        case let .failure(e):
            Log.write("转写失败 \(id)：\(e)")
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

    func exportMarkdown(_ id: UInt32) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = r.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(id).write(to: url, atomically: true, encoding: .utf8)
    }

    func exportAudio(_ id: UInt32) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ogg") ?? .audio]
        panel.nameFieldStringValue = r.displayTitle.replacingOccurrences(of: "/", with: "-") + ".ogg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.copyItem(at: audioURL(id), to: url)
    }

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
