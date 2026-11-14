// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
@testable import OpenBeanMCP
import XCTest

/// 对话段（segments.json）和日记（days/<日期>/day.json）在 MCP 里的样子。没有这些文件的旧录音库照常工作（ServerTests）
final class ConversationToolTests: XCTestCase {
    private var fx: Fixture!
    private var tools: LibraryTools!
    /// 2026-11-12 23:00 +08:00 开始、录了三个多小时的录音：23:01 一段、00:30 一段、04:20 一段（最后一段算 13 日）
    private let longID: UInt32 = 2001
    private var longStart: Date { Fixture.t0.addingTimeInterval(7 * 3600 + 48 * 60 + 27) }

    private let lines: [[String: Any]] = [
        ["start": 60.0, "end": 64.0, "text": "我们开始吧。"], ["start": 66.0, "end": 70.0, "text": "先说报价。"],
        ["start": 5400.0, "end": 5404.0, "text": "第二件事是招聘。"], ["start": 5406.0, "end": 5410.0, "text": "下周面试。"],
        ["start": 19_200.0, "end": 19_203.0, "text": "早上好。"],
    ]

    override func setUpWithError() throws {
        fx = try Fixture()
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fx.folder.appendingPathComponent("index.json"))) as? [[String: Any]])
        // 结束时刻是 0（设备没给）：墙上时间只靠开始 + 偏移
        var e = Fixture.entry(longID, start: longStart, seconds: 19_300, title: "长录音")
        e["end"] = Date(timeIntervalSince1970: 0).timeIntervalSinceReferenceDate
        index.append(e)
        try fx.writeJSON("index.json", index)
        try fx.writeJSON("transcript.json", lines, id: longID)
        let f = ConversationFile.build(lines.map { .init(start: $0["start"] as! Double, end: $0["end"] as! Double, text: $0["text"] as! String) },
                                       recordingStart: longStart, wallApprox: false)
        var withSummary = f
        withSummary.segments[0].summary = ConversationSummary(title: "报价", summary: "讨论了报价。", todos: ["发报价"])
        try fx.write("segments.json", String(decoding: try withSummary.encoded(), as: UTF8.self), id: longID)
        tools = LibraryTools(location: LibraryLocation(folder: fx.folder, flavor: .release), timeZone: Fixture.tz, now: { Fixture.now })
    }

    override func tearDown() { fx.remove() }

    private func call(_ name: String, _ args: [String: JSON]) throws -> ToolResult {
        try XCTUnwrap(tools.call(name, arguments: args))
    }

    func testDayOverviewListsConversationsByTheirOwnDay() throws {
        let d12 = try call("day_overview", ["date": "2026-11-12"])
        XCTAssertFalse(d12.isError)
        let recs = try XCTUnwrap(d12.structured?["recordings"]?.array)
        XCTAssertEqual(recs.compactMap { $0["id"]?.number }, [1001, 1003, Double(longID)])
        let convs = try XCTUnwrap(recs.last?["conversations"]?.array)
        XCTAssertEqual(convs.compactMap { $0["index"]?.number }, [0, 1])
        XCTAssertEqual(convs.first?["title"], "报价")
        XCTAssertEqual(convs.first?["todos"], ["发报价"])
        XCTAssertTrue(d12.text.contains("- conversation 0: 23:01–23:01 · 报价 — 讨论了报价。"), d12.text)
        XCTAssertTrue(d12.text.contains("- conversation 1: 00:30–00:30"), d12.text)

        // 04:20 那段归 13 日：同一条录音在 13 日也出现，只带那一段
        let d13 = try call("day_overview", ["date": "2026-11-13"])
        let recs13 = try XCTUnwrap(d13.structured?["recordings"]?.array)
        XCTAssertEqual(recs13.compactMap { $0["id"]?.number }, [Double(longID)])
        XCTAssertEqual(recs13[0]["conversations"]?.array?.compactMap { $0["index"]?.number }, [2])
    }

    func testGetRecordingListsMarks() throws {
        // 没有 marks.json：marks 是 null
        let before = try call("get_recording", ["id": .int(Int(longID))])
        XCTAssertEqual(before.structured?["marks"], JSON.null)
        try fx.write("marks.json", #"{"version":1,"marks":[65,5399]}"#, id: longID)
        let r = try call("get_recording", ["id": .int(Int(longID))])
        XCTAssertFalse(r.isError, r.text)
        let marks = try XCTUnwrap(r.structured?["marks"]?.array)
        XCTAssertEqual(marks.compactMap { $0["seconds"]?.number }, [65, 5399])
        // 5399 秒在两段之间：先敲后说，归第二段
        XCTAssertEqual(marks.compactMap { $0["conversation"]?.number }, [0, 1])
        XCTAssertTrue(r.text.contains("Marks (moments the user marked"), r.text)
        XCTAssertTrue(r.text.contains("- 1:05 (2026-11-12 23:01), conversation 0"), r.text)
        try fx.write("marks.json", #"{"version":1,"marks":[]}"#, id: longID)
        XCTAssertEqual(try call("get_recording", ["id": .int(Int(longID))]).structured?["marks"]?.array?.count, 0)
    }

    func testGetTranscriptByConversation() throws {
        let r = try call("get_transcript", ["id": .int(Int(longID)), "conversation": 1])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(r.structured?["segments"]?.array?.compactMap { $0["text"]?.string }, ["第二件事是招聘。", "下周面试。"])
        XCTAssertEqual(r.structured?["conversation"]?["index"], 1)
        XCTAssertTrue(r.text.contains("conversation 1"))
        XCTAssertTrue(try call("get_transcript", ["id": .int(Int(longID)), "conversation": 7]).isError)
        // 没切段的录音
        let none = try call("get_transcript", ["id": 1002, "conversation": 0])
        XCTAssertTrue(none.isError)
        XCTAssertTrue(none.text.contains("isn't split"))
    }

    func testStaleSegmentsAreIgnored() throws {
        // 转写改了、segments.json 还没重算：当作没有段
        var changed = lines
        changed[0]["text"] = "我们开始。"
        try fx.writeJSON("transcript.json", changed, id: longID)
        XCTAssertTrue(RecordingLibrary(folder: fx.folder).conversations(longID).isEmpty)
        let d12 = try call("day_overview", ["date": "2026-11-12"])
        XCTAssertNil(d12.structured?["recordings"]?.array?.last?["conversations"])
        XCTAssertTrue(try call("get_transcript", ["id": .int(Int(longID)), "conversation": 0]).isError)
    }

    func testDiaryComesFirst() throws {
        let a = ConversationRef(recording: longID, index: 0)
        let day = DayFile(date: "2026-11-12", timeZone: "Asia/Shanghai", dayStartHour: 4, signature: "s", status: .diary,
                          conversations: [DayConversation(ref: a, wallStart: longStart.addingTimeInterval(60), wallEnd: longStart.addingTimeInterval(70))],
                          diary: Diary(overview: "晚上开了个会。", decisions: [DiaryItem(text: "按三万个报价", refs: [a])],
                                       todos: [DiaryItem(text: "发报价", owner: "小王", refs: [a])],
                                       people: [DiaryName(name: "小王", refs: [a])]),
                          model: "local", createdAt: Fixture.now)
        let dir = DayFile.folder(library: fx.folder, date: "2026-11-12")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try day.encoded().write(to: DayFile.url(library: fx.folder, date: "2026-11-12"))
        let r = try call("day_overview", ["date": "2026-11-12"])
        XCTAssertEqual(r.structured?["diary"]?["overview"], "晚上开了个会。")
        XCTAssertEqual(r.structured?["diary"]?["todos"]?.array?.first?["owner"], "小王")
        XCTAssertEqual(r.structured?["diary"]?["decisions"]?.array?.first?["sources"], [["recording_id": .int(Int(longID)), "conversation": 0]])
        XCTAssertTrue(r.text.contains("- 按三万个报价 (23:01 id \(longID) conversation 0)"), r.text)
        let diaryAt = try XCTUnwrap(r.text.range(of: "Diary ("))
        let firstRecording = try XCTUnwrap(r.text.range(of: "(id 1001)"))
        XCTAssertLessThan(diaryAt.lowerBound, firstRecording.lowerBound)

        // 日记是按别的「一天从几点开始」写的：不用
        let other = LibraryTools(location: LibraryLocation(folder: fx.folder, flavor: .release), timeZone: Fixture.tz, dayStartHour: 0,
                                 now: { Fixture.now })
        XCTAssertNil(other.call("day_overview", arguments: ["date": "2026-11-12"])?.structured?["diary"])
    }
}
