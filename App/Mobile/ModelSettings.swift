// SPDX-License-Identifier: Apache-2.0

import OpenBeanVoice
import SwiftUI
import UIKit

/// 端侧模型不可用的原因，给人看的话
enum OnDeviceText {
    static func unavailable(_ a: OnDeviceAvailability) -> String {
        switch a {
        case .available:
            return String(localized: "Ready on this iPhone.")
        case .unsupportedOS:
            return String(localized: "Apple's on-device model needs iOS 26 or later.")
        case .deviceNotEligible:
            return String(localized: "This iPhone can't use Apple Intelligence, or Apple Intelligence isn't offered in your region. Use a cloud or network service instead.")
        case .appleIntelligenceOff:
            return String(localized: "Turn on Apple Intelligence in the Settings app (Apple Intelligence & Siri), then come back.")
        case .modelNotReady:
            return String(localized: "Apple Intelligence is still getting its model ready. Keep the iPhone on Wi‑Fi and charging, and try again later.")
        }
    }

    static func short(_ a: OnDeviceAvailability) -> String {
        switch a {
        case .available: return String(localized: "Ready")
        case .unsupportedOS, .deviceNotEligible: return String(localized: "Not supported")
        case .appleIntelligenceOff: return String(localized: "Apple Intelligence is off")
        case .modelNotReady: return String(localized: "Not ready yet")
        }
    }
}

/// 「测试连接」结果，给人看的话
enum ConnectionText {
    static func text(_ p: LLMConnectionProblem, model: String) -> String {
        switch p {
        case .invalidAddress: return String(localized: "This is not a valid address. It should start with https:// (or http:// on your local network).")
        case .pointsToThisDevice: return String(localized: "127.0.0.1 and localhost mean this iPhone, which has no model server. Use the address of the computer on your network, such as http://192.168.1.20:11434.")
        case .needsHTTPS: return String(localized: "Internet services must use https://. Plain http:// only works on your local network.")
        case .badKey: return String(localized: "The service rejected the API key. Check that it was copied in full.")
        case .noCredit: return String(localized: "The service says the account has no credit or quota left.")
        case .rateLimited: return String(localized: "The service is limiting requests right now. Try again in a minute.")
        case let .modelNotFound(s):
            return s.isEmpty ? String(localized: "The service doesn't know the model “\(model)”. Check the model name.")
                : String(localized: "The service doesn't know the model “\(model)”. It offers, for example: \(s.joined(separator: ", ")).")
        case .offline: return String(localized: "This iPhone is offline.")
        case let .localNetwork(denied):
            return denied ? String(localized: "OpenBean isn't allowed on your local network. Turn on Local Network for OpenBean in the Settings app (Privacy & Security → Local Network).")
                : String(localized: "Can't reach this address on your local network. Check that the computer is on and on the same Wi‑Fi, and that Local Network is allowed for OpenBean in the Settings app.")
        case .cannotFindHost: return String(localized: "Can't find this server. Check the address.")
        case .cannotConnect: return String(localized: "The server didn't accept the connection. Check the address and port.")
        case .timedOut: return String(localized: "The service took too long to answer.")
        case .secureConnection: return String(localized: "A secure connection couldn't be made (certificate problem or a proxy in the way).")
        case let .server(code): return String(localized: "The service had an error (HTTP \(code)). Try again later.")
        case let .unexpected(code): return String(localized: "Unexpected answer (HTTP \(code)). Check that the address is the service's OpenAI-compatible base URL.")
        case let .other(why): return why
        }
    }
}

/// 设置 → 整理用的模型：苹果端侧模型，或 OpenAI 兼容服务（预置几家云端 + 自定义地址）
struct ModelChoiceView: View {
    let model: MobileModel
    /// 截图用：打开时就弹出外发确认
    var confirmOnAppear: String?

    @State private var availability = OnDeviceLLM.availability
    @State private var pendingProvider: CloudPreset?
    @State private var pendingCustom = false
    @State private var testing = false
    @State private var result: String?
    @State private var resultOK = false
    @Environment(\.scenePhase) private var phase

    private var settings: Settings { model.settings }
    private var choice: LLMChoice { settings.llmChoice }
    private var preset: CloudPreset? { CloudPreset.with(id: settings.cloudProvider) }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                choiceRow(.onDevice, title: String(localized: "Apple on-device model"),
                          subtitle: availability.isAvailable ? String(localized: "Private and free. Works offline.") : OnDeviceText.short(availability))
                choiceRow(.service, title: String(localized: "Cloud or network service"),
                          subtitle: String(localized: "DeepSeek, OpenAI, OpenRouter, or your own server"))
            } footer: {
                Text(settings.llmDisclosure.sentence)
            }

            if choice != .service, !availability.isAvailable {
                Section {
                    Label(OnDeviceText.unavailable(availability), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if availability.userCanFix {
                        Button("Open the Settings app") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                } header: {
                    Text("On-device model unavailable")
                } footer: {
                    Text("Until a model is chosen, OpenBean still syncs and transcribes, but doesn't write summaries or the diary.")
                }
            }

            if choice == .service {
                Section("Service") {
                    ForEach(CloudPreset.all) { p in
                        Button { pick(p) } label: {
                            HStack {
                                Text(p.isCustom ? String(localized: "Custom address") : p.name).foregroundStyle(.primary)
                                Spacer()
                                if settings.cloudProvider == p.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }

                if let preset {
                    Section {
                        if preset.isCustom {
                            TextField("https://… or http://192.168.…", text: $settings.polishEndpoint)
                                .textContentType(.URL).keyboardType(.URL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .onSubmit { customAddressSubmitted() }
                        } else {
                            LabeledContent("Address", value: preset.endpoint).font(.footnote)
                        }
                        HStack {
                            TextField("Model", text: $settings.polishModel)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !preset.models.isEmpty {
                                Menu {
                                    ForEach(preset.models, id: \.self) { m in Button(m) { settings.polishModel = m } }
                                } label: { Image(systemName: "chevron.up.chevron.down") }
                            }
                        }
                        SecureField(preset.isCustom ? String(localized: "API key (if the server needs one)") : String(localized: "API key"),
                                    text: $settings.polishAPIKey)
                        if let page = preset.keyPage, let u = URL(string: page) {
                            Link(String(localized: "Get an API key from \(preset.name)"), destination: u)
                        }
                        HStack {
                            Button("Test connection") { Task { await test() } }.disabled(testing)
                            Spacer()
                            if testing { ProgressView() }
                        }
                        if let result {
                            Text(result).font(.footnote).foregroundStyle(resultOK ? .green : .red)
                        }
                    } footer: {
                        Text(preset.isCustom
                             ? String(localized: "Any OpenAI-compatible service. A model server on a computer at home (llama-server, Ollama, LM Studio) works too: use its address on your Wi‑Fi. The key is kept in the keychain.")
                             : String(localized: "The key is kept in this iPhone's keychain. Model names change over time; Test connection checks the name with the service."))
                    }
                }
            }

            if choice == .onDevice || (choice == .none && availability.isAvailable) {
                Section {
                    HStack {
                        Button("Test the on-device model") { Task { await test() } }.disabled(testing)
                        Spacer()
                        if testing { ProgressView() }
                    }
                    if let result { Text(result).font(.footnote).foregroundStyle(resultOK ? .green : .red) }
                }
            }
        }
        .navigationTitle("Model for summaries")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            availability = OnDeviceLLM.availability
            if let id = confirmOnAppear, let p = CloudPreset.with(id: id) { pendingProvider = p }
            // 已经选了云端服务却没确认过（旧版本跳过了确认）：补问一次
            else if choice == .service, !settings.cloudConfirmed, let p = CloudPreset.with(id: settings.cloudProvider), !p.isCustom {
                pendingProvider = p
            }
        }
        .onChange(of: phase) { _, p in if p == .active { availability = OnDeviceLLM.availability } }
        .onChange(of: settings.polishAPIKey) { result = nil }
        .onChange(of: settings.polishModel) { result = nil }
        .onChange(of: settings.polishEndpoint) { result = nil }
        .alert(confirmTitle, isPresented: Binding(get: { pendingProvider != nil || pendingCustom },
                                                  set: { if !$0 { pendingProvider = nil; pendingCustom = false } })) {
            Button(confirmButton) { confirm() }
            Button("Cancel", role: .cancel) { cancelConfirm() }
        } message: {
            Text("To write summaries, conversation titles and the diary, the text of your transcripts will be sent to \(confirmName). Audio never leaves this iPhone. You can switch back to the on-device model at any time.")
        }
    }

    // MARK: 选择

    private func choiceRow(_ c: LLMChoice, title: String, subtitle: String) -> some View {
        Button {
            select(c)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if choice == c { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .disabled(c == .onDevice && !availability.isAvailable && choice != .onDevice)
    }

    private func select(_ c: LLMChoice) {
        result = nil
        settings.llmChoiceStored = c.rawValue
        Log.write("整理用的模型：\(c.rawValue)")
    }

    private func pick(_ p: CloudPreset) {
        result = nil
        guard p.id != settings.cloudProvider else { return }
        let sendsOut = p.isCustom ? LLMChoiceRule.sendsTextOffDevice(.service, endpoint: Flavor.defaults.string(forKey: "cloudEndpoint.custom") ?? "")
            && !(Flavor.defaults.string(forKey: "cloudEndpoint.custom") ?? "").isEmpty
            : true
        // 「现在已经在外发」只认真的能用的服务：刚选了「云端服务」、还没选哪家时地址是空的，不算（否则第一次选服务就跳过了确认，
        // 而没确认过的服务又不会被使用，结果是选好了却一直提示没有设置服务）
        if LLMChoiceRule.needsCloudConfirmation(currentlySendsOut: settings.llmBackend?.sendsTextOffDevice == true,
                                                toSendsOut: sendsOut, alreadyConfirmed: settings.cloudConfirmed) {
            pendingProvider = p
        } else {
            settings.selectProvider(p.id)
        }
    }

    /// 自定义地址填完：是公网地址、还没确认过就问一次
    private func customAddressSubmitted() {
        let out = LLMChoiceRule.sendsTextOffDevice(.service, endpoint: settings.polishEndpoint)
        if out, !settings.cloudConfirmed { pendingCustom = true }
    }

    private var confirmName: String {
        if let p = pendingProvider, !p.isCustom { return p.name }
        return URL(string: settings.polishEndpoint)?.host ?? String(localized: "this service")
    }
    private var confirmTitle: String { String(localized: "Send transcripts to \(confirmName)?") }
    private var confirmButton: String { String(localized: "Use \(confirmName)") }

    private func confirm() {
        settings.cloudConfirmed = true
        Log.write("确认：转写文字会发给 \(confirmName)")
        if let p = pendingProvider { settings.selectProvider(p.id) }
        pendingProvider = nil
        pendingCustom = false
    }

    private func cancelConfirm() {
        if pendingCustom { settings.polishEndpoint = "" }
        pendingProvider = nil
        pendingCustom = false
    }

    // MARK: 测试

    private func test() async {
        testing = true
        defer { testing = false }
        if choice != .service {
            let a = OnDeviceLLM.availability
            availability = a
            resultOK = a.isAvailable
            result = OnDeviceText.unavailable(a)
            return
        }
        guard let s = settings.llmService else {
            resultOK = false
            result = ConnectionText.text(.invalidAddress, model: settings.polishModel)
            return
        }
        if Flavor.isDemo {
            resultOK = true
            result = String(localized: "Connected. The key and the model name work.")
            return
        }
        if let p = await LLMConnectionTest.run(s, onPhone: true) {
            resultOK = false
            result = ConnectionText.text(p, model: s.model)
            Log.write("测试连接 \(s.endpoint.host ?? "")：\(p)")
        } else {
            resultOK = true
            result = String(localized: "Connected. The key and the model name work.")
        }
    }
}

/// 设置 → 语音识别模型：SenseVoice 的状态、体积、重新下载、仅 Wi‑Fi 下载
struct SpeechModelView: View {
    let model: MobileModel
    @State private var confirmRedownload = false

    private var store: ModelStore { model.models }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("SenseVoice", value: stateText)
                if case let .downloading(p) = store.state {
                    ProgressView(value: p)
                }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
                if case let .failed(why) = store.state {
                    Text(why).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Speech recognition always runs on this iPhone, offline. Supports Chinese, English, Japanese, Korean and Cantonese. Audio never leaves the iPhone.")
            }

            Section {
                switch store.state {
                case .missing, .failed:
                    Button("Download speech model") { Task { await store.download(wifiOnly: settings.modelWifiOnly) } }
                case .ready:
                    Button("Download again") { confirmRedownload = true }
                case .checking, .downloading:
                    EmptyView()
                }
                Toggle("Download over Wi‑Fi only", isOn: $settings.modelWifiOnly)
            } footer: {
                Text("Download again if transcripts suddenly come out empty or garbled; the files are replaced.")
            }
        }
        .navigationTitle("Speech recognition")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Download the speech model again?", isPresented: $confirmRedownload, titleVisibility: .visible) {
            Button("Download again (\(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file)))") {
                Task { await store.redownload(wifiOnly: settings.modelWifiOnly) }
            }
        }
    }

    private var stateText: String {
        switch store.state {
        case .checking: return String(localized: "Checking…")
        case .ready: return String(localized: "Ready")
        case .missing: return String(localized: "Not downloaded")
        case let .downloading(p): return String(localized: "Downloading… \(Int(p * 100))%")
        case .failed: return String(localized: "Download failed")
        }
    }
}
