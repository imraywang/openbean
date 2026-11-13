// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import Speech

/// 语音模型：SenseVoice（每句定稿/文件转写）、Silero VAD（切句）、Apple 中文听写资源（灰字）
@MainActor @Observable
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case checking, missing, downloading(Double), ready
        case failed(String)
    }

    private(set) var state: State = .checking
    private(set) var appleReady = false

    private struct Item { let url: String; let path: String; let bytes: Int64 }
    private let items = [
        Item(url: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx",
             path: "sensevoice/model.int8.onnx", bytes: 239_233_841),
        Item(url: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt",
             path: "sensevoice/tokens.txt", bytes: 315_894),
        Item(url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
             path: "vad/silero_vad.onnx", bytes: 643_854),
    ]
    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    private var doneBytes: Int64 = 0
    private var current: CheckedContinuation<URL, Error>?
    /// 下载完成后通知（重新加载识别器）
    var onReady: () -> Void = {}

    #if DEMO || DEBUG
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
        Task { await checkApple() }
    }

    func checkApple() async {
        let zh = Locale(identifier: "zh_CN")
        let installed = await DictationTranscriber.installedLocales.contains { $0.identifier.hasPrefix("zh") }
        let supported = await DictationTranscriber.supportedLocale(equivalentTo: zh) != nil
        appleReady = installed || !supported
    }

    func download() async {
        guard state != .ready else { return }
        doneBytes = 0
        state = .downloading(0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            for item in items {
                let dest = AppPaths.models.appendingPathComponent(item.path)
                if FileManager.default.fileExists(atPath: dest.path) { doneBytes += item.bytes; continue }
                let tmp: URL = try await withCheckedThrowingContinuation { c in
                    current = c
                    session.downloadTask(with: URL(string: item.url)!).resume()
                }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                doneBytes += item.bytes
            }
            await installApple()
            state = .ready
            onReady()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Apple 设备端中文听写资源（灰字用）
    func installApple() async {
        guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else { return }
        let t = DictationTranscriber(locale: loc, preset: .progressiveShortDictation)
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await req.downloadAndInstall()
        }
        await checkApple()
    }

    // MARK: URLSessionDownloadDelegate

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        Task { @MainActor in
            state = .downloading(Double(doneBytes + totalBytesWritten) / Double(totalBytes))
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
