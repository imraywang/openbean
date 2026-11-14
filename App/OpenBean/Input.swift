// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

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
