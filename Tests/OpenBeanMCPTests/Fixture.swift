// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary
@testable import OpenBeanMCP

/// 临时目录里的假录音库：三条录音（一条有摘要和笔记、一条只有转写、一条还在录音豆上）和一条语音输入片段。
/// 时区固定 Asia/Shanghai，「现在」固定 2026-11-13 10:00 +08:00
struct Fixture {
    let root: URL
    var folder: URL { root.appendingPathComponent("Library") }
    static let tz = TimeZone(identifier: "Asia/Shanghai")!
    /// 2026-11-12 15:11:33 +08:00
    static let t0 = Date(timeIntervalSince1970: 1_794_467_493)
    static let now = Date(timeIntervalSince1970: 1_794_535_200)

    init(index: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("openbean-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard index else { return }
        let t0 = Self.t0
        try writeJSON("index.json", [
            Self.entry(1001, start: t0, seconds: 754, title: "周会"),
            Self.entry(1002, start: t0.addingTimeInterval(-86_400 + 3600), seconds: 30),           // 11-11 16:11
            Self.entry(1003, start: t0.addingTimeInterval(3600), seconds: 90, transcribed: false, downloaded: false),
            Self.entry(1004, start: t0.addingTimeInterval(600), seconds: 5, dictation: true),
        ])
        try writeJSON("transcript.json", [["start": 0.5, "end": 3.0, "text": "大家好，今天讨论 OpenBean 0.4 的发布。"],
                                          ["start": 3.0, "end": 8.2, "text": "下周五发布，预算不变。"],
                                          ["start": 65.4, "end": 70.0, "text": "小王负责写文档。"]], id: 1001)
        try writeJSON("summary.json", ["summary": ["title": "周会", "summary": "讨论 0.4 发布时间。", "keyPoints": ["下周五发布"],
                                                   "actionItems": ["小王写文档"]],
                                       "model": "qwen3", "createdAt": 816_161_000.0, "appliedTitle": "周会"], id: 1001)
        try writeJSON("note.json", ["path": "/Users/me/Notes/2026-11-12-周会.md", "writtenAt": 816_161_000.0], id: 1001)
        try writeJSON("transcript.json", [["start": 1.0, "end": 4.0, "text": "Remember to buy milk."]], id: 1002)
        try writeJSON("transcript.json", [["start": 0.0, "end": 2.0, "text": "语音输入的秘密内容"]], id: 1004)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ text: String, id: UInt32? = nil) throws {
        var dir = folder
        if let id { dir = dir.appendingPathComponent(String(id)) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    func writeJSON(_ name: String, _ object: Any, id: UInt32? = nil) throws {
        try write(name, String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), id: id)
    }

    static func entry(_ id: UInt32, start: Date, seconds: Double, title: String? = nil, transcribed: Bool = true,
                      downloaded: Bool = true, dictation: Bool = false) -> [String: Any] {
        var e: [String: Any] = ["id": id, "start": start.timeIntervalSinceReferenceDate,
                                "end": start.addingTimeInterval(seconds).timeIntervalSinceReferenceDate,
                                "durationMs": Int(seconds * 1000), "onDevice": true, "downloaded": downloaded,
                                "transcribed": transcribed, "isDictation": dictation]
        if let title { e["title"] = title }
        return e
    }

    func server(flavor: LibraryLocation.Flavor = .release) -> MCPServer {
        let tools = LibraryTools(location: LibraryLocation(folder: folder, flavor: flavor), timeZone: Self.tz, now: { Self.now })
        return MCPServer(tools: tools, version: "0.0-test")
    }
}
