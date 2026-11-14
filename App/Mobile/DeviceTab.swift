// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import SwiftUI
import UIKit

/// 录音豆：连接（扫描 → 连接 → 握手，每一步写进日志）、电量 / 存储 / 固件、设备上的录音、手动同步
struct DeviceTab: View {
    let model: MobileModel
    @State private var confirmForget = false

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
                        .disabled(!device.isReady || library.syncRunning || library.pendingDownloads().isEmpty)
                    Button("Refresh list") { Task { await library.refreshDeviceList() } }
                        .disabled(!device.isReady || device.activity != .idle)
                } header: {
                    Text(DeviceWord.pick(heart, "On Heart bean", "On recorder"))
                } footer: {
                    if let s = library.pendingSyncSeconds {
                        Text("About \(Self.minutes(s)) over Bluetooth. It keeps going in the background; if it's interrupted, it picks up where it stopped.")
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
        case .wifi, .paused:
            // iOS 没有 Wi‑Fi 同步和语音输入：不会出现
            EmptyView()
        case let .failed(why):
            Text(why).foregroundStyle(.red).font(.caption)
        }
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
