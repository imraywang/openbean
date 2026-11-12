// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OpenBeanKit

/// 保持和录音豆的连接：启动时连上，断了自动重连；把设备事件转给听写。
@available(macOS 26.0, *)
@MainActor @Observable
final class DeviceController {
    enum State: Equatable {
        case idle, searching, connecting, ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var info: DeviceInfo?
    private(set) var battery: Int?
    let link = Link()
    private(set) var session: D3200Session?
    /// 设备事件（主线程）
    var onEvent: (DeviceEvent) -> Void = { _ in }
    private var loop: Task<Void, Never>?

    private let lastDeviceFile = AppPaths.support.appendingPathComponent("last-device.txt")

    func start() {
        guard loop == nil else { return }
        link.sync {
            link.onDisconnect = { [weak self] in
                Task { @MainActor in self?.lostConnection() }
            }
        }
        loop = Task { await connectLoop() }
    }

    private func lostConnection() {
        Log.write("连接断开，准备重连")
        session = nil
        state = .searching
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
            do { try await link.connect(p, timeout: 12) } catch {
                Log.write("直连失败：\(error)，改为扫描")
                target = nil
            }
        }
        if target == nil {
            guard let d = await link.scan(seconds: 6).first(where: \.serviceMatch) else {
                throw LinkError.missing("录音豆（把它从充电盒拿出来或按一下盒子按钮唤醒）")
            }
            state = .connecting
            try await link.connect(d.peripheral)
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
    }

    private func handle(_ e: DeviceEvent) {
        if case let .battery(r, _) = e { battery = r }
        onEvent(e)
    }

    func refreshInfo() async {
        guard let s = session else { return }
        if let i = try? await s.deviceInfo() { info = i; battery = i.micBattery }
    }
}
