import Foundation

@main
struct DictationAdvancedTest {
    struct Fixture: Encodable {
        let family: String
        let input: String
        let expected: String
    }

    static func main() throws {
        let fixtures = clockCases() + valueCases() + writingCases()
        guard fixtures.count == 5_000, Set(fixtures.map(\.input)).count == fixtures.count else {
            fatalError("Expected 5,000 distinct formatting inputs")
        }
        if CommandLine.arguments.contains("--list") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for fixture in fixtures {
                FileHandle.standardOutput.write(try encoder.encode(fixture))
                FileHandle.standardOutput.write(Data([0x0a]))
            }
            return
        }

        let clock = ContinuousClock()
        let fixed = clock.now
        var failures = 0
        var elapsed: [Duration] = []
        for fixture in fixtures + edgeCases {
            let start = clock.now
            let actual = DictationTextFormatter.advancedCleanup(fixture.input, now: { fixed })
            if elapsed.count < fixtures.count { elapsed.append(start.duration(to: clock.now)) }
            if actual != fixture.expected {
                if failures < 16 {
                    print("[\(fixture.family)] \(fixture.input.debugDescription)")
                    print("  Expected \(fixture.expected.debugDescription)")
                    print("  Received \(actual.debugDescription)")
                }
                failures += 1
            }
        }
        guard failures == 0 else {
            print("\(failures) formatting cases failed")
            exit(1)
        }

        let source = "Um, I I I came in at nine thirty AM."
        var clockReads = 0
        let expired = DictationTextFormatter.advancedCleanup(source) {
            clockReads += 1
            return clockReads < 3 ? fixed : fixed + .milliseconds(30)
        }
        guard expired == source, clockReads == 3 else {
            fatalError("A missed deadline must return the complete original transcript")
        }

        let families = Set(fixtures.map(\.family)).count
        print("Passed \(fixtures.count) distinct cases across \(families) formatting families.")
        print("Passed \(edgeCases.count) additional edge cases and the deadline check.")
        print("Formatter p95 on generated inputs: \(p95Milliseconds(elapsed)) ms")

        let paragraphs = [
            "I have a few updates from today's meeting. Ana will send the draft by nine thirty AM tomorrow.",
            "The pickup is on the twenty-fourth of June. We still need a room for the workshop and a backup plan.",
            "Maya has confirmed the reservation. Jordan will check the equipment and send a note to the rest of the team."
        ]
        let transcript = (0..<4).flatMap { _ in paragraphs }.joined(separator: " ")
        var budgetFallbacks = 0
        let longer = (0..<20).map { _ in
            let start = clock.now
            let result = DictationTextFormatter.advancedCleanup(transcript, now: { clock.now })
            if result == transcript { budgetFallbacks += 1 }
            return start.duration(to: clock.now)
        }
        print("Long transcript p95: \(p95Milliseconds(longer)) ms. Budget fallbacks: \(budgetFallbacks) of \(longer.count).")
    }

    private static func p95Milliseconds(_ elapsed: [Duration]) -> String {
        let p95 = elapsed.sorted()[elapsed.count * 95 / 100 - 1].components
        let milliseconds = Double(p95.seconds) * 1_000 + Double(p95.attoseconds) / 1e15
        return String(format: "%.3f", milliseconds)
    }

    private static let hours = [
        "twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"
    ]

    private static let numberNames: [String] = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        return (0..<100).map { formatter.string(from: NSNumber(value: $0))! }
    }()

    private static func clockCases() -> [Fixture] {
        let leads = ["The train leaves at", "Please call by", "Lunch starts around", "The office is open until"]
        var cases: [Fixture] = []
        for hour in 1...12 {
            for minute in 0..<60 {
                let spoken = minute == 0 ? "o'clock" : (minute < 10 ? "oh " + numberNames[minute] : numberNames[minute])
                let digits = String(format: "%d:%02d", hour, minute)
                let lead = leads[minute % leads.count]
                for (period, forms) in [("AM", ["AM", "a m", "a.m."]), ("PM", ["pm", "p m", "p.m."])] {
                    let marker = forms[(minute + hour) % forms.count]
                    let input = "\(lead) \(hours[hour]) \(spoken) \(marker)" + (marker.hasSuffix(".") ? "" : ".")
                    cases.append(Fixture(family: "AM and PM", input: input, expected: "\(lead) \(digits) \(period)."))
                }
                let daypart = ["morning", "afternoon", "evening"][(minute + hour) % 3]
                let period = daypart == "morning" ? "AM" : "PM"
                cases.append(Fixture(
                    family: "Part of day", input: "\(lead) \(hours[hour]) \(spoken) in the \(daypart).",
                    expected: "\(lead) \(digits) \(period)."))
            }
            let offsets = [("quarter past", 15), ("half past", 30), ("quarter to", -15), ("ten to", -10)]
            for (phrase, delta) in offsets {
                for base in [0, 12] {
                    let period = base == 0 ? "AM" : "PM"
                    let total = ((hour % 12 + base) * 60 + delta + 1_440) % 1_440
                    let formattedHour = (total / 60 + 11) % 12 + 1
                    let digits = String(format: "%d:%02d", formattedHour, total % 60)
                    let resultingPeriod = total < 720 ? "AM" : "PM"
                    for lead in ["Call at", "Be ready by"] {
                        cases.append(Fixture(
                            family: "Relative clock time", input: "\(lead) \(phrase) \(hours[hour]) \(period).",
                            expected: "\(lead) \(digits) \(resultingPeriod)."))
                    }
                }
            }
        }
        for hour in 0..<24 {
            for minute in stride(from: 0, to: 60, by: 5) {
                let separator = minute.isMultiple(of: 10) ? " " : ""
                let spoken = String(format: "%02d%@%02d", hour, separator, minute)
                let digits = String(format: "%02d:%02d", hour, minute)
                cases.append(Fixture(
                    family: "24-hour time", input: "The next shift starts at \(spoken) hours.",
                    expected: "The next shift starts at \(digits)."))
            }
        }
        return cases
    }

    private static func valueCases() -> [Fixture] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        let months = calendar.monthSymbols
        let ordinals = """
            first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth \
            fifteenth sixteenth seventeenth eighteenth nineteenth twentieth twenty-first twenty-second twenty-third \
            twenty-fourth twenty-fifth twenty-sixth twenty-seventh twenty-eighth
            """.split(separator: " ")
        var cases: [Fixture] = []
        for month in months {
            for (day, ordinal) in ordinals.enumerated() {
                cases.append(Fixture(
                    family: "Named date", input: "Schedule the pickup for the \(ordinal) of \(month).",
                    expected: "Schedule the pickup for \(month) \(day + 1)."))
                cases.append(Fixture(
                    family: "Spoken year", input: "Save the date for the \(ordinal) of \(month), twenty twenty-seven.",
                    expected: "Save the date for \(month) \(day + 1), 2027."))
            }
        }
        let currencies = [("$", "dollars", "cents"), ("€", "euros", "cents"), ("£", "pounds sterling", "pence")]
        for amount in 0..<100 {
            for (symbol, unit, minor) in currencies {
                for fraction in [5, 99] {
                    let digits = String(format: "%02d", fraction)
                    let unit = amount == 1 ? unit.replacing(/s\b/, with: "") : unit
                    cases.append(Fixture(
                        family: "Currency and cents",
                        input: "The total is \(numberNames[amount]) \(unit) and \(numberNames[fraction]) \(minor).",
                        expected: "The total is \(symbol)\(amount).\(digits)."))
                }
            }
        }
        return cases
    }

    private static func writingCases() -> [Fixture] {
        let names = ["Ana", "James", "Maya", "Priya", "Noah", "Sam", "Ella", "Jordan"]
        let hosts = ["Jim", "Amir", "Nina", "Kai", "Grace", "Owen", "Rita", "Leo"]
        let tasks = [
            "agenda", "invoice", "contract", "proposal", "receipt", "schedule", "menu", "quote",
            "report", "playlist", "presentation", "form", "note", "budget", "outline", "draft"
        ]
        var cases: [Fixture] = []
        for name in names {
            for (index, task) in tasks.enumerated() {
                let sentence = "Send \(name) the \(task)."
                let amount = index + 10
                let value = index.isMultiple(of: 2)
                    ? Fixture(family: "Percentage", input: "Give \(name) \(numberNames[amount]) percent off the \(task).",
                              expected: "Give \(name) \(amount)% off the \(task).")
                    : Fixture(family: "Measurement", input: "The \(task) for \(name) needs \(numberNames[amount]) centimeters.",
                              expected: "The \(task) for \(name) needs \(amount) cm.")
                cases += [
                    Fixture(family: "Filler removal", input: "Um, send \(name) the \(task).", expected: sentence),
                    Fixture(family: "Stutter removal", input: "I I I will send \(name) the \(task).",
                            expected: "I will send \(name) the \(task)."),
                    Fixture(family: "Weekday correction", input: "Send \(name) the \(task) on Friday, no sorry, Monday.",
                            expected: "Send \(name) the \(task) on Monday."),
                    Fixture(family: "Paragraph command", input: "\(sentence) New paragraph. Keep a copy.",
                            expected: "\(sentence)\n\nKeep a copy."),
                    Fixture(
                        family: "Bullet list", input: "Tasks for \(name): bullet one send the \(task) bullet two keep a copy.",
                        expected: "Tasks for \(name):\n• send the \(task)\n• keep a copy."),
                    Fixture(
                        family: "Numbered list", input: "For \(name): first, open the \(task), second, check it, third, send it.",
                        expected: "For \(name):\n1. open the \(task)\n2. check it\n3. send it."),
                    Fixture(family: "Quoted speech", input: "Tell \(name) the \(task) says “Um, meet at nine thirty AM.”",
                            expected: "Tell \(name) the \(task) says “Um, meet at nine thirty AM.”"),
                    value
                ]
            }
            for host in hosts {
                let question = "\(name), joining us now, good morning, \(name). What's your take?"
                let reply = "Morning, \(host). I agree."
                cases.append(Fixture(
                    family: "Speaker handoff", input: "We're back. \(question) \(reply)",
                    expected: "We're back.\n\n\(question)\n\n\(reply)"))
            }
        }
        return cases
    }

    private static let edgeCases = [
        Fixture(family: "List from heading and sequence",
                input: "Here are the next steps. First, send the invoice. Next, confirm the date. Finally, notify the team.",
                expected: "Here are the next steps:\n1. send the invoice.\n2. confirm the date.\n3. notify the team."),
        Fixture(family: "Unpunctuated sequence",
                input: "First open the file and then check the figures, and finally send the draft.",
                expected: "1. open the file\n2. check the figures\n3. send the draft."),
        Fixture(family: "Two spoken numbered markers",
                input: "Number one, check the figures. Number two, send the draft.",
                expected: "1. check the figures.\n2. send the draft."),
        Fixture(family: "List from declared count",
                input: "I have two action items. Send the invoice. Confirm the delivery date.",
                expected: "I have two action items:\n• Send the invoice.\n• Confirm the delivery date."),
        Fixture(family: "List after introductory prose",
                input: "We're leaving tomorrow. Packing list: a charger, a notebook and a pen.",
                expected: "We're leaving tomorrow.\n\nPacking list:\n• a charger\n• a notebook\n• a pen."),
        Fixture(family: "List from start and exit commands",
                input: "Start numbered list. Check the figures. Next item. Send the draft. Exit list. Let me know.",
                expected: "1. Check the figures\n2. Send the draft.\n\nLet me know."),
        Fixture(family: "Text after list",
                input: "Next steps: First, call Ana. Finally, send the invoice. Let me know if that works.",
                expected: "Next steps:\n1. call Ana.\n2. send the invoice.\n\nLet me know if that works."),
        Fixture(family: "Declared count mismatch",
                input: "I have three action items. Send the invoice. Confirm the delivery date.",
                expected: "I have three action items. Send the invoice. Confirm the delivery date."),
        Fixture(family: "Incomplete ordinal sequence",
                input: "Next steps: First, open the file, third, send it.",
                expected: "Next steps: First, open the file, third, send it."),
        Fixture(family: "Comma-separated clauses",
                input: "Next steps: When the meeting ends, if you have a minute, call Ana.",
                expected: "Next steps: When the meeting ends, if you have a minute, call Ana."),
        Fixture(family: "Narration",
                input: "First, I looked at the figures. Then, I walked home. Finally, I went to bed.",
                expected: "First, I looked at the figures. Then, I walked home. Finally, I went to bed."),
        Fixture(family: "Topic change and recap",
                input: "Dr. Chen checked the figures. Moving on to delivery, the courier will call tomorrow. "
                    + "To sum up, everything is booked.",
                expected: "Dr. Chen checked the figures.\n\nMoving on to delivery, the courier will call tomorrow.\n\n"
                    + "To sum up, everything is booked."),
        Fixture(family: "Greeting and sign-off",
                input: "Hi Ana, the invoice is ready. Kind regards, Maya.",
                expected: "Hi Ana,\n\nthe invoice is ready.\n\nKind regards,\nMaya."),
        Fixture(family: "Ordinary continuation",
                input: "The file is ready. However, please check the totals again. Next week, we can send it.",
                expected: "The file is ready. However, please check the totals again. Next week, we can send it."),
        Fixture(family: "Existing formatting",
                input: "Next steps:\n1. Open the file.\n2. Send the invoice.",
                expected: "Next steps:\n1. Open the file.\n2. Send the invoice."),
        Fixture(family: "Noon and midnight", input: "We open at noon and close at midnight.",
                expected: "We open at 12:00 PM and close at 12:00 AM."),
        Fixture(family: "Compact time", input: "Start at 9:05am.", expected: "Start at 9:05 AM."),
        Fixture(family: "Time range", input: "Open from nine AM to five PM.", expected: "Open from 9:00 AM to 5:00 PM."),
        Fixture(family: "Unspecified part of day", input: "Call at nine thirty tomorrow.", expected: "Call at 9:30 tomorrow."),
        Fixture(family: "Spoken 24-hour time", input: "Call at fourteen thirty.", expected: "Call at 14:30."),
        Fixture(family: "Invalid time", input: "Call at 9:65 AM.", expected: "Call at 9:65 AM."),
        Fixture(family: "Invalid 24-hour time", input: "Leave at 2460 hours.", expected: "Leave at 2460 hours."),
        Fixture(family: "Address", input: "Meet me at nine thirty Main Street.", expected: "Meet me at nine thirty Main Street."),
        Fixture(family: "Duration", input: "Check it after twenty five minutes.",
                expected: "Check it after twenty five minutes."),
        Fixture(family: "Ordinary numbers", input: "It is for five to nine people.", expected: "It is for five to nine people."),
        Fixture(family: "Weight", input: "It weighs twenty pounds.", expected: "It weighs twenty pounds."),
        Fixture(family: "Unspecified clock time", input: "Send the draft at nine.", expected: "Send the draft at nine."),
        Fixture(family: "Cedis and pesewas", input: "Pay forty-five cedis and five pesewas.",
                expected: "Pay GH₵45.05."),
        Fixture(family: "Mismatched currency", input: "Pay forty pounds sterling and five cents.",
                expected: "Pay forty pounds sterling and five cents."),
        Fixture(family: "Large amount", input: "It cost two million twenty-five dollars.",
                expected: "It cost two million twenty-five dollars."),
        Fixture(family: "Decimal amount", input: "It costs 2.50 dollars.", expected: "It costs $2.50."),
        Fixture(family: "Grouped amount", input: "It costs 1,200 dollars.", expected: "It costs $1,200."),
        Fixture(family: "Malformed grouping", input: "It costs 12,00 dollars.", expected: "It costs 12,00 dollars."),
        Fixture(family: "Signed currency", input: "The balance is minus five dollars.",
                expected: "The balance is -$5."),
        Fixture(family: "Explicit currency", input: "The fee is fifty Indian rupees and five paise.",
                expected: "The fee is ₹50.05."),
        Fixture(family: "Unspecified currency", input: "The fee is fifty rupees.",
                expected: "The fee is fifty rupees."),
        Fixture(family: "Spoken decimal percentage", input: "The rate is twelve point five per cent.",
                expected: "The rate is 12.5%."),
        Fixture(family: "Percentage points", input: "It rose by five percentage points.",
                expected: "It rose by five percentage points."),
        Fixture(family: "Decimal measurement", input: "The sample weighs two point zero five kilograms.",
                expected: "The sample weighs 2.05 kg."),
        Fixture(family: "Written decimal measurement", input: "It holds 1.50 litres.",
                expected: "It holds 1.50 L."),
        Fixture(family: "Temperature", input: "It is minus five degrees Celsius.",
                expected: "It is -5 °C."),
        Fixture(family: "Storage", input: "The file is sixteen megabytes.",
                expected: "The file is 16 MB."),
        Fixture(family: "Explicit punctuation", input: "Bring three things, insert colon. A pen, paper, and a ruler.",
                expected: "Bring three things: A pen, paper, and a ruler."),
        Fixture(family: "Month first", input: "Ship on June twenty-fourth, twenty twenty seven.",
                expected: "Ship on June 24, 2027."),
        Fixture(family: "Spoken year", input: "It opened on June first, two thousand and five.",
                expected: "It opened on June 1, 2005."),
        Fixture(family: "Ambiguous month", input: "May first aid be taught here?",
                expected: "May first aid be taught here?"),
        Fixture(family: "Relative clock time", input: "Call at twenty five to nine PM.",
                expected: "Call at 8:35 PM."),
        Fixture(family: "Spaced clock marker", input: "Call at nine o clock.",
                expected: "Call at 9:00."),
        Fixture(family: "Leap date", input: "Ship on the twenty-ninth of February, 2028.",
                expected: "Ship on February 29, 2028."),
        Fixture(family: "Invalid date", input: "Ship on the twenty-ninth of February, 2027.",
                expected: "Ship on the twenty-ninth of February, 2027."),
        Fixture(family: "Code", input: "Print \u{60}at nine AM\u{60}.", expected: "Print \u{60}at nine AM\u{60}."),
        Fixture(family: "URL", input: "See example.com at nine AM.", expected: "See example.com at nine AM."),
        Fixture(family: "Contraction", input: "Let's meet at nine thirty in the morning.", expected: "Let's meet at 9:30 AM."),
        Fixture(family: "Dotted time in prose", input: "Call at 8 a.m. tomorrow.", expected: "Call at 8:00 AM tomorrow.")
    ]
}
