// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
@testable import OpenBeanMCP
import XCTest

/// 心力模式同步进来的录音（index.json 里 source = "heart"）：默认不给 agent 原文，只给段摘要和日记；
/// App 设置里允许后照常给。普通录音（没有 source）不受影响
final class HeartPrivacyToolTests: XCTestCase {
    private var fx: Fixture!
    private var allowed = false
    private var tools: LibraryTools!
    private let heartID: UInt32 = 3001
    private var heartStart: Date { Fixture.t0.addingTimeInterval(1800) } // 11-12 15:41

    private let lines: [[String: Any]] = [
        ["start": 1.0, "end": 4.0, "text": "心力豆里的私密原文。"], ["start": 5.0, "end": 8.0, "text": "关于预算的私下讨论。"],
        ["start": 900.0, "end": 904.0, "text": "第二段也说到预算。"],
    ]

    override func setUpWithError() throws {
        fx = try Fixture()
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fx.folder.appendingPathComponent("index.json"))) as? [[String: Any]])
        var e = Fixture.entry(heartID, start: heartStart, seconds: 910)
        e["source"] = "heart"
        index.append(e)
        try fx.writeJSON("index.json", index)
        try fx.writeJSON("transcript.json", lines, id: heartID)
        var f = ConversationFile.build(lines.map { .init(start: $0["start"] as! Double, end: $0["end"] as! Double, text: $0["text"] as! String) },
                                       recordingStart: heartStart, wallApprox: false)
        f.segments[0].summary = ConversationSummary(title: "预算", summary: "讨论了预算安排。")
        try fx.write("segments.json", String(decoding: try f.encoded(), as: UTF8.self), id: heartID)
        tools = LibraryTools(location: LibraryLocation(folder: fx.folder, flavor: .release), timeZone: Fixture.tz,
                             now: { Fixture.now }, heartTranscriptsAllowed: { [unowned self] in self.allowed })
    }

    override func tearDown() { fx.remove() }

    private func call(_ name: String, _ args: [String: JSON]) throws -> ToolResult {
        try XCTUnwrap(tools.call(name, arguments: args))
    }

    func testGetTranscriptIsPrivateByDefault() throws {
        let r = try call("get_transcript", ["id": .int(Int(heartID))])
        XCTAssertFalse(r.isError)
        XCTAssertFalse(r.text.contains("私密原文"), r.text)
        XCTAssertTrue(r.text.contains("Heart mode"), r.text)
        XCTAssertTrue(r.text.contains("conversation 0") && r.text.contains("讨论了预算安排。"), r.text)
        XCTAssertTrue(r.text.contains("day_overview with date 2026-11-12"), r.text)
        XCTAssertEqual(r.structured?["transcript_private"], .bool(true))
        XCTAssertEqual(r.structured?["segments"]?.array?.count, 0)
        // 按段、按时间范围也一样
        XCTAssertFalse(try call("get_transcript", ["id": .int(Int(heartID)), "conversation": 0]).text.contains("私密原文"))
        XCTAssertFalse(try call("get_transcript", ["id": .int(Int(heartID)), "start_seconds": 0, "end_seconds": 5]).text.contains("私密原文"))
    }

    func testGetTranscriptWhenAllowed() throws {
        allowed = true
        let r = try call("get_transcript", ["id": .int(Int(heartID))])
        XCTAssertTrue(r.text.contains("私密原文"), r.text)
        XCTAssertNil(r.structured?["transcript_private"])
    }

    func testNormalRecordingsUnaffected() throws {
        let r = try call("get_transcript", ["id": 1001])
        XCTAssertTrue(r.text.contains("下周五发布"), r.text)
    }

    func testSearchSkipsPrivateTranscriptsButFindsSummaries() throws {
        let words = try call("search_recordings", ["query": "私下讨论"])
        XCTAssertEqual(words.structured?["total"], .int(0), words.text)
        XCTAssertFalse(words.text.contains("私下讨论。"))

        let summary = try call("search_recordings", ["query": "预算安排"])
        XCTAssertEqual(summary.structured?["total"], .int(1), summary.text)
        let m = try XCTUnwrap(summary.structured?["results"]?.array?.first?["matches"]?.array?.first)
        XCTAssertEqual(m["field"], "conversation_summary")
        XCTAssertEqual(m["conversation"], .int(0))

        allowed = true
        XCTAssertEqual(try call("search_recordings", ["query": "私下讨论"]).structured?["total"], .int(1))
    }

    func testListAndOverviewDoNotLeakTheWords() throws {
        let list = try call("list_recordings", ["from": "2026-11-12", "to": "2026-11-12"])
        XCTAssertFalse(list.text.contains("私密原文"), list.text)
        XCTAssertTrue(list.text.contains("讨论了预算安排。"), list.text)
        XCTAssertEqual(try call("list_recordings", ["query": "私下讨论"]).structured?["total"], .int(0))

        let day = try call("day_overview", ["date": "2026-11-12"])
        XCTAssertFalse(day.text.contains("私密原文"), day.text)
        XCTAssertTrue(day.text.contains("讨论了预算安排。"), day.text)
    }

    func testGetRecordingShowsConversationSummaries() throws {
        let r = try call("get_recording", ["id": .int(Int(heartID))])
        XCTAssertTrue(r.text.contains("Transcript: private."), r.text)
        XCTAssertTrue(r.text.contains("conversation 0") && r.text.contains("预算"), r.text)
        XCTAssertEqual(r.structured?["transcript_private"], .bool(true))
        XCTAssertEqual(r.structured?["conversations"]?.array?.count, 2)
    }
}
