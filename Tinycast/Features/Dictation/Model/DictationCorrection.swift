import Foundation

struct DictationCorrection: Codable, Identifiable, Sendable {
    private static let punctuation = ".,!?…;:()[]{}\"“”«»"
    private static let maximumTextLength = 8_192
    private static let maximumAnchorLength = 40
    private static let anchorLookahead = 8
    private static let maximumChanges = 16
    private static let sensitiveWords = Set("""
        no not never neither nor none nothing nobody without cannot cant wont dont only
        zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen
        sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety
        hundred thousand million billion trillion half quarter first second third fourth fifth sixth
        seventh eighth ninth tenth monday tuesday wednesday thursday friday saturday sunday
        january february march april may june july august september october november december
        today tomorrow yesterday noon midnight am pm dollars dollar euros euro pounds pound cents cent
        """.split(whereSeparator: \.isWhitespace))

    private struct Token {
        let raw: Substring
        let word: Substring

        var leading: Substring { raw[..<word.startIndex] }
        var trailing: Substring { raw[word.endIndex...] }
    }

    private struct Change {
        let before: Range<Int>
        let after: Range<Int>
    }

    private enum Confidence {
        case clear
        case candidate
    }

    struct Detection {
        var corrections: [DictationCorrection] = []
        var candidates: [DictationCorrection] = []
        var isReliable = true
    }

    struct Context: Codable, Equatable, Sendable {
        let before: String?
        let after: String?
    }

    let original: String
    let spelling: String
    let context: Context?
    private let addedManually: Bool?

    var id: String { Self.key(for: original) }
    var isManual: Bool { addedManually == true }

    init(original: String, spelling: String, isManual: Bool = false, context: Context? = nil) {
        self.original = original
        self.spelling = spelling
        self.context = context
        addedManually = isManual ? true : nil
    }

    static func manual(spelling: String, misspelling: String) -> Self? {
        let spelling = phrase(spelling)
        guard !spelling.isEmpty else { return nil }
        let misspelling = phrase(misspelling)
        return Self(original: misspelling.isEmpty ? spelling : misspelling, spelling: spelling, isManual: true)
    }

    static func detect(from inserted: String, to edited: String, recognized: String) -> Detection {
        guard inserted.utf16.count <= maximumTextLength,
            edited.utf16.count <= maximumTextLength,
            recognized.utf16.count <= maximumTextLength
        else { return Detection(isReliable: false) }
        guard inserted != edited else { return Detection() }

        let before = tokens(in: inserted)
        let after = tokens(in: edited)
        let sameSource = inserted == recognized
        let source = sameSource ? before : tokens(in: recognized)
        guard let edits = changes(from: before, to: after),
            let attribution = sameSource ? [] : changes(from: source, to: before)
        else { return Detection(isReliable: false) }

        var detection = Detection()
        var matches: [(correction: Self, confidence: Confidence)] = []
        for edit in edits {
            let parts = wordPairs(in: edit).filter { part in
                part.before.count != part.after.count
                    || !zip(before[part.before], after[part.after]).allSatisfy { key($0.word) == key($1.word) }
            }
            let found = parts.compactMap {
                match($0, before: before, after: after, source: source, attribution: attribution)
            }
            if found.count == parts.count {
                matches.append(contentsOf: found)
            } else {
                detection.isReliable = false
            }
            guard matches.count <= maximumChanges else { return Detection(isReliable: false) }
        }

        guard !matches.isEmpty else { return detection }
        let sourceKeys = source.map { key($0.word) }
        let changedKeys = Set(matches.map { $0.correction.id })
        var seen = Set<String>()
        for (correction, _) in matches where seen.insert(correction.id).inserted {
            let sameOriginal = matches.filter { $0.correction.id == correction.id }
            let consistent = sameOriginal.allSatisfy {
                $0.correction.spelling == correction.spelling && $0.correction.context == correction.context
            }
            let spellingKey = key(for: correction.spelling)
            guard spellingKey == correction.id || !changedKeys.contains(spellingKey),
                consistent,
                sameOriginal.count == occurrences(of: correction.id, in: sourceKeys)
            else {
                detection.isReliable = false
                continue
            }
            if sameOriginal.allSatisfy({ $0.confidence == .clear }) {
                detection.corrections.append(correction)
            } else {
                detection.candidates.append(correction)
            }
        }
        return detection
    }

    static func applying(_ entries: [Self], to text: String) -> String {
        guard !entries.isEmpty else { return text }
        return autoreleasepool { replace(in: text, using: entries) }
    }

    private static func replace(in text: String, using entries: [Self]) -> String {
        let replacements = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let punctuation = Self.punctuation.unicodeScalars.map { "\\x{\(String($0.value, radix: 16))}" }.joined()
        let marks = "[\(punctuation)]"
        let phrases = replacements.keys.sorted { $0.count > $1.count }.compactMap { key in
            pattern(for: key, context: replacements[key]?.context, marks: marks)
        }.joined(separator: "|")
        guard !phrases.isEmpty else { return text }
        let pattern = "(?<!\\S)\(marks)*?(\(phrases))(?=\(marks)*(?:\\s|$))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        var corrected = ""
        var remaining = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let range = Range(match.range(at: 1), in: text),
                let replacement = replacements[key(for: String(text[range]))]
            else { continue }
            corrected += text[remaining..<range.lowerBound]
            corrected += replacement.spelling
            remaining = range.upperBound
        }
        corrected += text[remaining...]
        return corrected
    }

    private static func pattern(for key: String, context: Context?, marks: String) -> String? {
        let phrase = key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\h+")
        guard let context else { return phrase }
        let anchors = [context.before, context.after].compactMap { $0 }
        guard !anchors.isEmpty, anchors.allSatisfy(isAnchor) else { return nil }
        let before: String
        if let anchor = context.before {
            let word = NSRegularExpression.escapedPattern(for: anchor)
            before = "(?<=(?<!\\S)\(marks){0,8}\(word)\(marks){0,8}\\h{1,8}\(marks){0,8})"
        } else {
            before = "(?<=\\A\\s{0,8}\(marks){0,8})"
        }
        let after: String
        if let anchor = context.after {
            let word = NSRegularExpression.escapedPattern(for: anchor)
            after = "(?=\(marks)*\\h+\(marks)*\(word)\(marks)*(?:\\s|$))"
        } else {
            after = "(?=\(marks)*\\s*\\z)"
        }
        return before + phrase + after
    }

    static func key(for text: String) -> String {
        phrase(text).folding(options: .caseInsensitive, locale: nil)
    }

    private static func key(_ word: Substring) -> String {
        word.folding(options: .caseInsensitive, locale: nil)
    }

    private static func phrase(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func tokens(in text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).map { token in
            guard let start = token.firstIndex(where: { !punctuation.contains($0) }),
                let end = token.lastIndex(where: { !punctuation.contains($0) })
            else { return Token(raw: token, word: token) }
            return Token(raw: token, word: token[start...end])
        }
    }

    private static func changes(from before: [Token], to after: [Token]) -> [Change]? {
        var changes: [Change] = []
        var left = 0
        var right = 0
        var leftEnd = before.count
        var rightEnd = after.count
        while left < leftEnd, right < rightEnd, before[leftEnd - 1].raw == after[rightEnd - 1].raw {
            leftEnd -= 1
            rightEnd -= 1
        }
        while left < leftEnd || right < rightEnd {
            if left < leftEnd, right < rightEnd, before[left].raw == after[right].raw {
                left += 1
                right += 1
                continue
            }
            let anchor = nextAnchor(before: before[left..<leftEnd], after: after[right..<rightEnd])
            guard !anchor.isAmbiguous else { return nil }
            let nextLeft = anchor.before ?? leftEnd
            let nextRight = anchor.after ?? rightEnd
            changes.append(Change(before: left..<nextLeft, after: right..<nextRight))
            guard changes.count <= maximumChanges else { return nil }
            left = nextLeft
            right = nextRight
        }
        return changes
    }

    private static func nextAnchor(before: ArraySlice<Token>, after: ArraySlice<Token>) -> (
        before: Int?, after: Int?, isAmbiguous: Bool
    ) {
        let left = before.prefix(anchorLookahead + 1)
        let right = after.prefix(anchorLookahead + 1)
        var best: (before: Int, after: Int)?
        var distance = Int.max
        var ambiguous = false
        for leftIndex in left.indices {
            for rightIndex in right.indices where left[leftIndex].raw == right[rightIndex].raw {
                let current = leftIndex - left.startIndex + rightIndex - right.startIndex
                if current < distance {
                    distance = current
                    best = (leftIndex, rightIndex)
                    ambiguous = false
                } else if current == distance {
                    ambiguous = true
                }
            }
        }
        return (best?.before, best?.after, ambiguous)
    }

    private static func wordPairs(in change: Change) -> [Change] {
        guard change.before.count == change.after.count, change.before.count <= anchorLookahead else { return [change] }
        return zip(change.before, change.after).map { before, after in
            Change(before: before..<(before + 1), after: after..<(after + 1))
        }
    }

    private static func sourceRange(for range: Range<Int>, attribution: [Change]) -> Range<Int>? {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound
        for change in attribution {
            for part in wordPairs(in: change) {
                let shift = part.before.upperBound - part.after.upperBound
                if part.after.upperBound <= range.lowerBound {
                    lowerBound = range.lowerBound + shift
                    upperBound = range.upperBound + shift
                } else if part.after.lowerBound < range.upperBound {
                    guard range.lowerBound <= part.after.lowerBound, part.after.upperBound <= range.upperBound
                    else { return nil }
                    upperBound = range.upperBound + shift
                }
            }
        }
        guard lowerBound <= upperBound else { return nil }
        return lowerBound..<upperBound
    }

    private static func match(
        _ change: Change, before: [Token], after: [Token], source: [Token], attribution: [Change]
    ) -> (correction: Self, confidence: Confidence)? {
        let old = before[change.before]
        let new = after[change.after]
        guard let wrong = editablePhrase(old), let right = editablePhrase(new),
            old.count == new.count || (old.first?.leading == new.first?.leading && old.last?.trailing == new.last?.trailing),
            let sourceRange = sourceRange(for: change.before, attribution: attribution),
            sourceRange.lowerBound >= source.startIndex, sourceRange.upperBound <= source.endIndex,
            let original = editablePhrase(source[sourceRange])
        else { return nil }
        let wrongKey = key(for: String(wrong))
        let rightKey = key(for: String(right))
        guard wrongKey != rightKey else { return nil }
        let originalPhrase = phrase(String(original))
        let spelling = phrase(String(right))
        if key(for: originalPhrase) == rightKey {
            return (Self(original: originalPhrase, spelling: spelling), .clear)
        }
        guard let confidence = confidence(
            from: wrongKey, to: rightKey, named: hasNameCasing(old, new))
        else { return nil }
        if confidence == .clear { return (Self(original: originalPhrase, spelling: spelling), .clear) }
        guard let context = context(
            for: change, before: before, after: after, source: source, sourceRange: sourceRange)
        else { return nil }
        return (Self(original: originalPhrase, spelling: spelling, context: context), .candidate)
    }

    private static func context(
        for change: Change, before: [Token], after: [Token], source: [Token], sourceRange: Range<Int>
    ) -> Context? {
        let prior = anchor(in: before, at: change.before.lowerBound - 1)
        let next = anchor(in: before, at: change.before.upperBound)
        let originalPrior = anchor(in: source, at: sourceRange.lowerBound - 1)
        let originalNext = anchor(in: source, at: sourceRange.upperBound)
        guard prior == anchor(in: after, at: change.after.lowerBound - 1),
            next == anchor(in: after, at: change.after.upperBound),
            prior != nil || (change.before.lowerBound == before.startIndex && change.after.lowerBound == after.startIndex),
            next != nil || (change.before.upperBound == before.endIndex && change.after.upperBound == after.endIndex),
            originalPrior != nil || sourceRange.lowerBound == source.startIndex,
            originalNext != nil || sourceRange.upperBound == source.endIndex,
            originalPrior != nil || originalNext != nil
        else { return nil }
        return Context(before: originalPrior, after: originalNext)
    }

    private static func anchor(in tokens: [Token], at index: Int) -> String? {
        guard tokens.indices.contains(index) else { return nil }
        let word = tokens[index].word
        guard isAnchor(word) else { return nil }
        return key(word)
    }

    private static func isAnchor(_ word: some StringProtocol) -> Bool {
        !word.isEmpty && word.utf16.count <= maximumAnchorLength && word.allSatisfy(\.isLetter)
    }

    private static func editablePhrase(_ tokens: ArraySlice<Token>) -> Substring? {
        guard (1...3).contains(tokens.count), let first = tokens.first, let last = tokens.last,
            tokens.allSatisfy({ $0.word.allSatisfy(\.isLetter) })
        else { return nil }
        let text = first.raw.base[first.word.startIndex..<last.word.endIndex]
        guard (3...40).contains(text.count),
            text.allSatisfy({ $0.isLetter || ($0.isWhitespace && !$0.isNewline) })
        else { return nil }
        return text
    }

    private static func hasNameCasing(_ before: ArraySlice<Token>, _ after: ArraySlice<Token>) -> Bool {
        if before.first?.word.first?.isUppercase == true, after.first?.word.first?.isUppercase == true {
            return true
        }
        return [before, after].contains { tokens in
            tokens.indices.contains { index in
                let word = tokens[index].word
                return word.dropFirst().contains(where: \.isUppercase)
                    || (index > 0 && word.first?.isUppercase == true)
            }
        }
    }

    private static func confidence(from wrong: String, to right: String, named: Bool) -> Confidence? {
        let old = wrong.split(separator: " ")
        let new = right.split(separator: " ")
        guard !old.contains(where: sensitiveWords.contains), !new.contains(where: sensitiveWords.contains) else {
            return nil
        }
        let oldLetters = old.joined()
        let newLetters = new.joined()
        if oldLetters == newLetters { return named ? .clear : .candidate }
        let shorterLength = min(oldLetters.count, newLetters.count)
        let edits = newLetters.difference(from: oldLetters)
        let changed = max(edits.insertions.count, edits.removals.count)
        let samePrefix = zip(oldLetters, newLetters).prefix { $0 == $1 }.count
        let sameSuffix = zip(oldLetters.reversed(), newLetters.reversed()).prefix { $0 == $1 }.count
        let onlyInsertionsOrDeletions = edits.insertions.isEmpty || edits.removals.isEmpty
        if named, changed == 1
            || (changed == 2 && shorterLength >= 5 && (onlyInsertionsOrDeletions || samePrefix + sameSuffix >= 3)) {
            return .clear
        }
        if named, shorterLength >= 5, changed <= 3, max(samePrefix, sameSuffix) >= 3 { return .candidate }
        if shorterLength >= 5, changed == 1, samePrefix + sameSuffix >= shorterLength - 1 { return .candidate }
        return nil
    }

    private static func occurrences(of key: String, in tokens: [String]) -> Int {
        let words = key.split(separator: " ")
        return tokens.indices.count { start in
            let end = start + words.count
            guard end <= tokens.count else { return false }
            return zip(tokens[start..<end], words).allSatisfy { $0 == $1 }
        }
    }
}
