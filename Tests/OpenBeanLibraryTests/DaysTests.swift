// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

final class DaysTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    func testRefRoundTrip() {
        XCTAssertEqual(ConversationRef("1794550000#3"), ConversationRef(recording: 1_794_550_000, index: 3))
        XCTAssertNil(ConversationRef("abc#1"))
        XCTAssertNil(ConversationRef("12"))
        XCTAssertNil(ConversationRef("12#-1"))
        XCTAssertEqual(ConversationRef(recording: 5, index: 0).description, "5#0")
    }

    func testKeyAndBack() {
        XCTAssertEqual(DayFile.key(at(3, 0), calendar: cal), "2026-11-03")
        XCTAssertEqual(DayFile.day("2026-11-03", calendar: cal), at(3, 0))
        XCTAssertNil(DayFile.day("2026-11", calendar: cal))
    }

    /// 23:30 开始的录音，设备没给结束时刻（index 里存成 1970 年）：墙上时间只靠「开始 + 偏移」。
    /// 00:10 的段还算 13 日，04:30 的段算 14 日；没有一段被当成「暂停过」
    func testRecordingWithoutEndTimeIsAssignedBySegmentStart() {
        let start = at(13, 23, 30)
        let lines: [ConversationFile.Line] = [
            .init(start: 600, end: 610, text: "a"), .init(start: 2400, end: 2410, text: "b"),
            .init(start: 18_000, end: 18_030, text: "c"),
        ]
        let noEnd = Date(timeIntervalSince1970: 0)
        let approx = ConversationFile.likelyPaused(start: start, end: noEnd, duration: 18_100)
        XCTAssertFalse(approx)
        let f = ConversationFile.build(lines, recordingStart: start, wallApprox: approx)
        XCTAssertEqual(f.segments.count, 3)
        XCTAssertEqual(f.segments.map(\.wallStart), [at(13, 23, 40), at(14, 0, 10), at(14, 4, 30)])
        let days = DayAssignment.days(of: f.segments, boundary: DayBoundary(startHour: 4, calendar: cal))
        XCTAssertEqual(days, ["2026-11-13": [0, 1], "2026-11-14": [2]])
        // 换成一天从 0 点开始：00:10 那段就是 14 日了
        let midnight = DayAssignment.days(of: f.segments, boundary: DayBoundary(startHour: 0, calendar: cal))
        XCTAssertEqual(midnight, ["2026-11-13": [0], "2026-11-14": [1, 2]])
    }

    func testSegmentCrossingTheBoundaryBelongsToItsStartDay() {
        let start = at(14, 3, 0)
        let f = ConversationFile.build([.init(start: 0, end: 7200, text: "长谈")], recordingStart: start, wallApprox: false)
        let days = DayAssignment.days(of: f.segments, boundary: DayBoundary(startHour: 4, calendar: cal))
        XCTAssertEqual(days, ["2026-11-13": [0]])
    }

    func testSignatureIgnoresOrder() {
        XCTAssertEqual(DayFile.signature(["a", "b"]), DayFile.signature(["b", "a"]))
        XCTAssertNotEqual(DayFile.signature(["a"]), DayFile.signature(["a", "b"]))
    }

    func testDayFileRoundTripAndLenientRead() throws {
        let r = ConversationRef(recording: 9, index: 1)
        let day = DayFile(date: "2026-11-13", timeZone: "Asia/Shanghai", dayStartHour: 4, signature: "s", status: .diary,
                          conversations: [DayConversation(ref: r, wallStart: at(13, 9), wallEnd: at(13, 10), title: "t")],
                          diary: Diary(overview: "o", decisions: [DiaryItem(text: "d", refs: [r])],
                                       people: [DiaryName(name: "甲", refs: [r])]),
                          model: "local", createdAt: at(13, 22), stats: DayStats(calls: 2, seconds: 3.5, dropped: 1))
        let data = try day.encoded()
        XCTAssertEqual(try JSONDecoder().decode(DayFile.self, from: data), day)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"9#1\""))

        let messy = """
        {"date": "2026-11-13", "extra": 1, "status": "weird",
         "conversations": [{"ref": "9#1", "wallStart": "2026-11-13T01:00:00Z"}, {"ref": "bad"}, 7],
         "diary": {"overview": "o", "todos": [{"text": "x", "refs": ["9#1", "nope"]}, {"refs": []}], "people": "no"}}
        """
        let m = try JSONDecoder().decode(DayFile.self, from: Data(messy.utf8))
        XCTAssertEqual(m.status, .brief)
        XCTAssertEqual(m.conversations.count, 1)
        XCTAssertEqual(m.diary?.todos, [DiaryItem(text: "x", refs: [r])])
        XCTAssertEqual(m.diary?.people, [])
        XCTAssertEqual(m.dayStartHour, 4)
    }
}
