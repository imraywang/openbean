// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

final class DayBoundaryTests: XCTestCase {
    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testAfterMidnightBeforeFourBelongsToPreviousDay() {
        let c = cal("Asia/Shanghai"), b = DayBoundary(calendar: c)
        XCTAssertEqual(b.day(of: date(c, 2026, 11, 13, 2, 10)), date(c, 2026, 11, 12, 0))
        XCTAssertEqual(b.day(of: date(c, 2026, 11, 13, 3, 59)), date(c, 2026, 11, 12, 0))
        XCTAssertEqual(b.day(of: date(c, 2026, 11, 13, 4, 0)), date(c, 2026, 11, 13, 0))
        XCTAssertEqual(b.day(of: date(c, 2026, 11, 13, 23, 59)), date(c, 2026, 11, 13, 0))
    }

    func testIntervalRunsFromFourToFour() {
        let c = cal("Asia/Shanghai"), b = DayBoundary(calendar: c)
        let i = b.interval(of: date(c, 2026, 11, 13, 15))
        XCTAssertEqual(i.start, date(c, 2026, 11, 13, 4))
        XCTAssertEqual(i.end, date(c, 2026, 11, 14, 4))
        // 一条从 23:40 录到 01:10 的录音按开始时刻算在 13 日；01:10 本身也还在 13 日的区间里
        XCTAssertTrue(i.contains(date(c, 2026, 11, 13, 23, 40)))
        XCTAssertTrue(i.contains(date(c, 2026, 11, 14, 1, 10)))
        XCTAssertTrue(b.contains(date(c, 2026, 11, 14, 3, 59), inDay: date(c, 2026, 11, 13, 0)))
        XCTAssertFalse(b.contains(date(c, 2026, 11, 14, 4), inDay: date(c, 2026, 11, 13, 0)))
    }

    func testMidnightStartIsPlainCalendarDay() {
        let c = cal("Asia/Shanghai"), b = DayBoundary(startHour: 0, calendar: c)
        XCTAssertEqual(b.day(of: date(c, 2026, 11, 13, 0, 30)), date(c, 2026, 11, 13, 0))
        XCTAssertEqual(b.interval(of: date(c, 2026, 11, 13, 9)).duration, 86_400)
    }

    func testSpringForwardDayIs23Hours() {
        // 纽约 2026-03-08 凌晨 2 点跳到 3 点：这一刻落在 3 月 7 日那一天（7 日 4 点到 8 日 4 点）里
        let c = cal("America/New_York"), b = DayBoundary(calendar: c)
        XCTAssertEqual(b.interval(of: date(c, 2026, 3, 7, 12)).duration, 23 * 3600)
        XCTAssertEqual(b.interval(of: date(c, 2026, 3, 8, 12)).duration, 24 * 3600)
        XCTAssertEqual(b.day(of: date(c, 2026, 3, 8, 3, 30)), date(c, 2026, 3, 7, 0))
    }

    func testFallBackDayIs25Hours() {
        // 纽约 2026-11-01 凌晨 2 点回到 1 点
        let c = cal("America/New_York"), b = DayBoundary(calendar: c)
        XCTAssertEqual(b.interval(of: date(c, 2026, 10, 31, 12)).duration, 25 * 3600)
        XCTAssertEqual(b.interval(of: date(c, 2026, 11, 1, 12)).duration, 24 * 3600)
        // 重复出现的 1:30 两次都算前一天
        let first = date(c, 2026, 11, 1, 1, 30)
        XCTAssertEqual(b.day(of: first), date(c, 2026, 10, 31, 0))
        XCTAssertEqual(b.day(of: first.addingTimeInterval(3600)), date(c, 2026, 10, 31, 0))
    }

    func testBoundaryHourSkippedByDSTUsesNextTime() {
        // 起点设在 2 点、正好碰上纽约跳过的那个小时：取跳过之后的 3 点
        let c = cal("America/New_York"), b = DayBoundary(startHour: 2, calendar: c)
        XCTAssertEqual(b.interval(of: date(c, 2026, 3, 8, 12)).start, date(c, 2026, 3, 8, 3))
    }

    func testTimeZoneChangeFollowsCurrentZone() {
        // 同一个绝对时刻：北京时间 13 日 03:00 算 12 日；在东京（04:00）已经是 13 日
        let sh = cal("Asia/Shanghai"), tk = cal("Asia/Tokyo")
        let t = date(sh, 2026, 11, 13, 3)
        XCTAssertEqual(DayBoundary(calendar: sh).day(of: t), date(sh, 2026, 11, 12, 0))
        XCTAssertEqual(DayBoundary(calendar: tk).day(of: t), date(tk, 2026, 11, 13, 0))
    }

    func testOffset() {
        let c = cal("Asia/Shanghai"), b = DayBoundary(calendar: c)
        XCTAssertEqual(b.day(date(c, 2026, 11, 13, 15), offsetBy: -1), date(c, 2026, 11, 12, 0))
        XCTAssertEqual(b.day(date(c, 2026, 3, 1, 0), offsetBy: -1), date(c, 2026, 2, 28, 0))
    }
}
