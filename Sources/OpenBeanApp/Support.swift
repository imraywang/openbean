// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import Foundation
import Observation

enum AppPaths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("openbean")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var models: URL { support.appendingPathComponent("models") }
    static var glossary: URL { support.appendingPathComponent("glossary.txt") }
    static var log: URL { support.appendingPathComponent("openbean.log") }

    static func readGlossary() -> [String] {
        if !FileManager.default.fileExists(atPath: glossary.path) {
            try? "# 个人词表：每行一个常用词、人名或术语，润色时优先纠正成这些词\n".write(to: glossary, atomically: true, encoding: .utf8)
        }
        return ((try? String(contentsOf: glossary, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// 简单日志：写到 ~/Library/Application Support/openbean/openbean.log
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
}

/// 设置（存 UserDefaults）
@MainActor @Observable
final class Settings {
    private let d = UserDefaults.standard
    var typeIntoApp: Bool { didSet { d.set(typeIntoApp, forKey: "typeIntoApp") } }
    var polishEnabled: Bool { didSet { d.set(polishEnabled, forKey: "polishEnabled") } }
    var polishEndpoint: String { didSet { d.set(polishEndpoint, forKey: "polishEndpoint") } }
    var polishModel: String { didSet { d.set(polishModel, forKey: "polishModel") } }
    var paragraphGap: Double { didSet { d.set(paragraphGap, forKey: "paragraphGap") } }
    /// 停顿多久算一句结束（交给 SenseVoice 定稿）。太短会把一句话切碎、识别变差；重启 App 后生效
    var sentencePause: Double { didSet { d.set(sentencePause, forKey: "sentencePause") } }

    init() {
        d.register(defaults: ["typeIntoApp": true, "polishEnabled": false,
                              "polishEndpoint": "http://127.0.0.1:8092", "polishModel": "local", "paragraphGap": 1.5,
                              "sentencePause": 0.8])
        typeIntoApp = d.bool(forKey: "typeIntoApp")
        polishEnabled = d.bool(forKey: "polishEnabled")
        polishEndpoint = d.string(forKey: "polishEndpoint") ?? ""
        polishModel = d.string(forKey: "polishModel") ?? "local"
        paragraphGap = d.double(forKey: "paragraphGap")
        sentencePause = d.double(forKey: "sentencePause")
    }
}

/// 用键盘事件把文字打进当前焦点所在的应用（需要「辅助功能」权限）。
enum Typist {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
