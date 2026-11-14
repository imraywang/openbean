// SPDX-License-Identifier: Apache-2.0

import AppKit
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

// MARK: - 心力模式页 → 设置（右上角齿轮）
//
// 总开关 + 心力模式下各项的选择。这一页只在心力模式开着时出现；关掉开关，心力模式页回到「已关闭」的空状态。
// 心力模式开着时整个界面把设备叫「心力豆」（Heart bean）。
// 「一天从几点开始」和设置页里的是同一个设置（settings.dayStartHour）。

struct HeartSettings: View {
    @Bindable var settings: Settings
    let notes: NoteService
    let nav: Navigator

    private var on: Bool { settings.heartMode }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.heartMode) {
                    Text("Heart mode")
                    Text("Wear your Heart bean all day. When it goes back in its case, OpenBean syncs the day, splits it into conversations and writes today's diary and to-dos.")
                }
                LLMServiceStatusRow(settings: settings) { nav.open(.voiceTyping(cleanUp: true)) }
            }

            Group {
                Section {
                    DayStartPicker(settings: settings)
                    LabeledContent {
                        TextField("Diary folder", text: $settings.diaryFolder, prompt: Text("Diary"))
                            .labelsHidden().frame(maxWidth: 180)
                    } label: {
                        Text("Diary folder")
                        if notes.diary.diaryFolderInvalid {
                            Text("Must stay inside the notes folder or one level above it; using the default for now.")
                                .foregroundStyle(.orange)
                        } else if notes.notesFolder == nil {
                            Text("Choose a notes folder in Settings to also save each day's diary as a Markdown file. Until then it's shown in Today.")
                        } else {
                            Text("Relative to the notes folder, for example Diary or ../Journal")
                        }
                    }
                    Toggle(isOn: $settings.heartRecordingNotes) {
                        Text("Also write a note for each recording")
                        Text("Off: only the diary is written. Notes already saved stay as they are.")
                    }
                } header: {
                    Text("Each day")
                }

                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Syncs automatically when the Heart bean goes back in its case")
                            Text("Always on in Heart mode, over Bluetooth.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $settings.heartDeleteFromRecorder) {
                        Text("Delete the recording from the Heart bean after it's synced and transcribed")
                        Text("Deleted recordings can't be recovered. A recording is only deleted when the copy on this Mac is complete and checked against the Heart bean.")
                    }
                } header: {
                    Text("Sync")
                }

                Section {
                    Picker(selection: $settings.heartAudioRetention) {
                        Text("Delete after transcription").tag(AudioRetention.afterTranscription)
                        Text("7 days").tag(AudioRetention.sevenDays)
                        Text("Keep").tag(AudioRetention.forever)
                    } label: {
                        Text("Keep audio on this Mac")
                        Text("Transcripts, summaries and the diary are kept. Applies to recordings synced in Heart mode.")
                    }
                    .onChange(of: settings.heartAudioRetention) { _, r in
                        Log.write("心力模式：本机音频保留改为 \(r.rawValue)")
                        notes.library?.applyAudioRetention()
                    }
                    Toggle(isOn: $settings.heartAgentTranscripts) {
                        Text("Let agents (MCP) read the transcripts of Heart mode recordings")
                        Text("Off: agents get the diary and conversation summaries, not the words.")
                    }
                } header: {
                    Text("Privacy")
                }
            }
            .disabled(!on)
        }
        .formStyle(.grouped)
    }
}

/// 「一天从几点开始」（心力模式设置和设置页共用这一个设置）
struct DayStartPicker: View {
    @Bindable var settings: Settings
    var body: some View {
        Picker(selection: $settings.dayStartHour) {
            ForEach(0..<7) { h in
                Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
                    .formatted(date: .omitted, time: .shortened)).tag(h)
            }
        } label: {
            Text("A day starts at")
            Text("With 4:00 AM, a conversation at 2 AM still counts as the day before.")
        }
    }
}

/// 大模型服务通不通（语音输入页「润色」里设的那个服务）：打开这一页时探测一次。不通时日记和段摘要等服务恢复后补上
struct LLMServiceStatusRow: View {
    @Bindable var settings: Settings
    var openCleanUp: () -> Void
    @State private var status: Polisher.Status?
    @State private var checking = false

    private var url: URL? { URL(string: settings.polishEndpoint) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if checking {
                ProgressView().controlSize(.small)
                Text("Checking the LLM service…").foregroundStyle(.secondary)
            } else if let status {
                Circle().fill(status == .ok ? Color.green : .orange).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    switch status {
                    case .ok:
                        Text("LLM service connected")
                        if let u = url, !Polisher.isLocal(u), let host = u.host {
                            Text("Conversation text is sent to \(host) for the diary and summaries.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .unauthorized:
                        Text("The LLM service rejected the API key")
                        Text("The diary and conversation summaries are written once it works again.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .unreachable:
                        Text("The LLM service is not reachable")
                        Text("Recordings are still synced and transcribed; the diary and conversation summaries are written once the service is back.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if status != nil && status != .ok {
                Button("Check again") { Task { await check() } }
            }
            Button("Clean-up settings…", action: openCleanUp).buttonStyle(.link)
        }
        .task(id: settings.polishEndpoint) { await check() }
    }

    private func check() async {
        #if DEMO || DEBUG
        if Flavor.isFake { status = DemoState.llmReachable ? .ok : .unreachable("connection refused"); return } // 演示版、预览不连任何服务
        #endif
        guard let url else { status = .unreachable(String(localized: "invalid address")); return }
        checking = true
        status = await Polisher.check(url, apiKey: settings.polishAPIKey)
        checking = false
    }
}
