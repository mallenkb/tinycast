import Foundation

enum DictationCleanupMode: Hashable, Sendable {
    case off, basic, advanced, smart
}

enum DictationTextFormatter {
    struct Context: Sendable {
        let trailing: Character?
        let lastNonWhitespace: Character?
        let newParagraph: Bool
        let following: Character?

        init(before: Substring, after: Substring) {
            trailing = before.last
            following = after.first
            var last: Character?
            var paragraph = false
            for character in before.reversed() {
                if !character.isWhitespace {
                    last = character
                    break
                }
                if character.isNewline { paragraph = true }
            }
            lastNonWhitespace = last
            newParagraph = paragraph
        }
    }

    static func removingFillerWords(_ transcript: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.wholeMatch(of: /(?:[Uu][mh][,.!?…]*(?:[ \t]+|$))+/) != nil { return "" }
        return text
            .replacing(/(^|\n|[.!?…][ \t]+)(?:[Uu][mh][,.!?…]*[ \t]+)+(\p{L})/) { match in
                String(match.1) + match.2.uppercased()
            }
            .replacing(/([.!?…])[ \t]+(?:[Uu][mh][,.!?…]*(?:[ \t]+|$))+$/) { String($0.1) }
            .replacing(/(?:,[ \t]+[Uu][mh],|[ \t]+[Uu][mh],?)(?=\s|$)/, with: "")
            .replacing(/,?[ \t]+[Uu][mh](?=[.!?…]+(?:\s|$))/, with: "")
    }

    static func basicCleanup(
        _ transcript: String, normalize: (String) -> String, preparedLine: (Substring) -> String? = { _ in nil },
        now: () -> ContinuousClock.Instant
    ) -> String {
        let cleaned = removingFillerWords(transcript)
        return cleanLines(cleaned, now: now) { line in
            preparedLine(line) ?? cleanBasicLine(line, normalize: normalize)
        } ?? currencyCleanup(cleaned, now: now)
    }

    static func advancedCleanup(
        _ transcript: String, normalize: (String) -> String = { $0 }, preparedLine: (Substring) -> String? = { _ in nil },
        now: () -> ContinuousClock.Instant
    ) -> String {
        cleanLines(transcript, now: now) { preparedLine($0) ?? cleanAdvancedLine($0, normalize: normalize) } ?? transcript
    }

    private static func cleanLines(
        _ transcript: String, now: () -> ContinuousClock.Instant, clean: (Substring) -> String
    ) -> String? {
        let deadline = now() + .milliseconds(30)
        guard transcript.utf8.prefix(16_385).count <= 16_384 else { return transcript }
        guard transcript.firstMatch(of: /[\x22“”‘\x60]|(?:^|[^\p{L}])['’]\p{L}/) == nil else { return transcript }
        var lines: [String] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            guard now() < deadline else { return nil }
            lines.append(clean(line))
        }
        let result = lines.joined(separator: "\n")
        return now() < deadline ? result : nil
    }

    private static func preservesLiteral(_ line: Substring) -> Bool {
        let literalCheck = line.replacing(/(?i:\b[ap]\.m\b)/, with: "")
        return literalCheck.firstMatch(of: /[@\/\\<>]|(?i:\b(?:https?:|www\.))|(?:\w\.\p{L}|\p{L}\.\w)/) != nil
    }

    static func cleanBasicLine(_ line: Substring, normalize: (String) -> String) -> String {
        preservesLiteral(line) ? String(line) : formatSpokenValues(String(line), normalize: normalize)
    }

    static func cleanAdvancedLine(_ line: Substring, normalize: (String) -> String) -> String {
        guard !preservesLiteral(line) else { return String(line) }
        guard let first = line.firstIndex(where: { !$0.isWhitespace }),
              let last = line.lastIndex(where: { !$0.isWhitespace })
        else { return String(line) }

        let leading = line[..<first]
        let trailing = line[line.index(after: last)...]
        var text = String(line[first...last])
        if text.wholeMatch(of: /(?i:new paragraph)[.!]?/) != nil { return "" }
        text = text.replacing(/(?i:\b(?:erm+|umm+|uhh+)\b)/, with: "um")
        text = removingFillerWords(text)
        text = text.replacing(/(?i:\b(the|a|an|to|in|of|for|from|with)(?:[ \t]+\1\b)+)/) { String($0.1) }
        text = removingRepeatedPronouns(text)
        if text.firstMatch(of: /(?i:\b(?:not|never|except|unless|without|only)\b|n['’]t\b)/) == nil {
            text = text.replacing(
                #/
                (?ix: \b (?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)
                  (?: ,[\x20\t]*no,[\x20\t]+ |
                    [,\t\x20]+(?:no[,\t\x20]+sorry|sorry[,\t\x20]+I[\x20\t]meant|make[\x20\t]that)[,\t\x20]+ )
                  (Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) \b )
                (?=[,.;!?]|$)
                /#
            ) { String($0.1) }
        }
        text = text.replacing(/(?i:[.!?][ \t]+new paragraph[.!?,][ \t]+)/) {
            String($0.output.prefix(1)) + "\n\n"
        }
        text = text.replacing(/(?i:[.!?][ \t]+new line[.!?,][ \t]+)/) {
            String($0.output.prefix(1)) + "\n"
        }
        text = text.replacing(/(?i:,[ \t]+new paragraph,[ \t]+)/, with: "\n\n")
        text = text.replacing(/(?i:,[ \t]+new line,[ \t]+)/, with: "\n")
        text = insertSpokenPunctuation(text)
        text = formatSpokenValues(text, normalize: normalize)
        return leading + formatSpokenStructure(text) + trailing
    }

    private static func removingRepeatedPronouns(_ text: String) -> String {
        text.replacing(
            #/
            (?ix:
                (^|[^\w'’])
                (
                    (?:i|you|he|she|it|we|they)(?:['’](?:m|re|s|ve|ll|d))?\b(?!['’])
                    (?:[\x20\t]+(?:i|you|he|she|it|we|they)(?:['’](?:m|re|s|ve|ll|d))?\b(?!['’]))+
                )
                (?=[\x20\t]+\p{L})
            )
            /#
        ) { match in
            var result = String(match.1)
            var end = match.2.startIndex
            var previous = ""
            for word in match.2.split(whereSeparator: \.isWhitespace) {
                let normalized = word.lowercased()
                if normalized != previous { result += match.2[end..<word.endIndex] }
                previous = normalized
                end = word.endIndex
            }
            return result
        }
    }

    private static func formatSpokenValues(_ input: String, normalize: (String) -> String) -> String {
        var text = input
        text = normalizeSpokenQuantities(text)
        text = normalizeSpokenCurrency(text)
        text = normalizeSpokenDates(text)
        text = normalizeSpokenTimes(text)
        return normalize(text)
    }

    private static func insertSpokenPunctuation(_ text: String) -> String {
        text.replacing(
            #/
            (?i:,[\x20\t]+insert[\x20\t]+
                (comma|period|full stop|question mark|exclamation mark|colon|semicolon|ellipsis))
            (?:[,.!?]|$)(?=\s|$)
            /#
        ) {
            switch $0.1.lowercased() {
            case "comma": ","
            case "period", "full stop": "."
            case "question mark": "?"
            case "exclamation mark": "!"
            case "colon": ":"
            case "semicolon": ";"
            default: "…"
            }
        }
    }

    private static let quantityUnits = [
        "millimeter": "mm", "millimetre": "mm", "centimeter": "cm", "centimetre": "cm",
        "meter": "m", "metre": "m", "kilometer": "km", "kilometre": "km",
        "milligram": "mg", "gram": "g", "kilogram": "kg",
        "milliliter": "mL", "millilitre": "mL", "liter": "L", "litre": "L",
        "kilobyte": "KB", "megabyte": "MB", "gigabyte": "GB", "terabyte": "TB"
    ]

    private static func normalizeSpokenQuantities(_ text: String) -> String {
        text.replacing(
            #/
            (?ix:
                (?<sign>[-−+]|(?:minus|negative|plus|positive)[\x20\t]+)?\b
                (?<whole>[0-9]+(?:,[0-9]{3})*|
                    (?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|
                       fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|
                       sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion)
                    (?:[-\x20\t]+(?:and[\x20\t]+)?
                       (?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|
                          fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|
                          sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion)){0,5})
                (?:\.(?<writtenFraction>[0-9]+)|
                   [\x20\t]+point[\x20\t]+(?<spokenFraction>
                       (?:zero|oh|one|two|three|four|five|six|seven|eight|nine|[0-9]+)
                       (?:[\x20\t]+(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|[0-9]+)){0,8}))?
                [\x20\t]+
                (?<unit>percent|per[\x20\t]+cent|millimet(?:er|re)s?|centimet(?:er|re)s?|kilomet(?:er|re)s?|
                    met(?:er|re)s?|milligrams?|kilograms?|grams?|millilit(?:er|re)s?|lit(?:er|re)s?|
                    (?:kilo|mega|giga|tera)bytes?|degrees?[\x20\t]+(?:Celsius|Fahrenheit))\b
                (?![\x20\t]+(?:percentage[\x20\t]+)?points?\b)
            )
            /#
        ) { match in
            let prefix = text[..<match.range.lowerBound].suffix(48)
            let prior = prefix.split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
            if prefix.last?.isLetter == true || prefix.last?.isNumber == true
                || prefix.firstMatch(of: /(?:[0-9][.,]|[+−$€£₵\/-])$/) != nil
                || prior.first?.isNumber == true || units.contains(prior) || tens.contains(prior)
                || ["hundred", "thousand", "million", "billion", "trillion", "point", "minus", "negative",
                    "plus", "positive", "half", "quarter"].contains(prior)
            { return String(match.output.0) }

            let whole: String
            if match.whole.first?.isNumber == true {
                whole = String(match.whole)
            } else if let value = spokenNumber(match.whole) {
                whole = String(value)
            } else {
                return String(match.output.0)
            }

            var value = whole
            if let fraction = match.writtenFraction {
                value += "." + fraction
            } else if let fraction = match.spokenFraction {
                let words = fraction.split(whereSeparator: \.isWhitespace)
                let digits = words.compactMap { word -> String? in
                    if word.utf8.allSatisfy({ (48...57).contains($0) }) { return String(word) }
                    if word.lowercased() == "oh" { return "0" }
                    guard let digit = spokenNumber(word), digit < 10 else { return nil }
                    return String(digit)
                }
                guard digits.count == words.count else { return String(match.output.0) }
                value += "." + digits.joined()
            }

            if let sign = match.sign?.trimmingCharacters(in: .whitespaces).lowercased() {
                value = (["-", "−", "minus", "negative"].contains(sign) ? "-" : "+") + value
            }
            let unit = match.unit.lowercased()
            if unit == "percent" || unit.hasPrefix("per") { return value + "%" }
            if unit.hasSuffix("celsius") { return value + " °C" }
            if unit.hasSuffix("fahrenheit") { return value + " °F" }
            let singular = unit.hasSuffix("s") ? String(unit.dropLast()) : unit
            guard let symbol = quantityUnits[singular] else { return String(match.output.0) }
            return value + " " + symbol
        }
    }

    private static let spokenListNumbers = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"
    ]
    private static let spokenListOrdinals = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"
    ]

    private struct ListHeading {
        let range: Range<String.Index>
        let text: String
        let count: Int?
        let numbered: Bool
        let hasColon: Bool
    }

    private static func listHeading(in text: Substring) -> ListHeading? {
        guard let match = text.firstMatch(of: #/
            (?ix:
                (?:^|[.!?][\x20\t]+)
                (?<title>
                    (?:(?:i[\x20\t]+have|we[\x20\t]+(?:have|need)|you[\x20\t]+need|
                        here[\x20\t]+are|there[\x20\t]+are)[\x20\t]+)?
                    (?:(?<count>two|three|four|five|six|seven|eight|nine|ten|[2-9]|10)[\x20\t]+|
                        (?:the|a[\x20\t]+few)[\x20\t]+)?
                    (?<kind>next[\x20\t]+steps|action[\x20\t]+items|shopping[\x20\t]+list|
                        to-do[\x20\t]+list|checklist|packing[\x20\t]+list|ingredients|agenda|
                        steps|tasks|priorities|requirements|things|items|points)
                    (?:[\x20\t]+to[\x20\t]+(?:cover|do|buy|pack|review|check|discuss|remember))?
                    | (?:do|bring|check|prepare|review|buy|pack|include|consider)[\x20\t]+the[\x20\t]+following
                    | here['’]s[\x20\t]+(?:what[\x20\t]+we[\x20\t]+need|the[\x20\t]+plan)
                )
                (?<delimiter>[:.,])[\x20\t]+
            )
            /#)
        else { return nil }
        let count = match.count.flatMap { number in
            Int(number) ?? spokenListNumbers.firstIndex(of: number.lowercased()).map { $0 + 1 }
        }
        let before = text[..<match.title.startIndex].trimmingCharacters(in: .whitespaces)
        let title = (before.isEmpty ? "" : before + "\n\n") + match.title + ":"
        return ListHeading(
            range: match.title.startIndex..<match.range.upperBound,
            text: title,
            count: count,
            numbered: match.kind?.lowercased().hasSuffix("steps") == true,
            hasColon: match.delimiter == ":")
    }

    private static func formatSpokenList(_ text: Substring) -> String? {
        let ending = text.firstMatch(of: #/
            (?ix:
                (?:[.!?,;][\x20\t]+)
                (?:end|exit)[\x20\t]+(?:the[\x20\t]+)?list\b
                (?:[.!?,][\x20\t]*|$)
            )
            /#)
        let bodyEnd = ending.map { match in
            let start = match.range.lowerBound
            return ".!?".contains(text[start]) ? text.index(after: start) : start
        } ?? text.endIndex
        let body = text[..<bodyEnd]
        let heading = listHeading(in: body)
        guard let formatted = formatMarkedList(body, heading: heading)
            ?? formatCommandList(body)
            ?? heading.flatMap({ formatIntroducedList(body, heading: $0) })
        else { return nil }
        let remainder = ending.map { text[$0.range.upperBound...].trimmingCharacters(in: .whitespaces) } ?? ""
        return remainder.isEmpty ? formatted : formatted + "\n\n" + remainder
    }

    private static func formatMarkedList(_ text: Substring, heading: ListHeading?) -> String? {
        let markers = text.matches(of: #/
            (?ix: \b (?:
                (?<kind>bullet|item|step|number)[\x20\t]+
                (?<label>point|one|two|three|four|five|six|seven|eight|nine|ten|10|[1-9])\b
                (?=[,.:\x20\t])
                | (?<join>and[\x20\t]+)?
                  (?<ordinal>first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|
                    next|then|finally)\b(?=[,.:\x20\t])
            ) (?<delimiter>[,.:])?[\x20\t]+ )
            /#)
        let explicit = markers.filter { marker in
            marker.kind?.lowercased() == "bullet" || (marker.kind != nil && marker.delimiter != nil)
        }
        let candidates = explicit.isEmpty ? markers.filter { marker in
            guard marker.ordinal != nil, heading?.range.contains(marker.range.lowerBound) != true else { return false }
            let before = text[..<marker.range.lowerBound].last { !$0.isWhitespace }
            return (before.map { ",;:.!?".contains($0) } ?? true) || marker.join != nil
        } : explicit
        guard let first = candidates.first, candidates.count >= 2 else { return nil }
        let prefix = text[..<first.range.lowerBound].trimmingCharacters(in: .whitespaces)
        let matchedHeading = heading.flatMap { $0.range.upperBound == first.range.lowerBound ? $0 : nil }
        let family = first.kind?.lowercased()
        let titled = matchedHeading != nil || prefix.last == ":"
        guard titled || prefix.isEmpty || (family != nil && prefix.last.map { ".!?".contains($0) } == true)
        else { return nil }
        if let count = matchedHeading?.count, count != candidates.count { return nil }
        let hasTransitions = candidates.contains { marker in
            ["finally", "then", "next"].contains(marker.ordinal?.lowercased() ?? "")
        }
        guard family != nil || candidates.count <= 10 else { return nil }

        var items: [String] = []
        for (index, marker) in candidates.enumerated() {
            let next = index + 1 < candidates.count ? candidates[index + 1].range.lowerBound : text.endIndex
            let item = text[marker.range.upperBound..<next].trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            let before = text[..<marker.range.lowerBound].last { !$0.isWhitespace }
            guard index == 0 || family == "bullet" || marker.join != nil
                || before.map({ ",;:.!?".contains($0) }) == true else {
                return nil
            }
            if let family {
                guard marker.kind?.lowercased() == family, let label = marker.label?.lowercased()
                else { return nil }
                if first.label?.lowercased() == "point" {
                    guard family == "bullet", label == "point" else { return nil }
                } else {
                    let number = Int(label) ?? spokenListNumbers.firstIndex(of: label).map { $0 + 1 }
                    guard number == index + 1 else { return nil }
                }
            } else {
                let ordinal = marker.ordinal?.lowercased() ?? ""
                let sequence = spokenListOrdinals.indices.contains(index) && ordinal == spokenListOrdinals[index]
                let transition = index > 0 && (ordinal == "next" || ordinal == "then"
                    || (ordinal == "finally" && index + 1 == candidates.count))
                guard sequence || transition else { return nil }
                if marker.delimiter == nil || (!titled && hasTransitions) {
                    guard beginsWithAction(item) else { return nil }
                }
            }
            items.append(item)
        }
        guard family != nil || titled || items.count >= 3 else { return nil }
        return renderList(items, numbered: family != "bullet", prefix: matchedHeading?.text ?? String(prefix))
    }

    private static func beginsWithAction(_ text: String) -> Bool {
        text.firstMatch(of: #/
            (?ix: ^(?:add|ask|book|bring|buy|call|check|choose|clean|close|collect|confirm|contact|copy|create|
                download|edit|email|fill|find|finish|get|give|include|install|keep|make|measure|mix|move|notify|
                open|pack|pay|place|prepare|print|read|remove|replace|review|save|schedule|select|send|set|share|
                sign|start|submit|take|test|turn|update|upload|use|verify|wait|write|archive)\b[\x20\t]+\p{L})
            /#) != nil
    }

    private static func formatCommandList(_ text: Substring) -> String? {
        guard let start = text.firstMatch(of: #/
            (?ix: ^(?:start|create)[\x20\t]+(?:a[\x20\t]+)?
                (numbered[\x20\t]+list|bulleted[\x20\t]+list|bullet[\x20\t]+list|list)[.,:][\x20\t]+)
            /#)
        else { return nil }
        let body = text[start.range.upperBound...]
        let boundaries = body.matches(of: #/
            (?ix: [.!?,;][\x20\t]+(?:next[\x20\t]+(?:item|bullet|line)|new[\x20\t]+bullet)\b[.,:]?[\x20\t]+)
            /#)
        guard !boundaries.isEmpty else { return nil }
        var startOfItem = body.startIndex
        var items: [String] = []
        for boundary in boundaries {
            let endOfItem = "!?".contains(body[boundary.range.lowerBound])
                ? body.index(after: boundary.range.lowerBound) : boundary.range.lowerBound
            items.append(String(body[startOfItem..<endOfItem]))
            startOfItem = boundary.range.upperBound
        }
        items.append(String(body[startOfItem...]))
        guard items.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return renderList(items, numbered: start.1.lowercased().hasPrefix("numbered"), prefix: "")
    }

    private static func formatIntroducedList(_ text: Substring, heading: ListHeading) -> String? {
        let body = text[heading.range.upperBound...]
        guard body.firstMatch(of: #/
            (?ix: ^(?:first|second|third|finally)[,.:]|
                ^(?:bullet|item|number|step)[\x20\t]+(?:point|one|two|three|[0-9]+)\b)
            /#) == nil
        else { return nil }
        let sentences = sentenceBoundaries(in: body)
        var items: [String]
        if !sentences.isEmpty {
            guard let count = heading.count, sentences.count + 1 == count else { return nil }
            var start = body.startIndex
            items = sentences.map { boundary in
                let end = body.index(after: boundary.lowerBound)
                defer { start = boundary.upperBound }
                return String(body[start..<end])
            }
            items.append(String(body[start...]))
            if !heading.hasColon {
                let parallelActions = items.allSatisfy(beginsWithAction)
                let shortFragments = items.allSatisfy { item in
                    item.split(whereSeparator: \.isWhitespace).count <= 5 &&
                        item.firstMatch(of: /(?i:^(?:i|we|you|he|she|it|they|this|that|there)\b)/) == nil
                }
                guard parallelActions || shortFragments else { return nil }
            }
        } else {
            guard heading.hasColon else { return nil }
            let separator: Regex<Substring> = body.firstMatch(of: /;[ \t]+/) == nil ? /,[ \t]+/ : /;[ \t]+/
            items = body.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            if let last = items.last, last.firstMatch(of: /(?i:^and[ \t]+)/) == nil,
               heading.count.map({ items.count < $0 }) ?? (items.count > 1 && items.count < 3),
               let conjunction = last.firstMatch(of: /(?i:[ \t]+and[ \t]+)/) {
                items.removeLast()
                items.append(String(last[..<conjunction.range.lowerBound]))
                items.append(String(last[conjunction.range.upperBound...]))
            }
            if let last = items.last {
                items[items.count - 1] = last.replacing(/(?i:^and[ \t]+)/, with: "")
            }
            guard !items.contains(where: { item in
                item.firstMatch(of: #/
                    (?ix: ^(?:if|when|while|because|although|unless|before|after|since|once|until|
                        even[\x20\t]+though)[\x20\t]+)
                    /#) != nil
            }) else { return nil }
        }
        guard ((heading.count ?? 3)...10).contains(items.count), heading.count.map({ $0 == items.count }) ?? true,
              items.allSatisfy({ (1...18).contains($0.split(whereSeparator: \.isWhitespace).count) })
        else { return nil }
        return renderList(items, numbered: heading.numbered, prefix: heading.text)
    }

    private static func renderList(_ items: [String], numbered: Bool, prefix: String) -> String {
        var items = items
        var closing = ""
        let last = items[items.count - 1]
        if let boundary = sentenceBoundaries(in: last[...]).first(where: {
            last[$0.upperBound...].firstMatch(of: #/
                (?ix: ^(?:let[\x20\t]+me[\x20\t]+know|if[\x20\t]+you[\x20\t]+have[\x20\t]+(?:any[\x20\t]+)?questions|
                    thanks[\x20\t]+for|thank[\x20\t]+you[\x20\t]+for|that['’]s[\x20\t]+all)\b)
                /#) != nil
        }) {
            closing = "\n\n" + last[boundary.upperBound...]
            items[items.count - 1] = String(last[..<last.index(after: boundary.lowerBound)])
        }
        let list = items.enumerated().map { index, item in
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            let content = index + 1 < items.count && trimmed.last.map({ ",;".contains($0) }) == true
                ? String(trimmed.dropLast()) : trimmed
            return (numbered ? "\(index + 1). " : "• ") + content
        }.joined(separator: "\n")
        return (prefix.isEmpty ? list : prefix + "\n" + list) + closing
    }

    private static func sentenceBoundaries(in text: Substring) -> [Range<String.Index>] {
        text.matches(of: /[.!?][ \t]+(?=\p{L})/).compactMap { match in
            if text[match.range.lowerBound] == "." {
                let lastWord = text[..<match.range.lowerBound].suffix(16).split(whereSeparator: \.isWhitespace).last ?? ""
                if (lastWord.count == 1 && lastWord.first?.isLetter == true) ||
                    lastWord.wholeMatch(of: /(?:\p{L}\.)+\p{L}/) != nil ||
                    ["mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "vs", "etc", "fig", "no"]
                    .contains(lastWord.lowercased()) { return nil }
            }
            return match.range
        }
    }

    private static func separateTopicParagraphs(_ text: Substring) -> String {
        var start = text.startIndex
        var paragraphs: [String] = []
        var sentenceCount = 0
        for boundary in sentenceBoundaries(in: text) {
            sentenceCount += 1
            let remainder = text[boundary.upperBound...]
            let explicitTransition = remainder.firstMatch(of: #/
                (?ix: ^
                    (?: (?:on[\x20\t]+(?:another|a[\x20\t]+(?:separate|different))[\x20\t]+note|
                          changing[\x20\t]+(?:topics|subjects)|switching[\x20\t]+gears|
                          in[\x20\t]+(?:summary|conclusion)|to[\x20\t]+(?:sum[\x20\t]+up|recap|wrap[\x20\t]+up)|
                          next[\x20\t]+topic|one[\x20\t]+last[\x20\t]+thing)
                          [,:\x20\t]
                        | (?:moving[\x20\t]+on[\x20\t]+to|let['’]s[\x20\t]+move[\x20\t]+on[\x20\t]+to|
                            turning[\x20\t]+(?:now[\x20\t]+)?to|
                            as[\x20\t]+for|that[\x20\t]+brings[\x20\t]+(?:me|us)[\x20\t]+to)[\x20\t]+\p{L}
                    )
                )
                /#) != nil
            let end = text.index(after: boundary.lowerBound)
            let developedPassage = sentenceCount >= 2
                && text[start..<end].split(maxSplits: 29, whereSeparator: \.isWhitespace).count == 30
                && remainder.split(maxSplits: 14, whereSeparator: \.isWhitespace).count == 15
            guard explicitTransition || (developedPassage && startsParagraphTransition(remainder))
            else { continue }
            guard text[start..<end].split(maxSplits: 3, whereSeparator: \.isWhitespace).count == 4,
                  text[boundary.upperBound...].split(maxSplits: 3, whereSeparator: \.isWhitespace).count == 4
            else { continue }
            paragraphs.append(String(text[start..<end]))
            start = boundary.upperBound
            sentenceCount = 0
        }
        paragraphs.append(String(text[start...]))
        return paragraphs.joined(separator: "\n\n")
    }

    private static func startsParagraphTransition(_ text: Substring) -> Bool {
        if text.firstMatch(of: #/
            (?ix: ^(?:however|nevertheless|meanwhile|instead|but|yet)\b[,:\x20\t]
                | ^(?:for[\x20\t]+(?:example|instance)|on[\x20\t]+the[\x20\t]+other[\x20\t]+hand|
                      in[\x20\t]+contrast|as[\x20\t]+a[\x20\t]+result)[,:\x20\t])
            /#) != nil { return true }
        return text.firstMatch(of: #/
            (?ix: ^(?:what|why|how|when|where|who|which)\b[^.!?\r\n]{0,160}\?)
            /#) != nil
    }

    private static func formatSpokenStructure(_ text: String) -> String {
        let separated = formatCorrespondence(text)
            .replacing(
                #/
                ([.!?])[\x20\t]+(?=(\p{Lu}\p{Ll}+),[\x20\t]+[^.!?\r\n]{0,65}?
                    (?i:good[\x20\t]+(?:morning|afternoon|evening)),[\x20\t]+\2[.!?])
                /#
            ) { String($0.1) + "\n\n" }
            .replacing(
                #/
                \?[\x20\t]+(?=(?i:(?:good[\x20\t]+)?(?:morning|afternoon|evening)|hello|hi),?[\x20\t]+\p{Lu}\p{Ll}+[.!])
                /#,
                with: "?\n\n")
        return separated.split(separator: "\n", omittingEmptySubsequences: false)
            .map(separateTopicParagraphs).joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { formatSpokenList($0) ?? wrapLongParagraph($0) }.joined(separator: "\n")
    }

    private static func formatCorrespondence(_ text: String) -> String {
        guard let closing = text.firstMatch(of: #/
            [.!?][\x20\t]+
            ((?i:(?:(?:best|kind|warm)[\x20\t]+)?regards|sincerely|yours[\x20\t]+truly|best[\x20\t]+wishes),)
            [\x20\t]+(\p{Lu}\p{L}*(?:[\x20\t]+\p{Lu}\p{L}*){0,2}\.?)$
            /#)
        else { return text }
        let endOfBody = text.index(after: closing.range.lowerBound)
        let body = text[..<endOfBody].replacing(
            #/
            ^((?i:dear|hello|hi)[\x20\t]+\p{Lu}\p{L}*(?:[\x20\t]+\p{Lu}\p{L}*){0,2},)[\x20\t]+
            /#
        ) { String($0.1) + "\n\n" }
        return body + "\n\n" + closing.1 + "\n" + closing.2
    }

    private static func wrapLongParagraph(_ text: Substring) -> String {
        var result = ""
        var paragraphStart = text.startIndex
        var sentenceStart = text.startIndex
        var paragraphWords = 0
        var remainingWords = text.split(whereSeparator: \.isWhitespace).count
        guard remainingWords >= 125 else { return String(text) }
        for boundary in sentenceBoundaries(in: text) where text[boundary.upperBound].isUppercase {
            let wordCount = text[sentenceStart..<boundary.upperBound].split(whereSeparator: \.isWhitespace).count
            paragraphWords += wordCount
            remainingWords -= wordCount
            sentenceStart = boundary.upperBound
            if paragraphWords >= 90 && remainingWords >= 35 {
                let end = text.index(after: boundary.lowerBound)
                result += text[paragraphStart..<end] + "\n\n"
                paragraphStart = sentenceStart
                paragraphWords = 0
            }
        }
        return result + text[paragraphStart...]
    }

    private static func normalizeSpokenDates(_ text: String) -> String {
        let dayFirst = text
            .replacing(
                #/
                (?ix:
                    \b(?:the[\x20\t]+)?
                    (?<day>(?:twenty|thirty)[-\x20\t]+(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth)|
                        first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|
                        thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth|thirtieth|
                        [0-9]{1,2}(?:st|nd|rd|th)?)
                    [\x20\t]+of[\x20\t]+
                    (?<month>January|February|March|April|May|June|July|August|September|October|November|December)\b
                    (?:,?[\x20\t]+(?<year>[0-9]{4}|(?:nineteen|twenty)[\x20\t]+
                        (?:(?:oh|zero)[\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine)|
                        (?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|
                        twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)
                        (?:[-\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine))?)|
                        two[\x20\t]+thousand(?:[\x20\t]+(?:and[\x20\t]+)?
                        (?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|
                        fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)
                        (?:[-\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine))?)?)(?=[,.!?]|$))?
                )
                /#
            ) { match in
                formattedDate(day: match.day, month: match.month, year: match.year) ?? String(match.output.0)
            }
        return dayFirst.replacing(
                #/
                (?ix:
                    \b(?<month>January|February|March|April|May|June|July|August|September|October|November|December)
                    [\x20\t]+(?:the[\x20\t]+)?
                    (?<day>(?:twenty|thirty)[-\x20\t]+(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth)|
                        first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|
                        thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth|thirtieth|
                        [0-9]{1,2}(?:st|nd|rd|th)?)\b
                    (?:,?[\x20\t]+(?<year>[0-9]{4}|(?:nineteen|twenty)[\x20\t]+
                        (?:(?:oh|zero)[\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine)|
                        (?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|
                        twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)
                        (?:[-\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine))?)|
                        two[\x20\t]+thousand(?:[\x20\t]+(?:and[\x20\t]+)?
                        (?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|
                        fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)
                        (?:[-\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine))?)?)(?=[,.!?]|$))?
                )
                /#
            ) { match in
                guard match.year != nil || match.range.upperBound == dayFirst.endIndex
                    || dayFirst[match.range.upperBound...].firstMatch(
                        of: /^(?:[,.!?;:]|[ \t]+(?i:at|to|through|until)\b)/) != nil
                else { return String(match.output.0) }
                return formattedDate(day: match.day, month: match.month, year: match.year) ?? String(match.output.0)
            }
    }

    private static func formattedDate(day: Substring, month: Substring, year: Substring?) -> String? {
        guard let day = spokenDay(day), day >= 1 else { return nil }
        let month = month.capitalized
        let value = year.flatMap(spokenYear)
        if year != nil, value == nil { return nil }
        let leap = value.map { $0.isMultiple(of: 4) && (!$0.isMultiple(of: 100) || $0.isMultiple(of: 400)) }
        let maxDay = ["April", "June", "September", "November"].contains(month) ? 30
            : (month == "February" ? (leap == false ? 28 : 29) : 31)
        guard day <= maxDay else { return nil }
        return "\(month) \(day)" + (value.map { ", \($0)" } ?? "")
    }

    private static let currencyNames: [String: String] = {
        var names = DictationCurrencyData.englishNames
        let aliases = [
            "cedi": "GHS", "cedis": "GHS", "ghana cedi": "GHS", "ghana cedis": "GHS",
            "ghana cd": "GHS", "ghana cds": "GHS", "ghana c d's": "GHS", "ghana c d’s": "GHS",
            "ghana cities": "GHS", "ghana sades": "GHS", "ghana sadis": "GHS", "ghs": "GHS", "g h s": "GHS",
            "dollar": "USD", "dollars": "USD", "american dollar": "USD", "american dollars": "USD",
            "euro": "EUR", "euros": "EUR", "yen": "JPY",
            "pound sterling": "GBP", "pounds sterling": "GBP", "naira": "NGN",
            "yuan": "CNY", "renminbi": "CNY", "reais": "BRL",
            "uae dirham": "AED", "uae dirhams": "AED"
        ]
        names.merge(aliases) { _, alias in alias }
        return names
    }()

    private static let legacyCurrencySymbols = [
        "dollar": "$", "dollars": "$", "euro": "€", "euros": "€", "yen": "¥",
        "pound sterling": "£", "pounds sterling": "£", "indian rupee": "₹", "indian rupees": "₹"
    ]
    private static let currencyCodeWords: Set<String> = ["ALL", "BAM", "BOB", "CUP", "GEL", "MAD", "PEN", "TOP", "TRY"]

    private static let minorUnits: [String: [String: Int]] = {
        let cents = ["cent": 2, "cents": 2]
        var units = Dictionary(uniqueKeysWithValues: [
            "USD", "EUR", "CAD", "AUD", "NZD", "SGD", "HKD", "ZAR", "BMD", "XCD", "FJD", "JMD"
        ].map { ($0, cents) })
        units["GHS"] = cents.merging([
            "pesewa": 2, "pesewas": 2, "peswa": 2, "peswas": 2,
            "persua": 2, "persuas": 2, "pesuer": 2, "pasewas": 2, "passe was": 2
        ]) { first, _ in first }
        units["GBP"] = ["penny": 2, "pence": 2, "pennies": 2]
        units["INR"] = ["paisa": 2, "paise": 2]
        units["NGN"] = ["kobo": 2]
        units["CHF"] = ["centime": 2, "centimes": 2, "rappen": 2]
        units["BRL"] = ["centavo": 2, "centavos": 2]
        units["MXN"] = units["BRL"]
        units["ARS"] = units["BRL"]
        units["AED"] = ["fils": 2]
        units["BHD"] = ["fils": 3]
        units["KWD"] = ["fils": 3]
        units["JOD"] = ["fils": 3]
        units["OMR"] = ["baisa": 3, "baisas": 3]
        units["TND"] = ["millime": 3, "millimes": 3]
        units["CNY"] = ["jiao": 1, "fen": 2]
        return units
    }()

    private static let currencyScales: [Substring: Int] = [
        "thousand": 3, "lakh": 5, "lakhs": 5, "million": 6, "crore": 7, "crores": 7,
        "billion": 9, "trillion": 12, "quadrillion": 15, "quintillion": 18
    ]

    private static let currencyPattern: NSRegularExpression? = {
        let whitespace = #"[\t ]"#
        func alternatives(_ phrases: some Sequence<String>) -> String {
            phrases.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }.map { phrase in
                NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: " ", with: whitespace + "+")
            }.joined(separator: "|")
        }
        let codes = alternatives(DictationCurrencyData.digits.keys)
        let word = "(?i:" + alternatives(units + tens + ["a", "an", "hundred", "point", "oh"]
            + currencyScales.keys.map { String($0) }) + ")"
        let digits = #"(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?"#
        let number = "(?:\(digits)|\(word))"
        let scaleConjunction = (["hundred"] + currencyScales.keys.map { String($0) }).sorted()
            .map { "(?<=\($0))" }.joined(separator: "|")
        let amount = #"(?:[+−-][\t ]*|(?i:plus|positive|minus|negative)[\t ]+)?"#
            + number + "(?:(?:(?i:\(scaleConjunction))\(whitespace)+(?i:and)\(whitespace)+|[\\t -]+)\(number)){0,30}"
        let aliases = alternatives(currencyNames.keys)
        let marker = "(?:\(codes)|(?i:\(aliases))|GH[₵¢])"
        let prefix = "(?:\(codes)|(?i:GHS|G[\\t ]+H[\\t ]+S|GH[₵¢])|₵)"
        let bound = #"(?![\p{L}\p{N}_]|['’]\p{L})"#
        let unitsPattern = alternatives(Set(minorUnits.values.flatMap(\.keys)))
        func minor(_ valueName: String, _ unitName: String) -> String {
            "(?:\(whitespace)+(?:(?i:and)\(whitespace)+)?(?<\(valueName)>\(amount))"
                + "\(whitespace)+(?<\(unitName)>(?i:\(unitsPattern)))\(bound))?"
        }
        let standalone = alternatives(["pesewa", "pesewas", "peswa", "peswas"])
        let range = "(?:(?<rangeStart>(?i:between|from)\(whitespace)+)(?<first>\(amount))"
            + "(?<rangeJoin>\(whitespace)+(?i:and|to)\(whitespace)+))?"
        let suffixForm = "\(range)(?<value>\(amount))\(whitespace)+(?<unit>\(marker))\(bound)"
            + minor("minor", "subunit")
        let prefixForm = "(?<codeSign>[+−-])?(?<code>\(prefix))(?:\(whitespace)+|(?<=[₵¢]))(?<prefixed>\(amount))\(bound)"
            + #"(?![.,:][0-9])"# + "(?:\(whitespace)+(?<followingUnit>\(marker))\(bound))?"
            + minor("prefixMinor", "prefixSubunit")
        let minorForm = "(?<standaloneValue>\(amount))\(whitespace)+(?<standaloneUnit>(?i:\(standalone)))\(bound)"
        return try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])(?:\(suffixForm)|\(prefixForm)|\(minorForm))"
        )
    }()

    static func currencyCleanup(_ transcript: String, now: () -> ContinuousClock.Instant = { .now }) -> String {
        cleanLines(transcript, now: now) { line in
            preservesLiteral(line) ? String(line) : normalizeSpokenCurrency(String(line))
        } ?? transcript
    }

    private static func normalizeSpokenCurrency(_ text: String) -> String {
        guard let currencyPattern else { return text }
        var output = ""
        var cursor = text.startIndex
        for match in currencyPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            output += text[cursor..<range.lowerBound]
            let prior = text[..<range.lowerBound].suffix(32)
            let replacement = isCurrencyBoundary(prior) ? currencyReplacement(match, in: text, range: range) : nil
            output += replacement ?? String(text[range])
            cursor = range.upperBound
        }
        return output + text[cursor...]
    }

    private static func isCurrencyBoundary(_ prefix: Substring) -> Bool {
        if prefix.firstMatch(of: /(?:[0-9][.,:]|[+−$€£₵¢¥₹-])$/) != nil { return false }
        guard let prior = prefix.split(whereSeparator: \.isWhitespace).last?.lowercased() else { return true }
        return !(prior.wholeMatch(of: /[0-9]+(?:[.,][0-9]+)*/) != nil || units.contains(prior) || tens.contains(prior)
            || currencyScales[prior[...]] != nil
            || ["hundred", "point", "plus", "positive", "minus", "negative"].contains(prior))
    }

    private static func currencyReplacement(_ match: NSTextCheckingResult, in text: String, range: Range<String.Index>)
        -> String? {
        func group(_ name: String) -> Substring? {
            Range(match.range(withName: name), in: text).map { text[$0] }
        }

        if let standalone = group("standaloneValue"), var value = currencyAmount(standalone), value.fraction.isEmpty,
           let cents = UInt64(value.whole.filter { $0 != "," }) {
            value.whole = String(cents / 100)
            value.fraction = leftPadded(value: String(cents % 100), to: 2)
            return value.render(code: "GHS", symbol: nil, digits: 2)
        }

        guard let unit = group("unit") ?? group("code"),
              let code = currencyCode(unit), let digits = DictationCurrencyData.digits[code],
              let rawAmount = group("value") ?? group("prefixed"),
              var value = currencyAmount(rawAmount)
        else { return nil }

        let name = normalizedCurrencyName(unit)
        let ghanaMishearing = ["ghana cities", "ghana sades", "ghana sadis"].contains(name)
        let ambiguousCode = currencyCodeWords.contains(String(unit)) && group("followingUnit") == nil
            && text[range.upperBound...].firstMatch(of: /^[ \t]+\p{L}/) != nil
        if ghanaMishearing || ambiguousCode {
            let context = text[..<range.lowerBound].suffix(80)
            let paymentContext = context.firstMatch(of: #/
                (?ix: \b(?:paid|pay|costs?|spent|spend|charged?|worth|(?:fee|salary|price|budget)[\x20\t]+(?:is|of))
                    [\x20\t]+(?:(?:about|around|roughly|approximately|at[\x20\t]+least|up[\x20\t]+to)[\x20\t]+)?$)
                /#) != nil
            let ghanaContext = ghanaMishearing && context.firstMatch(of: #/
                (?ix: \b(?:invoice[\x20\t]+lists|cost[\x20\t]+(?:is|of))[\x20\t]+
                    (?:(?:about|around|roughly|approximately|at[\x20\t]+least|up[\x20\t]+to)[\x20\t]+)?$)
                /#) != nil
            guard paymentContext || ghanaContext else { return nil }
        }
        if let followingUnit = group("followingUnit"), currencyCode(followingUnit) != code { return nil }

        if let codeSign = group("codeSign") {
            guard value.sign.isEmpty else { return nil }
            value.sign = codeSign == "+" ? "+" : "-"
        }
        if let rawMinor = group("minor") ?? group("prefixMinor"),
           let subunit = group("subunit") ?? group("prefixSubunit") {
            guard value.fraction.isEmpty, let scale = minorUnits[code]?[subunit.lowercased()],
                  let minor = currencyAmount(rawMinor), minor.sign.isEmpty, minor.fraction.isEmpty,
                  minor.whole.count <= scale
            else { return nil }
            value.fraction = leftPadded(value: minor.whole, to: scale)
        }
        if code == "GHS", value.fraction.count > digits {
            guard value.fraction.dropFirst(digits).allSatisfy({ $0 == "0" }) else { return nil }
            value.fraction = String(value.fraction.prefix(digits))
        }
        let symbol = legacyCurrencySymbols[name]
        let rendered = value.render(code: code, symbol: symbol, digits: digits)
        guard let first = group("first"), let lead = group("rangeStart"), let join = group("rangeJoin") else {
            return rendered
        }
        let expectedJoin = lead.lowercased().hasPrefix("between") ? "and" : "to"
        guard join.lowercased().contains(expectedJoin), var start = currencyAmount(first)
        else { return nil }
        if code == "GHS", start.fraction.count > digits {
            guard start.fraction.dropFirst(digits).allSatisfy({ $0 == "0" }) else { return nil }
            start.fraction = String(start.fraction.prefix(digits))
        }
        return lead + start.render(code: code, symbol: symbol, digits: digits) + join + rendered
    }

    private static func normalizedCurrencyName(_ unit: Substring) -> String {
        unit.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func currencyCode(_ unit: Substring) -> String? {
        if DictationCurrencyData.digits[String(unit)] != nil { return String(unit) }
        if ["gh₵", "gh¢", "₵"].contains(unit.lowercased()) { return "GHS" }
        return currencyNames[normalizedCurrencyName(unit)]
    }

    private struct CurrencyAmount {
        var sign: String
        var whole: String
        var fraction: String

        func render(code: String, symbol: String?, digits: Int) -> String {
            let prefix = symbol ?? code + " "
            let grouped = Self.grouped(whole.filter { $0 != "," })
            let fraction = symbol == nil
                ? fraction.padding(toLength: max(digits, fraction.count), withPad: "0", startingAt: 0) : fraction
            return sign + prefix + grouped + (fraction.isEmpty ? "" : "." + fraction)
        }

        private static func grouped(_ whole: String) -> String {
            String(whole.reversed().enumerated().flatMap { index, digit in
                index > 0 && index.isMultiple(of: 3) ? [",", digit] : [digit]
            }.reversed())
        }
    }

    private static func leftPadded(value: String, to count: Int) -> String {
        String(repeating: "0", count: max(0, count - value.count)) + value
    }

    private static func currencyAmount(_ raw: Substring) -> CurrencyAmount? {
        var text = raw.lowercased()[...]
        let sign: String
        if let first = text.first, "+-−".contains(first) {
            sign = first == "+" ? "+" : "-"
            text = text.dropFirst().drop(while: \.isWhitespace)
        } else if let first = text.split(whereSeparator: \.isWhitespace).first,
                  ["minus", "negative", "plus", "positive"].contains(first) {
            sign = first == "minus" || first == "negative" ? "-" : "+"
            text = text.dropFirst(first.count).drop(while: \.isWhitespace)
        } else {
            sign = ""
        }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        var integral: UInt64 = 0
        var largestAllowedScale = 19
        var start = words.startIndex
        for index in words.indices {
            guard let power = currencyScales[words[index]] else { continue }
            guard power < largestAllowedScale else { return nil }
            let segment = removingScaleConjunction(words[start..<index], afterScale: start > 0)
            guard let value = currencyCoefficient(segment), let group = scaledCurrencyInteger(value, by: power)
            else { return nil }
            let sum = integral.addingReportingOverflow(group)
            guard !sum.overflow else { return nil }
            integral = sum.partialValue
            largestAllowedScale = power
            start = index + 1
        }
        if start == words.endIndex, start > 0 {
            return CurrencyAmount(sign: sign, whole: String(integral), fraction: "")
        }
        let segment = removingScaleConjunction(words[start...], afterScale: start > 0)
        guard let value = currencyCoefficient(segment), let tail = UInt64(value.whole.filter { $0 != "," })
        else { return nil }
        if start == 0 { return CurrencyAmount(sign: sign, whole: value.whole, fraction: value.fraction) }
        guard value.whole.filter(\.isNumber).count <= largestAllowedScale else { return nil }
        let total = integral.addingReportingOverflow(tail)
        guard !total.overflow else { return nil }
        return CurrencyAmount(sign: sign, whole: String(total.partialValue), fraction: value.fraction)
    }

    private static func removingScaleConjunction(_ words: ArraySlice<Substring>, afterScale: Bool)
        -> ArraySlice<Substring> {
        afterScale && words.first == "and" ? words.dropFirst() : words
    }

    private static func currencyCoefficient(_ words: ArraySlice<Substring>) -> (whole: String, fraction: String)? {
        if words.count == 1, let numeric = words.first,
           numeric.wholeMatch(of: /(?:[0-9]{1,20}|[0-9]{1,3}(?:,[0-9]{3}){1,6})(?:\.[0-9]{1,12})?/) != nil {
            let parts = numeric.split(separator: ".")
            return (String(parts[0]), parts.count == 2 ? String(parts[1]) : "")
        }

        let parts = words.split(separator: "point", omittingEmptySubsequences: false)
        guard let first = parts.first, parts.count <= 2 else { return nil }
        let phrase = first.joined(separator: " ")
        let whole: String
        if ["a", "an"].contains(phrase) { whole = "1" } else if first.isEmpty, parts.count == 2 {
            whole = "0"
        } else if let number = spokenNumber(phrase[...]) {
            whole = String(number)
        } else {
            return nil
        }
        guard parts.count == 2 else { return (whole, "") }
        let digits = parts[1].compactMap { word -> String? in
            if word.wholeMatch(of: /[0-9]{1,12}/) != nil { return String(word) }
            if word == "oh" { return "0" }
            guard let digit = spokenNumber(word), digit < 10 else { return nil }
            return String(digit)
        }
        let fraction = digits.joined()
        guard digits.count == parts[1].count, (1...12).contains(fraction.count) else { return nil }
        return (whole, fraction)
    }

    private static func scaledCurrencyInteger(_ value: (whole: String, fraction: String), by scale: Int) -> UInt64? {
        let whole = value.whole.filter { $0 != "," }
        let fraction = value.fraction.prefix(scale)
        guard value.fraction.dropFirst(scale).allSatisfy({ $0 == "0" }) else { return nil }
        return UInt64(whole + fraction + String(repeating: "0", count: scale - fraction.count))
    }

    private static func normalizeSpokenTimes(_ text: String) -> String {
        let anchored = text
            .replacing(
                #/
                (?i: \b(?<lead>(?:at|by|around|before|after|from|until|to)[\x20\t]+)
                    (?<hour>[0-9]{2})[\x20\t]*(?<minute>[0-9]{2})[\x20\t]+hours\b )
                /#
            ) { match in
                guard let hour = Int(match.hour), hour < 24, let minute = Int(match.minute), minute < 60
                else { return String(match.output.0) }
                return String(match.lead) + match.hour + ":" + match.minute
            }
            .replacing(/(?i:\b(?<lead>(?:at|by|around|before|after|from|until|to)[ \t]+)(?<time>noon|midnight)\b)/) {
                String($0.lead) + ($0.time.lowercased() == "noon" ? "12:00 PM" : "12:00 AM")
            }
        let explicit = anchored.replacing(
                #/
                (?ix:
                    (?<lead>\b(?:at|by|around|before|after|from|until)[\x20\t]+|^)
                    (?:a[\x20\t]+)?(?<offset>quarter|half|[0-9]{1,2}|
                        (?:twenty|thirty|forty|fifty)(?:[-\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine))?|
                        one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|
                        fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)
                    [\x20\t]+(?:minutes?[\x20\t]+)?(?<direction>past|to)[\x20\t]+
                    (?<hour>one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[0-9]{1,2})\b
                    (?:[\x20\t]+(?<period>[ap]\.m(?:\.(?=[,!?]|[\x20\t]+\p{Ll}))?|[ap][\x20\t]*m|
                        in[\x20\t]+the[\x20\t]+(?:morning|afternoon|evening)))?
                    (?![\p{L}\p{N}])
                )
                /#
            ) { match in
                guard let hour = spokenNumber(match.hour), (1...12).contains(hour)
                else { return String(match.output.0) }
                let offset: Int?
                switch match.offset.lowercased() {
                case "quarter": offset = 15
                case "half": offset = 30
                default: offset = spokenNumber(match.offset)
                }
                guard let offset, (1...59).contains(offset) else { return String(match.output.0) }
                let period = afternoon(match.period)
                if period == nil, !isClockBoundary(anchored[match.range.upperBound...]) {
                    return String(match.output.0)
                }
                let delta = match.direction.lowercased() == "to" ? -offset : offset
                let total = ((hour % 12 + (period == true ? 12 : 0)) * 60 + delta + 1_440) % 1_440
                let hours = total / 60 % 12
                return String(match.lead) + clockText(hours == 0 ? 12 : hours, total % 60, pm: period.map { _ in total >= 720 })
            }
        return explicit.replacing(
                #/
                (?ix:
                    (?<lead>\b(?:at|by|around|before|after|from|until|to)[\x20\t]+|^)
                    (?<hour>one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|
                        thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty(?:[-\x20\t]+(?:one|two|three))?|
                        [0-9]{1,2})(?=\b|[ap]m\b)
                    (?:
                        (?:[\x20\t]+|:)(?<minute>[0-9]{1,2}|
                        (?:oh|zero)[\x20\t]+(?:[1-9]|one|two|three|four|five|six|seven|eight|nine)|
                        (?:twenty|thirty|forty|fifty)(?:[-\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine))?|
                        zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|
                        fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)(?=\b|[ap]m\b)
                        |[\x20\t]+(?<oclock>o(?:['’]|[\x20\t]+)?clock)\b
                    )?
                    (?:[\x20\t]*(?<period>[ap]\.m(?:\.(?=[,!?]|[\x20\t]+\p{Ll}))?|[ap][\x20\t]*m|
                        in[\x20\t]+the[\x20\t]+(?:morning|afternoon|evening)))?
                    (?![\p{L}\p{N}])
                )
                /#
            ) { match in
                guard let hour = spokenNumber(match.hour), hour < 24 else { return String(match.output.0) }
                let period = afternoon(match.period)
                if period != nil, !(1...12).contains(hour) { return String(match.output.0) }
                guard period != nil || match.oclock != nil || match.minute != nil else { return String(match.output.0) }
                if period == nil, match.oclock == nil {
                    guard !match.lead.isEmpty, !match.output.0.contains(":"),
                          isClockBoundary(explicit[match.range.upperBound...])
                    else { return String(match.output.0) }
                }
                var minute = 0
                if let spoken = match.minute {
                    let words = spoken.split(whereSeparator: \.isWhitespace)
                    let value = words.count == 2 && ["oh", "zero"].contains(words[0].lowercased())
                        ? spokenNumber(words[1]) : spokenNumber(spoken)
                    guard let value, value < 60 else { return String(match.output.0) }
                    minute = value
                }
                return String(match.lead) + clockText(hour, minute, pm: period)
            }
    }

    private static func isClockBoundary(_ text: Substring) -> Bool {
        text.firstMatch(of: /^(?:$|[,.;!?]|[ \t]+(?i:today|tomorrow|tonight|on|to|until)\b)/) != nil
    }

    private static func afternoon(_ period: Substring?) -> Bool? {
        period.map {
            let value = $0.lowercased()
            return value.hasPrefix("p") || value.hasSuffix("afternoon") || value.hasSuffix("evening")
        }
    }

    private static func clockText(_ hour: Int, _ minute: Int, pm: Bool?) -> String {
        "\(hour):" + (minute < 10 ? "0\(minute)" : String(minute)) + (pm.map { $0 ? " PM" : " AM" } ?? "")
    }

    private static let units = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"
    ]
    private static let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let ordinalWords = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth",
        "nineteenth", "twentieth", "thirtieth"
    ]

    private static func spokenNumber(_ text: Substring) -> Int? {
        if let value = Int(text), (0...999).contains(value) { return value }
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        guard !words.isEmpty else { return nil }
        if words.count >= 2, words[1] == "hundred",
           let first = units.firstIndex(of: String(words[0])), (1...9).contains(first) {
            var rest = words.dropFirst(2)
            if rest.isEmpty { return first * 100 }
            if rest.first == "and" { rest = rest.dropFirst() }
            return underHundred(rest).map { first * 100 + $0 }
        }
        return underHundred(words[...])
    }

    private static func underHundred(_ words: ArraySlice<Substring>) -> Int? {
        guard let first = words.first else { return nil }
        if words.count == 1, let value = units.firstIndex(of: String(first)) { return value }
        guard let tensIndex = tens.firstIndex(of: String(first)) else { return nil }
        if words.count == 1 { return (tensIndex + 2) * 10 }
        guard words.count == 2, let last = words.last, let unitsIndex = units.firstIndex(of: String(last)),
              (1...9).contains(unitsIndex)
        else { return nil }
        return (tensIndex + 2) * 10 + unitsIndex
    }

    private static func spokenDay(_ text: Substring) -> Int? {
        if text.first?.isNumber == true { return Int(text.prefix(while: \.isNumber)) }
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        guard let last = words.last, let ordinal = ordinalWords.firstIndex(of: String(last)) else { return nil }
        if words.count == 1 { return ordinal == 20 ? 30 : ordinal + 1 }
        return words.first == "twenty" ? 21 + ordinal : 31 + ordinal
    }

    private static func spokenYear(_ text: Substring) -> Int? {
        if let value = Int(text) { return value > 0 ? value : nil }
        let parts = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        if parts.count >= 2, parts[0] == "two", parts[1] == "thousand" {
            var rest = parts.dropFirst(2)
            if rest.first == "and" { rest = rest.dropFirst() }
            if rest.isEmpty { return 2_000 }
            return underHundred(rest).map { 2_000 + $0 }
        }
        let words = text.lowercased().split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard words.count == 2 else { return nil }
        let tailWords = words[1].split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let rest = ["oh", "zero"].contains(tailWords.first ?? "") ? tailWords.dropFirst() : tailWords[...]
        guard let tail = underHundred(rest) else { return nil }
        return (words[0] == "twenty" ? 2_000 : 1_900) + tail
    }

    static func format(_ transcription: String, context: Context?, adaptCapitalization: Bool = true) -> String
    {
        var text = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context else { return text }
        if adaptCapitalization, let first = text.first, first.isLetter {
            let replacement: String
            if context.lastNonWhitespace == nil || context.newParagraph
                || context.lastNonWhitespace.map({ ".!?".contains($0) }) == true
            {
                replacement = String(first).uppercased()
            } else {
                replacement = String(first).lowercased()
            }
            text.replaceSubrange(text.startIndex...text.startIndex, with: replacement)
        }
        if let trailing = context.trailing, !trailing.isWhitespace,
            !"([{/\"'‘’“—-".contains(trailing),
            let leading = text.first, !".,!?;:)]}/\"'”".contains(leading)
        {
            text = " " + text
        }
        if let leading = context.following, !leading.isWhitespace,
            let trailing = text.last, !trailing.isWhitespace,
            !".,!?;:)]}/\"'”".contains(leading)
        {
            text += " "
        }
        return text
    }
}
