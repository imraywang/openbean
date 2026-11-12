// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OpenBeanKit

/// 保持和录音豆的连接：启动时连上，断了自动重连；把设备事件转给听写；
/// 仲裁谁在用连接（听写和同步录音都要独占传输通道，听写优先）。
@MainActor @Observable
final class DeviceController {
    enum State: Equatable {
        case idle, searching, connecting, ready
        case failed(String)
    }

    enum Activity: Equatable {
        case idle, dictating, syncing
    }

    private(set) var state: State = .idle
    private(set) var info: DeviceInfo?
    private(set) var battery: Int?
    private(set) var deviceName = "soundcore Work"
    private(set) var activity: Activity = .idle
    /// 听写要用连接时置位，正在进行的同步看到后尽快让出
    private(set) var syncShouldYield = false
    let link = Link()
    private(set) var session: D3200Session?
    /// 设备事件（主线程）
    var onEvent: (DeviceEvent) -> Void = { _ in }
    /// 刚连上（每次连上都会调用）
    var onConnected: () -> Void = {}
    private var loop: Task<Void, Never>?
    private var poller: Task<Void, Never>?

    private let lastDeviceFile = AppPaths.support.appendingPathComponent("last-device.txt")

    var isReady: Bool { state == .ready && session != nil }

    func start() {
        guard loop == nil else { return }
        link.sync {
            link.onDisconnect = { [weak self] in
                Task { @MainActor in self?.lostConnection() }
            }
        }
        loop = Task { await connectLoop() }
    }

    /// 忘掉这台设备：下次重新扫描
    func forget() {
        try? FileManager.default.removeItem(at: lastDeviceFile)
        link.disconnect()
    }

    private func lostConnection() {
        Log.write("连接断开，准备重连")
        session = nil
        state = .searching
        activity = .idle
        loop?.cancel()
        loop = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await connectLoop()
        }
    }

    private func connectLoop() async {
        var delay: UInt64 = 2
        while !Task.isCancelled {
            do {
                // 蓝牙状态偶尔迟迟不回报，也要一直重试，不能放弃
                try await link.waitPoweredOn()
                try await connectOnce()
                Log.write("已连接录音豆")
                return
            } catch {
                state = .failed("\(error)")
                Log.write("连接失败（\(delay) 秒后重试）：\(error)")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    private func connectOnce() async throws {
        state = .searching
        var target = (try? String(contentsOf: lastDeviceFile, encoding: .utf8))
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { link.retrieve($0) }
        if let p = target {
            state = .connecting
            Log.write("按上次的设备直连")
            do { try await link.connect(p, timeout: 8) } catch {
                Log.write("直连失败：\(error)，改为扫描")
                target = nil
            }
        }
        if target == nil {
            guard let d = await link.scan(seconds: 6).first(where: \.serviceMatch) else {
                throw LinkError.missing(String(localized: "recorder. Take it out of the case or press the case button to wake it."))
            }
            state = .connecting
            try await link.connect(d.peripheral)
            if !d.name.isEmpty { deviceName = d.name }
            try? d.peripheral.identifier.uuidString.write(to: lastDeviceFile, atomically: true, encoding: .utf8)
        }
        let s = D3200Session(link: link)
        info = try await s.deviceInfo()
        battery = info?.micBattery
        try await s.handshake()
        try? await s.syncTime()
        s.observeEvents { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
        session = s
        state = .ready
        startPolling()
        onConnected()
    }

    private func handle(_ e: DeviceEvent) {
        if case let .battery(r, _) = e { battery = r }
        onEvent(e)
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if activity == .idle { await refreshInfo() }
            }
        }
    }

    func refreshInfo() async {
        guard let s = session, activity == .idle else { return }
        if let i = try? await s.deviceInfo() { info = i; battery = i.micBattery }
    }

    // MARK: 连接仲裁

    /// 听写开始：同步要让出连接
    func beginDictation() async {
        if activity == .syncing {
            syncShouldYield = true
            Log.write("听写开始，暂停同步")
            for _ in 0..<40 where activity == .syncing { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        activity = .dictating
    }

    func endDictation() {
        activity = .idle
        syncShouldYield = false
    }

    /// 同步开始；正在听写时返回 false
    func beginSync() -> Bool {
        guard isReady, activity == .idle else { return false }
        activity = .syncing
        syncShouldYield = false
        return true
    }

    func endSync() {
        if activity == .syncing { activity = .idle }
    }

    func startRecording() async {
        try? await session?.startRecording()
    }

    func pauseRecording() async {
        try? await session?.pauseRecording()
    }
}
