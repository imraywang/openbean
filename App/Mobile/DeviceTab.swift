// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import SwiftUI
import UIKit

/// 录音豆：连接（扫描 → 连接 → 握手，每一步写进日志）、电量 / 存储 / 固件、设备上的录音、手动同步
struct DeviceTab: View {
    let model: MobileModel
    @State private var confirmForget = false
    /// 「用 Wi‑Fi 同步」的确认（true = 正在蓝牙同步，点了是把剩下的切过去）
    @State private var confirmWifi: Bool?

    private var device: DeviceController { model.device }
    private var library: LibraryStore { model.library }
    private var heart: Bool { model.settings.mode.callsDeviceHeartBean }
    private var started: Bool { Flavor.defaults.bool(forKey: MobileModel.connectKey) || Flavor.isDemo }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.circle.fill").font(.largeTitle)
                            .foregroundStyle(device.isReady ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.deviceName).font(.headline)
                            Text(stateText).foregroundStyle(.secondary)
                        }
                    }
                    if !started || device.state == .idle {
                        Button("Connect") { model.connect() }
                    }
                    if case .failed = device.state {
                        let p = device.problem ?? .other
                        VStack(alignment: .leading, spacing: 4) {
                            Label(p.title, systemImage: p.symbol).foregroundStyle(.orange)
                            Text(p.advice).font(.callout).foregroundStyle(.secondary)
                        }
                        if let s = p.settings {
                            Button(s.label) { UIApplication.shared.open(s.url) }
                        }
                    }
                    NavigationLink("Connection log") { LogView() }
                }

                if let i = device.info {
                    Section("Battery") {
                        LabeledContent(DeviceWord.title(heart: heart), value: battery(device.battery ?? i.micBattery, charging: i.micCharging))
                        LabeledContent("Charging case", value: battery(i.caseBattery, charging: i.caseCharging))
                    }
                    Section("Storage") {
                        let used = Double(Int(i.totalKB) - Int(i.freeKB)), total = Double(max(i.totalKB, 1))
                        ProgressView(value: used / total) {
                            Text("\(bytes(used)) of \(bytes(total)) used")
                        }
                    }
                    Section("Firmware") {
                        LabeledContent(DeviceWord.title(heart: heart), value: i.firmware)
                        LabeledContent("Charging case", value: i.caseFirmware)
                    }
                }

                Section {
                    syncRow
                    Button("Sync") { Task { await library.syncAll() } }
                        .disabled(!device.isReady || library.syncRunning || library.wifiRunning || library.pendingDownloads().isEmpty)
                    Button("Sync over Wi‑Fi") { confirmWifi = false }
                        .disabled(!device.isReady || library.syncRunning || library.wifiRunning || library.pendingDownloads().isEmpty)
                    Button("Refresh list") { Task { await library.refreshDeviceList() } }
                        .disabled(!device.isReady || device.activity != .idle)
                } header: {
                    Text(DeviceWord.pick(heart, "On Heart bean", "On recorder"))
                } footer: {
                    if let s = library.pendingSyncSeconds, !library.wifiRunning {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("About \(Self.minutes(s)) over Bluetooth. It keeps going in the background; if it's interrupted, it picks up where it stopped.")
                            if let w = library.pendingWifiSeconds {
                                Text("About \(Self.minutes(w)) over Wi‑Fi, with OpenBean kept open.")
                            }
                        }
                    }
                }
                Section {
                    let onDevice = library.recordings.filter { $0.onDevice && !$0.isDictation }
                    if onDevice.isEmpty {
                        Text(heart ? "No recordings on the Heart bean." : "No recordings on the recorder.").foregroundStyle(.secondary)
                    }
                    ForEach(onDevice) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.start.formatted(date: .abbreviated, time: .shortened))
                                Text(LibraryStore.clock(r.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: r.downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(r.downloaded ? Color.green : .secondary)
                                .accessibilityLabel(r.downloaded ? "Synced" : "Not synced")
                        }
                    }
                }

                if started, !Flavor.isDemo {
                    Section {
                        Button(DeviceWord.pick(heart, "Forget this Heart bean", "Forget this recorder"), role: .destructive) { confirmForget = true }
                    }
                }
            }
            .navigationTitle(DeviceWord.title(heart: heart))
            .refreshable { await device.refreshInfo() }
            .alert("Sync over Wi‑Fi?", isPresented: Binding(get: { confirmWifi != nil }, set: { if !$0 { confirmWifi = nil } }),
                   presenting: confirmWifi) { switching in
                Button(switching ? "Switch to Wi‑Fi" : "Sync over Wi‑Fi") {
                    Task { if switching { await library.switchToWifi() } else { await library.syncViaWifi(ids: library.pendingDownloads().map(\.id)) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(Self.wifiExplanation(seconds: library.pendingWifiSeconds ?? SyncPolicy.wifiOverhead, heart: heart))
            }
            .confirmationDialog(DeviceWord.pick(heart, "Forget this Heart bean?", "Forget this recorder?"), isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { device.forget() }
            } message: {
                Text(DeviceWord.pick(heart, "OpenBean scans for a Heart bean again next time it connects. Keep it out of its case and near this iPhone.",
                                     "OpenBean scans for a recorder again next time it connects. Keep it out of its case and near this iPhone."))
            }
        }
    }

    @ViewBuilder
    private var syncRow: some View {
        switch library.sync {
        case .idle:
            EmptyView()
        case .listing:
            Label("Checking the recorder…", systemImage: "arrow.triangle.2.circlepath")
        case let .downloading(_, done, total, fraction, kbps):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction) {
                    Text("Downloading \(done + 1) of \(total)")
                }
                Text(String(format: "%.1f KB/s", kbps)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            wifiSuggestion
        case let .wifi(msg):
            Label(msg, systemImage: "wifi")
        case .paused:
            // iOS 没有语音输入：不会出现
            EmptyView()
        case let .failed(why):
            Text(why).foregroundStyle(.red).font(.caption)
        }
    }

    /// 蓝牙同步还要很久（WifiAdvice.suggestAfterIOS 以上、Wi‑Fi 至少快一倍）：提示可以把剩下的改用 Wi‑Fi
    @ViewBuilder
    private var wifiSuggestion: some View {
        if let wifi = library.pendingWifiSeconds,
           WifiAdvice.suggest(bluetoothSeconds: library.syncSecondsLeft, wifiSeconds: wifi) {
            VStack(alignment: .leading, spacing: 6) {
                Text("About \(Self.minutes(library.syncSecondsLeft ?? 0)) left over Bluetooth. Over Wi‑Fi the rest takes about \(Self.minutes(wifi)).")
                    .font(.callout)
                Button { confirmWifi = true } label: { Label("Switch to Wi‑Fi", systemImage: "wifi") }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 2)
        }
    }

    /// 改用 Wi‑Fi 前说清楚：iPhone 的 Wi‑Fi 会暂时连到录音豆、大约多久、系统会问一次、要把 App 留在前台
    static func wifiExplanation(seconds: Double, heart: Bool) -> String {
        let t = minutes(seconds)
        return heart
            ? String(localized: "Your iPhone joins the Heart bean's own Wi‑Fi for about \(t), then goes back to your usual Wi‑Fi. iOS asks once to join the network. Meanwhile there's no internet over Wi‑Fi; mobile data may take over. Keep OpenBean open: if you leave it, what was received is kept and Bluetooth continues from there.")
            : String(localized: "Your iPhone joins the recorder's own Wi‑Fi for about \(t), then goes back to your usual Wi‑Fi. iOS asks once to join the network. Meanwhile there's no internet over Wi‑Fi; mobile data may take over. Keep OpenBean open: if you leave it, what was received is kept and Bluetooth continues from there.")
    }

    private var stateText: String {
        switch device.state {
        case .idle: return String(localized: "Not connected")
        case .searching:
            // iOS 挂着不超时的连接：录音豆一进范围、一出盒子就连上
            return heart ? String(localized: "Waiting for the Heart bean…") : String(localized: "Waiting for the recorder…")
        case .connecting: return String(localized: "Connecting…")
        case .ready:
            switch device.activity {
            case .syncing: return String(localized: "Syncing")
            default: return String(localized: "Connected")
            }
        case let .failed(why): return why
        }
    }

    private func battery(_ v: Int?, charging: Bool) -> String {
        guard let v else { return "–" }
        return charging ? String(localized: "\(v)%, charging") : "\(v)%"
    }

    private func bytes(_ kb: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb * 1024), countStyle: .file)
    }

    static func minutes(_ s: Double) -> String {
        Duration.seconds(max(60, s)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
