// SPDX-License-Identifier: Apache-2.0

import OpenBeanVoice
import SwiftUI
import UIKit

/// 设置：大模型服务（地址、模型、密钥存钥匙串）、转写和摘要、语音识别模型、日志
struct MobileSettingsTab: View {
    let model: MobileModel
    @State private var check: LLMService.Status?
    @State private var checking = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $settings.polishEndpoint)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model", text: $settings.polishModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API key", text: $settings.polishAPIKey)
                    HStack {
                        Button("Test connection") { Task { await test() } }.disabled(checking)
                        Spacer()
                        if checking { ProgressView() } else if let check { Text(checkText(check)).foregroundStyle(check == .ok ? .green : .red).font(.caption) }
                    }
                } header: {
                    Text("LLM service")
                } footer: {
                    Text("Any OpenAI-compatible service: a cloud API or a model on a computer on your network. Summaries, conversation titles and the diary use it. The key is kept in the keychain.")
                }

                Section("Recordings") {
                    Toggle("Transcribe after syncing", isOn: $settings.autoTranscribe)
                    Toggle("Summarise after transcribing", isOn: $settings.summarizeRecordings)
                    Toggle("Sync automatically", isOn: $settings.autoSync)
                    Stepper(value: $settings.dayStartHour, in: 0...8) {
                        LabeledContent("A day starts at", value: hourText(settings.dayStartHour))
                    }
                }

                Section {
                    ModelRow(models: model.models)
                } header: {
                    Text("Speech recognition")
                } footer: {
                    Text("SenseVoice runs on this iPhone, offline. The model is downloaded once.")
                }

                Section {
                    NavigationLink("Log") { LogView() }
                } footer: {
                    Text("OpenBean \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func test() async {
        checking = true
        defer { checking = false }
        guard let s = model.library.notes.service else { check = .unreachable(String(localized: "Not a valid address")); return }
        check = await s.check()
    }

    private func checkText(_ s: LLMService.Status) -> String {
        switch s {
        case .ok: return String(localized: "Connected")
        case .unauthorized: return String(localized: "The service rejected the API key.")
        case let .unreachable(why): return why
        }
    }

    private func hourText(_ h: Int) -> String {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "\(h):00"
    }
}

private struct ModelRow: View {
    let models: ModelStore

    var body: some View {
        switch models.state {
        case .checking:
            LabeledContent("SenseVoice", value: String(localized: "Checking…"))
        case .ready:
            LabeledContent("SenseVoice", value: String(localized: "Ready"))
        case .missing:
            Button("Download speech model (about 240 MB)") { Task { await models.download() } }
        case let .downloading(p):
            ProgressView(value: p) { Text("Downloading speech model…") }
        case let .failed(why):
            VStack(alignment: .leading) {
                Text(why).foregroundStyle(.red).font(.caption)
                Button("Try again") { Task { await models.download() } }
            }
        }
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
