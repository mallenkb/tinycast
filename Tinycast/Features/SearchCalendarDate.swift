import Foundation

nonisolated enum SearchCalendarDate {
    enum Failure: Error, Sendable, Equatable {
        case invalid
        case ambiguous(String, [String])
    }
    struct Match: Sendable {
        let bounds: SearchFileConstraints.Bounds
        let count: Int
        let detail: String
    }
    private static let months = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december"
    ]

    static func match(_ words: [String], now: Date, calendar supplied: Calendar) throws -> Match {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = supplied.timeZone
        calendar.firstWeekday = supplied.firstWeekday
        calendar.minimumDaysInFirstWeek = supplied.minimumDaysInFirstWeek
        guard let first = words.first else { throw Failure.invalid }
        if first == "between" {
            guard let separator = words.firstIndex(of: "and"), separator > 1 else { throw Failure.invalid }
            let lower = try point(Array(words[1..<separator]), now: now, calendar: calendar)
            guard lower.count == separator - 1 else { throw Failure.invalid }
            let upper = try point(Array(words[(separator + 1)...]), now: now, calendar: calendar)
            guard lower.interval.start < upper.interval.end else { throw Failure.invalid }
            return Match(
                bounds: .init(start: lower.interval.start, end: upper.interval.end),
                count: separator + 1 + upper.count,
                detail: label(lower.interval.start, calendar) + " … "
                    + label(upper.interval.end.addingTimeInterval(-1), calendar))
        }
        let comparison = ["before", "after"].contains(first) ? first : nil
        let offset = comparison == nil ? 0 : 1
        let value = try point(Array(words.dropFirst(offset)), now: now, calendar: calendar)
        let bounds: SearchFileConstraints.Bounds
        if comparison == "before" {
            bounds = .init(start: nil, end: value.interval.start)
        } else if comparison == "after" {
            bounds = .init(start: value.interval.end, end: nil)
        } else {
            bounds = .init(start: value.interval.start, end: value.interval.end)
        }
        let startLabel = label(value.interval.start, calendar)
        let endLabel = label(value.interval.end.addingTimeInterval(-1), calendar)
        let detail =
            comparison.map { ($0 == "before" ? "< " : "> ") + ($0 == "before" ? startLabel : endLabel) }
            ?? (startLabel == endLabel ? startLabel : startLabel + " … " + endLabel)
        return Match(bounds: bounds, count: offset + value.count, detail: detail)
    }

    private static func point(
        _ words: [String], now: Date, calendar: Calendar
    ) throws -> (interval: DateInterval, count: Int) {
        guard let first = words.first else { throw Failure.invalid }
        if let relative = SearchDatePhrase.match(in: words, at: 0, now: now, calendar: calendar) {
            return (relative.dates, relative.count)
        }
        if first.contains("/") {
            let pieces = first.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
                throw Failure.invalid
            }
            let parts = pieces.compactMap { Int($0) }
            guard parts.count == 3, (1000...9999).contains(parts[2]) else { throw Failure.invalid }
            let monthFirst = try? day(parts[2], parts[0], parts[1], calendar)
            let dayFirst = try? day(parts[2], parts[1], parts[0], calendar)
            if let monthFirst, let dayFirst, monthFirst != dayFirst {
                throw Failure.ambiguous(
                    first, [label(monthFirst.start, calendar), label(dayFirst.start, calendar)])
            }
            guard let result = monthFirst ?? dayFirst else { throw Failure.invalid }
            return (result, 1)
        }
        if first.contains("-") {
            let pieces = first.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.map(\.count) == [4, 2, 2], pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
                throw Failure.invalid
            }
            let parts = pieces.compactMap { Int($0) }
            guard parts.count == 3, first.count == 10 else { throw Failure.invalid }
            return (try day(parts[0], parts[1], parts[2], calendar), 1)
        }
        if let month = month(first) {
            if words.count > 1, let number = number(words[1]), number <= 31 {
                let year = words.count > 2 ? Int(words[2]) : nil
                let hasYear = year.map { (1000...9999).contains($0) } ?? false
                return (
                    try day(hasYear ? year! : calendar.component(.year, from: now), month, number, calendar),
                    hasYear ? 3 : 2
                )
            }
            let year = words.count > 1 ? Int(words[1]) : nil
            let hasYear = year.map { (1000...9999).contains($0) } ?? false
            let firstDay = try day(hasYear ? year! : calendar.component(.year, from: now), month, 1, calendar)
            guard let interval = calendar.dateInterval(of: .month, for: firstDay.start) else {
                throw Failure.invalid
            }
            return (interval, hasYear ? 2 : 1)
        }
        guard let number = number(first) else { throw Failure.invalid }
        if (1000...9999).contains(number) {
            let firstDay = try day(number, 1, 1, calendar)
            guard let interval = calendar.dateInterval(of: .year, for: firstDay.start) else {
                throw Failure.invalid
            }
            return (interval, 1)
        }
        var cursor = 1
        if words.count > cursor, words[cursor] == "of" { cursor += 1 }
        if words.count > cursor + 1, ["last", "this"].contains(words[cursor]), words[cursor + 1] == "month" {
            guard let base = calendar.dateInterval(of: .month, for: now)?.start,
                let target = calendar.date(
                    byAdding: .month, value: words[cursor] == "last" ? -1 : 0, to: base)
            else { throw Failure.invalid }
            return (
                try day(
                    calendar.component(.year, from: target), calendar.component(.month, from: target), number,
                    calendar), cursor + 2
            )
        }
        guard words.count > cursor, let month = month(words[cursor]) else { throw Failure.invalid }
        cursor += 1
        let year = words.count > cursor ? Int(words[cursor]) : nil
        let hasYear = year.map { (1000...9999).contains($0) } ?? false
        return (
            try day(hasYear ? year! : calendar.component(.year, from: now), month, number, calendar),
            cursor + (hasYear ? 1 : 0)
        )
    }

    private static func day(
        _ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar
    ) throws -> DateInterval {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month,
            calendar.component(.day, from: date) == day,
            let interval = calendar.dateInterval(of: .day, for: date)
        else { throw Failure.invalid }
        return interval
    }

    private static func month(_ word: String) -> Int? {
        months.firstIndex { $0 == word || String($0.prefix(3)) == word }.map { $0 + 1 }
    }
    private static func number(_ word: String) -> Int? {
        let digits = word.prefix(while: \.isNumber)
        let suffix = word.dropFirst(digits.count)
        guard let value = Int(digits) else { return nil }
        let expected: String
        if (11...13).contains(value % 100) {
            expected = "th"
        } else {
            switch value % 10 {
            case 1: expected = "st"
            case 2: expected = "nd"
            case 3: expected = "rd"
            default: expected = "th"
            }
        }
        guard suffix.isEmpty || suffix == expected else { return nil }
        return value
    }
    private static func label(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
