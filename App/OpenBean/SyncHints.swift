// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import OpenBeanKit

/// 蓝牙要下很久（20 分钟以上）时提示可以改用 Wi‑Fi。只提示、不自动：Wi‑Fi 下载时 Mac 会断网几分钟。
/// 放在「今天」顶上的设备一行和工具栏同步按钮的详情里。
struct WifiSuggestion: View {
    let device: DeviceController
    let library: LibraryStore
    @State private var confirm = false

    private var downloading: Bool { if case .downloading = library.sync { return true } else { return false } }
    private var bluetoothSeconds: Double? { downloading ? library.syncSecondsLeft : library.pendingSyncSeconds }
    private var wifiSeconds: Double {
        let ms = library.pendingDownloads().reduce(0.0) { $0 + Double($1.durationMs) }
        return SyncPolicy.wifiSeconds(bytes: SyncEstimate.audioBytes(durationMs: ms))
    }

    var body: some View {
        if device.isReady, device.activity != .dictating, SyncPolicy.suggestWifi(bluetoothSeconds: bluetoothSeconds) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Over Wi‑Fi it takes about \(SyncStatus.phrase(wifiSeconds)), but your Mac is offline meanwhile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(downloading ? "Switch to Wi‑Fi…" : "Download over Wi‑Fi…") { confirm = true }
                    .controlSize(.small)
            }
            .confirmationDialog("Download over Wi‑Fi?", isPresented: $confirm) {
                Button("Download over Wi‑Fi") { Task { await library.switchToWifi() } }
            } message: {
                Text(DeviceWord.pick(library.settings.mode.callsDeviceHeartBean,
                                     "Your Mac joins the Heart bean's own Wi‑Fi and is offline for a few minutes, then reconnects to your usual network. What Bluetooth has already received is kept.",
                                     "Your Mac joins the recorder's own Wi‑Fi and is offline for a few minutes, then reconnects to your usual network. What Bluetooth has already received is kept."))
            }
        }
    }
}
