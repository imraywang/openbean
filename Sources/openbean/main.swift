// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreBluetooth
import OpenBeanKit
import Foundation

let usage = """
用法：openbean <命令> [选项]

  scan [--all]            扫描附近的录音豆（--all 顺带列出其他有名字的蓝牙设备）
  info                    连接并读取设备信息（只读）
  list                    设备信息 + 录音文件列表（只读）
  pull [id|latest|shortest|longest] [--max 秒]
                          ECDH 握手后经 BLE 拉一个文件，解密并封装成 .ogg（默认 shortest）
  wifi [id|longest|...] [--max 秒]
                          经 Wi‑Fi 热点通道拉文件：让设备开热点 → Mac 临时加入 → WebSocket 拉取
                          → 关热点 → Mac 重连原来的网络。期间 Mac 断网
  watch [秒数]            只连接和监听，不发控制命令，打印设备主动发来的所有帧（默认 90 秒）
  live [秒数]             让录音豆开始录音，实时拉流若干秒（默认 15），然后暂停录音
  delete <id> --yes [--local 路径]
                          ⚠️ 删除录音豆上的一个录音（1A/10，未经真机验证，删了不能恢复）。
                          只有本机副本存在、且解码时长和设备上的一致时才删；默认核对 App 录音库里的
                          Library/<id>/audio.ogg，也可以用 --local 指定（例如 pull 出来的 .ogg）。
                          录音豆正在录音时不删；删完回读列表确认

选项：
  --id <UUID>             指定 CoreBluetooth 设备标识（默认用上次连接的那台，或扫描信号最强的）
  -v                      打印每条收发的帧

不会发送：绑定/解绑、恢复出厂、OTA。删除文件只有 delete 子命令会发，且必须带 --yes。
"""

var args = Array(CommandLine.arguments.dropFirst())
let verbose = args.contains("-v")
args.removeAll { $0 == "-v" }
let explicitId: UUID? = {
    guard let i = args.firstIndex(of: "--id"), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return UUID(uuidString: args[i + 1])
}()
let outPath: String? = {
    guard let i = args.firstIndex(of: "--out"), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}()
let maxSeconds: Double? = {
    guard let i = args.firstIndex(of: "--max"), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return Double(args[i + 1])
}()
let showAll = args.contains("--all")
args.removeAll { $0 == "--all" }
let localPath: String? = {
    guard let i = args.firstIndex(of: "--local"), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}()
let confirmed = args.contains("--yes")
args.removeAll { $0 == "--yes" }
guard let command = args.first else { print(usage); exit(0) }

let outDir = URL(fileURLWithPath: outPath ?? FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("openbean")
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
let lastDeviceFile = stateDir.appendingPathComponent("last-device.txt")

func say(_ s: String) { print(s); fflush(stdout) }
func fmtDate(_ d: Date?) -> String {
    guard let d else { return "-" }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: d)
}
func fmtDur(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

let link = Link()
link.verbose = verbose
var cachedSession: D3200Session?
func session() -> D3200Session {
    if let s = cachedSession { return s }
    let s = D3200Session(link: link)
    cachedSession = s
    return s
}

func connectDevice() async throws {
    try await link.waitPoweredOn()
    let saved = (try? String(contentsOf: lastDeviceFile, encoding: .utf8)).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if let id = explicitId ?? saved, let p = link.retrieve(id) {
        say("连接 \(p.name ?? "设备") \(id)（\(explicitId != nil ? "指定" : "上次连过")）…")
        do { try await link.connect(p, timeout: 15); return } catch {
            say("  直连失败：\(error)，改为扫描")
        }
    }
    say("扫描 6 秒…")
    let devices = await link.scan(seconds: 6).filter(\.serviceMatch)
    guard let d = devices.first else {
        throw LinkError.missing("录音豆。把录音豆从充电盒拿出来或按一下盒子按钮唤醒，并确认手机上的飞书没连着它")
    }
    say("连接 \(d.name.isEmpty ? "(无名)" : d.name) mac=\(d.mac ?? "?") rssi=\(d.rssi) 已绑定=\(d.bound.map { $0 ? "是" : "否" } ?? "?")…")
    try await link.connect(d.peripheral)
    try? d.peripheral.identifier.uuidString.write(to: lastDeviceFile, atomically: true, encoding: .utf8)
}


// MARK: - Wi‑Fi 辅助（networksetup）

@discardableResult
func sh(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    guard (try? p.run()) != nil else { return (-1, "无法运行 \(path)") }
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

func wifiInterface() -> String {
    let out = sh("/usr/sbin/networksetup", ["-listallhardwareports"]).1.components(separatedBy: "\n")
    for (i, line) in out.enumerated() where line.contains("Wi-Fi") && i + 1 < out.count {
        if let dev = out[i + 1].components(separatedBy: "Device: ").last?.trimmingCharacters(in: .whitespaces), !dev.isEmpty { return dev }
    }
    return "en1"
}

func interfaceIP(_ ifc: String) -> String? {
    let ip = sh("/usr/sbin/ipconfig", ["getifaddr", ifc]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    return ip.isEmpty ? nil : ip
}

func sameSubnet(_ a: String, _ b: String) -> Bool {
    Array(a.split(separator: ".").prefix(3)) == Array(b.split(separator: ".").prefix(3))
}

func joinSoftAP(ifc: String, ssid: String, password: String, deviceIP: String) async throws {
    for attempt in 1...4 {
        let (_, out) = sh("/usr/sbin/networksetup", ["-setairportnetwork", ifc, ssid, password])
        let msg = out.trimmingCharacters(in: .whitespacesAndNewlines)
        say("  加入 \(ssid)（第 \(attempt) 次）\(msg.isEmpty ? "" : "：" + msg)")
        for _ in 0..<20 {
            if let ip = interfaceIP(ifc), sameSubnet(ip, deviceIP) { say("  已加入，本机 IP \(ip)"); return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
    throw LinkError.timeout("加入设备热点 \(ssid)")
}

func restoreWifi(ifc: String, ssid: String, deviceIP: String) async {
    say("恢复网络：从首选列表删除 \(ssid)，关开 Wi‑Fi 让系统自动重连…")
    let (code, out) = sh("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", ifc, ssid])
    if code != 0 || out.lowercased().contains("error") { say("  删除首选网络没成功（不影响）：\(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
    sh("/usr/sbin/networksetup", ["-setairportpower", ifc, "off"])
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    sh("/usr/sbin/networksetup", ["-setairportpower", ifc, "on"])
    for _ in 0..<45 {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let ip = interfaceIP(ifc), !sameSubnet(ip, deviceIP), !ip.hasPrefix("169.254") { say("  已重连，本机 IP \(ip)"); return }
    }
    say("  45 秒内没重连上，请手动在菜单栏选回原来的 Wi‑Fi")
}

func save(_ t: Transfer, tag: String) {
    let base = outDir.appendingPathComponent("\(t.fileId)\(tag)")
    let rawURL = base.appendingPathExtension("opus.raw")
    let oggURL = base.appendingPathExtension("ogg")
    if verbose { try? Data(t.audio).write(to: rawURL) }
    try? Data(OggOpus.mux(frames: OggOpus.frames(from: t.audio))).write(to: oggURL)

    say("""

    传输结果
      分片        \(t.slices) 片，seq \(t.firstSeq.map(String.init) ?? "-") … \(t.lastSeq.map(String.init) ?? "-")，缺 \(t.missingSeqs) 片
      结束包      \(t.gotDone ? "收到 1A0A" : "没收到")
      文件头      \(t.head.map { "size=\($0.size) err=\($0.errorCode)" } ?? "没收到 1A07 文件头")
      解密        \(t.decrypted ? "已解密" : "未解密") \(t.decryptError ?? "")
      音频        \(t.audio.count) 字节 ≈ \(fmtDur(Double(t.audio.count) / 160 * 0.02))，耗时 \(String(format: "%.1f", t.seconds)) 秒（\(String(format: "%.1f", Double(t.audio.count) / 1024 / max(t.seconds, 0.1))) KB/s）
      TOC 一致率  \(String(format: "%.0f%%", t.tocConsistency * 100))（主 TOC 0x\(t.dominantTOC.map { String(format: "%02X", $0) } ?? "--")；解密正确时应接近 100%）
      输出        \(oggURL.path)
    """)

    // -v 时用 ffmpeg 真解一遍，确认是能播的 Opus
    guard verbose, FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { return }
    let wavURL = base.appendingPathExtension("wav")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    task.arguments = ["-v", "error", "-y", "-i", oggURL.path, "-ac", "1", "-ar", "16000", wavURL.path]
    let errPipe = Pipe()
    task.standardError = errPipe
    if (try? task.run()) != nil {
        task.waitUntilExit()
        let errs = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
        let wavSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0
        say("  ffmpeg 解码  退出码 \(task.terminationStatus)，错误 \(errs.count) 行，WAV \(wavSize / 1024) KB ≈ \(fmtDur(Double(max(0, wavSize - 44)) / 32000))")
        errs.prefix(3).forEach { say("    \($0)") }
    }
}

do {
    switch command {
    case "scan":
        try await link.waitPoweredOn()
        say("扫描 8 秒…")
        let list = await link.scan(seconds: 8, all: showAll)
        if list.isEmpty { say("没发现录音豆") }
        for d in list {
            say(String(format: "%@ %4d dBm  %@  mac=%@ 已绑定=%@  %@",
                       d.serviceMatch ? "★" : " ", d.rssi, d.peripheral.identifier.uuidString,
                       d.mac ?? "-", d.bound.map { $0 ? "是" : "否" } ?? "-", d.name.isEmpty ? "(无名)" : d.name))
            if verbose, !d.manufacturer.isEmpty { say("      mfr \(d.manufacturer.hex)") }
        }

    case "info", "list":
        try await connectDevice()
        if let info = try await session().deviceInfo() { say("\n" + info.description) }
        if command == "list" {
            let files = try await session().listFiles()
            say("\n录音 \(files.count) 条（fileId / 开始时间 / 时长 / 解密后大小）")
            for f in files {
                say(String(format: "  %10u  %@  %@  %7.1f KB", f.id, fmtDate(f.startDate), fmtDur(f.durationSeconds), Double(f.audioBytes) / 1024))
            }
        }

    case "pull":
        try await connectDevice()
        let s = session()
        if let info = try await s.deviceInfo() { say("\n" + info.description + "\n") }
        say("ECDH 握手…")
        try await s.handshake()
        say("  会话密钥已建立")
        let files = try await s.listFiles().filter { $0.durationMs > 0 }
        let which = args.dropFirst().first ?? "shortest"
        let file: RecordingFile?
        switch which {
        case "latest": file = files.first
        case "longest": file = files.max { $0.durationMs < $1.durationMs }
        case "shortest": file = files.min { $0.durationMs < $1.durationMs }
        default: file = files.first { String($0.id) == which }
        }
        guard let file else { throw LinkError.missing("文件 \(which)（共 \(files.count) 条）") }
        say("拉取 \(file.id)（\(fmtDate(file.startDate))，\(fmtDur(file.durationSeconds))，约 \(file.wireBytes / 1024) KB）…")
        var lastPrint = Date.distantPast
        let t = try await s.pull(file, maxSeconds: maxSeconds) { got, expected, elapsed in
            guard Date().timeIntervalSince(lastPrint) > 2 else { return }
            lastPrint = Date()
            let pct = expected > 0 ? Double(got) / Double(expected) * 100 : 0
            say(String(format: "  %5.1f%%  %d / %d KB  %.1f KB/s", pct, got / 1024, expected / 1024, Double(got) / 1024 / max(elapsed, 0.1)))
        }
        save(t, tag: "")

    case "wifi":
        try await connectDevice()
        let s = session()
        if let info = try await s.deviceInfo() { say("\n" + info.description + "\n") }
        say("ECDH 握手…")
        try await s.handshake()
        say("  会话密钥已建立")
        let files = try await s.listFiles().filter { $0.durationMs > 0 }
        let which = args.dropFirst().first ?? "longest"
        let file: RecordingFile?
        switch which {
        case "latest": file = files.first
        case "longest": file = files.max { $0.durationMs < $1.durationMs }
        case "shortest": file = files.min { $0.durationMs < $1.durationMs }
        default: file = files.first { String($0.id) == which }
        }
        guard let file else { throw LinkError.missing("文件 \(which)") }

        let ifc = wifiInterface()
        let ssid = "WiFi-d3200spike"
        let password = "1762900000000"
        say("让设备开热点 \(ssid)…")
        let ack = try await link.request(Cmd.openSoftAP(ssid: ssid, password: password), timeout: 45,
                                         label: "热点地址（1A05）") { $0.type == 0x1A && $0.id == 0x05 }
        say("  回包 \(ack.raw.hex)")
        guard let ep = SoftAPEndpoint(frame: ack.raw) else { throw LinkError.missing("热点地址（设备拒绝或回包异常）") }
        say("  设备热点地址 \(ep)，等 10 秒让热点起来…")
        try await Task.sleep(nanoseconds: 10_000_000_000)

        var transfer: Transfer?
        var failure: Error?
        do {
            try await joinSoftAP(ifc: ifc, ssid: ssid, password: password, deviceIP: ep.ip)
            let w = WifiExport(endpoint: ep, crypto: s.crypto)
            w.log = { say("  · \($0)") }
            try await w.connect()
            say("拉取 \(file.id)（\(fmtDur(file.durationSeconds))，约 \(file.wireBytes / 1024) KB）…")
            var lastPrint = Date.distantPast
            transfer = try await w.pull(file, maxSeconds: maxSeconds) { got, expected, elapsed in
                guard Date().timeIntervalSince(lastPrint) > 2 else { return }
                lastPrint = Date()
                let pct = expected > 0 ? Double(got) / Double(expected) * 100 : 0
                say(String(format: "  %5.1f%%  %d / %d KB  %.1f KB/s", pct, got / 1024, expected / 1024, Double(got) / 1024 / max(elapsed, 0.1)))
            }
            say("  WebSocket 共收 \(w.rxBytes / 1024) KB")
            await w.close()
        } catch {
            failure = error
        }
        try? link.send(Cmd.closeSoftAP())
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await restoreWifi(ifc: ifc, ssid: ssid, deviceIP: ep.ip)
        if let failure { throw failure }
        if let transfer { save(transfer, tag: "-wifi") }

    case "decode":
        // 调试：用系统 Opus 解码一个 .opus.raw，写成 48 kHz WAV
        guard let path = args.dropFirst().first else { throw LinkError.missing("参数：.opus.raw 路径") }
        let raw = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
        let dec = try OpusDecoder()
        let outURL = URL(fileURLWithPath: path + ".sys.wav")
        let file = try AVAudioFile(forWriting: outURL, settings: dec.outputFormat.settings)
        var frames = 0, samples = 0
        let t0 = Date()
        for start in stride(from: 0, to: raw.count - 159, by: 160) {
            let pcm = try dec.decode(Array(raw[start..<start + 160]))
            try file.write(from: pcm)
            frames += 1; samples += Int(pcm.frameLength)
        }
        say("解了 \(frames) 帧，\(samples) 个采样（每帧 \(frames > 0 ? samples / frames : 0)），耗时 \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms → \(outURL.path)")

    case "watch":
        let secs = Double(args.dropFirst().first ?? "90") ?? 90
        try await connectDevice()
        let s = session()
        if let info = try await s.deviceInfo() { say("\n" + info.description + "\n") }
        let t0 = Date()
        link.onPacket = { p in
            let t = String(format: "%6.2f s", Date().timeIntervalSince(t0))
            let raw = p.raw.count > 40 ? p.raw.prefix(40).hex + " …" : p.raw.hex
            say("\(t)  \(String(format: "%02X/%02X", p.type, p.id)) st=\(String(format: "%02X", p.status)) len=\(p.raw.count)  \(raw)")
        }
        say("监听 \(Int(secs)) 秒，现在可以按录音豆或充电盒上的按钮…")
        try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        link.sync { link.onPacket = nil }
        if let info = try await s.deviceInfo() {
            say("\n结束时 录音中=\(info.recording.map { $0 ? "是" : "否" } ?? "?")")
            if info.recording == true {
                _ = try? await link.request(Cmd.pauseRecord(), label: "暂停录音") { $0.type == 0x18 && $0.id == 0x82 }
                say("（测试中开始的录音已暂停）")
            }
        }

    case "live":
        let secs = Double(args.dropFirst().first ?? "15") ?? 15
        try await connectDevice()
        let s = session()
        if let info = try await s.deviceInfo() { say("\n" + info.description + "\n") }
        say("ECDH 握手…")
        try await s.handshake()
        say("  会话密钥已建立\n同步时间…")
        try await s.syncTime()
        say("开始录音并实时拉流 \(Int(secs)) 秒，对着录音豆说话…")
        let t = try await s.live(seconds: secs) { got, elapsed in
            say(String(format: "  %4.0fs  收到 %6.1f KB ≈ %4.1f 秒音频", elapsed, Double(got) / 1024, Double(got) / 160 * 0.02))
        }
        save(t, tag: "-live")

    case "delete":
        guard let arg = args.dropFirst().first, let id = UInt32(arg) else { throw LinkError.missing("参数：要删除的录音 id（数字）") }
        let local = localPath.map { URL(fileURLWithPath: $0) }
            ?? stateDir.appendingPathComponent("Library").appendingPathComponent(String(id)).appendingPathComponent("audio.ogg")
        say("核对本机副本 \(local.path)…")
        let localSeconds = LocalAudio.decodedSeconds(local)
        say("  " + (localSeconds.map { "解码时长 \(fmtDur($0))（\(String(format: "%.2f", $0)) 秒）" } ?? "不存在或无法解码"))
        guard localSeconds != nil else { throw DeleteError.refused(.localAudioMissing) }
        guard confirmed else {
            say("\n没有带 --yes，什么都没发。删除不能恢复；确认要删时再加 --yes。")
            exit(1)
        }
        try await connectDevice()
        say("删除 \(id)…")
        let after = try await session().deleteFile(id: id) { file in
            say("  设备上：\(fmtDate(file.startDate))，\(fmtDur(file.durationSeconds))（\(String(format: "%.2f", file.durationSeconds)) 秒）")
            if let r = DeletePolicy.check(onRecorder: true, downloaded: true, localSeconds: localSeconds,
                                          expectedSeconds: file.durationSeconds, recorderRecording: false, busy: false) {
                throw DeleteError.refused(r)
            }
            say("  核对通过，发送 \(Cmd.deleteFile(id: id).hex)")
        }
        say("已删除 \(id)，回读列表确认：录音豆上还有 \(after.count) 条")

    default:
        print(usage)
    }
    link.disconnect()
    exit(0)
} catch {
    say("\n✗ \(error)")
    link.disconnect()
    exit(1)
}

