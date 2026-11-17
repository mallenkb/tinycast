import Foundation

struct WeatherForecastSelection: Sendable {
    let days: [WeatherDay]
    let hour: WeatherHour?
    let requestedTime: Date?

    static func resolve(
        _ timing: WeatherQuery.Timing, in forecast: WeatherForecast
    ) -> Self? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        calendar.firstWeekday = 2
        let now = forecast.current.time
        let today = calendar.startOfDay(for: now)

        if let hourOffset = timing.hourOffset {
            guard let requested = calendar.date(byAdding: .hour, value: hourOffset, to: now)
            else { return nil }
            return hourlySelection(at: requested, in: forecast, calendar: calendar)
        }

        if timing.week || timing.weekend {
            guard let span = week(containing: today, next: timing.nextWeek, calendar: calendar)
            else { return nil }
            let days = forecast.days.filter {
                let day = calendar.startOfDay(for: $0.date)
                let weekday = calendar.component(.weekday, from: day)
                return day >= span.start && day < span.end
                    && (!timing.weekend || weekday == 7 || weekday == 1)
            }
            guard !days.isEmpty else { return nil }
            guard let hour = timing.hour else { return Self(days: days, hour: nil, requestedTime: nil) }
            let requested = days.lazy.compactMap {
                clockTime(hour, minute: timing.minute, on: $0.date, calendar: calendar, atOrAfter: now)
            }.first
            guard let requested else { return nil }
            return hourlySelection(at: requested, in: forecast, calendar: calendar)
        }

        guard let date = day(for: timing, today: today, calendar: calendar) else { return nil }
        guard let hour = timing.hour else {
            guard let reading = forecast.days.first(where: { calendar.isDate($0.date, inSameDayAs: date) })
            else { return nil }
            return Self(days: [reading], hour: nil, requestedTime: nil)
        }
        let hasDay = timing.dayOffset != nil || timing.weekday != nil || timing.month != nil
        let time = clockTime(
            hour, minute: timing.minute, on: date, calendar: calendar, atOrAfter: hasDay ? nil : now)
        if let time { return hourlySelection(at: time, in: forecast, calendar: calendar) }

        guard !hasDay,
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
            let next = clockTime(hour, minute: timing.minute, on: tomorrow, calendar: calendar)
        else { return nil }
        return hourlySelection(at: next, in: forecast, calendar: calendar)
    }

    private static func hourlySelection(
        at time: Date, in forecast: WeatherForecast, calendar: Calendar
    ) -> Self? {
        guard let day = forecast.days.first(where: { calendar.isDate($0.date, inSameDayAs: time) }),
            let hour = forecast.hours.last(where: {
                let offset = time.timeIntervalSince($0.time)
                return offset >= 0 && offset < 3600 && calendar.isDate($0.time, inSameDayAs: time)
            })
        else { return nil }
        return Self(days: [day], hour: hour, requestedTime: time)
    }

    private static func day(
        for timing: WeatherQuery.Timing, today: Date, calendar: Calendar
    ) -> Date? {
        if let offset = timing.dayOffset {
            return calendar.date(byAdding: .day, value: offset, to: today)
        }
        if let weekday = timing.weekday {
            guard (1...7).contains(weekday) else { return nil }
            if timing.nextWeek {
                guard let span = week(containing: today, next: true, calendar: calendar) else { return nil }
                return calendar.date(byAdding: .day, value: (weekday + 5) % 7, to: span.start)
            }
            let current = calendar.component(.weekday, from: today)
            return calendar.date(byAdding: .day, value: (weekday - current + 7) % 7, to: today)
        }
        guard let month = timing.month, let day = timing.day else { return today }

        let year = calendar.component(.year, from: today)
        if let explicitYear = timing.year {
            return calendarDay(year: explicitYear, month: month, day: day, calendar: calendar)
        }
        if let date = calendarDay(year: year, month: month, day: day, calendar: calendar),
            date >= today
        {
            return date
        }
        return calendarDay(year: year + 1, month: month, day: day, calendar: calendar)
    }

    private static func calendarDay(
        year: Int, month: Int, day: Int, calendar: Calendar
    ) -> Date? {
        let requested = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: requested) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else { return nil }
        return date
    }

    private static func clockTime(
        _ hour: Int, minute: Int, on date: Date, calendar: Calendar, atOrAfter limit: Date? = nil
    ) -> Date? {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        let start = calendar.startOfDay(for: date)
        let requested = DateComponents(hour: hour, minute: minute, second: 0)
        for policy in [Calendar.RepeatedTimePolicy.first, .last] {
            guard let time = calendar.nextDate(
                after: start.addingTimeInterval(-1), matching: requested,
                matchingPolicy: .strict, repeatedTimePolicy: policy),
                calendar.isDate(time, inSameDayAs: start)
            else { continue }
            if limit.map({ time >= $0 }) ?? true { return time }
        }
        return nil
    }

    private static func week(containing date: Date, next: Bool, calendar: Calendar) -> DateInterval? {
        let start = next ? calendar.date(byAdding: .weekOfYear, value: 1, to: date) : date
        return start.flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
    }
}
