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
            .appendingPathComponent("openbean")
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
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
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
    private let d = UserDefaults.standard
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
    @ObservationIgnored var onHotkeyChange: (() -> Void)?

    init() {
        d.register(defaults: ["typeIntoApp": true, "polishEnabled": false,
                              "polishEndpoint": "http://127.0.0.1:8092", "polishModel": "local",
                              "paragraphGap": 2.5, "sentencePause": 0.8,
                              "hotkey": Hotkey.Preset.optionSpace.rawValue, "autoTranscribe": true,
                              "onboardingDone": false, "buttonDictates": true, "readySound": true,
                              "keepHistory": true, "autoSync": true, "summarizeRecordings": false,
                              "notesEnabled": false, "notesFolder": ""])
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
    }
}

/// 用键盘事件把文字打进当前焦点所在的应用（需要辅助功能权限）。
enum Typist {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
