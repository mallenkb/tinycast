import Foundation

struct SearchIntent: Sendable {
    enum Destination: String, Sendable { case literal, files, clipboard, command }
    enum Context: String, Sendable { case launcher, files, clipboard }
    enum DateRange: String, Sendable {
        case any, today, yesterday, thisWeek, lastWeek, lastSevenDays, lastMonth, specific
    }

    struct Command: Sendable {
        let id: String
        let title: String
    }

    let destination: Destination
    let description: SearchDescription?
    let commandID: String?

    static func dates(
        _ range: DateRange, start: String, end: String, now: Date, calendar: Calendar
    ) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        switch range {
        case .any: return nil
        case .today:
            return calendar.date(byAdding: .day, value: 1, to: today).map { DateInterval(start: today, end: $0) }
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: today).map { DateInterval(start: $0, end: today) }
        case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now)
        case .lastWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
                let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start)
            else { return nil }
            return DateInterval(start: previous, end: week.start)
        case .lastSevenDays:
            guard let first = calendar.date(byAdding: .day, value: -6, to: today),
                let last = calendar.date(byAdding: .day, value: 1, to: today)
            else { return nil }
            return DateInterval(start: first, end: last)
        case .lastMonth:
            guard let month = calendar.dateInterval(of: .month, for: now),
                let previous = calendar.date(byAdding: .month, value: -1, to: month.start)
            else { return nil }
            return DateInterval(start: previous, end: month.start)
        case .specific:
            guard let first = date(start, calendar: calendar), let last = date(end, calendar: calendar), last > first
            else { return nil }
            return DateInterval(start: first, end: last)
        }
    }

    private static func date(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, value.count == 10 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day], from: date) == components
        else { return nil }
        return date
    }
}
