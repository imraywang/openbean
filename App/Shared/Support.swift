// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OpenBeanLibrary
import OpenBeanVoice
import Security

enum AppPaths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Flavor.dataFolder)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var models: URL { support.appendingPathComponent("models") }
    static var library: URL {
        let u = support.appendingPathComponent("Library")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var glossary: URL { support.appendingPathComponent("glossary.txt") }
    static var log: URL { support.appendingPathComponent("openbean.log") }
    /// 笔记模板（用户可改）；文件不存在或为空时用默认模板
    static var noteTemplate: URL { support.appendingPathComponent("note-template.md") }

    static func readNoteTemplate() -> String {
        let s = (try? String(contentsOf: noteTemplate, encoding: .utf8)) ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NoteTemplate.defaultTemplate : s
    }

    /// 「编辑笔记模板」：第一次打开时写一份带说明的默认模板
    static func ensureNoteTemplate() {
        guard !FileManager.default.fileExists(atPath: noteTemplate.path) else { return }
        try? (NoteTemplate.help + NoteTemplate.defaultTemplate).write(to: noteTemplate, atomically: true, encoding: .utf8)
    }

    static func readGlossary() -> [String] {
        if !FileManager.default.fileExists(atPath: glossary.path) {
            try? """
            # One term per line (names, product names, jargon). OpenBean fixes same-sounding words to these; clean-up prefers them too.
            # A word it keeps mishearing: write the term, an equals sign, then what it hears, separated by commas:
            #   Claude Code = cloud code, 克劳德 code
            # English aliases ignore case, spaces and hyphens and match whole words; Chinese ones must match exactly.

            """.write(to: glossary, atomically: true, encoding: .utf8)
        }
        return ((try? String(contentsOf: glossary, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// 简单日志：~/Library/Application Support/openbean/openbean.log
enum Log {
    private static let q = DispatchQueue(label: "openbean.log")
    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: AppPaths.log) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: AppPaths.log, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 等排队的日志都写完（退出前用）
    static func flush() { q.sync {} }
}

/// 钥匙串里的通用密码（服务名 OpenBean）
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "OpenBean", kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        #if DEMO || DEBUG || os(iOS)
        // 演示版、预览不碰钥匙串（服务名和正式版、开发版相同，读了会弹授权框）
        if Flavor.isFake { return nil }
        #endif
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        #if DEMO || DEBUG || os(iOS)
        if Flavor.isFake { return }
        #endif
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        let st = SecItemAdd(q as CFDictionary, nil)
        if st != errSecSuccess { Log.write("钥匙串写入失败 \(account)：\(st)") }
    }
}

/// 设置（UserDefaults）
@MainActor @Observable
final class Settings {
    private let d = Flavor.defaults
    var typeIntoApp: Bool { didSet { d.set(typeIntoApp, forKey: "typeIntoApp") } }
    var polishEnabled: Bool { didSet { d.set(polishEnabled, forKey: "polishEnabled") } }
    var polishEndpoint: String { didSet { d.set(polishEndpoint, forKey: "polishEndpoint") } }
    var polishModel: String { didSet { d.set(polishModel, forKey: "polishModel") } }
    /// 云端润色服务的 Key，存钥匙串，不进 UserDefaults
    var polishAPIKey: String { didSet { Keychain.set(polishAPIKey, for: "polishAPIKey") } }
    /// 整理用哪种后端："onDevice" / "service" / 空（没选过：iOS 上端侧能用就用端侧，否则不整理；Mac 不看它）
    var llmChoiceStored: String { didSet { d.set(llmChoiceStored, forKey: "llmBackend") } }
    /// 选的预置服务（CloudPreset.id）；空 = 没选过
    var cloudProvider: String { didSet { d.set(cloudProvider, forKey: "cloudProvider") } }
    /// 确认过「转写文字会发给云端服务」（第一次从端侧切到云端时问一次）
    var cloudConfirmed: Bool { didSet { d.set(cloudConfirmed, forKey: "cloudConfirmed") } }
    /// 语音识别模型只在 Wi‑Fi 下下载（iOS）
    var modelWifiOnly: Bool { didSet { d.set(modelWifiOnly, forKey: "modelWifiOnly") } }
    var paragraphGap: Double { didSet { d.set(paragraphGap, forKey: "paragraphGap") } }
    /// 停顿多久算一句结束；重启 App 后生效
    var sentencePause: Double { didSet { d.set(sentencePause, forKey: "sentencePause") } }
    #if os(macOS)
    var hotkey: Hotkey.Preset { didSet { d.set(hotkey.rawValue, forKey: "hotkey"); onHotkeyChange?() } }
    /// 自己录的快捷键（hotkey == .custom 时用）
    var hotkeyCustom: Hotkey.Combo? {
        didSet {
            d.set(hotkeyCustom.flatMap { try? JSONEncoder().encode($0) }, forKey: "hotkeyCustom")
            onHotkeyChange?()
        }
    }
    /// 现在生效的键；没有（关掉了，或选了自定义还没录）返回 nil
    var hotkeyKey: (code: UInt32, mods: UInt32)? {
        hotkey == .custom ? hotkeyCustom.map { ($0.code, $0.mods) } : hotkey.key
    }
    /// 显示用的写法
    var hotkeyLabel: String {
        hotkey == .custom ? (hotkeyCustom?.label ?? String(localized: "None")) : hotkey.label
    }
    #endif
    var autoTranscribe: Bool { didSet { d.set(autoTranscribe, forKey: "autoTranscribe") } }
    /// 录音转写显示干净版（去语气词、口吃和重复，见 TranscriptCleaner）；复制、导出、笔记里的转写也跟着它。
    /// 存着的转写、摘要、日记都用原文，不受它影响
    var cleanTranscripts: Bool { didSet { d.set(cleanTranscripts, forKey: "cleanTranscripts") } }
    /// 连上录音豆、或放回充电盒时自动经蓝牙下载新录音
    var autoSync: Bool { didSet { d.set(autoSync, forKey: "autoSync") } }
    var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    /// 录音豆按键：true = 语音输入；false = 只录音（例如录会议）
    var buttonDictates: Bool { didSet { d.set(buttonDictates, forKey: "buttonDictates") } }
    /// 可以开始说话时提示一声
    var readySound: Bool { didSet { d.set(readySound, forKey: "readySound") } }
    /// 「今天」和日记里一天从几点开始（默认凌晨 4 点：凌晨两点的谈话算前一天）
    var dayStartHour: Int { didSet { d.set(dayStartHour, forKey: "dayStartHour") } }
    /// 在本机保存语音输入记录（语音输入页、「今天」里的语音输入一行靠它）
    var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }
    /// 转写完用大模型（润色那个服务）写摘要
    var summarizeRecordings: Bool { didSet { d.set(summarizeRecordings, forKey: "summarizeRecordings") } }
    /// 心力模式总开关。默认关，只有走完心力模式介绍（或之后在心力模式设置里打开）才开；
    /// 0.5 以前开着「每天写一篇日记」的人也一样，只是介绍里会提一句（见 HeartIntro）。
    /// 随模式变的取值都在 `mode`（ModeDefaults）里算，别处不直接判断这个开关
    var heartMode: Bool { didSet { d.set(heartMode, forKey: ModeKeys.heartMode) } }
    /// 心力模式介绍走完或点过「以后再说」：之后不再自动出现（心力模式页关着时还可以再打开）
    var heartIntroSeen: Bool { didSet { d.set(heartIntroSeen, forKey: ModeKeys.heartIntroSeen) } }
    /// 启动时算出的：这次要不要自动出现心力模式介绍、什么时候（启动时 / 首次使用向导之后）
    @ObservationIgnored private(set) var heartIntroAtLaunch: HeartIntro.Decision = .seen
    /// 介绍里几项选择的初始值：现在存着的选择（没改过就是出厂值）
    var heartIntroPrefill: HeartIntro.Prefill {
        HeartIntro.Prefill(deleteFromRecorder: heartDeleteFromRecorder, audioRetention: heartAudioRetention,
                           hadDailyDiary: d.bool(forKey: ModeKeys.legacyDailyDiary))
    }
    /// 现在该不该自动打开介绍（看过了、已经开着就不）
    var heartIntroPending: Bool {
        if case .show = heartIntroAtLaunch { return !heartIntroSeen && !heartMode }
        return false
    }
    /// 心力模式：同时为每条录音写一篇笔记（默认关，只写日记）
    var heartRecordingNotes: Bool { didSet { d.set(heartRecordingNotes, forKey: ModeKeys.heartRecordingNotes) } }
    /// 心力模式：同步并转写完成后，从心力豆删除这条录音
    var heartDeleteFromRecorder: Bool { didSet { d.set(heartDeleteFromRecorder, forKey: ModeKeys.heartDeleteFromRecorder) } }
    /// 心力模式录音的本机音频留多久
    var heartAudioRetention: AudioRetention { didSet { d.set(heartAudioRetention.rawValue, forKey: ModeKeys.heartAudioRetention) } }
    /// 允许 Agent（MCP）读取心力模式录音的原文（MCP 服务每次调用时从偏好设置读）
    var heartAgentTranscripts: Bool { didSet { d.set(heartAgentTranscripts, forKey: ModeKeys.heartAgentTranscripts) } }

    /// 现在生效的、随模式变的取值（界面和业务都从这里读）
    var mode: ModeDefaults {
        ModeDefaults(heartMode: heartMode, autoSyncSetting: autoSync, notesSetting: notesEnabled,
                     heartRecordingNotes: heartRecordingNotes, heartDeleteFromRecorder: heartDeleteFromRecorder,
                     heartAudioRetention: heartAudioRetention, heartAgentTranscripts: heartAgentTranscripts)
    }
    /// 日记笔记放在笔记文件夹的哪个子文件夹；空 = 默认（按 App 语言，「日记」或 Diary）
    var diaryFolder: String { didSet { d.set(diaryFolder, forKey: "diaryFolder") } }
    /// 每条录音在下面这个文件夹里写一份 Markdown 笔记
    var notesEnabled: Bool { didSet { d.set(notesEnabled, forKey: "notesEnabled") } }
    /// 笔记文件夹（如 Obsidian 库里的某个文件夹）；空 = 没选
    var notesFolder: String { didSet { d.set(notesFolder, forKey: "notesFolder") } }
    /// 语音输入结束后，从录音豆删掉 App 为这次语音输入新建的文件
    var deleteDictationAudio: Bool { didSet { d.set(deleteDictationAudio, forKey: "deleteDictationAudio") } }
    @ObservationIgnored var onHotkeyChange: (() -> Void)?

    /// 大模型服务地址的默认值：Mac 上是 App 自己起的本机 llama-server；手机上没有本机服务，默认空（选服务时填）
    #if os(macOS)
    static let defaultEndpoint = "http://127.0.0.1:8092"
    #else
    static let defaultEndpoint = ""
    #endif

    /// 「语音输入后删设备文件」的默认值（只改这一处）
    static let deleteDictationAudioDefault = true

    init() {
        // 要在注册默认值之前：注册后就分不清 heartMode 是「没设置过」还是「设成了关」。
        // 心力模式开关本身不在这里改：旧的「每日日记」不再自动打开心力模式，只让介绍出现
        let intro = HeartIntro.run(d)
        switch intro {
        case .alreadyOn: Log.write("心力模式已经开着：保持开，不再介绍")
        case let .show(when, p): Log.write("心力模式介绍：\(when == .atLaunch ? "启动时" : "首次使用向导之后")出现\(p.hadDailyDiary ? "（以前开着每日日记）" : "")")
        case .seen: break
        }
        d.register(defaults: ModeDefaults.registeredDefaults)
        d.register(defaults: ["typeIntoApp": true, "polishEnabled": false,
                              "polishEndpoint": Self.defaultEndpoint, "polishModel": "local",
                              "llmBackend": "", "cloudProvider": "", "cloudConfirmed": false, "modelWifiOnly": true,
                              "paragraphGap": 2.5, "sentencePause": 0.8,
                              "autoTranscribe": true, "cleanTranscripts": true,
                              "onboardingDone": false, "buttonDictates": true, "readySound": true,
                              "keepHistory": true, "autoSync": true, "summarizeRecordings": false,
                              "notesEnabled": false, "notesFolder": "", "dayStartHour": 4,
                              "diaryFolder": "",
                              "deleteDictationAudio": Self.deleteDictationAudioDefault])
        #if os(macOS)
        d.register(defaults: ["hotkey": Hotkey.Preset.optionSpace.rawValue])
        #endif
        typeIntoApp = d.bool(forKey: "typeIntoApp")
        polishEnabled = d.bool(forKey: "polishEnabled")
        polishEndpoint = d.string(forKey: "polishEndpoint") ?? ""
        polishModel = d.string(forKey: "polishModel") ?? "local"
        polishAPIKey = Keychain.get("polishAPIKey") ?? ""
        llmChoiceStored = d.string(forKey: "llmBackend") ?? ""
        cloudProvider = d.string(forKey: "cloudProvider") ?? ""
        cloudConfirmed = d.bool(forKey: "cloudConfirmed")
        modelWifiOnly = d.bool(forKey: "modelWifiOnly")
        paragraphGap = d.double(forKey: "paragraphGap")
        sentencePause = d.double(forKey: "sentencePause")
        #if os(macOS)
        hotkey = Hotkey.Preset(rawValue: d.string(forKey: "hotkey") ?? "") ?? .optionSpace
        hotkeyCustom = d.data(forKey: "hotkeyCustom").flatMap { try? JSONDecoder().decode(Hotkey.Combo.self, from: $0) }
        #endif
        autoTranscribe = d.bool(forKey: "autoTranscribe")
        cleanTranscripts = d.bool(forKey: "cleanTranscripts")
        autoSync = d.bool(forKey: "autoSync")
        onboardingDone = d.bool(forKey: "onboardingDone")
        buttonDictates = d.bool(forKey: "buttonDictates")
        readySound = d.bool(forKey: "readySound")
        keepHistory = d.bool(forKey: "keepHistory")
        dayStartHour = d.integer(forKey: "dayStartHour")
        summarizeRecordings = d.bool(forKey: "summarizeRecordings")
        notesEnabled = d.bool(forKey: "notesEnabled")
        let m = ModeDefaults(defaults: d)
        heartMode = m.heartMode
        heartIntroSeen = d.bool(forKey: ModeKeys.heartIntroSeen)
        heartIntroAtLaunch = intro
        heartRecordingNotes = m.heartRecordingNotes
        heartDeleteFromRecorder = m.heartDeleteFromRecorder
        heartAudioRetention = m.heartAudioRetention
        heartAgentTranscripts = m.heartAgentTranscripts
        diaryFolder = d.string(forKey: "diaryFolder") ?? ""
        notesFolder = d.string(forKey: "notesFolder") ?? ""
        deleteDictationAudio = d.bool(forKey: "deleteDictationAudio")
    }
}

/// 开发版（bin/build-app 编出来的「OpenBean Dev」）和正式版是两个 App：应用标识、数据目录、链接前缀都分开，
/// 可以装在同一台机器上互不影响。开发版不自动更新，免得被正式包覆盖。
enum Flavor {
    static let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    #if os(iOS)
    /// iOS 版的演示数据：启动参数 -demo 或环境变量 OPENBEAN_DEMO=1（模拟器 simctl launch 时可带），
    /// 和 Mac 演示版同一套假数据（Demo.swift 的 DemoData），数据目录 openbean-demo，不碰蓝牙和钥匙串
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
        || ProcessInfo.processInfo.environment["OPENBEAN_DEMO"] == "1"
    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
    static let schemes: Set<String> = ["openbean"]
    static let dataFolder = isDemo ? DemoState.dataFolder : isPreview ? "openbean-preview" : "openbean"
    #elseif DEMO
    /// 演示版（OPENBEAN_FLAVOR=demo bin/build-app，编译条件 DEMO）：假数据、不碰蓝牙，截界面用，见 Demo.swift
    static let isDemo = true
    static let isPreview = false
    static let schemes: Set<String> = ["openbean-demo"]
    static let dataFolder = DemoState.dataFolder
    #else
    static let isDemo = false
    #if DEBUG
    /// Xcode 预览（Previews.swift）：和演示版用同一套假数据（数据目录 openbean-preview），不碰蓝牙和钥匙串
    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
    #else
    static let isPreview = false
    #endif
    /// 这个 App 认的链接前缀。开发版也认 openbean://，这样已有的笔记链接和快捷指令照常能用
    static let schemes: Set<String> = isDev ? ["openbean-dev", "openbean"] : ["openbean"]
    static let dataFolder = isPreview ? "openbean-preview" : isDev ? "openbean-dev" : "openbean"
    #endif
    /// 用假数据（演示版、Xcode 预览）
    static var isFake: Bool { isDemo || isPreview }
    /// 设置存在哪：预览和 Debug 版同一个应用标识（dev.openbean.app），不能写进正式版的设置
    #if os(iOS)
    /// iOS 版演示数据和正式数据在同一个 App 里：演示时设置写进单独的一份，不覆盖真实设置
    static let defaults: UserDefaults = isFake ? UserDefaults(suiteName: "dev.openbean.ios.demo") ?? .standard : .standard
    #else
    static let defaults: UserDefaults = isPreview ? UserDefaults(suiteName: "dev.openbean.preview") ?? .standard : .standard
    #endif
    /// 开发版、演示版、预览不自动更新
    static var updates: Bool { !isDev && !isFake }
    /// 菜单栏图标旁的小标记：开发版 D，演示版 DEMO
    static var badge: String? { isDemo ? "DEMO" : isDev ? "D" : nil }
}
