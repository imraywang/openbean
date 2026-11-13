// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Observation
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
        #if DEMO || DEBUG
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
        #if DEMO || DEBUG
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
    var paragraphGap: Double { didSet { d.set(paragraphGap, forKey: "paragraphGap") } }
    /// 停顿多久算一句结束；重启 App 后生效
    var sentencePause: Double { didSet { d.set(sentencePause, forKey: "sentencePause") } }
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
    var autoTranscribe: Bool { didSet { d.set(autoTranscribe, forKey: "autoTranscribe") } }
    /// 连上录音豆、或放回充电盒时自动经蓝牙下载新录音
    var autoSync: Bool { didSet { d.set(autoSync, forKey: "autoSync") } }
    var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    /// 录音豆按键：true = 语音输入；false = 只录音（例如录会议）
    var buttonDictates: Bool { didSet { d.set(buttonDictates, forKey: "buttonDictates") } }
    /// 可以开始说话时提示一声
    var readySound: Bool { didSet { d.set(readySound, forKey: "readySound") } }
    /// 在本机保存语音输入记录（概览里的统计也靠它）
    var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }
    /// 转写完用大模型（润色那个服务）写摘要
    var summarizeRecordings: Bool { didSet { d.set(summarizeRecordings, forKey: "summarizeRecordings") } }
    /// 每条录音在下面这个文件夹里写一份 Markdown 笔记
    var notesEnabled: Bool { didSet { d.set(notesEnabled, forKey: "notesEnabled") } }
    /// 笔记文件夹（如 Obsidian 库里的某个文件夹）；空 = 没选
    var notesFolder: String { didSet { d.set(notesFolder, forKey: "notesFolder") } }
    /// 语音输入结束后，从录音豆删掉 App 为这次语音输入新建的文件
    var deleteDictationAudio: Bool { didSet { d.set(deleteDictationAudio, forKey: "deleteDictationAudio") } }
    @ObservationIgnored var onHotkeyChange: (() -> Void)?

    /// 「语音输入后删设备文件」的默认值（只改这一处）
    static let deleteDictationAudioDefault = true

    init() {
        d.register(defaults: ["typeIntoApp": true, "polishEnabled": false,
                              "polishEndpoint": "http://127.0.0.1:8092", "polishModel": "local",
                              "paragraphGap": 2.5, "sentencePause": 0.8,
                              "hotkey": Hotkey.Preset.optionSpace.rawValue, "autoTranscribe": true,
                              "onboardingDone": false, "buttonDictates": true, "readySound": true,
                              "keepHistory": true, "autoSync": true, "summarizeRecordings": false,
                              "notesEnabled": false, "notesFolder": "",
                              "deleteDictationAudio": Self.deleteDictationAudioDefault])
        typeIntoApp = d.bool(forKey: "typeIntoApp")
        polishEnabled = d.bool(forKey: "polishEnabled")
        polishEndpoint = d.string(forKey: "polishEndpoint") ?? ""
        polishModel = d.string(forKey: "polishModel") ?? "local"
        polishAPIKey = Keychain.get("polishAPIKey") ?? ""
        paragraphGap = d.double(forKey: "paragraphGap")
        sentencePause = d.double(forKey: "sentencePause")
        hotkey = Hotkey.Preset(rawValue: d.string(forKey: "hotkey") ?? "") ?? .optionSpace
        hotkeyCustom = d.data(forKey: "hotkeyCustom").flatMap { try? JSONDecoder().decode(Hotkey.Combo.self, from: $0) }
        autoTranscribe = d.bool(forKey: "autoTranscribe")
        autoSync = d.bool(forKey: "autoSync")
        onboardingDone = d.bool(forKey: "onboardingDone")
        buttonDictates = d.bool(forKey: "buttonDictates")
        readySound = d.bool(forKey: "readySound")
        keepHistory = d.bool(forKey: "keepHistory")
        summarizeRecordings = d.bool(forKey: "summarizeRecordings")
        notesEnabled = d.bool(forKey: "notesEnabled")
        notesFolder = d.string(forKey: "notesFolder") ?? ""
        deleteDictationAudio = d.bool(forKey: "deleteDictationAudio")
    }
}

/// 用键盘事件把文字打进当前焦点所在的应用（需要辅助功能权限）。
enum Typist {
    static var trusted: Bool {
        #if DEMO || DEBUG
        if Flavor.isFake { return DemoState.trustedValue }
        #endif
        return AXIsProcessTrusted()
    }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    enum Focus: Equatable { case editable, notEditable, unknown }

    /// 当前键盘焦点能不能打字。只有明确看到「焦点在一个不能输入的控件上」才说不能；
    /// 拿不到焦点信息、或者是网页 / 窗口这类看不出里面是什么的，一律算不知道（照常打字）。
    static func focus() -> (kind: Focus, role: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (.unknown, "no app") }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        func focused() -> AXUIElement? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &v) == .success,
                  let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
        func role(_ e: AXUIElement) -> String {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v)
            return v as? String ?? "?"
        }
        let opaque: Set<String> = ["AXWebArea", "AXWindow", "AXApplication", "AXScrollArea", "AXGroup", "AXUnknown", "?"]
        var el = focused()
        // Electron 默认不给出网页里的控件，要先打开它的辅助功能再问；打开成功说明是 Electron，
        // 这之后输入框会报成文本控件，焦点还停在网页 / 分组上就是没在输入框里（比如点在画布上）
        var electron = false
        if el.map({ opaque.contains(role($0)) }) ?? true {
            electron = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
            if electron {
                // 辅助功能树要一点时间才建好，最多等 0.4 秒
                for _ in 0..<4 {
                    usleep(100_000)
                    el = focused()
                    if let e = el, !opaque.contains(role(e)) { break }
                }
            }
        }
        guard let el else { return (.unknown, "none") }
        let r = role(el)
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) { return (.editable, r) }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue {
            return (.editable, r)
        }
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return (.editable, r)
        }
        if opaque.contains(r) { return (electron && (r == "AXWebArea" || r == "AXGroup") ? .notEditable : .unknown, r) }
        return (.notEditable, r)
    }

    static func type(_ text: String) {
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            var chunk = Array(units[start..<min(start + 16, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// 分段用 Shift+回车：聊天软件里直接回车会把消息发出去
    static func newline() {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down) else { continue }
            e.flags = .maskShift
            e.post(tap: .cghidEventTap)
        }
    }
}

/// 开发版（bin/build-app 编出来的「OpenBean Dev」）和正式版是两个 App：应用标识、数据目录、链接前缀都分开，
/// 可以装在同一台机器上互不影响。开发版不自动更新，免得被正式包覆盖。
enum Flavor {
    static let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    #if DEMO
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
    static let defaults: UserDefaults = isPreview ? UserDefaults(suiteName: "dev.openbean.preview") ?? .standard : .standard
    /// 开发版、演示版、预览不自动更新
    static var updates: Bool { !isDev && !isFake }
    /// 菜单栏图标旁的小标记：开发版 D，演示版 DEMO
    static var badge: String? { isDemo ? "DEMO" : isDev ? "D" : nil }
}

/// 全局快捷键（Carbon 热键，不需要额外权限）
@MainActor
final class Hotkey {
    enum Preset: String, CaseIterable, Identifiable {
        case off, optionSpace, controlOptionSpace, commandShiftD, f5, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return String(localized: "None")
            case .optionSpace: return "⌥ Space"
            case .controlOptionSpace: return "⌃⌥ Space"
            case .commandShiftD: return "⇧⌘ D"
            case .f5: return "F5"
            case .custom: return String(localized: "Custom…")
            }
        }
        var key: (code: UInt32, mods: UInt32)? {
            switch self {
            case .off: return nil
            case .optionSpace: return (UInt32(kVK_Space), UInt32(optionKey))
            case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(optionKey | controlKey))
            case .commandShiftD: return (UInt32(kVK_ANSI_D), UInt32(cmdKey | shiftKey))
            case .f5: return (UInt32(kVK_F5), 0)
            case .custom: return nil // 自定义的键在 Settings.hotkeyCustom 里
            }
        }
    }

    /// 用户自己录的快捷键：虚拟键码 + Carbon 修饰键 + 显示用的写法（如 ⌃⌥ D）
    struct Combo: Codable, Equatable {
        var code: UInt32
        var mods: UInt32
        var label: String

        static let functionKeys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
            kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        ]
        static let namedKeys: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]

        /// 从一次按键得到快捷键。普通键必须带 ⌘、⌥ 或 ⌃（只带 ⇧ 会挡住正常打字）；F 键可以单独用。不合格返回 nil
        init?(event: NSEvent) {
            let code = Int(event.keyCode)
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let fn = Self.functionKeys[code]
            guard fn != nil || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
            let name = fn ?? Self.namedKeys[code] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var mods: UInt32 = 0, symbols = ""
            if flags.contains(.control) { mods |= UInt32(controlKey); symbols += "⌃" }
            if flags.contains(.option) { mods |= UInt32(optionKey); symbols += "⌥" }
            if flags.contains(.shift) { mods |= UInt32(shiftKey); symbols += "⇧" }
            if flags.contains(.command) { mods |= UInt32(cmdKey); symbols += "⌘" }
            self.code = UInt32(code)
            self.mods = mods
            self.label = symbols.isEmpty ? name : "\(symbols) \(name)"
        }
    }

    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: () -> Void = {}

    /// 注册快捷键；nil = 不用快捷键。返回是否注册成功（被系统或别的 App 占用时失败）
    @discardableResult
    func register(_ key: (code: UInt32, mods: UInt32)?) -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.shared.onPress() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        guard let k = key else { return true }
        let id = EventHotKeyID(signature: OSType(0x4F42_4E21), id: 1) // "OBN!"
        let status = RegisterEventHotKey(k.code, k.mods, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.write("快捷键注册失败 code=\(k.code) mods=\(k.mods)：\(status)") }
        return status == noErr
    }
}
