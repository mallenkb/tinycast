import Foundation

struct WeatherQuery: Equatable, Sendable {
    enum Metric: Equatable, Sendable {
        case conditions, rain, wind
    }

    struct Timing: Equatable, Sendable {
        var dayOffset: Int?
        var weekday: Int?
        var hour: Int?
        var minute = 0
        var year: Int?
        var month: Int?
        var day: Int?
        var hourOffset: Int?
        var nextWeek = false
        var weekend = false
        var week = false
    }

    enum Place: Equatable, Sendable {
        case city(String), macLocation, setup, missingCity
    }

    let place: Place
    let timing: Timing?
    let metric: Metric?

    init?(_ query: String, defaultCity: String, useMacLocation: Bool) {
        var remainder = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty, remainder.count <= 200 else { return nil }
        remainder = remainder.replacingOccurrences(of: "’", with: "'")
        remainder = remainder.trimmingCharacters(in: Self.sentenceEnds)
        _ = Self.consume(Self.politeness, from: &remainder)

        if Self.consume(Self.rainLead, from: &remainder) != nil {
            metric = .rain
        } else if Self.consume(Self.windLead, from: &remainder) != nil {
            metric = .wind
        } else if Self.consume(Self.weatherLead, from: &remainder) != nil {
            metric = nil
        } else {
            return nil
        }

        var timing = Timing()
        Self.extractRelativeTime(from: &remainder, timing: &timing)
        Self.extractDate(from: &remainder, timing: &timing)
        Self.extractDay(from: &remainder, timing: &timing)
        let clockHasMeridiem = Self.extractClock(from: &remainder, timing: &timing)
        Self.extractDaypart(from: &remainder, timing: &timing, clockHasMeridiem: clockHasMeridiem)
        _ = Self.consume(Self.currentTime, from: &remainder)
        self.timing = timing == Timing() ? nil : timing

        remainder = remainder.trimmingCharacters(in: Self.phraseEnds)
        let locationMarker = Self.consume(Self.locationLead, from: &remainder) != nil
        remainder = remainder.trimmingCharacters(in: Self.phraseEnds)
        let useDefaultCity = remainder.isEmpty || Self.defaultLocation.firstMatch(
            in: remainder, range: NSRange(remainder.startIndex..., in: remainder)) != nil
        if useDefaultCity {
            if locationMarker && remainder.isEmpty {
                place = .missingCity
            } else if useMacLocation {
                place = .macLocation
            } else if let city = Self.city(defaultCity) {
                place = .city(city)
            } else {
                place = .setup
            }
        } else {
            guard let city = Self.city(remainder), Self.nonLocation.firstMatch(
                in: city, range: NSRange(city.startIndex..., in: city)) == nil
            else { return nil }
            place = .city(city)
        }
    }

    private static func city(_ name: String) -> String? {
        let city = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...160).contains(city.count), city.unicodeScalars.contains(where: CharacterSet.letters.contains)
        else { return nil }
        return city
    }

    private static let sentenceEnds = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!."))
    private static let phraseEnds = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",?!."))
    private static let command = #"(?:(?:please\s+)?(?:show|tell|give)\s+me\s+|(?:check|look\s+up)\s+)?"#
    private static let question = #"(?:(?:what(?:'s|\s+is)|how(?:'s|\s+is)|(?:what|how)\s+will)\s+)?"#
    private static let weatherLead = expression(
        "^" + command + question + #"(?:the\s+)?(?:current\s+)?"#
            + #"(?:weather(?:\s+forecast)?|forecast|temperature)\b"#
            + #"(?:\s+(?:will\s+be|be\s+like|look\s+like|be|is)\b)?"#)
    private static let rainLead = expression(
        "^" + command + question
            + #"(?:(?:will|is)\s+it\s+(?:going\s+to\s+)?rain(?:ing)?\b"#
            + #"|(?:the\s+)?(?:chance\s+of\s+rain|rain\s+(?:chance|forecast))\b(?:\s+be\b)?"#
            + #"|rain(?=\s+(?:in|at|for|on|today|tomorrow|tonight|this|next)\b))"#)
    private static let windLead = expression(
        "^" + command + question
            + #"(?:(?:the\s+)?wind\s+(?:speed|forecast|gusts)\b(?:\s+be\b)?"#
            + #"|wind(?=\s+(?:in|at|for|on|today|tomorrow|tonight|this|next)\b)"#
            + #"|(?:will|is)\s+it\s+(?:be\s+)?windy\b)"#)
    private static let politeness = expression(#"\s+please\s*$"#)
    private static let locationLead = expression(#"^(?:is|in|at|for)\b"#)
    private static let defaultLocation = expression(
        #"^(?:here|near\s+me|my\s+(?:area|city|location)|current\s+location|where\s+i\s+am)$"#)
    private static let nonLocation = expression(
        #"^(?:the\s+)?(?:apps?|widgets?|settings|radar|maps?|api|channel|underground)\b"#
            + #"|^(?:on|by)\b|\s+(?:in|at|on|for)\s*$|^\d|\s+at\s+\d"#)
    private static let currentTime = expression(#"\b(?:right\s+now|now|currently)\b"#)

    private static let numberWords = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "a": 1, "an": 1,
    ]
    private static let number = #"(?:[0-9]{1,2}|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#
    private static let offset = expression(
        #"\bin\s+("# + number + #"|an?|a\s+couple\s+of)\s+(hours?|days?|weeks?)\b"#)
    private static let isoDate = expression(#"\b(?:(?:on|for)\s+)?([0-9]{4})-([0-9]{2})-([0-9]{2})\b"#)
    private static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]
    private static let months = monthNames.joined(separator: "|")
    private static let monthFirst = expression(
        #"\b(?:(?:on|for)\s+)?("# + months + #")\s+([0-9]{1,2})(?:st|nd|rd|th)?(?:,?\s+([0-9]{4}))?\b"#)
    private static let dayFirst = expression(
        #"\b(?:(?:on|for)\s+)?([0-9]{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + months
            + #")(?:,?\s+([0-9]{4}))?\b"#)
    private static let relativeDay = expression(
        #"\b(?:(?:on|for)\s+)?(?:later\s+)?((?:the\s+)?day\s+after\s+tomorrow|tomorrow|today)\b"#)
    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let weekdays = weekdayNames.joined(separator: "|")
    private static let weekday = expression(
        #"\b(?:for\s+)?(?:(on|this|next)\s+)?("# + weekdays
            + #")(?=\s*(?:[,?!]|$)|\s+(?:(?:in|at|for|morning|afternoon|evening|night|noon|midnight)\b|[0-9]))"#)
    private static let weekRange = expression(#"\b(?:(?:on|for)\s+)?(?:(this|next)\s+)?(weekend|week)\b"#)
    private static let specialClock = expression(#"\b(?:at\s+)?(noon|midnight)\b"#)
    private static let clockSuffix = #"(?:a\.?\s*m\.?|p\.?\s*m\.?)"#
    private static let spokenMinutes = #"(?:fifteen|thirty|forty[ -]five)"#
    private static let clock = expression(
        #"\b(?:(at)\s+)?("# + number + #")(?:\s*[:h]\s*([0-9]{2})|\s+("# + spokenMinutes
            + #"))?(?:\s*(?:("# + clockSuffix + #")|(o'?clock)))?(?=$|[\s,?.!])"#)
    private static let militaryClock = expression(#"\bat\s+([01][0-9]|2[0-3])([0-5][0-9])\b"#)
    private static let daypart = expression(
        #"\b(?:in\s+the\s+|this\s+|for\s+|at\s+)?(tonight|morning|afternoon|evening|night)"#
            + #"(?=\s*(?:[,?!]|$)|\s+(?:(?:in|at|for|today|tomorrow)\b|[0-9]))"#)

    private static func extractRelativeTime(from text: inout String, timing: inout Timing) {
        guard let groups = consume(offset, from: &text), let token = groups[1], let unit = groups[2],
            let count = integer(token) ?? (token.hasPrefix("a couple") ? 2 : nil)
        else { return }
        if unit.hasPrefix("hour") {
            timing.hourOffset = count
        } else {
            timing.dayOffset = unit.hasPrefix("week") ? count * 7 : count
        }
    }

    private static func extractDate(from text: inout String, timing: inout Timing) {
        if let groups = consume(isoDate, from: &text) {
            timing.year = integer(groups[1])
            timing.month = integer(groups[2])
            timing.day = integer(groups[3])
        } else if let groups = consume(monthFirst, from: &text) {
            timing.month = month(groups[1])
            timing.day = integer(groups[2])
            timing.year = integer(groups[3])
        } else if let groups = consume(dayFirst, from: &text) {
            timing.day = integer(groups[1])
            timing.month = month(groups[2])
            timing.year = integer(groups[3])
        }
    }

    private static func extractDay(from text: inout String, timing: inout Timing) {
        if let groups = consume(relativeDay, from: &text) {
            timing.dayOffset = switch groups[1] {
            case "today": 0
            case "tomorrow": 1
            default: 2
            }
        } else if let groups = consume(weekday, from: &text), let name = groups[2],
            let index = weekdayNames.firstIndex(of: name)
        {
            timing.weekday = index + 1
            timing.nextWeek = groups[1] == "next"
        } else if let groups = consume(weekRange, from: &text) {
            timing.week = groups[2] == "week"
            timing.weekend = groups[2] == "weekend"
            timing.nextWeek = groups[1] == "next"
        }
    }

    private static func extractClock(from text: inout String, timing: inout Timing) -> Bool {
        if let groups = consume(specialClock, from: &text) {
            timing.hour = groups[1] == "noon" ? 12 : 0
            return true
        }
        if let groups = consume(militaryClock, from: &text) {
            timing.hour = integer(groups[1])
            timing.minute = integer(groups[2]) ?? 0
            return true
        }
        let matches = clock.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let groups = captures(match, in: text)
            guard groups[1] != nil || groups[3...6].contains(where: { $0 != nil }),
                let rawHour = integer(groups[2]),
                let range = Range(match.range, in: text)
            else { continue }
            let minute = integer(groups[3]) ?? spokenMinute(groups[4])
            guard (0...59).contains(minute) else { continue }
            let hour: Int
            if let meridiem = groups[5] {
                guard (1...12).contains(rawHour) else { continue }
                hour = rawHour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
            } else {
                guard (0...23).contains(rawHour) else { continue }
                hour = rawHour
            }
            timing.hour = hour
            timing.minute = minute
            text.replaceSubrange(range, with: " ")
            return groups[5] != nil || rawHour > 12
        }
        return false
    }

    private static func extractDaypart(from text: inout String, timing: inout Timing, clockHasMeridiem: Bool) {
        guard let groups = consume(daypart, from: &text), let part = groups[1] else { return }
        let defaultHour: Int
        switch part {
        case "morning": defaultHour = 9
        case "afternoon": defaultHour = 15
        case "evening": defaultHour = 18
        default: defaultHour = 20
        }
        if timing.hour == nil {
            timing.hour = defaultHour
        } else if !clockHasMeridiem, let hour = timing.hour, (1...11).contains(hour), part != "morning" {
            timing.hour = hour + 12
        } else if !clockHasMeridiem, timing.hour == 12, part == "morning" {
            timing.hour = 0
        }
        if part == "tonight", timing.dayOffset == nil, timing.weekday == nil, timing.day == nil {
            timing.dayOffset = 0
        }
    }

    private static func spokenMinute(_ text: String?) -> Int {
        switch text {
        case "fifteen": 15
        case "thirty": 30
        case "forty five", "forty-five": 45
        default: 0
        }
    }

    private static func integer(_ value: String?) -> Int? {
        value.flatMap { Int($0) ?? numberWords[$0] }
    }

    private static func month(_ value: String?) -> Int? {
        value.flatMap { monthNames.firstIndex(of: $0) }.map { $0 + 1 }
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            preconditionFailure("Invalid weather query pattern: \(error)")
        }
    }

    private static func consume(_ pattern: NSRegularExpression, from text: inout String) -> [String?]? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text)
        else { return nil }
        let groups = captures(match, in: text)
        text.replaceSubrange(range, with: " ")
        return groups
    }

    private static func captures(_ match: NSTextCheckingResult, in text: String) -> [String?] {
        (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { text[$0].lowercased() }
        }
    }
}
