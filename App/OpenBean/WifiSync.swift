// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanKit

// 经录音豆自己的 Wi‑Fi 热点批量下载（约 1.5 MB/s）。流程两端共用（OpenBeanKit 的 WifiSyncFlow，热点名和密码也在那里），
// 这里是 Mac 的部分：Mac 会临时加入设备热点、断网约一分钟，结束后关开 Wi‑Fi 让系统自动连回原来的网络。
// 设备开热点后蓝牙会断开，结束后 DeviceController 会自动重连。

/// LibraryStore.syncViaWifi 里按平台不同的部分（iOS 版见 App/Mobile/WifiHotspot.swift）
@MainActor
enum WifiPlatform {
    static func makeJoiner() -> HotspotJoining { MacHotspotJoiner() }

    static let connectAttempts = 3

    /// Mac 不等蓝牙重连（界面和原来一样），只在日志里记重连用时
    static let waitsForBluetooth = false

    /// 文案和拆分前完全相同（Mac 一直叫 recorder）
    static func text(_ step: WifiSyncStep, heart: Bool) -> String {
        switch step {
        case .openingHotspot:
            return String(localized: "Asking the recorder to start its Wi‑Fi…")
        case .joining, .connecting:
            return String(localized: "Joining the recorder's Wi‑Fi (your Mac is offline for a moment)…")
        case let .downloading(n, count, pct):
            return String(localized: "Downloading \(n + 1) of \(count) over Wi‑Fi… \(pct)%")
        case .leaving, .waitingForBluetooth:
            return String(localized: "Reconnecting to your usual network…")
        }
    }

    static func failureText(_ error: Error, heart: Bool) -> String { "\(error)" }

    /// 下载期间不让 Mac 空闲睡眠；返回结束时调用的闭包（Mac 没有「要停」的情况）
    static func hold(onCancel: @escaping () -> Void) -> () -> Void {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Downloading recordings over Wi‑Fi")
        return { ProcessInfo.processInfo.endActivity(activity) }
    }
}

/// Mac 加入 / 离开设备热点：networksetup 加入，结束后删掉这个网络、关开 Wi‑Fi 让系统连回原来的网络
final class MacHotspotJoiner: HotspotJoining {
    private let ifc = MacHotspotJoiner.wifiInterface()

    func join(ssid: String, password: String, device: SoftAPEndpoint) async throws {
        for _ in 1...4 {
            Self.sh("/usr/sbin/networksetup", ["-setairportnetwork", ifc, ssid, password])
            for _ in 0..<20 {
                if let a = Self.ip(ifc), Self.sameSubnet(a, device.ip) { return }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw LinkError.timeout("Wi‑Fi")
    }

    func leave(ssid: String, device: SoftAPEndpoint) async {
        Self.sh("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", ifc, ssid])
        Self.sh("/usr/sbin/networksetup", ["-setairportpower", ifc, "off"])
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        Self.sh("/usr/sbin/networksetup", ["-setairportpower", ifc, "on"])
        for _ in 0..<45 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let a = Self.ip(ifc), !Self.sameSubnet(a, device.ip), !a.hasPrefix("169.254") { return }
        }
    }

    @discardableResult
    private static func sh(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func wifiInterface() -> String {
        let out = sh("/usr/sbin/networksetup", ["-listallhardwareports"]).components(separatedBy: "\n")
        for (i, line) in out.enumerated() where line.contains("Wi-Fi") && i + 1 < out.count {
            if let dev = out[i + 1].components(separatedBy: "Device: ").last?.trimmingCharacters(in: .whitespaces), !dev.isEmpty {
                return dev
            }
        }
        return "en0"
    }

    private static func ip(_ ifc: String) -> String? {
        let s = sh("/usr/sbin/ipconfig", ["getifaddr", ifc]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func sameSubnet(_ a: String, _ b: String) -> Bool {
        Array(a.split(separator: ".").prefix(3)) == Array(b.split(separator: ".").prefix(3))
    }
}
