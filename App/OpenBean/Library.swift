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

struct TranscriptSegment: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

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
    private let work = DispatchQueue(label: "openbean.library", qos: .userInitiated)
    private var resumeAfterDictation = false

    private var indexURL: URL { AppPaths.library.appendingPathComponent("index.json") }
    func folder(_ id: UInt32) -> URL {
        let u = AppPaths.library.appendingPathComponent(String(id))
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func audioURL(_ id: UInt32) -> URL { folder(id).appendingPathComponent("audio.ogg") }
    private func transcriptURL(_ id: UInt32) -> URL { folder(id).appendingPathComponent("transcript.json") }

    init(device: DeviceController, settings: Settings) {
        self.device = device
        self.settings = settings
        load()
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

    /// 删除本机副本（不动设备上的录音）
    func deleteLocal(_ id: UInt32) {
        try? FileManager.default.removeItem(at: folder(id))
        transcripts[id] = nil
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
        guard case .idle = device.activity else { return }
        await refreshDeviceList()
        let pending = recordings.filter { r in
            r.onDevice && !r.downloaded && r.durationMs > 0 && (ids?.contains(r.id) ?? !r.isDictation)
        }.sorted { $0.durationMs < $1.durationMs }
        guard !pending.isEmpty else { sync = .idle; return }
        guard device.beginSync(), let s = device.session else { return }
        defer { device.endSync() }
        Log.write("同步 \(pending.count) 条录音 recorder=\(DeviceController.field(device.battery))")
        for (n, r) in pending.enumerated() {
            if device.syncShouldYield { pauseForDictation(); return }
            sync = .downloading(id: r.id, done: n, total: pending.count, fraction: 0, kbps: 0)
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
                    }
                }
                if device.syncShouldYield { pauseForDictation(); return }
                guard t.decrypted, Double(t.audio.count) >= Double(file.audioBytes) * 0.95 || t.gotDone else {
                    Log.write("下载不完整 \(r.id)：\(t.audio.count)/\(file.audioBytes)")
                    continue
                }
                try saveAudio(t.audio, id: r.id)
                Log.write("已下载 \(r.id)（\(t.audio.count / 1024) KB，\(Int(t.seconds)) 秒）")
                if settings.autoTranscribe { Task { await transcribe(r.id) } }
            } catch {
                sync = .failed("\(error)")
                return
            }
        }
        sync = .idle
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
        let result: Result<[TranscriptSegment], Error> = await withCheckedContinuation { c in
            work.async {
                c.resume(returning: Result {
                    try FileTranscriber.transcribe(url: url, models: models) { p in
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
        case let .failure(e):
            Log.write("转写失败 \(id)：\(e)")
        }
    }

    // MARK: 导出

    func markdown(_ id: UInt32) -> String {
        guard let r = recordings.first(where: { $0.id == id }) else { return "" }
        var s = "# \(r.displayTitle)\n\n"
        s += "\(r.start.formatted(date: .long, time: .shortened)) · \(Self.clock(r.duration))\n\n"
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

/// 离线转写一个音频文件：解码 → 16 kHz → VAD 切句 → SenseVoice
enum FileTranscriber {
    static func transcribe(url: URL, models: URL, progress: (Double) -> Void) throws -> [TranscriptSegment] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { throw VoiceError.initFailed("converter") }
        let recognizer = try SentenceRecognizer(modelsDir: models, minSilence: 0.6)
        var out: [TranscriptSegment] = []
        let chunk: AVAudioFrameCount = 48000
        let total = max(Double(file.length), 1)
        var done = false
        while !done, file.framePosition < file.length {
            let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
            // Ogg Opus 的 length 是估算值，读到末尾时 AVAudioFile 会抛 eofErr（-39），当作读完
            do {
                try file.read(into: inBuf, frameCount: chunk)
            } catch let e as NSError where e.domain == NSOSStatusErrorDomain && e.code == -39 {
                done = true
            }
            if inBuf.frameLength == 0 { break }
            let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk / 3 + 64)!
            var fed = false
            conv.convert(to: outBuf, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return inBuf
            }
            let samples = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            out += recognizer.accept(samples).map(seg)
            progress(Double(file.framePosition) / total)
        }
        out += recognizer.flush().map(seg)
        return out.filter { !$0.text.isEmpty }
    }

    private static func seg(_ s: SentenceRecognizer.Sentence) -> TranscriptSegment {
        TranscriptSegment(start: s.start, end: s.end, text: s.text)
    }
}
