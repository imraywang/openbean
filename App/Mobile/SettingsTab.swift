// SPDX-License-Identifier: Apache-2.0

import OpenBeanVoice
import SwiftUI
import UIKit

/// 设置首页，分五组：整理用的模型 / 语音识别模型 / 自动摘要与日记 / 一天从几点开始 / 关于与日志。
/// 别的页面（心力模式、录音库）要加入口时，加在标了「入口」的位置，各占一行
struct MobileSettingsTab: View {
    let model: MobileModel
    @State private var path: [SettingsRoute] = SettingsRoute.initial
    @State private var availability = OnDeviceLLM.availability
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack(path: $path) {
            Form {
                // 整理用的模型
                Section {
                    NavigationLink(value: SettingsRoute.model) {
                        LabeledContent("Model", value: modelSummary)
                    }
                    if settings.llmChoice == .none {
                        Label(availability.isAvailable ? String(localized: "Choose a model to turn on summaries.")
                              : OnDeviceText.unavailable(availability), systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Model for summaries")
                } footer: {
                    Text(settings.llmDisclosure.sentence)
                }

                // 语音识别模型
                Section {
                    NavigationLink(value: SettingsRoute.speech) {
                        LabeledContent("SenseVoice", value: speechSummary)
                    }
                } header: {
                    Text("Speech recognition")
                } footer: {
                    Text("Runs on this iPhone, offline.")
                }

                // 自动摘要与日记
                Section {
                    Toggle("Transcribe after syncing", isOn: $settings.autoTranscribe)
                    // 没有可用的模型时显示为关、不能打开（存着的开关不动，选好模型后照旧生效）
                    Toggle("Summarise after transcribing", isOn: Binding(
                        get: { settings.summarizeRecordings && settings.llmBackend != nil },
                        set: { settings.summarizeRecordings = $0 }))
                        .disabled(settings.llmBackend == nil)
                    Toggle("Sync automatically", isOn: $settings.autoSync)
                    // 入口：心力模式（每天的日记）在这里加一行
                } header: {
                    Text("Summaries and diary")
                } footer: {
                    if settings.llmBackend == nil {
                        Text("Summaries and the diary need a model. Choose one under Model for summaries.")
                    }
                }

                // 一天从几点开始
                Section {
                    Stepper(value: $settings.dayStartHour, in: 0...8) {
                        LabeledContent("A day starts at", value: hourText(settings.dayStartHour))
                    }
                } footer: {
                    Text("Recordings before this hour count toward the previous day, in Today and in the diary.")
                }

                // 入口：录音库等其他设置在这里加一组

                // 关于与日志
                Section {
                    NavigationLink("Log", value: SettingsRoute.log)
                    LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                } header: {
                    Text("About")
                } footer: {
                    Text("OpenBean is open source. Audio stays on this iPhone; speech recognition runs on the iPhone.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { r in
                switch r {
                case .model: ModelChoiceView(model: model, confirmOnAppear: SettingsRoute.confirmProvider)
                case .speech: SpeechModelView(model: model)
                case .log: LogView()
                }
            }
            .onAppear { availability = OnDeviceLLM.availability }
            .onChange(of: phase) { _, p in if p == .active { availability = OnDeviceLLM.availability } }
        }
    }

    private var modelSummary: String {
        let s = model.settings
        switch s.llmChoice {
        case .onDevice: return String(localized: "Apple on-device")
        case .service:
            if s.cloudProvider.isEmpty { return String(localized: "Service not chosen") }
            return LLMChoiceRule.serviceName(provider: s.cloudProvider, endpoint: s.polishEndpoint) ?? String(localized: "Custom address")
        case .none: return String(localized: "Not set up")
        }
    }

    private var speechSummary: String {
        switch model.models.state {
        case .checking: return String(localized: "Checking…")
        case .ready: return String(localized: "Ready")
        case .missing: return String(localized: "Not downloaded")
        case let .downloading(p): return String(localized: "Downloading… \(Int(p * 100))%")
        case .failed: return String(localized: "Download failed")
        }
    }

    private func hourText(_ h: Int) -> String {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "\(h):00"
    }
}

/// 设置里的子页面
enum SettingsRoute: Hashable {
    case model, speech, log

    /// 截图用：启动参数 -settingsScreen model|speech|confirm（confirm：打开模型页并弹出外发确认，服务用 -confirmProvider，默认 DeepSeek）
    static var initial: [SettingsRoute] {
        switch UserDefaults.standard.string(forKey: "settingsScreen") {
        case "model", "confirm": return [.model]
        case "speech": return [.speech]
        default: return []
        }
    }

    static var confirmProvider: String? {
        UserDefaults.standard.string(forKey: "settingsScreen") == "confirm"
            ? (UserDefaults.standard.string(forKey: "confirmProvider") ?? CloudPreset.deepseek.id) : nil
    }
}

/// App 内的日志（AppPaths.log 的最后一段）：连接、握手、同步、转写每一步都在这里。能复制全文
struct LogView: View {
    static let verboseKey = "bleVerbose"
    @State private var text = ""
    @State private var copied = false
    @AppStorage(LogView.verboseKey, store: Flavor.defaults) private var verbose = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? String(localized: "The log is empty.") : text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear { reload(); proxy.scrollTo("end") }
            .refreshable { reload() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(copied ? "Copied" : "Copy") {
                        Log.flush()
                        UIPasteboard.general.string = (try? String(contentsOf: AppPaths.log, encoding: .utf8)) ?? text
                        copied = true
                    }
                    Menu {
                        Toggle("Log every Bluetooth packet", isOn: $verbose)
                        Button("Reload") { reload(); proxy.scrollTo("end") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: verbose) { _, v in
            MobileModel.shared.device.link.verbose = v
            Log.write("详细蓝牙日志：\(v ? "开" : "关")")
        }
    }

    /// 只显示最后 200 KB（整个文件可能很大）；复制时复制全文
    private func reload() {
        Log.flush()
        guard let h = try? FileHandle(forReadingFrom: AppPaths.log) else { text = ""; return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let keep: UInt64 = 200_000
        try? h.seek(toOffset: size > keep ? size - keep : 0)
        text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        copied = false
    }
}
