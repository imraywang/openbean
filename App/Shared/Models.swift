// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OpenBeanVoice
#if os(macOS)
import Speech
#endif

/// 语音模型：SenseVoice（每句定稿/文件转写）、Silero VAD（切句）、Apple 中文听写资源（灰字）
@MainActor @Observable
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case checking, missing, downloading(Double), ready
        case failed(String)
    }

    private(set) var state: State = .checking
    private(set) var appleReady = false

    struct Item { let url: String; let path: String; let bytes: Int64 }
    private let items = [
        Item(url: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx",
             path: "sensevoice/model.int8.onnx", bytes: 239_233_841),
        Item(url: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt",
             path: "sensevoice/tokens.txt", bytes: 315_894),
        Item(url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
             path: "vad/silero_vad.onnx", bytes: 643_854),
    ]
    /// 一个文件依次尝试的下载地址：原地址，然后是镜像（只有 HuggingFace 的文件有镜像）
    nonisolated static func sources(for url: String) -> [String] {
        let hf = "https://huggingface.co/"
        return url.hasPrefix(hf) ? [url, "https://hf-mirror.com/" + url.dropFirst(hf.count)] : [url]
    }

    /// 全部模型文件的大小（下载量）
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    /// 已经在磁盘上的大小
    var installedBytes: Int64 {
        items.reduce(0) { sum, item in
            let size = (try? FileManager.default.attributesOfItem(atPath: AppPaths.models.appendingPathComponent(item.path).path)[.size]
                        as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }
    private var doneBytes: Int64 = 0
    private var current: CheckedContinuation<URL, Error>?
    /// 下载完成后通知（重新加载识别器）
    var onReady: () -> Void = {}

    #if DEMO || DEBUG || os(iOS)
    /// 演示版、预览：不看磁盘，直接摆出模型状态
    func demoSet(_ s: State) {
        state = s
        appleReady = true
    }
    #endif

    func check() {
        let fm = FileManager.default
        let ok = items.allSatisfy { fm.fileExists(atPath: AppPaths.models.appendingPathComponent($0.path).path) }
        state = ok ? .ready : .missing
        checkSpeaker()
        Task { await checkApple() }
    }

    func checkApple() async {
        #if os(macOS)
        let zh = Locale(identifier: "zh_CN")
        let installed = await DictationTranscriber.installedLocales.contains { $0.identifier.hasPrefix("zh") }
        let supported = await DictationTranscriber.supportedLocale(equivalentTo: zh) != nil
        appleReady = installed || !supported
        #else
        appleReady = true  // iOS 版没有语音输入，不用灰字资源
        #endif
    }

    /// - wifiOnly：不用蜂窝网络（iOS 设置里「仅 Wi‑Fi 下载」）；Mac 不传
    func download(wifiOnly: Bool = false) async {
        guard state != .ready else { return }
        // 两个下载共用一个会话代理：声纹模型正在下就等它
        while fetchingSpeaker { try? await Task.sleep(nanoseconds: 500_000_000) }
        doneBytes = 0
        state = .downloading(0)
        let cfg = URLSessionConfiguration.default
        if wifiOnly {
            cfg.allowsCellularAccess = false
            cfg.allowsExpensiveNetworkAccess = false
        }
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            for item in items {
                if FileManager.default.fileExists(atPath: AppPaths.models.appendingPathComponent(item.path).path) { doneBytes += item.bytes; continue }
                try await fetch(item, session: session)
                doneBytes += item.bytes
            }
            await installApple()
            state = .ready
            onReady()
        } catch {
            if wifiOnly, let u = error as? URLError, u.networkUnavailableReason == .cellular || u.networkUnavailableReason == .expensive {
                state = .failed(String(localized: "Connect to Wi‑Fi to download the speech model, or turn off Wi‑Fi only."))
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 下载一个文件放到模型文件夹。HuggingFace 在有些网络下连不上或一直没有数据：主地址失败（含 60 秒没有数据超时）后换镜像再试
    private func fetch(_ item: Item, session: URLSession) async throws {
        let dest = AppPaths.models.appendingPathComponent(item.path)
        var tmp: URL?
        var lastError: Error = URLError(.cannotConnectToHost)
        for address in Self.sources(for: item.url) {
            do {
                tmp = try await withCheckedThrowingContinuation { c in
                    current = c
                    session.downloadTask(with: URL(string: address)!).resume()
                }
                break
            } catch {
                lastError = error
                Log.write("语音模型下载失败（\(URL(string: address)?.host ?? "")）：\(error.localizedDescription)")
            }
        }
        guard let tmp else { throw lastError }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        #if os(iOS)
        // 模型能重新下载：不进 iCloud 备份
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        var d = dest
        try? d.setResourceValues(rv)
        #endif
    }

    // MARK: 声纹模型（「认出我的声音」才要，单独下载，不算进上面的语音模型）

    /// 3D-Speaker CAM++ zh_en advanced（Apache-2.0）：sherpa-onnx 作者在 HuggingFace 上的副本，连不上换镜像
    static let speakerItem = Item(
        url: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
        path: SpeakerEmbedder.modelPath, bytes: 28_281_164)
    private(set) var speaker: State = .checking
    /// 正在下的是声纹模型（进度回调按这个分给 speaker 还是 state）
    private var fetchingSpeaker = false

    var speakerReady: Bool { speaker == .ready }

    func checkSpeaker() {
        speaker = FileManager.default.fileExists(atPath: AppPaths.models.appendingPathComponent(Self.speakerItem.path).path) ? .ready : .missing
    }

    /// 下载声纹模型（打开「认出我的声音」时）。语音模型正在下就等它下完
    func downloadSpeaker(wifiOnly: Bool = false) async {
        checkSpeaker()
        guard speaker != .ready, !fetchingSpeaker else { return }
        while isDownloading { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        fetchingSpeaker = true
        defer { fetchingSpeaker = false }
        speaker = .downloading(0)
        let cfg = URLSessionConfiguration.default
        if wifiOnly {
            cfg.allowsCellularAccess = false
            cfg.allowsExpensiveNetworkAccess = false
        }
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await fetch(Self.speakerItem, session: session)
            speaker = .ready
            Log.write("声纹模型已下载")
        } catch {
            if wifiOnly, let u = error as? URLError, u.networkUnavailableReason == .cellular || u.networkUnavailableReason == .expensive {
                speaker = .failed(String(localized: "Connect to Wi‑Fi to download the voice model, or turn off Wi‑Fi only."))
            } else {
                speaker = .failed(error.localizedDescription)
            }
        }
    }

    /// 删掉模型文件重新下载（文件坏了、识别出错时用）
    func redownload(wifiOnly: Bool = false) async {
        guard !isDownloading else { return }
        for item in items { try? FileManager.default.removeItem(at: AppPaths.models.appendingPathComponent(item.path)) }
        state = .missing
        await download(wifiOnly: wifiOnly)
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    /// Apple 设备端中文听写资源（灰字用）
    func installApple() async {
        #if os(macOS)
        guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else { return }
        let t = DictationTranscriber(locale: loc, preset: .progressiveShortDictation)
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await req.downloadAndInstall()
        }
        #endif
        await checkApple()
    }

    // MARK: URLSessionDownloadDelegate

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        Task { @MainActor in
            if fetchingSpeaker {
                speaker = .downloading(Double(totalBytesWritten) / Double(Self.speakerItem.bytes))
            } else {
                state = .downloading(Double(doneBytes + totalBytesWritten) / Double(totalBytes))
            }
        }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 临时文件在回调返回后会被删除，先挪走
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = (try? FileManager.default.moveItem(at: location, to: keep)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        Task { @MainActor in
            if moved, status == 200 { current?.resume(returning: keep) } else {
                current?.resume(throwing: URLError(.badServerResponse))
            }
            current = nil
        }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            current?.resume(throwing: error)
            current = nil
        }
    }
}
