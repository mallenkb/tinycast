import Foundation

enum DictationEditCheck {
    enum Verdict: Equatable, Sendable {
        case accepted, changedNumber, changedNegation, changedName, changedWords
    }

    /// `reference` is the source after Basic cleanup, so formatted values such as "$45.99" match.
    static func verdict(source: String, edited: String, reference: String? = nil) -> Verdict {
        let sourceTokens = DictationWords.tokens(source)
        let editedTokens = DictationWords.tokens(edited)
        guard !editedTokens.isEmpty || sourceTokens.allSatisfy({ removable.contains($0.key) }) else {
            return .changedWords
        }
        let referenceTokens = reference.map(DictationWords.tokens) ?? sourceTokens
        let correctable = correctableIndices(sourceTokens)
        if !keepsNumbers(sourceTokens, referenceTokens, editedTokens, correctable: correctable) {
            return .changedNumber
        }

        let source = sourceTokens.filter { !$0.isNumber && !numberish.contains($0.key) }
        let words = editedTokens.filter { !$0.isNumber && !numberish.contains($0.key) }
        let pairs = DictationWords.alignment(source, words)
        let keptSource = Set(pairs.map(\.source))
        let keptEdited = Set(pairs.map(\.edited))
        let wordCorrectable = correctableIndices(source)

        var contentEdits = 0
        var lightEdits = 0
        for (index, token) in source.enumerated() where !keptSource.contains(index) {
            let stutter = (index > 0 && source[index - 1].key == token.key)
                || (index + 1 < source.count && source[index + 1].key == token.key)
            if stutter || wordCorrectable.contains(index) || removable.contains(token.key) { continue }
            if negations.contains(token.key) { return .changedNegation }
            if token.capitalized, !token.startsSentence, token.key != "i" { return .changedName }
            if light.contains(token.key) { lightEdits += 1 } else { contentEdits += 1 }
        }
        let introduced = Set(source.map(\.key))
        for (index, token) in words.enumerated() where !keptEdited.contains(index) {
            if removable.contains(token.key) || token.key == "i" { continue }
            if negations.contains(token.key) { return .changedNegation }
            if token.capitalized, !token.startsSentence, !introduced.contains(token.key) { return .changedName }
            if light.contains(token.key) { lightEdits += 1 } else { contentEdits += 1 }
        }

        let contentCount = source.count { !light.contains($0.key) && !removable.contains($0.key) }
        if contentEdits > max(3, contentCount * 12 / 100) { return .changedWords }
        if lightEdits > max(4, source.count / 4) { return .changedWords }
        return .accepted
    }

    private static func keepsNumbers(
        _ spokenSource: [DictationWords.Token], _ spokenReference: [DictationWords.Token],
        _ edited: [DictationWords.Token], correctable: Set<Int>
    ) -> Bool {
        let (source, runs) = mergingDigitRuns(spokenSource)
        let reference = mergingDigitRuns(spokenReference).tokens
        let editedDigits = edited.filter(\.isNumber).map { $0.key.filter(\.isNumber) }.joined()
        guard runs.allSatisfy(editedDigits.contains) else { return false }
        var allowed: Set<Double> = []
        for run in runs {
            let digits = Array(run)
            for start in digits.indices {
                for end in start..<min(digits.count, start + 15) {
                    if let value = Double(String(digits[start...end])) { allowed.insert(value) }
                }
            }
        }
        var pairs: Set<Double> = []
        for tokens in [source, reference] {
            for (index, token) in tokens.enumerated() {
                if let ordinal = DictationWords.ordinalWords[token.key] { allowed.insert(Double(ordinal)) }
                guard token.isNumber else { continue }
                allowed.formUnion(components(token.key))
                guard let value = token.number else { continue }
                allowed.insert(value)
                if index + 1 < tokens.count, value >= 20, value < 100, value.truncatingRemainder(dividingBy: 10) == 0,
                   let ordinal = DictationWords.ordinalWords[tokens[index + 1].key], ordinal < 10 {
                    allowed.insert(value + Double(ordinal))
                }
                if index + 1 < tokens.count, let first = Int(token.key.dropFirst()), (10...99).contains(first),
                   let second = Int(tokens[index + 1].key.dropFirst()), (0...99).contains(second),
                   tokens[index + 1].number != nil {
                    pairs.insert(Double(first * 100 + second))
                }
            }
        }
        allowed.formUnion(pairs)
        var mentions = 0
        for token in edited where token.isNumber {
            guard components(token.key).isSubset(of: allowed) || allowed.contains(token.number ?? .nan)
            else { return false }
            let groups = token.key.dropFirst().split(whereSeparator: { !$0.isNumber }).count
            mentions += groups + (groups == 1 && pairs.contains(token.number ?? .nan) ? 1 : 0)
        }
        let dropped = spokenSource.indices.count { spokenSource[$0].isNumber && correctable.contains($0) }
        let required = min(
            source.count(where: \.isNumber), reference.count(where: \.isNumber)) - dropped
        return mentions >= required
    }

    /// Digits read one at a time, as in a phone number, become one token holding the digit string.
    private static func mergingDigitRuns(
        _ tokens: [DictationWords.Token]
    ) -> (tokens: [DictationWords.Token], runs: [String]) {
        func written(_ index: Int) -> String? {
            let key = tokens[index].key
            guard key.count == 2, key.first == "#", let last = key.last, last.isNumber else { return nil }
            return String(last)
        }
        func digit(_ index: Int) -> String? {
            if let value = written(index) { return value }
            let between = index > 0 && index + 1 < tokens.count && written(index - 1) != nil
                && written(index + 1) != nil
            return tokens[index].key == "oh" && between ? "0" : nil
        }
        var merged: [DictationWords.Token] = []
        var runs: [String] = []
        var index = 0
        while index < tokens.count {
            var end = index
            var run = ""
            while end < tokens.count, let value = digit(end) {
                run += value
                end += 1
            }
            guard run.count >= 3 else {
                merged.append(tokens[index])
                index += 1
                continue
            }
            merged.append(DictationWords.Token(
                key: "#" + run, word: tokens[index].word, capitalized: false,
                startsSentence: tokens[index].startsSentence))
            runs.append(run)
            index = end
        }
        return (merged, runs)
    }

    private static func components(_ key: String) -> Set<Double> {
        Set(key.dropFirst().split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) })
    }

    /// Words before a spoken correction cue, which the engine may drop with the cue.
    private static func correctableIndices(_ tokens: [DictationWords.Token]) -> Set<Int> {
        var indices: Set<Int> = []
        for (index, token) in tokens.enumerated() {
            let next = index + 1 < tokens.count ? tokens[index + 1].key : ""
            let cue = ["sorry", "scratch", "correction", "rather"].contains(token.key)
                || (token.key == "no" && index > 0 && !tokens[index - 1].isNumber && next != "")
                || (token.key == "i" && next == "mean")
                || (token.key == "make" && next == "that")
                || (token.key == "actually" && index > 0)
            guard cue else { continue }
            for offset in max(0, index - 4)..<min(tokens.count, index + 2) { indices.insert(offset) }
        }
        return indices
    }

    private static let negations: Set<String> = [
        "not", "never", "nothing", "none", "nobody", "nowhere", "neither", "nor", "without", "cannot"
    ]

    /// Words cleanup exists to remove: fillers, discourse markers, spoken commands and list cues.
    private static let removable: Set<String> = [
        "um", "uh", "umm", "uhm", "erm", "er", "ah", "hmm", "mm", "mhm", "okay", "ok", "so", "well", "right",
        "yeah", "like", "basically", "actually", "really", "just", "you", "know", "mean", "kind", "sort",
        "new", "line", "paragraph", "comma", "period", "full", "stop", "question", "mark", "exclamation",
        "colon", "semicolon", "dash", "hyphen", "bullet", "insert", "quote", "unquote", "open", "close",
        "bracket", "parenthesis", "next", "item", "slash", "dot", "firstly", "secondly", "thirdly",
        "finally", "lastly", "then", "step", "also", "and", "or", "point", "at", "number"
    ]

    /// Unit and number words that formatting turns into digits or symbols.
    private static let numberish: Set<String> = [
        "dollar", "dollars", "cent", "cents", "euro", "euros", "pound", "pounds", "percent", "per", "degree",
        "degrees", "celsius", "fahrenheit", "am", "pm", "a.m", "p.m", "o'clock", "oh", "hundred", "thousand",
        "million", "billion", "half", "halves", "quarter", "quarters", "thirds", "fourths", "fifths",
        "minus", "plus", "hours", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        "ninth", "tenth", "twentieth", "thirtieth", "eleventh", "twelfth", "thirteenth", "fourteenth",
        "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "w", "www", "com", "org", "net",
        "megabytes", "gigabytes", "kilobytes", "litres", "liters", "kilometres", "kilometers", "metres",
        "meters", "centimetres", "centimeters", "kilograms", "grams", "noon", "midnight"
    ]

    /// Words an engine may add or drop while fixing grammar.
    private static let light: Set<String> = [
        "a", "an", "the", "of", "to", "for", "in", "on", "with", "that", "this", "these", "those", "it", "is",
        "are", "was", "were", "be", "been", "i", "we", "he", "she", "they", "me", "us", "my", "our", "your",
        "there", "here", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should",
        "as", "if", "which", "who", "what", "about", "from", "by", "up", "out", "all", "some", "any",
        "please", "let", "but", "am", "going", "want", "got", "its", "their", "them", "him", "her", "his",
        "being", "into", "onto", "than", "too", "very", "now", "still", "thanks", "thank", "hi", "hey",
        "hello", "dear"
    ]
}
