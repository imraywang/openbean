// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanLibrary
@testable import OpenBeanMCP
import XCTest

/// 一天从凌晨 4 点算（和 App 的「今天」同一个规则）：day_overview、from / to、today 都按它分天
final class DayStartTests: XCTestCase {
    private var fx: Fixture!
    private let c: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = Fixture.tz; return c }()

    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        c.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    override func setUpWithError() throws {
        fx = try Fixture(index: false)
        try fx.writeJSON("index.json", [
            Fixture.entry(2001, start: at(12, 23, 50), seconds: 5400, title: "跨午夜的会"),   // 11-12
            Fixture.entry(2002, start: at(13, 1, 30), seconds: 60, title: "凌晨随手记"),      // 凌晨，算 11-12
            Fixture.entry(2003, start: at(13, 4, 10), seconds: 60, title: "早上"),          // 11-13
        ])
    }

    override func tearDown() { fx.remove() }

    private func tools(now: Date, startHour: Int = 4) -> LibraryTools {
        LibraryTools(location: LibraryLocation(folder: fx.folder, flavor: .custom), timeZone: Fixture.tz,
                     dayStartHour: startHour, now: { now })
    }

    private func ids(_ r: ToolResult?) -> [Double] {
        r?.structured?["recordings"]?.array?.compactMap { $0["id"]?.number } ?? []
    }

    func testDayOverviewUsesFourAM() {
        let t = tools(now: at(13, 10))
        XCTAssertEqual(ids(t.call("day_overview", arguments: ["date": "2026-11-12"])), [2001, 2002])
        XCTAssertEqual(ids(t.call("day_overview", arguments: ["date": "2026-11-13"])), [2003])
        let r = t.call("day_overview", arguments: [:])
        XCTAssertEqual(r?.structured?["day_starts_at"], "04:00")
        XCTAssertTrue(r?.text.contains("A day runs from 04:00") == true, r?.text ?? "")
    }

    func testTodayBeforeFourIsStillYesterday() {
        let t = tools(now: at(13, 3))
        XCTAssertEqual(t.call("day_overview", arguments: [:])?.structured?["date"], "2026-11-12")
        XCTAssertEqual(t.call("day_overview", arguments: ["date": "yesterday"])?.structured?["date"], "2026-11-11")
    }

    func testDateRangeUsesFourAM() {
        let t = tools(now: at(13, 10))
        let r = t.call("list_recordings", arguments: ["from": "2026-11-12", "to": "2026-11-12"])
        XCTAssertEqual(Set(ids(r)), [2001, 2002])
    }

    func testMidnightSettingKeepsCalendarDays() {
        let t = tools(now: at(13, 10), startHour: 0)
        XCTAssertEqual(ids(t.call("day_overview", arguments: ["date": "2026-11-13"])), [2002, 2003])
        XCTAssertEqual(t.call("day_overview", arguments: [:])?.text.contains("A day runs") , false)
    }
}
