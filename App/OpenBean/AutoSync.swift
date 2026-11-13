// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanKit

/// 自动同步（只走蓝牙，从不自动开 Wi‑Fi：那会让 Mac 断网）。
///
/// 触发：读到设备文件列表、发现有没下载的录音（连上时和每次刷新列表后）；录音豆放回充电盒（01/04 录音豆在充电）。
/// 不触发：正在语音输入或同步、录音豆正在录音（包括只录音）。
/// 防抖：触发后等 3 秒再开始，期间的重复触发合并成一次；同一时间只跑一次。
/// 失败（同步报错、或跑完仍有没下下来的）后退避：1、2、4…最多 30 分钟后再试，成功一次就清零。
@MainActor
final class AutoSync {
    private let device: DeviceController
    private let library: LibraryStore
    private let settings: Settings

    /// 从设备事件得知录音豆在录音（含只录音）；开始自动同步前还会读一次设备信息确认
    private var recorderRecording = false
    private var pending: Task<Void, Never>?
    private var running = false
    private var failures = 0
    private var notBefore = Date.distantPast

    static let debounce: TimeInterval = 3

    init(device: DeviceController, library: LibraryStore, settings: Settings) {
        self.device = device
        self.library = library
        self.settings = settings
    }

    /// 失败后等多久再试：60 秒起翻倍，最多 30 分钟
    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(60 * pow(2, Double(failures - 1)), 1800)
    }

    // MARK: 触发

    func handle(_ e: DeviceEvent) {
        switch e {
        case .recordingStarted:
            recorderRecording = true
            pending?.cancel()
        case .recordingStopped:
            recorderRecording = false
        case let .charging(recorder, _) where recorder:
            schedule("录音豆放回充电盒", refresh: true)
        default:
            break
        }
    }

    /// 读到了设备文件列表（LibraryStore 回调）
    func listRefreshed() {
        // 自己跑的同步里也会刷新列表，不能再触发自己
        guard !running, !library.pendingDownloads().isEmpty else { return }
        schedule("有 \(library.pendingDownloads().count) 条新录音", refresh: false)
    }

    private func schedule(_ reason: String, refresh: Bool, after delay: TimeInterval = debounce) {
        guard settings.autoSync else { Log.write("自动同步（\(reason)）：设置里关着，不同步"); return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.run(reason, refresh: refresh)
        }
    }

    // MARK: 执行

    private func run(_ reason: String, refresh: Bool) async {
        // 触发了却没跑，写一行原因：排查时分得清是没触发、忙、还是没东西可下
        if let busy = Self.busyReason(autoSync: settings.autoSync, running: running, syncRunning: library.syncRunning,
                                      ready: device.isReady, activity: device.activity) {
            Log.write("自动同步（\(reason)）：\(busy)，这次不同步")
            return
        }
        let wait = notBefore.timeIntervalSinceNow
        if wait > 0 {
            // 退避中：到点再试一次，不在这之前反复重试
            Log.write("自动同步（\(reason)）：上次没完成，\(Int(wait.rounded())) 秒后再试")
            schedule(reason, refresh: true, after: wait)
            return
        }
        running = true
        defer { running = false }

        // 用最新的设备信息确认没在录音（只录音时没有听写在占连接，只能靠这个）
        await device.refreshInfo()
        if let r = device.info?.recording { recorderRecording = r }
        if recorderRecording {
            Log.write("自动同步（\(reason)）：录音豆正在录音，先不同步")
            return
        }
        if refresh { await library.refreshDeviceList() }
        let before = Set(library.pendingDownloads().map(\.id))
        if before.isEmpty {
            Log.write("自动同步（\(reason)）：没有要下载的录音")
            return
        }
        if let busy = Self.busyReason(autoSync: true, running: false, syncRunning: library.syncRunning,
                                      ready: device.isReady, activity: device.activity) {
            Log.write("自动同步（\(reason)）：\(busy)，这次不同步")
            return
        }

        Log.write("自动同步（\(reason)）：\(before.count) 条")
        await library.syncAll()

        // 让给了语音输入：听写结束后 LibraryStore 自己会接着同步，不算失败
        if library.sync == .paused || device.activity == .dictating { return }
        let left = before.intersection(library.pendingDownloads().map(\.id))
        if case .failed = library.sync {
            failed("同步出错")
        } else if !left.isEmpty {
            failed("还有 \(left.count) 条没下载完")
        } else {
            failures = 0
            notBefore = .distantPast
        }
    }

    /// 现在不能跑自动同步的原因；nil = 可以跑
    static func busyReason(autoSync: Bool, running: Bool, syncRunning: Bool, ready: Bool,
                           activity: DeviceController.Activity) -> String? {
        if !autoSync { return "设置里关着" }
        if running { return "上一次自动同步还在跑" }
        if syncRunning { return "正在同步" }
        if !ready { return "录音豆没连上" }
        switch activity {
        case .idle: return nil
        case .dictating: return "正在语音输入"
        case .syncing: return "连接正忙（同步或删除）"
        }
    }

    private func failed(_ why: String) {
        failures += 1
        let wait = Self.backoff(failures: failures)
        notBefore = Date().addingTimeInterval(wait)
        Log.write("自动同步没完成（\(why)），\(Int(wait)) 秒后再试")
        schedule("重试", refresh: true, after: wait)
    }
}
