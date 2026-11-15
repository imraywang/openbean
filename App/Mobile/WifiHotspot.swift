// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Network
import NetworkExtension
import OpenBeanKit
import UIKit

// 经 Wi‑Fi 同步的 iOS 部分（流程本身两端共用：OpenBeanKit 的 WifiSyncFlow；Mac 的部分在 App/OpenBean/WifiSync.swift）。
//
// 加入热点：NEHotspotConfiguration，joinOnce（不存进系统的网络列表）。系统第一次会弹「加入网络」的确认。
// 按苹果文档，joinOnce 的热点在这些情况下会被系统断开、配置删掉：App 在后台超过 15 秒、设备睡眠、App 退出 / 崩溃、
// 用户或别的 App 连了别的 Wi‑Fi。所以：
// - 只在前台由用户发起（后台自动同步一律走蓝牙；apply 在后台会报 applicationIsNotInForeground）
// - 传输期间不让屏幕自动锁（isIdleTimerDisabled），免得设备睡眠把热点断掉
// - App 切到后台或锁屏：马上停下当前文件（已收的片留在临时文件里），申请一点后台时间收尾、离开热点，
//   剩下的交给蓝牙续传（录音豆关热点后蓝牙重连，自动同步按连续前缀带 offset 接着下）。
//   不尝试「做完当前文件」：一个几小时的文件经 Wi‑Fi 也要一两分钟，远超 15 秒
//
// 加入后的确认：apply 成功不等于已经连上（苹果文档原话），所以再看 Wi‑Fi 接口（en0）有没有拿到和设备同网段的地址；
// 再用 Network 框架只走 Wi‑Fi 地连一下设备端口：第一次会弹「本地网络」权限，用户没点之前系统可能先拒绝，这里等着它
//（权限一给，连接自己就通了）；最后真的拒绝了就报 localNetworkDenied。
// 走 Wi‑Fi 而不是蜂窝：设备地址在热点子网里，内核路由本来就走 Wi‑Fi；WifiExport 在 iOS 上另外禁止了蜂窝
// （URLSession allowsCellularAccess = false，UDP 保活 requiredInterfaceType = .wifi）。

@MainActor
enum WifiPlatform {
    static func makeJoiner() -> HotspotJoining { IOSHotspotJoiner() }

    /// 第一次可能要等「本地网络」权限弹窗，WebSocket 多试几次
    static let connectAttempts = 5

    /// 离开热点后在界面上等蓝牙连回来（最多 `bluetoothWait` 秒），并记下用时
    static let waitsForBluetooth = true
    static let bluetoothWait: Double = 60

    static func text(_ step: WifiSyncStep, heart: Bool) -> String {
        switch step {
        case .openingHotspot:
            return heart ? String(localized: "Asking the Heart bean to start its Wi‑Fi…")
                         : String(localized: "Asking the recorder to start its Wi‑Fi…")
        case .joining:
            return heart ? String(localized: "Joining the Heart bean's Wi‑Fi…")
                         : String(localized: "Joining the recorder's Wi‑Fi…")
        case .connecting:
            return heart ? String(localized: "Connecting to the Heart bean over Wi‑Fi…")
                         : String(localized: "Connecting to the recorder over Wi‑Fi…")
        case let .downloading(n, count, pct):
            return String(localized: "Downloading \(n + 1) of \(count) over Wi‑Fi… \(pct)%")
        case .leaving:
            return String(localized: "Leaving the Wi‑Fi…")
        case .waitingForBluetooth:
            return heart ? String(localized: "Reconnecting to the Heart bean over Bluetooth…")
                         : String(localized: "Reconnecting to the recorder over Bluetooth…")
        }
    }

    static func failureText(_ error: Error, heart: Bool) -> String {
        switch error as? WifiSyncError {
        case .userDenied:
            return String(localized: "Wi‑Fi sync was cancelled. Bluetooth sync picks up from where it stopped.")
        case .localNetworkDenied:
            return String(localized: "OpenBean needs Local Network access for Wi‑Fi sync. Turn it on in Settings › Privacy & Security › Local Network.")
        case .cancelled:
            return String(localized: "Wi‑Fi sync stopped because OpenBean left the screen. What was received is kept; Bluetooth continues from there.")
        case .dropped:
            return String(localized: "The Wi‑Fi connection dropped. What was received is kept; Bluetooth continues from there.")
        case .notOnHotspot, .joinFailed, .unreachable:
            return heart ? String(localized: "Couldn't connect to the Heart bean's Wi‑Fi. Bluetooth sync picks up from where it stopped.")
                         : String(localized: "Couldn't connect to the recorder's Wi‑Fi. Bluetooth sync picks up from where it stopped.")
        case .noAddress, nil:
            return heart ? String(localized: "The Heart bean didn't start its Wi‑Fi. Try again, or keep syncing over Bluetooth.")
                         : String(localized: "The recorder didn't start its Wi‑Fi. Try again, or keep syncing over Bluetooth.")
        }
    }

    /// 传输期间：屏幕不自动锁；App 切到后台（含锁屏）时调用 `onCancel`，并申请后台时间收尾（离开热点）。
    /// 返回结束时调用的闭包
    static func hold(onCancel: @escaping () -> Void) -> () -> Void {
        let app = UIApplication.shared
        let idleBefore = app.isIdleTimerDisabled
        app.isIdleTimerDisabled = true
        var task: UIBackgroundTaskIdentifier = .invalid
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Log.write("Wi‑Fi 同步：App 进入后台，停下当前文件（已收的留着），收尾后交给蓝牙")
                if task == .invalid {
                    task = app.beginBackgroundTask(withName: "Wi‑Fi sync wrap-up") {
                        Log.write("Wi‑Fi 同步：后台时间用完")
                        app.endBackgroundTask(task)
                        task = .invalid
                    }
                }
                onCancel()
            }
        }
        return {
            NotificationCenter.default.removeObserver(observer)
            app.isIdleTimerDisabled = idleBefore
            if task != .invalid {
                Log.write(String(format: "Wi‑Fi 同步：后台收尾完成（后台时间还剩 %.0f 秒）", min(app.backgroundTimeRemaining, 9999)))
                app.endBackgroundTask(task)
                task = .invalid
            }
        }
    }
}

/// iOS 加入 / 离开录音豆的热点
final class IOSHotspotJoiner: HotspotJoining, @unchecked Sendable {
    /// 等系统的「加入网络」弹窗和加入结果最多多久（用户要读弹窗）
    static let applyTimeout: Double = 90
    /// apply 成功后等 Wi‑Fi 接口拿到热点地址最多多久
    static let addressTimeout: Double = 20
    /// 只走 Wi‑Fi 地连设备端口最多等多久（含「本地网络」权限弹窗）
    static let probeTimeout: Double = 60

    private var monitor: NWPathMonitor?

    func join(ssid: String, password: String, device: SoftAPEndpoint) async throws {
        let before = Self.wifiAddress()
        Log.write("Wi‑Fi 同步：加入热点前 Wi‑Fi 地址 \(before ?? "无")")
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        config.joinOnce = true
        let t0 = Date()
        do {
            try await Self.withTimeout(Self.applyTimeout) {
                try await NEHotspotConfigurationManager.shared.apply(config)
            }
            Log.write(String(format: "Wi‑Fi 同步：系统加入热点：成功（%.1f 秒）", Date().timeIntervalSince(t0)))
        } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain {
            let code = NEHotspotConfigurationError(rawValue: e.code)
            Log.write(String(format: "Wi‑Fi 同步：系统加入热点：错误 %d（%@，%.1f 秒）", e.code, e.localizedDescription, Date().timeIntervalSince(t0)))
            switch code {
            case .alreadyAssociated: break
            case .userDenied: throw WifiSyncError.userDenied
            case .applicationIsNotInForeground: throw WifiSyncError.cancelled
            default: throw WifiSyncError.joinFailed(e.localizedDescription)
            }
        } catch is TimeoutError {
            Log.write(String(format: "Wi‑Fi 同步：系统加入热点 %.0f 秒没有结果", Self.applyTimeout))
            throw WifiSyncError.joinFailed("timeout")
        }

        // apply 成功不等于连上了：等 Wi‑Fi 接口拿到和设备同网段的地址
        let ta = Date()
        var addr: String?
        while Date().timeIntervalSince(ta) < Self.addressTimeout {
            addr = Self.wifiAddress()
            if let a = addr, Self.sameSubnet(a, device.ip) { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let current = await NEHotspotNetwork.fetchCurrent()
        let ssidNow = current?.ssid ?? "（读不到）"
        guard let a = addr, Self.sameSubnet(a, device.ip) else {
            Log.write(String(format: "Wi‑Fi 同步：%.0f 秒内没拿到热点地址（Wi‑Fi 地址 %@，当前网络 %@）", Self.addressTimeout, addr ?? "无", ssidNow))
            throw WifiSyncError.notOnHotspot
        }
        Log.write(String(format: "Wi‑Fi 同步：Wi‑Fi 地址 %@（%.1f 秒），当前网络 %@", a, Date().timeIntervalSince(ta), ssidNow))
        startMonitor()
        try await probe(device)
    }

    /// 只走 Wi‑Fi 地连一下设备端口：确认路由走 Wi‑Fi、本地网络权限给了
    private func probe(_ device: SoftAPEndpoint) async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: device.port)) else { throw WifiSyncError.unreachable }
        let conn = NWConnection(host: NWEndpoint.Host(device.ip), port: port, using: params)
        let t0 = Date()
        let box = ProbeState()
        conn.stateUpdateHandler = { st in box.update(st, path: conn.currentPath) }
        conn.start(queue: .global())
        defer { conn.stateUpdateHandler = nil; conn.cancel() }
        var said = ""
        while Date().timeIntervalSince(t0) < Self.probeTimeout {
            let (ready, note, denied, failed) = box.snapshot()
            if note != said { said = note; Log.write("Wi‑Fi 同步：连设备 \(device)：\(note)") }
            if ready {
                Log.write(String(format: "Wi‑Fi 同步：设备 %@ 经 Wi‑Fi 可达（%.1f 秒）", device.description, Date().timeIntervalSince(t0)))
                return
            }
            if failed { throw denied ? WifiSyncError.localNetworkDenied : WifiSyncError.unreachable }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let denied = box.snapshot().denied
        Log.write(String(format: "Wi‑Fi 同步：%.0f 秒连不上设备%@", Self.probeTimeout, denied ? "（本地网络权限被拒）" : ""))
        throw denied ? WifiSyncError.localNetworkDenied : WifiSyncError.unreachable
    }

    private final class ProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false, failed = false, denied = false, note = "开始"
        func update(_ st: NWConnection.State, path: Network.NWPath?) {
            lock.lock(); defer { lock.unlock() }
            let ifc = path?.availableInterfaces.map(\.name).joined(separator: ",") ?? "?"
            switch st {
            case .ready: ready = true; note = "已连上（接口 \(ifc)）"
            case let .waiting(e):
                denied = path?.unsatisfiedReason == .localNetworkDenied
                note = denied ? "在等本地网络权限（\(e)）" : "在等（\(e)，接口 \(ifc)）"
            case let .failed(e):
                failed = true
                denied = denied || path?.unsatisfiedReason == .localNetworkDenied
                note = "失败（\(e)）"
            case .preparing: note = "连接中"
            default: break
            }
        }
        func snapshot() -> (ready: Bool, note: String, denied: Bool, failed: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (ready, note, denied, failed)
        }
    }

    /// 传输期间 Wi‑Fi 路径变了就记一笔（iOS 判定「无互联网」后是否离开热点，看这几行）
    private func startMonitor() {
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        var last = ""
        m.pathUpdateHandler = { p in
            let s = "\(p.status)\(p.isExpensive ? " expensive" : "")\(p.isConstrained ? " constrained" : "")"
                + " 地址 \(IOSHotspotJoiner.wifiAddress() ?? "无")"
            guard s != last else { return }
            last = s
            Log.write("Wi‑Fi 同步：Wi‑Fi 路径 \(s)")
        }
        m.start(queue: DispatchQueue(label: "openbean.wifi.monitor"))
        monitor = m
    }

    func leave(ssid: String, device: SoftAPEndpoint) async {
        monitor?.cancel()
        monitor = nil
        // joinOnce 的配置：删掉配置就会断开这个热点，系统自己回到原来的网络
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        let t0 = Date()
        var addr = Self.wifiAddress()
        while Date().timeIntervalSince(t0) < 15, let a = addr, Self.sameSubnet(a, device.ip) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            addr = Self.wifiAddress()
        }
        Log.write(String(format: "Wi‑Fi 同步：删掉热点配置 %.1f 秒后 Wi‑Fi 地址 %@", Date().timeIntervalSince(t0), addr ?? "无"))
    }

    // MARK: 工具

    struct TimeoutError: Error {}

    static func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await body() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    /// Wi‑Fi 接口（iPhone 上是 en0）的 IPv4 地址
    nonisolated static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let start = list else { return nil }
        defer { freeifaddrs(start) }
        for i in sequence(first: start, next: { $0.pointee.ifa_next }) {
            guard String(cString: i.pointee.ifa_name) == "en0", let sa = i.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    static func sameSubnet(_ a: String, _ b: String) -> Bool {
        Array(a.split(separator: ".").prefix(3)) == Array(b.split(separator: ".").prefix(3))
    }
}
