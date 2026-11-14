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
    /// 最近一次连接失败的原因（state 为 .failed 时有意义），界面据此说人话
    private(set) var problem: ConnectionProblem?
    /// 听写要用连接时置位，正在进行的同步看到后尽快让出
    private(set) var syncShouldYield = false
    /// 旁听语音输入结束后故意断开、正在重连（让录音豆停止外发实时流，见 RelinkPolicy）。
    /// 这期间界面照旧显示已连接、连接仍算「语音输入占着」（activity == .dictating），同步、刷新列表都不会插进来；
    /// 新的语音输入请求等重连完成（Dictation.waitingForLink）
    private(set) var relinking = false
    /// 故意断开时登记：这个时刻之前收到的一次断开回调是我们自己断的，不当成掉线
    @ObservationIgnored private var intentionalDropUntil: Date?
    @ObservationIgnored private var intentionalDropSeen = false
    #if DEMO || DEBUG
    /// 演示版、预览从不连接：用到才建（建 Link 就会初始化 CoreBluetooth、弹蓝牙权限）
    @ObservationIgnored lazy var link = Link()
    #else
    let link = Link()
    #endif
    private(set) var session: D3200Session?
    /// 设备事件（主线程）
    var onEvent: (DeviceEvent) -> Void = { _ in }
    /// 刚连上（每次连上都会调用）
    var onConnected: () -> Void = {}
    private var loop: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    /// 电量日志：上次写进日志的档位和充电状态，只在变化时再写
    private var loggedLevels: (recorder: Int?, chargingCase: Int?) = (nil, nil)
    private var loggedCharging: (recorder: Bool, chargingCase: Bool)?

    private let lastDeviceFile = AppPaths.support.appendingPathComponent("last-device.txt")

    #if DEMO || DEBUG
    var isReady: Bool { state == .ready && (session != nil || Flavor.isFake || relinking) }
    #else
    /// 故意重连的几秒里也算可用：快捷键、菜单照常能按，语音输入会等连接回来
    var isReady: Bool { state == .ready && (session != nil || relinking) }
    #endif

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
        #if DEMO || DEBUG
        if Flavor.isFake { return }
        #endif
        try? FileManager.default.removeItem(at: lastDeviceFile)
        link.disconnect()
    }

    private func lostConnection() {
        if let until = intentionalDropUntil, Date() < until {
            // 旁听结束后我们自己断的：不算掉线，重连由 relinkToStopStream 自己做
            intentionalDropUntil = nil
            intentionalDropSeen = true
            Log.write("连接已断开（故意的，旁听结束后让录音豆停止外发）")
            return
        }
        if relinking {
            // 故意重连的过程中又断了：由 relinkToStopStream 的重试接着处理
            Log.write("旁听后重连时连接断开")
            session = nil
            return
        }
        Log.write("连接断开，准备重连")
        if session != nil { Log.write("battery event=disconnect recorder=\(Self.field(battery))") }
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
                problem = ConnectionProblem(error)
                Log.write("连接失败（\(delay) 秒后重试）：\(error)")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    /// `quiet`：故意重连时不改 state（界面不闪「正在搜索」）、不调用 onConnected（重连完再调用）
    private func connectOnce(quiet: Bool = false) async throws {
        if !quiet { state = .searching }
        var target = (try? String(contentsOf: lastDeviceFile, encoding: .utf8))
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { link.retrieve($0) }
        if let p = target {
            if !quiet { state = .connecting }
            Log.write("按上次的设备直连")
            let t0 = Date()
            do {
                try await link.connect(p, timeout: 8, scanAssist: true)
                Log.write(String(format: "直连成功，用了 %.1f 秒", Date().timeIntervalSince(t0)))
            } catch {
                Log.write("直连失败：\(error)，改为扫描")
                target = nil
            }
        }
        if target == nil {
            guard let d = await link.scan(seconds: 6).first(where: \.serviceMatch) else {
                throw LinkError.missing(String(localized: "recorder. Take it out of the case or press the case button to wake it."))
            }
            if !quiet { state = .connecting }
            try await link.connect(d.peripheral)
            if !d.name.isEmpty { deviceName = d.name }
            try? d.peripheral.identifier.uuidString.write(to: lastDeviceFile, atomically: true, encoding: .utf8)
        }
        let s = D3200Session(link: link)
        info = try await s.deviceInfo()
        battery = info?.micBattery
        if let i = info {
            loggedLevels = (i.micBattery, i.caseBattery)
            loggedCharging = (i.micCharging, i.caseCharging)
            Log.write("battery event=connect recorder=\(Self.field(i.micBattery)) case=\(Self.field(i.caseBattery)) "
                      + "charging=\(Self.field(i.micCharging)) caseCharging=\(Self.field(i.caseCharging))"
                      + (quiet ? " intentional=1" : ""))
        }
        try await s.handshake()
        try? await s.syncTime()
        s.observeEvents { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
        session = s
        state = .ready
        startPolling()
        if !quiet { onConnected() }
    }

    // MARK: 旁听之后断开重连

    /// 旁听结束：断开蓝牙让录音豆停止外发实时流，马上重连（不发任何录音命令）。重试几次（每次直连，失败就扫描），
    /// 都不行就交给常规重连循环。全程 activity 保持 .dictating，结束时放回 .idle。
    /// 重连时 connectOnce 会重新读设备信息（还在不在录、电量）、握手、校时。返回重连成功没有
    @discardableResult
    func relinkToStopStream() async -> Bool {
        guard RelinkPolicy.shouldRelink(requestedStream: true, connected: session != nil && link.isConnected) else {
            Log.write("旁听结束：连接已经断了，不用再断开")
            endDictation()
            return false
        }
        let t0 = Date()
        relinking = true
        activity = .dictating
        defer { relinking = false }
        poller?.cancel()
        loop?.cancel()
        Log.write("battery event=disconnect intentional=1 reason=listen-in recorder=\(Self.field(battery))")
        intentionalDropSeen = false
        intentionalDropUntil = Date().addingTimeInterval(RelinkPolicy.disconnectWait + 7)
        session = nil
        link.disconnect()
        // 等断开回调（在 lostConnection 里被认成故意的）；等不到也往下走
        while !intentionalDropSeen, Date().timeIntervalSince(t0) < RelinkPolicy.disconnectWait {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !intentionalDropSeen { Log.write("故意断开后 \(Int(RelinkPolicy.disconnectWait)) 秒没等到断开回调，照样重连") }
        var failures = 0
        while true {
            do {
                try await link.waitPoweredOn()
                try await connectOnce(quiet: true)
                Log.write(String(format: "旁听后重连成功，用了 %.1f 秒（第 %d 次）；录音中=%@ 电量=%@",
                                 Date().timeIntervalSince(t0), failures + 1, Self.field(info?.recording), Self.field(battery)))
                break
            } catch {
                failures += 1
                switch RelinkPolicy.next(afterFailures: failures) {
                case let .retry(after):
                    Log.write("旁听后重连失败（第 \(failures) 次）：\(error)，\(after) 秒后再试")
                    try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                case .handOver:
                    Log.write("旁听后重连失败 \(failures) 次：\(error)，交给常规重连")
                    intentionalDropUntil = nil
                    session = nil
                    state = .searching
                    activity = .idle
                    syncShouldYield = false
                    relinking = false
                    loop = Task { await connectLoop() }
                    return false
                }
            }
        }
        intentionalDropUntil = nil
        activity = .idle
        syncShouldYield = false
        relinking = false
        // 常规连上时做的事（刷新设备文件列表 → 自动同步自己判断要不要下载；录音豆还在录就不下）。
        // 有语音输入在等连接时先不刷：让它先用连接
        if !dictationWaiting { onConnected() }
        return true
    }

    /// 有语音输入请求在等重连（Dictation 设置）
    @ObservationIgnored var dictationWaiting = false

    /// 等故意重连结束；返回连接能不能用。没在重连时立刻返回
    func waitForLink(timeout: Double = RelinkPolicy.waitForLink) async -> Bool {
        let t0 = Date()
        while relinking, Date().timeIntervalSince(t0) < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !relinking && session != nil && state == .ready
    }

    /// 设备上最新的录音文件号：录音开始事件（1A/06）和读到的文件列表都会更新。旁听时放进实时请求（设备不看它，见 PROTOCOL §11）
    var newestFileId: UInt32?

    private func handle(_ e: DeviceEvent) {
        switch e {
        case let .recordingStarted(id):
            newestFileId = max(newestFileId ?? 0, id)
        case let .battery(r, c):
            battery = r
            noteLevels(recorder: r, chargingCase: c)
        case let .charging(r, c):
            noteCharging(recorder: r, chargingCase: c)
        default:
            break
        }
        onEvent(e)
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task {
            var minutes = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if activity == .idle { await refreshInfo() }
                // 每 10 分钟写一行心跳：统计脚本靠它识别睡眠、崩溃这类没留下断开记录的空档
                minutes += 1
                if minutes % 10 == 0, isReady {
                    Log.write("battery event=tick recorder=\(Self.field(battery)) case=\(Self.field(loggedLevels.chargingCase)) "
                              + "charging=\(Self.field(loggedCharging?.recorder)) caseCharging=\(Self.field(loggedCharging?.chargingCase))")
                }
            }
        }
    }

    func refreshInfo() async {
        guard let s = session, activity == .idle else { return }
        if let i = try? await s.deviceInfo() {
            info = i; battery = i.micBattery
            noteLevels(recorder: i.micBattery, chargingCase: i.caseBattery)
            noteCharging(recorder: i.micCharging, chargingCase: i.caseCharging)
        }
    }

    // MARK: 电量日志

    /// 日志里的取值：未知写 ?，开关写 1/0
    static func field(_ v: Int?) -> String { v.map(String.init) ?? "?" }
    static func field(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "?" }

    /// 录音豆或盒子的电量档位变了才写；某一项没报（nil）就沿用上次的值
    private func noteLevels(recorder: Int?, chargingCase: Int?) {
        let r = recorder ?? loggedLevels.recorder, c = chargingCase ?? loggedLevels.chargingCase
        guard r != loggedLevels.recorder || c != loggedLevels.chargingCase else { return }
        loggedLevels = (r, c)
        Log.write("battery event=level recorder=\(Self.field(r)) case=\(Self.field(c))")
    }

    /// 充电标志变了才写：charging=1 表示录音豆放进了充电盒，caseCharging=1 表示盒子接着电源
    private func noteCharging(recorder: Bool, chargingCase: Bool) {
        if let l = loggedCharging, l.recorder == recorder, l.chargingCase == chargingCase { return }
        loggedCharging = (recorder, chargingCase)
        Log.write("battery event=charging charging=\(Self.field(recorder)) caseCharging=\(Self.field(chargingCase)) "
                  + "recorder=\(Self.field(battery))")
    }

    #if DEMO || DEBUG
    /// 演示版、预览：直接摆出一种连接状态
    func demoApply(state: State, info: DeviceInfo?, activity: Activity, problem: ConnectionProblem? = nil) {
        self.state = state
        self.problem = problem
        self.info = info
        battery = info?.micBattery
        self.activity = activity
    }
    #endif

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

    /// 设备页「停止录音」：先暂停再结束（真机测过的顺序），录音豆收尾成一个独立文件，下次开始不会续写
    func stopRecording() async {
        guard let s = session else { return }
        do { try await s.pauseRecording() } catch { Log.write("暂停录音失败：\(error)"); return }
        do {
            let id = try await s.stopRecording()
            Log.write("已结束录音" + (id.map { "（1A/0A file=\($0)）" } ?? "（没等到 1A/0A）"))
        } catch {
            Log.write("结束录音失败：\(error)")
        }
    }
}

/// 连接失败的原因，给人看的说法和下一步。只是把 Link 抛出的错误归类，不影响连接流程；原始错误照旧写日志
enum ConnectionProblem: Equatable {
    case bluetoothOff, noPermission, notFound, lost, other

    init(_ error: Error) {
        switch error as? LinkError {
        // 这两句是 Link.stateName 的开头
        case let .bluetooth(s)?: self = s.hasPrefix("没有蓝牙权限") ? .noPermission : s.hasPrefix("蓝牙已关闭") ? .bluetoothOff : .other
        // 「GATT 服务」「写特征」是连上了但不像录音豆
        case let .missing(s)?: self = s.hasPrefix("GATT") || s.hasPrefix("写特征") ? .other : .notFound
        case .timeout?, .disconnected?: self = .lost
        case nil: self = .other
        }
    }

    var title: String {
        switch self {
        case .bluetoothOff: return String(localized: "Bluetooth is off")
        case .noPermission: return String(localized: "OpenBean isn't allowed to use Bluetooth")
        case .notFound: return String(localized: "Can't find your recorder")
        case .lost: return String(localized: "The connection dropped")
        case .other: return String(localized: "Couldn't connect to the recorder")
        }
    }

    var advice: String {
        switch self {
        case .bluetoothOff: return String(localized: "Turn on Bluetooth in Control Center or System Settings. OpenBean connects as soon as it's on.")
        case .noPermission: return String(localized: "Turn on OpenBean in System Settings → Privacy & Security → Bluetooth.")
        case .notFound: return String(localized: "Take the recorder out of its case, or press the button on the case to wake it. OpenBean keeps looking.")
        case .lost: return String(localized: "Keep the recorder near this Mac. OpenBean reconnects by itself.")
        case .other: return String(localized: "OpenBean keeps trying. If it doesn't connect in a minute, put the recorder back in its case and take it out again.")
        }
    }

    var symbol: String {
        switch self {
        case .bluetoothOff, .noPermission: return "antenna.radiowaves.left.and.right.slash"
        case .notFound: return "magnifyingglass"
        case .lost, .other: return "exclamationmark.triangle"
        }
    }

    /// 能帮上忙的系统设置页
    var settings: (label: String, url: URL)? {
        switch self {
        case .bluetoothOff:
            return (String(localized: "Open Bluetooth Settings"), URL(string: "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension")!)
        case .noPermission:
            return (String(localized: "Open Privacy Settings"), URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
        default: return nil
        }
    }
}
