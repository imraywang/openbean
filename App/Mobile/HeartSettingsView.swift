// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI
import UIKit
import UserNotifications

// MARK: - 心力模式设置（心力模式页右上角齿轮；设置页里也有一个入口）
//
// 总开关、大模型服务状态、一天从几点开始、同步后从心力豆删除、本机音频留多久、后台和通知。
// 和 Mac 一样的设置项（存在同一组键里）；Mac 专属的（日记文件夹、每条录音写笔记、允许 Agent 读转写）这里没有。
// 打开开关：没走过引导就先走引导，看完最后一步才开。

struct HeartSettingsView: View {
    let model: MobileModel
    @State private var showIntro = false
    @State private var status: LLMService.Status?
    @State private var checking = false
    @State private var notifications: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var settings = model.settings
        let heart = settings.mode.callsDeviceHeartBean
        Form {
            Section {
                Toggle("Heart mode", isOn: Binding(get: { settings.heartMode }, set: { on in
                    if on { showIntro = true } else { settings.heartMode = false }
                }))
            } footer: {
                Text("Wear your Heart bean all day. When it goes back in its case, OpenBean syncs the day, splits it into conversations and writes today's diary and to-dos.")
            }

            Group {
                Section {
                    serviceRow
                    Button("Change in Settings") { MobileRouter.shared.tab = .settings }
                } header: {
                    Text("LLM service")
                } footer: {
                    Text("Recordings are still synced and transcribed without it; the diary and conversation summaries are written once it's reachable.")
                }

                Section {
                    Picker("A day starts at", selection: $settings.dayStartHour) {
                        ForEach(0..<7) { h in Text(verbatim: Self.hour(h)).tag(h) }
                    }
                } header: {
                    Text("Each day")
                } footer: {
                    Text("With 4:00 AM, a conversation at 2 AM still counts as the day before.")
                }

                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(heart ? "Syncs automatically when the Heart bean goes back in its case" : "Syncs automatically when the recorder goes back in its case")
                            Text("Always on in Heart mode, over Bluetooth, also in the background.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary) }
                    Toggle(isOn: $settings.heartDeleteFromRecorder) {
                        Text("Delete the recording from the Heart bean after it's synced and transcribed")
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Deleted recordings can't be recovered. A recording is only deleted when the copy on this iPhone is complete and checked against the Heart bean.")
                }

                Section {
                    Picker("Keep audio on this iPhone", selection: $settings.heartAudioRetention) {
                        Text("Delete after transcription").tag(AudioRetention.afterTranscription)
                        Text("7 days").tag(AudioRetention.sevenDays)
                        Text("Keep").tag(AudioRetention.forever)
                    }
                    .onChange(of: settings.heartAudioRetention) { _, r in
                        Log.write("心力模式：本机音频保留改为 \(r.rawValue)")
                        model.library.applyAudioRetention()
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Transcripts, summaries and the diary are kept. Applies to recordings synced in Heart mode.")
                }

                Section {
                    notificationRow
                } header: {
                    Text("Background")
                } footer: {
                    Text("Keep Bluetooth on. If you swipe OpenBean away in the app switcher, iOS stops waking it in the background until you open it again. Transcribing and the diary run when iOS allows it, or when you open OpenBean.")
                }
            }
            .disabled(!settings.heartMode)
        }
        .navigationTitle("Heart mode")
        .sheet(isPresented: $showIntro) { HeartIntroSheet(model: model, step: 0) }
        .task(id: settings.polishEndpoint) { await check() }
        .task(id: phase) { await readNotifications() }
    }

    private static func hour(_ h: Int) -> String {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)
    }

    // MARK: 大模型服务

    @ViewBuilder private var serviceRow: some View {
        let service = model.library.notes.service
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if checking {
                ProgressView().controlSize(.small)
                Text("Checking the LLM service…").foregroundStyle(.secondary)
            } else if let status {
                Circle().fill(status == .ok ? Color.green : .orange).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    switch status {
                    case .ok: Text("LLM service connected")
                    case .unauthorized: Text("The LLM service rejected the API key")
                    case .unreachable: Text("The LLM service is not reachable")
                    }
                    if let s = service, let host = s.endpoint.host {
                        if s.isLocal {
                            Text("Runs on your own network (\(host)).").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Conversation text is sent to \(host) for the diary and summaries.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if status != .ok { Button("Check again") { Task { await check() } }.buttonStyle(.borderless) }
            }
        }
    }

    private func check() async {
        if Flavor.isDemo { status = .ok; return } // 演示数据不连任何服务
        guard let s = model.library.notes.service else { status = .unreachable(String(localized: "invalid address")); return }
        checking = true
        status = await s.check()
        checking = false
    }

    // MARK: 通知

    @ViewBuilder private var notificationRow: some View {
        switch notifications {
        case .denied?:
            LabeledContent {
                Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    .buttonStyle(.borderless)
            } label: {
                Text("Notifications are off")
                Text("You won't hear when today's record is updated or a sync needs you.")
            }
        case .notDetermined?:
            LabeledContent {
                Button("Allow") { Notifier.requestPermission(); Task { try? await Task.sleep(for: .seconds(1)); await readNotifications() } }
                    .buttonStyle(.borderless)
            } label: {
                Text("Notifications")
                Text("When today's record is updated or a sync needs you.")
            }
        default:
            LabeledContent {
                Image(systemName: "checkmark").foregroundStyle(.green)
            } label: {
                Text("Notifications")
                Text("When today's record is updated or a sync needs you.")
            }
        }
    }

    private func readNotifications() async {
        if Flavor.isDemo { notifications = .authorized; return }
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
