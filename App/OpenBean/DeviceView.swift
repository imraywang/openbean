// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import SwiftUI

struct DeviceView: View {
    let device: DeviceController
    let dictation: Dictation
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    BeanBadge(size: 44, color: device.isReady ? .accentColor : .secondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.deviceName).font(.title3.weight(.semibold))
                        Text(stateText).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh") { Task { await device.refreshInfo() } }
                        .disabled(!device.isReady || device.activity != .idle)
                }
            }

            if case .failed = device.state {
                let p = device.problem ?? .other
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title).font(.headline)
                            Text(p.advice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: p.symbol).foregroundStyle(.orange)
                    }
                    if let s = p.settings {
                        Button(s.label) { NSWorkspace.shared.open(s.url) }
                    }
                }
            }

            if let i = device.info {
                Section("Battery") {
                    LabeledContent("Recorder", value: battery(device.battery ?? i.micBattery, charging: i.micCharging))
                    LabeledContent("Charging case", value: battery(i.caseBattery, charging: i.caseCharging))
                }
                Section("Storage") {
                    let used = Double(Int(i.totalKB) - Int(i.freeKB)), total = Double(max(i.totalKB, 1))
                    ProgressView(value: used / total) {
                        Text("\(bytes(used)) of \(bytes(total)) used")
                    }
                }
                Section("Recording") {
                    LabeledContent("Status", value: activityText(i))
                    HStack {
                        Button("Start recording") {
                            dictation.ignoreNextStart = true
                            Task { await device.startRecording() }
                        }
                        Button("Stop recording") { Task { await device.stopRecording() } }
                    }
                    .disabled(!device.isReady)
                    Text("Records on the recorder without voice typing — for meetings and notes. Sync it to the library afterwards.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("About this recorder") {
                    LabeledContent("Firmware", value: i.firmware)
                    LabeledContent("Case firmware", value: i.caseFirmware)
                    LabeledContent("Wi‑Fi firmware", value: i.wifiFirmware)
                    LabeledContent("Serial number", value: i.serial)
                }
            }

            Section {
                // 没连上时「忘记」不该是页面上最显眼的按钮（它解决不了连接问题），收成说明下面的一个链接
                if device.isReady {
                    Button("Forget this recorder…", role: .destructive) { confirmForget = true }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenBean never pairs, unbinds, resets or updates the recorder. It deletes a recording from the recorder only when you ask and that recording is safely on this Mac, or, after voice typing, the file it created for that dictation (see Settings).")
                        .font(.caption).foregroundStyle(.secondary)
                    if !device.isReady {
                        Button("Forget this recorder…") { confirmForget = true }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget this recorder?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { device.forget() }
        } message: {
            Text("OpenBean disconnects and searches again. Nothing on the recorder changes.")
        }
    }

    private var stateText: String {
        switch device.state {
        case .ready:
            switch device.activity {
            case .dictating: return String(localized: "Connected · voice typing")
            case .syncing: return String(localized: "Connected · syncing")
            case .idle: return String(localized: "Connected")
            }
        case .connecting: return String(localized: "Connecting…")
        case .idle, .searching: return String(localized: "Searching… Take the recorder out of its case.")
        case .failed: return String(localized: "Not connected · OpenBean keeps trying")
        }
    }

    private func activityText(_ i: DeviceInfo) -> String {
        if device.activity == .dictating { return String(localized: "Voice typing") }
        return i.recording == true ? String(localized: "Recording") : String(localized: "Not recording")
    }

    private func battery(_ v: Int?, charging: Bool) -> String {
        let pct = v.map { "\($0)%" } ?? "—"
        return charging ? String(localized: "\(pct), charging") : pct
    }

    private func bytes(_ kb: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb * 1024), countStyle: .file)
    }
}
