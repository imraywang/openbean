// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

/// 在临时目录里造一个假录音库（格式和 App 写的一样：日期是 2001-01-01 起的秒数）
struct FakeLibrary {
    let root: URL
    var folder: URL { root.appendingPathComponent("Library") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("openbean-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ text: String, id: UInt32? = nil) throws {
        var dir = folder
        if let id { dir = dir.appendingPathComponent(String(id)) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    func writeJSON(_ name: String, _ object: Any, id: UInt32? = nil) throws {
        let d = try JSONSerialization.data(withJSONObject: object)
        try write(name, String(decoding: d, as: UTF8.self), id: id)
    }

    static func entry(_ id: UInt32, start: Date, seconds: Double = 60, title: String? = nil, transcribed: Bool = true,
                      downloaded: Bool = true, dictation: Bool = false) -> [String: Any] {
        var e: [String: Any] = ["id": id, "start": start.timeIntervalSinceReferenceDate,
                                "end": start.addingTimeInterval(seconds).timeIntervalSinceReferenceDate,
                                "durationMs": Int(seconds * 1000), "onDevice": true, "downloaded": downloaded,
                                "transcribed": transcribed, "isDictation": dictation]
        if let title { e["title"] = title }
        return e
    }

    static func summary(title: String, summary: String, keyPoints: [String] = [], actionItems: [String] = []) -> [String: Any] {
        ["summary": ["title": title, "summary": summary, "keyPoints": keyPoints, "actionItems": actionItems],
         "model": "test-model", "createdAt": 800_000_000.0, "appliedTitle": title]
    }
}

final class RecordingLibraryTests: XCTestCase {
    private var fake: FakeLibrary!
    private var lib: RecordingLibrary { RecordingLibrary(folder: fake.folder) }
    // 2026-11-12 15:11:33 +08:00
    private let t0 = Date(timeIntervalSince1970: 1_794_467_493)

    override func setUpWithError() throws { fake = try FakeLibrary() }
    override func tearDown() { fake.remove() }

    func testMissingIndexThrowsNotFound() {
        XCTAssertFalse(lib.exists)
        XCTAssertThrowsError(try lib.recordings()) { XCTAssertEqual($0 as? RecordingLibrary.LibraryError, .notFound(fake.folder.path)) }
    }

    func testCorruptIndexThrowsUnreadable() throws {
        try fake.write("index.json", "[{\"id\": 1, \"start\": ")  // 写到一半
        XCTAssertThrowsError(try lib.recordings()) {
            guard case .unreadable = $0 as? RecordingLibrary.LibraryError else { return XCTFail("\($0)") }
        }
        try fake.write("index.json", "{\"id\": 1}")  // 不是数组
        XCTAssertThrowsError(try lib.recordings())
    }

    func testIndexSkipsBadEntriesAndDictationAndIgnoresExtraFields() throws {
        var extra = FakeLibrary.entry(3, start: t0, title: "周会")
        extra["someFutureField"] = ["x": 1]
        try fake.writeJSON("index.json", [
            FakeLibrary.entry(1, start: t0.addingTimeInterval(-3600)),
            FakeLibrary.entry(2, start: t0.addingTimeInterval(60), dictation: true),
            extra,
            ["id": "not a number", "start": 1.0],
            ["id": 4],                                   // 缺 start
            ["id": 5, "start": 1.0, "durationMs": true], // 字段类型不对：用默认值
            "garbage",
            FakeLibrary.entry(3, start: t0.addingTimeInterval(-10)), // id 重复：取第一项
        ])
        let list = try lib.recordings()
        XCTAssertEqual(list.map(\.id), [3, 1, 5])
        XCTAssertEqual(list[0].title, "周会")
        XCTAssertEqual(list[0].start, t0)
        XCTAssertEqual(list[0].durationMs, 60_000)
        XCTAssertEqual(list[2].durationMs, 0)
        XCTAssertNil(list[1].title)
        XCTAssertNil(try lib.recording(2), "语音输入片段不算录音")
    }

    func testMinimalEntryUsesDefaults() throws {
        try fake.write("index.json", #"[{"id": 7, "start": 800000000}]"#)
        let r = try XCTUnwrap(try lib.recording(7))
        XCTAssertFalse(r.transcribed)
        XCTAssertFalse(r.isDictation)
        XCTAssertNil(r.end)
    }

    func testTranscriptSummaryNoteLoads() throws {
        try fake.writeJSON("index.json", [FakeLibrary.entry(1, start: t0)])
        XCTAssertNil(lib.transcript(1).value)
        guard case .missing = lib.transcript(1) else { return XCTFail() }

        try fake.writeJSON("transcript.json", [["start": 5.0, "end": 6.0, "text": "第二句"],
                                               ["start": 0.5, "end": 2.0, "text": "第一句"],
                                               ["start": "bad", "text": "坏句子"]], id: 1)
        XCTAssertEqual(lib.transcript(1).value?.map(\.text), ["第一句", "第二句"])

        try fake.write("transcript.json", "[{\"start\": 0, \"te", id: 1)  // 正在写
        guard case .unreadable = lib.transcript(1) else { return XCTFail() }

        try fake.writeJSON("summary.json", FakeLibrary.summary(title: "周会", summary: "讨论发布。", keyPoints: ["周五发布"],
                                                               actionItems: ["小王写文档"]), id: 1)
        let s = try XCTUnwrap(lib.summary(1).value)
        XCTAssertEqual(s.title, "周会")
        XCTAssertEqual(s.actionItems, ["小王写文档"])
        XCTAssertEqual(s.model, "test-model")
        XCTAssertTrue(lib.hasSummary(1))

        try fake.writeJSON("summary.json", ["model": "x"], id: 1)  // 没有 summary 字段
        XCTAssertFalse(lib.hasSummary(1))

        XCTAssertNil(lib.notePath(1))
        try fake.writeJSON("note.json", ["path": "/Users/me/Notes/2026-11-12-周会.md", "writtenAt": 1.0], id: 1)
        XCTAssertEqual(lib.notePath(1), "/Users/me/Notes/2026-11-12-周会.md")
        try fake.write("note.json", "null", id: 1)
        XCTAssertNil(lib.notePath(1))
    }

    func testDateRangeIsHalfOpen() throws {
        let day = DateInterval(start: t0, duration: 86_400)
        try fake.writeJSON("index.json", [
            FakeLibrary.entry(1, start: t0),                          // 左端：算
            FakeLibrary.entry(2, start: t0.addingTimeInterval(86_399)),
            FakeLibrary.entry(3, start: t0.addingTimeInterval(86_400)), // 右端：不算
            FakeLibrary.entry(4, start: t0.addingTimeInterval(-1)),
        ])
        XCTAssertEqual(try lib.recordings(in: day).map(\.id), [2, 1])
        XCTAssertEqual(try lib.recordings(in: nil).count, 4)
    }

    func testSearchFindsTranscriptSummaryAndTitleCaseInsensitive() throws {
        try fake.writeJSON("index.json", [
            FakeLibrary.entry(1, start: t0, title: "OpenBean 周会"),
            FakeLibrary.entry(2, start: t0.addingTimeInterval(-86_400)),
            FakeLibrary.entry(3, start: t0.addingTimeInterval(-2 * 86_400), transcribed: false, downloaded: false),
        ])
        try fake.writeJSON("transcript.json", [["start": 0.0, "end": 3.0, "text": "大家好，今天讨论发布。"],
                                               ["start": 3.0, "end": 9.0, "text": "openbean 下周五发布 0.4。"],
                                               ["start": 9.0, "end": 12.0, "text": "预算不变。"]], id: 1)
        try fake.writeJSON("summary.json", FakeLibrary.summary(title: "发布会议", summary: "讨论 OPENBEAN 的发布。",
                                                               actionItems: ["小王写 OpenBean 文档"]), id: 1)
        try fake.writeJSON("transcript.json", [["start": 1.0, "end": 2.0, "text": "和 OpenBean 无关的一句"]], id: 2)

        let (hits, total) = try lib.search("openbean")
        XCTAssertEqual(total, 2)
        XCTAssertEqual(hits.map(\.recording.id), [1, 2])
        let fields = hits[0].matches.map(\.field)
        XCTAssertEqual(fields, [.title, .summary, .actionItem, .transcript])
        let t = try XCTUnwrap(hits[0].matches.last)
        XCTAssertEqual(t.time, 3.0)
        // 前后文带上相邻句子
        XCTAssertTrue(t.snippet.contains("大家好"), t.snippet)
        XCTAssertTrue(t.snippet.contains("预算不变"), t.snippet)

        // 中文子串，不分词
        XCTAssertEqual(try lib.search("周五发").hits.map(\.recording.id), [1])
        // 全角也能找到
        XCTAssertEqual(try lib.search("ＯＰＥＮＢＥＡＮ").totalRecordings, 2)
        // 日期范围和条数上限
        XCTAssertEqual(try lib.search("openbean", in: DateInterval(start: t0, duration: 60)).hits.map(\.recording.id), [1])
        let limited = try lib.search("openbean", limit: 1, perRecording: 2)
        XCTAssertEqual(limited.hits.count, 1)
        XCTAssertEqual(limited.totalRecordings, 2)
        XCTAssertEqual(limited.hits[0].matches.count, 2)
        XCTAssertEqual(limited.hits[0].total, 4)
        XCTAssertTrue(try lib.search("  ").hits.isEmpty)
        XCTAssertTrue(try lib.search("不存在的词").hits.isEmpty)
    }

    func testContainsForListFilter() throws {
        try fake.writeJSON("index.json", [FakeLibrary.entry(1, start: t0, title: "周会")])
        try fake.writeJSON("transcript.json", [["start": 0.0, "end": 1.0, "text": "Budget is fine"]], id: 1)
        let r = try XCTUnwrap(try lib.recording(1))
        XCTAssertTrue(lib.contains(r, query: "周会"))
        XCTAssertTrue(lib.contains(r, query: "BUDGET"))
        XCTAssertTrue(lib.contains(r, query: ""))
        XCTAssertFalse(lib.contains(r, query: "预算"))
    }

    func testSnippetTrimsLongText() {
        let long = String(repeating: "甲", count: 200) + "关键词" + String(repeating: "乙", count: 200)
        let s = TextMatch.snippet(long, "关键词", radius: 10)
        XCTAssertEqual(s, "…" + String(repeating: "甲", count: 10) + "关键词" + String(repeating: "乙", count: 10) + "…")
        XCTAssertEqual(TextMatch.snippet("短句关键词", "关键词", before: "前一句", after: "后一句"), "前一句 短句关键词 后一句")
    }

    func testLocationResolution() throws {
        let support = fake.root.appendingPathComponent("Support")
        let env: [String: String] = [:]
        XCTAssertEqual(LibraryLocation.resolve(path: nil, dev: false, environment: env, executable: nil, support: support),
                       LibraryLocation(folder: support.appendingPathComponent("openbean/Library"), flavor: .release))
        XCTAssertEqual(LibraryLocation.resolve(path: nil, dev: true, environment: env, executable: nil, support: support).folder,
                       support.appendingPathComponent("openbean-dev/Library"))
        // 数据目录或 Library 文件夹都行；--library 优先于环境变量
        let viaData = LibraryLocation.resolve(path: fake.root.path, dev: true, environment: ["OPENBEAN_LIBRARY": "/nope"],
                                              executable: nil, support: support)
        XCTAssertEqual(viaData, LibraryLocation(folder: fake.folder, flavor: .custom))
        XCTAssertEqual(LibraryLocation.resolve(path: nil, dev: false, environment: ["OPENBEAN_LIBRARY": fake.folder.path],
                                               executable: nil, support: support).folder, fake.folder)
        XCTAssertEqual(viaData.linkScheme, "openbean")

        // 在开发版 .app 里：按包的应用标识读 openbean-dev
        let app = fake.root.appendingPathComponent("OpenBean Dev.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.openbean.app.dev", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let exe = app.appendingPathComponent("Helpers/openbean-mcp")
        XCTAssertEqual(LibraryLocation.enclosingBundleIdentifier(exe), "dev.openbean.app.dev")
        let inDev = LibraryLocation.resolve(path: nil, dev: false, environment: env, executable: exe, support: support)
        XCTAssertEqual(inDev.flavor, .dev)
        XCTAssertEqual(inDev.linkScheme, "openbean-dev")
        XCTAssertNil(LibraryLocation.enclosingBundle(URL(fileURLWithPath: "/usr/local/bin/openbean-mcp")))
    }
}
