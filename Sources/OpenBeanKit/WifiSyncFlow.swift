// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - 经 Wi‑Fi 同步：两端共用的流程（测试见 WifiSyncFlowTests）
//
// 让录音豆开热点（蓝牙 1A/05）→ 等它起来 → 加入热点（按平台：Mac 用系统命令，iOS 用 NEHotspotConfiguration）→
// WebSocket 连上 → 逐个文件下载进 FrameSpool（和蓝牙同一套 Downloader，边收边落盘、同样的完整性判断）→
// 收尾（FINISH + 1A/0A）→ 离开热点。录音豆开热点后蓝牙会断开，结束后 DeviceController 自己重连。
//
// 续传：Wi‑Fi 请求一律从 offset 0 开始（Wi‑Fi 上的 offset 字段没在真机上验证过，PROTOCOL.md §10），
// spool 里已有的片（蓝牙或上一次 Wi‑Fi 收的）不重写，只补缺的；Wi‑Fi 被打断时收下的片留在 spool 里，
// 之后蓝牙按连续前缀带 offset 续传（和蓝牙自己被打断时完全同一套规则：ResumePlan）。

/// 加入 / 离开设备热点（按平台各自实现）
public protocol HotspotJoining: AnyObject {
    /// 加入热点，返回时已经确认连上（拿到和设备同网段的地址）；用户拒绝、失败、超时都抛错
    func join(ssid: String, password: String, device: SoftAPEndpoint) async throws
    /// 离开热点、让系统回到原来的网络（没加入成功时也会调用：把配置清掉）
    func leave(ssid: String, device: SoftAPEndpoint) async
}

/// 热点上的文件通道（`WifiExport`；测试里用假的）
public protocol WifiTransport: AnyObject {
    func open() async throws
    func fetch(_ file: RecordingFile, spool: FrameSpool, shouldCancel: @escaping () async -> Bool,
                  progress: @escaping (DownloadProgress) async -> Void) async throws -> DownloadResult
    func close() async
}

extension WifiExport: WifiTransport {
    public func open() async throws { try await connect(attempts: connectAttempts) }
    public func fetch(_ file: RecordingFile, spool: FrameSpool, shouldCancel: @escaping () async -> Bool,
                         progress: @escaping (DownloadProgress) async -> Void) async throws -> DownloadResult {
        try await download(file, spool: spool, idle: 20, shouldCancel: shouldCancel, progress: progress)
    }
}

public enum WifiSyncError: Error, Equatable, CustomStringConvertible {
    /// 1A/05 的回包里没有地址
    case noAddress
    /// 用户在系统的「加入网络」弹窗里点了取消
    case userDenied
    /// 系统加入热点失败（带系统给的原因）
    case joinFailed(String)
    /// 系统说加入了，可等了这么久也没拿到和设备同网段的地址
    case notOnHotspot
    /// 用户没给「本地网络」权限：连不上热点上的设备
    case localNetworkDenied
    /// 加入了热点，可是连不上设备（地址、端口不通）
    case unreachable
    /// App 要停（切到后台、锁屏）
    case cancelled
    /// 下载中途 Wi‑Fi 断了（剩下的交给蓝牙）
    case dropped

    public var description: String {
        switch self {
        case .noAddress: return "no Wi‑Fi address from the recorder"
        case .userDenied: return "Joining the recorder's Wi‑Fi was cancelled"
        case let .joinFailed(why): return "couldn't join the recorder's Wi‑Fi: \(why)"
        case .notOnHotspot: return "not on the recorder's Wi‑Fi"
        case .localNetworkDenied: return "Local Network access is off"
        case .unreachable: return "the recorder's Wi‑Fi doesn't answer"
        case .cancelled: return "cancelled"
        case .dropped: return "the Wi‑Fi connection dropped"
        }
    }
}

/// 流程走到哪一步（界面按平台翻成文案）
public enum WifiSyncStep: Equatable, Sendable {
    case openingHotspot
    case joining
    case connecting
    case downloading(index: Int, count: Int, percent: Int)
    case leaving
    case waitingForBluetooth
}

public struct WifiSyncFlow {
    /// 让录音豆开的热点名和密码（两端相同；8 位以上）
    public static let defaultSSID = "WiFi-openbean"
    public static let defaultPassword = "1762900000000"

    /// 经蓝牙让录音豆开热点，返回它的地址（1A/05 回包）
    public var openHotspot: () async throws -> SoftAPEndpoint
    public var joiner: HotspotJoining
    public var makeTransport: (SoftAPEndpoint) -> WifiTransport
    public var ssid: String
    public var password: String
    /// 开热点后等多久再加入（实测约 10 秒热点才起来）
    public var settle: Double = 10
    public var log: (String) -> Void = { _ in }
    public var sleep: (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    public var now: () -> Date = Date.init

    public init(openHotspot: @escaping () async throws -> SoftAPEndpoint, joiner: HotspotJoining,
                makeTransport: @escaping (SoftAPEndpoint) -> WifiTransport, ssid: String, password: String) {
        self.openHotspot = openHotspot
        self.joiner = joiner
        self.makeTransport = makeTransport
        self.ssid = ssid
        self.password = password
    }

    /// 走到了哪一步（测试和日志用）
    public enum Stage: Equatable, Sendable {
        case opening, joining, connecting, downloading, finished
    }

    public struct Report {
        public var endpoint: SoftAPEndpoint?
        /// 每个下完（或停下）的文件：结果已经交给 `fileDone` 处理过
        public var files: [(id: UInt32, result: DownloadResult)] = []
        /// 没走完的原因（nil = 每个文件都请求过了；有没有下完看各自的结果）
        public var failure: Error?
        /// 失败时停在哪一步
        public var stage: Stage = .opening
        /// 加入了热点（离开过）
        public var joined = false
        public var joinSeconds: Double?
    }

    /// 跑一遍。`spool(id)` 给每个文件的临时文件；`fileDone` 在每个文件停下时马上调用（调用方据此保存或留着），
    /// 后面的文件出错不影响前面已经存下的。`shouldCancel` 为真时停在当前文件（已收的留在 spool 里）。
    public func run(files: [RecordingFile],
                    spool: (UInt32) async throws -> FrameSpool,
                    shouldCancel: @escaping () async -> Bool = { false },
                    step: @escaping (WifiSyncStep) async -> Void,
                    fileDone: (UInt32, DownloadResult, FrameSpool) async -> Void) async -> Report {
        var report = Report()
        await step(.openingHotspot)
        log("请求录音豆开热点（\(ssid)），\(files.count) 个文件")
        let t0 = now()
        let ep: SoftAPEndpoint
        do {
            ep = try await openHotspot()
        } catch {
            log("开热点失败：\(error)")
            report.failure = error
            return report
        }
        report.endpoint = ep
        log(String(format: "设备热点 %@（回包用了 %.1f 秒），等 %.0f 秒再加入", ep.description, now().timeIntervalSince(t0), settle))
        do { try await sleep(settle) } catch { report.failure = error; return report }

        report.stage = .joining
        await step(.joining)
        let tj = now()
        do {
            if await shouldCancel() { throw WifiSyncError.cancelled }
            try await joiner.join(ssid: ssid, password: password, device: ep)
            report.joined = true
            report.joinSeconds = now().timeIntervalSince(tj)
            log(String(format: "已加入热点，用了 %.1f 秒", report.joinSeconds!))
            try await transfer(files: files, endpoint: ep, spool: spool, shouldCancel: shouldCancel, step: step,
                               fileDone: fileDone, report: &report)
            report.stage = .finished
        } catch {
            if !report.joined { log(String(format: "加入热点失败（%.1f 秒）：%@", now().timeIntervalSince(tj), "\(error)")) }
            report.failure = error
        }
        await step(.leaving)
        let tl = now()
        await joiner.leave(ssid: ssid, device: ep)
        log(String(format: "已离开热点，用了 %.1f 秒", now().timeIntervalSince(tl)))
        return report
    }

    private func transfer(files: [RecordingFile], endpoint ep: SoftAPEndpoint,
                          spool: (UInt32) async throws -> FrameSpool,
                          shouldCancel: @escaping () async -> Bool,
                          step: @escaping (WifiSyncStep) async -> Void,
                          fileDone: (UInt32, DownloadResult, FrameSpool) async -> Void,
                          report: inout Report) async throws {
        report.stage = .connecting
        await step(.connecting)
        let w = makeTransport(ep)
        let tc = now()
        try await w.open()
        log(String(format: "WebSocket 已连上（%.1f 秒）", now().timeIntervalSince(tc)))
        report.stage = .downloading
        do {
            for (n, f) in files.enumerated() {
                if await shouldCancel() { throw WifiSyncError.cancelled }
                let sp = try await spool(f.id)
                let before = sp.count
                await step(.downloading(index: n, count: files.count, percent: 0))
                let r = try await w.fetch(f, spool: sp, shouldCancel: shouldCancel) { p in
                    let pct = p.expected > 0 ? min(100, Int(Double(p.received) / Double(p.expected) * 100)) : 0
                    await step(.downloading(index: n, count: files.count, percent: pct))
                }
                let kbps = Double(r.bytesThisAttempt) / 1024 / max(r.seconds, 0.1)
                log(String(format: "Wi‑Fi 文件 %u（%d/%d）：%@；原有 %d 片，%.0f KB/s", f.id, n + 1, files.count,
                           r.summary, before, kbps))
                report.files.append((f.id, r))
                await fileDone(f.id, r, sp)
                switch r.stop {
                case .cancelled: throw WifiSyncError.cancelled
                case .disconnected: throw WifiSyncError.dropped
                default: break
                }
            }
        } catch {
            await w.close()
            throw error
        }
        await w.close()
        log("Wi‑Fi 传输收尾（FINISH + 1A/0A）")
    }
}

// MARK: - 什么时候提示改用 Wi‑Fi、两种方式各要多久

public enum WifiAdvice {
    /// iOS：蓝牙预计还要这么久以上时提示可以改用 Wi‑Fi。比 Mac（20 分钟）低：iPhone 的蓝牙更慢（实测约 36 KB/s），
    /// 而且 Wi‑Fi 只多一次系统弹窗、不会让手机断网（Mac 会断网所以门槛高）。再低就不值得：Wi‑Fi 的固定开销约 1.5 分钟，
    /// 期间还得把 App 留在前台
    public static let suggestAfterIOS: TimeInterval = 10 * 60

    /// 两种方式的预计时间（秒）
    public struct Estimate: Equatable, Sendable {
        public let bluetooth: Double
        public let wifi: Double
    }

    /// `bluetoothBytesPerSecond`：记住的蓝牙速度；每个文件另加蓝牙的固定开销
    public static func estimate(durationsMs: [Double], bluetoothBytesPerSecond: Double) -> Estimate {
        let bytes = durationsMs.map { SyncEstimate.audioBytes(durationMs: $0) }
        let bt = bytes.reduce(0.0) { $0 + SyncEstimate.fileSeconds(bytes: $1, bytesPerSecond: bluetoothBytesPerSecond) }
        return Estimate(bluetooth: bt, wifi: SyncPolicy.wifiSeconds(bytes: bytes.reduce(0, +)))
    }

    /// 值不值得提示改用 Wi‑Fi：蓝牙要很久，且 Wi‑Fi 明显更快（至少省一半）
    public static func suggest(bluetoothSeconds: Double?, wifiSeconds: Double, threshold: TimeInterval = suggestAfterIOS) -> Bool {
        guard let b = bluetoothSeconds, b >= threshold else { return false }
        return wifiSeconds <= b / 2
    }
}
