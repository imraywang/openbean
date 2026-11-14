// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

/// 重点标记：marks.json、标记归哪句 / 哪段、日记里摘出来的前后文
final class MarksTests: XCTestCase {
    private let spans: [(start: Double, end: Double)] = [(0, 4), (6, 10), (30, 34), (35, 40)]

    func testMarkGoesToSentenceOrTheOneAfter() {
        XCTAssertEqual(MarkPlacement.line(for: 2, spans: spans), 0)        // 在句子里
        XCTAssertEqual(MarkPlacement.line(for: 5, spans: spans), 1)        // 两句之间：先敲后说，归后一句
        XCTAssertEqual(MarkPlacement.line(for: 29, spans: spans), 2)
        XCTAssertEqual(MarkPlacement.line(for: 29.8, spans: spans), 2)     // 句首前一点点
        XCTAssertEqual(MarkPlacement.line(for: 34.5, spans: spans), 3)
        XCTAssertEqual(MarkPlacement.line(for: 99, spans: spans), 3)       // 最后一句之后：最后一句
        XCTAssertNil(MarkPlacement.line(for: 1, spans: []))
        XCTAssertEqual(MarkPlacement.byLine([33, 5, 7], spans: spans), [1: [5, 7], 2: [33]])
    }

    func testMarksGoToConversations() {
        // 两段对话：第 0–1 句、第 2–4 句（中间停了很久）
        let lines: [ConversationFile.Line] = [
            .init(start: 60, end: 64, text: "我们开始吧。"), .init(start: 66, end: 70, text: "先说报价。"),
            .init(start: 5400, end: 5404, text: "第二件事是招聘。"), .init(start: 5406, end: 5410, text: "下周面试。"),
            .init(start: 5412, end: 5415, text: "就这样。"),
        ]
        let t0 = Date(timeIntervalSince1970: 1_794_500_000)
        let f = ConversationFile.build(lines, recordingStart: t0, wallApprox: false, marks: [65, 5399, 5407])
        XCTAssertEqual(f.segments.count, 2)
        XCTAssertEqual(f.segments[0].marks, [65])
        // 5399 在两段之间：归后一句，也就落在第二段
        XCTAssertEqual(f.segments[1].marks, [5399, 5407])
        XCTAssertEqual(MarkPlacement.byConversation([65, 5399, 5407], spans: lines.map { ($0.start, $0.end) },
                                                    conversations: f.segments), [[65], [5399, 5407]])
        // 没有标记：每段都是空的
        XCTAssertTrue(ConversationFile.build(lines, recordingStart: t0, wallApprox: false).segments.allSatisfy { $0.marks.isEmpty })

        // 日记里摘的：时刻、所在段、标记那句和前后各一句（不跨段）
        let marks = DiaryMark.collect(recording: 9, recordingStart: t0, conversations: f.segments,
                                      spans: lines.map { ($0.start, $0.end) }, texts: lines.map(\.text))
        XCTAssertEqual(marks.map(\.ref), [ConversationRef(recording: 9, index: 0), ConversationRef(recording: 9, index: 1),
                                          ConversationRef(recording: 9, index: 1)])
        XCTAssertEqual(marks[0].quote, ["我们开始吧。", "先说报价。"])
        XCTAssertEqual(marks[1].quote, ["第二件事是招聘。", "下周面试。"]) // 段的第一句：前面那句在别的段，不带
        XCTAssertEqual(marks[2].quote, ["第二件事是招聘。", "下周面试。", "就这样。"])
        XCTAssertEqual(marks[0].wall, t0.addingTimeInterval(65))
    }

    func testMarksFileAndDayFileRoundTrip() throws {
        let m = RecordingMarks(marks: [68.02, 33.22, 33.22, -1, 102.88])
        XCTAssertEqual(m.marks, [33.22, 68.02, 102.88])
        let back = try JSONDecoder().decode(RecordingMarks.self, from: try m.encoded())
        XCTAssertEqual(back, m)
        XCTAssertEqual(try JSONDecoder().decode(RecordingMarks.self, from: Data(#"{"marks":[3,"x",1]}"#.utf8)).marks, [1, 3])

        let t = Date(timeIntervalSince1970: 1_794_500_000)
        let ref = ConversationRef(recording: 1, index: 0)
        var day = DayFile(date: "2026-11-13", timeZone: "UTC", dayStartHour: 4, signature: "s", status: .brief,
                          conversations: [], diary: nil, model: nil, createdAt: t)
        // 没有标记：不写这个键
        XCTAssertFalse(String(decoding: try day.encoded(), as: UTF8.self).contains("marks"))
        day.marks = [DiaryMark(ref: ref, at: 33.22, wall: t.addingTimeInterval(33.22), quote: ["先说报价。"])]
        let d2 = try JSONDecoder().decode(DayFile.self, from: try day.encoded())
        XCTAssertEqual(d2.marks.first?.ref, ref)
        XCTAssertEqual(d2.marks.first?.at, 33.22)
        XCTAssertEqual(d2.marks.first?.quote, ["先说报价。"])
    }

    func testLibraryReadsMarks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openbean-libmarks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("5"), withIntermediateDirectories: true)
        let lib = RecordingLibrary(folder: dir)
        XCTAssertNil(lib.marks(5)) // 没有 marks.json：不知道
        try RecordingMarks(marks: []).encoded().write(to: dir.appendingPathComponent("5/marks.json"))
        XCTAssertEqual(lib.marks(5), [])
        try RecordingMarks(marks: [1.5]).encoded().write(to: dir.appendingPathComponent("5/marks.json"))
        XCTAssertEqual(lib.marks(5), [1.5])
    }
}
