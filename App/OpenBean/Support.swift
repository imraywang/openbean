// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Observation
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

    static func readGlossary() -> [String] {
        if !FileManager.default.fileExists(atPath: glossary.path) {
            try? "# One term per line (names, product names, jargon). OpenBean fixes same-sounding words to these; clean-up prefers them too.\n"
                .write(to: glossary, atomically: true, encoding: .utf8)
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
    var autoTranscribe: Bool { didSet { d.set(autoTranscribe, forKey: "autoTranscribe") } }
    var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    /// 录音豆按键：true = 语音输入；false = 只录音（例如录会议）
    var buttonDictates: Bool { didSet { d.set(buttonDictates, forKey: "buttonDictates") } }
    /// 可以开始说话时提示一声
    var readySound: Bool { didSet { d.set(readySound, forKey: "readySound") } }
    /// 在本机保存语音输入记录（概览里的统计也靠它）
    var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }
    @ObservationIgnored var onHotkeyChange: (() -> Void)?

    init() {
        d.register(defaults: ["typeIntoApp": true, "polishEnabled": false,
                              "polishEndpoint": "http://127.0.0.1:8092", "polishModel": "local",
                              "paragraphGap": 2.5, "sentencePause": 0.8,
                              "hotkey": Hotkey.Preset.optionSpace.rawValue, "autoTranscribe": true,
                              "onboardingDone": false, "buttonDictates": true, "readySound": true,
                              "keepHistory": true])
        typeIntoApp = d.bool(forKey: "typeIntoApp")
        polishEnabled = d.bool(forKey: "polishEnabled")
        polishEndpoint = d.string(forKey: "polishEndpoint") ?? ""
        polishModel = d.string(forKey: "polishModel") ?? "local"
        polishAPIKey = Keychain.get("polishAPIKey") ?? ""
        paragraphGap = d.double(forKey: "paragraphGap")
        sentencePause = d.double(forKey: "sentencePause")
        hotkey = Hotkey.Preset(rawValue: d.string(forKey: "hotkey") ?? "") ?? .optionSpace
        autoTranscribe = d.bool(forKey: "autoTranscribe")
        onboardingDone = d.bool(forKey: "onboardingDone")
        buttonDictates = d.bool(forKey: "buttonDictates")
        readySound = d.bool(forKey: "readySound")
        keepHistory = d.bool(forKey: "keepHistory")
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
        case off, optionSpace, controlOptionSpace, commandShiftD, f5
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return String(localized: "None")
            case .optionSpace: return "⌥ Space"
            case .controlOptionSpace: return "⌃⌥ Space"
            case .commandShiftD: return "⇧⌘ D"
            case .f5: return "F5"
            }
        }
        var key: (code: UInt32, mods: UInt32)? {
            switch self {
            case .off: return nil
            case .optionSpace: return (UInt32(kVK_Space), UInt32(optionKey))
            case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(optionKey | controlKey))
            case .commandShiftD: return (UInt32(kVK_ANSI_D), UInt32(cmdKey | shiftKey))
            case .f5: return (UInt32(kVK_F5), 0)
            }
        }
    }

    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: () -> Void = {}

    func register(_ preset: Preset) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.shared.onPress() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        guard let k = preset.key else { return }
        let id = EventHotKeyID(signature: OSType(0x4F42_4E21), id: 1) // "OBN!"
        let status = RegisterEventHotKey(k.code, k.mods, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.write("快捷键注册失败 \(preset.rawValue)：\(status)") }
    }
}
