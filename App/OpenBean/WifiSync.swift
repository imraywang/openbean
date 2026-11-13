// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanKit

/// 经录音豆自己的 Wi‑Fi 热点批量下载（约 1.5 MB/s）。
/// Mac 会临时加入设备热点、断网约一分钟，结束后关开 Wi‑Fi 让系统自动连回原来的网络。
/// 设备开热点后蓝牙会断开，结束后 DeviceController 会自动重连。
enum WifiSync {
    static let ssid = "WiFi-openbean"
    static let password = "1762900000000"

    /// 每个文件边收边写进 `spool(id)` 给的临时文件；返回每个文件的下载结果（完整性由调用方按结果处理）
    static func run(session: D3200Session, link: Link, files: [RecordingFile],
                    spool: (UInt32) async throws -> FrameSpool,
                    status: @escaping (String) async -> Void) async throws -> [(UInt32, DownloadResult, FrameSpool)] {
        let ifc = wifiInterface()
        await status(String(localized: "Asking the recorder to start its Wi‑Fi…"))
        let ack = try await link.request(Cmd.openSoftAP(ssid: ssid, password: password), timeout: 45,
                                         label: "Wi‑Fi") { $0.type == 0x1A && $0.id == 0x05 }
        guard let ep = SoftAPEndpoint(frame: ack.raw) else { throw LinkError.missing("Wi‑Fi address") }
        Log.write("设备热点 \(ep)")
        try await Task.sleep(nanoseconds: 10_000_000_000)

        var results: [(UInt32, DownloadResult, FrameSpool)] = []
        var failure: Error?
        do {
            await status(String(localized: "Joining the recorder's Wi‑Fi (your Mac is offline for a moment)…"))
            try await join(ifc: ifc, deviceIP: ep.ip)
            let w = WifiExport(endpoint: ep, crypto: session.crypto)
            w.log = { Log.write("Wi‑Fi: \($0)") }
            try await w.connect()
            for (n, f) in files.enumerated() {
                let sp = try await spool(f.id)
                let r = try await w.download(f, spool: sp) { p in
                    let pct = p.expected > 0 ? min(100, Int(Double(p.received) / Double(p.expected) * 100)) : 0
                    await status(String(localized: "Downloading \(n + 1) of \(files.count) over Wi‑Fi… \(pct)%"))
                }
                results.append((f.id, r, sp))
            }
            await w.close()
        } catch {
            failure = error
        }
        await status(String(localized: "Reconnecting to your usual network…"))
        await restore(ifc: ifc, deviceIP: ep.ip)
        if let failure { throw failure }
        return results
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

    private static func join(ifc: String, deviceIP: String) async throws {
        for _ in 1...4 {
            sh("/usr/sbin/networksetup", ["-setairportnetwork", ifc, ssid, password])
            for _ in 0..<20 {
                if let a = ip(ifc), sameSubnet(a, deviceIP) { return }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw LinkError.timeout("Wi‑Fi")
    }

    private static func restore(ifc: String, deviceIP: String) async {
        sh("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", ifc, ssid])
        sh("/usr/sbin/networksetup", ["-setairportpower", ifc, "off"])
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        sh("/usr/sbin/networksetup", ["-setairportpower", ifc, "on"])
        for _ in 0..<45 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let a = ip(ifc), !sameSubnet(a, deviceIP), !a.hasPrefix("169.254") { return }
        }
    }
}
