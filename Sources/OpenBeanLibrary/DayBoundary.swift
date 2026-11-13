// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 「一天」从哪一刻开始：默认凌晨 4 点，凌晨两点的谈话算前一天。
/// App 的「今天」页和以后的每日日记共用这一个函数，两边的边界必须一致。
/// 日期都按 calendar 的时区算：录音存的是绝对时刻，换了时区以后，一条录音算哪天跟着当前时区走。
public struct DayBoundary: Sendable, Equatable {
    /// 一天从几点开始（0–23）
    public var startHour: Int
    public var calendar: Calendar

    public init(startHour: Int = 4, calendar: Calendar = .current) {
        self.startHour = min(max(startHour, 0), 23)
        self.calendar = calendar
    }

    /// 这一刻属于哪一天：返回那个日历日的 0 点（当作这一天的标识，可以直接用来比较和显示日期）
    public func day(of date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        guard calendar.component(.hour, from: date) < startHour else { return start }
        return calendar.date(byAdding: .day, value: -1, to: start) ?? start
    }

    /// 某一天的起止：[那天的 startHour 点, 下一天的 startHour 点)。夏令时那天可能是 23 或 25 小时。
    /// day 可以是那个日历日的任何时刻
    public func interval(of day: Date) -> DateInterval {
        let d0 = calendar.startOfDay(for: day)
        let d1 = calendar.date(byAdding: .day, value: 1, to: d0) ?? d0.addingTimeInterval(86_400)
        return DateInterval(start: boundary(on: d0), end: boundary(on: d1))
    }

    /// 这一刻是不是在这一天里（左闭右开：下一天的起点不算这一天；DateInterval.contains 两头都算）
    public func contains(_ date: Date, inDay day: Date) -> Bool {
        let i = interval(of: day)
        return date >= i.start && date < i.end
    }

    /// 前后翻 n 天（n 可以是负数），返回那天的 0 点
    public func day(_ day: Date, offsetBy n: Int) -> Date {
        let d0 = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: n, to: d0) ?? d0
    }

    /// 某个日历日的 startHour 点；这个时刻因为夏令时不存在时取之后最近的时刻
    private func boundary(on dayStart: Date) -> Date {
        calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: dayStart,
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            ?? dayStart.addingTimeInterval(Double(startHour) * 3600)
    }
}
