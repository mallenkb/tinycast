import Foundation

nonisolated enum SearchDatePhrase {
    static func match(
        in words: [String],
        at start: Int,
        now: Date,
        calendar: Calendar
    ) -> (dates: DateInterval, count: Int)? {
        guard words.indices.contains(start) else { return nil }
        let phrase = Array(words[start...].prefix(4))

        if let weekday = weekday(phrase[0]) {
            let offset = phrase.count > 1 && phrase[1] == "of" ? 2 : 1
            if phrase.count > offset + 1,
               let previous = relativeWeek(phrase[offset]), phrase[offset + 1] == "week",
               let dates = weekdayInterval(weekday, previousWeek: previous, now: now, calendar: calendar) {
                return (dates, offset + 2)
            }
            return nil
        }

        if let previous = relativeWeek(phrase[0]), phrase.count > 1 {
            if phrase[1] == "week" {
                let offset = phrase.count > 2 && phrase[2] == "on" ? 3 : 2
                if phrase.count > offset, let weekday = weekday(phrase[offset]),
                   let dates = weekdayInterval(weekday, previousWeek: previous, now: now, calendar: calendar) {
                    return (dates, offset + 1)
                }
                if let dates = weekInterval(previous: previous, now: now, calendar: calendar) {
                    return (dates, 2)
                }
            } else if let weekday = weekday(phrase[1]) {
                if previous {
                    let today = calendar.startOfDay(for: now)
                    let difference = (calendar.component(.weekday, from: today) - weekday + 7) % 7
                    let daysBack = difference == 0 ? 7 : difference
                    if let day = calendar.date(byAdding: .day, value: -daysBack, to: today),
                       let dates = calendar.dateInterval(of: .day, for: day) {
                        return (dates, 2)
                    }
                } else if let dates = weekdayInterval(weekday, previousWeek: false, now: now, calendar: calendar) {
                    return (dates, 2)
                }
                return nil
            }
        }

        let today = calendar.startOfDay(for: now)
        switch phrase[0] {
        case "today":
            return calendar.dateInterval(of: .day, for: today).map { ($0, 1) }
        case "yesterday":
            guard let day = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
            return calendar.dateInterval(of: .day, for: day).map { ($0, 1) }
        case "last", "past":
            if phrase.count >= 3, ["seven", "7"].contains(phrase[1]), phrase[2] == "days",
               let firstDay = calendar.date(byAdding: .day, value: -6, to: today),
               let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
                return (DateInterval(start: firstDay, end: tomorrow), 3)
            }
            if phrase[0] == "last", phrase.count >= 2, phrase[1] == "month",
               let month = calendar.dateInterval(of: .month, for: now),
               let previous = calendar.date(byAdding: .month, value: -1, to: month.start),
               let dates = calendar.dateInterval(of: .month, for: previous) {
                return (dates, 2)
            }
            return nil
        default:
            return nil
        }
    }

    private static func relativeWeek(_ word: String) -> Bool? {
        switch word {
        case "last": true
        case "this": false
        default: nil
        }
    }

    private static func weekday(_ word: String) -> Int? {
        switch word {
        case "sunday", "sun": 1
        case "monday", "mon": 2
        case "tuesday", "tue", "tues": 3
        case "wednesday", "wed": 4
        case "thursday", "thu", "thur", "thurs": 5
        case "friday", "fri": 6
        case "saturday", "sat": 7
        default: nil
        }
    }

    private static func weekInterval(previous: Bool, now: Date, calendar: Calendar) -> DateInterval? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        guard previous else { return week }
        guard let day = calendar.date(byAdding: .day, value: -1, to: week.start) else { return nil }
        return calendar.dateInterval(of: .weekOfYear, for: day)
    }

    private static func weekdayInterval(
        _ weekday: Int,
        previousWeek: Bool,
        now: Date,
        calendar: Calendar
    ) -> DateInterval? {
        guard let week = weekInterval(previous: previousWeek, now: now, calendar: calendar) else { return nil }
        let offset = (weekday - calendar.component(.weekday, from: week.start) + 7) % 7
        guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
        return calendar.dateInterval(of: .day, for: day)
    }
}
