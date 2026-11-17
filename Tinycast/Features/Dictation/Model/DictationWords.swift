import Foundation

enum DictationWords {
    struct Token: Equatable, Sendable {
        let key: String
        let word: Int
        let capitalized: Bool
        let startsSentence: Bool
        var isNumber: Bool { key.first == "#" }
        var number: Double? { isNumber ? Double(key.dropFirst()) : nil }
    }

    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var sentenceEnded = true
        for (index, word) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            for match in word.matches(of: /[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*|\p{N}+(?:[.,:\/]\p{N}+)*/) {
                let piece = match.output
                if piece.first?.isNumber == true {
                    tokens.append(Token(
                        key: "#" + numberKey(piece), word: index, capitalized: false, startsSentence: sentenceEnded))
                } else {
                    let capitalized = piece.first?.isUppercase == true
                    for (offset, key) in expand(piece.lowercased().replacing("’", with: "'")).enumerated() {
                        tokens.append(Token(
                            key: key, word: index, capitalized: capitalized && offset == 0,
                            startsSentence: sentenceEnded && offset == 0))
                    }
                }
                sentenceEnded = false
            }
            if let last = word.last(where: { !"\"')]}”’".contains($0) }), ".!?:\n".contains(last) {
                sentenceEnded = true
            }
        }
        return collapsingSpokenNumbers(tokens)
    }

    /// Ranges of the whitespace-separated words that `Token.word` indexes.
    static func wordRanges(_ text: String) -> [Range<String.Index>] {
        text.matches(of: /\S+/).map(\.range)
    }

    static func alignment(_ source: [Token], _ edited: [Token]) -> [(source: Int, edited: Int)] {
        let rows = source.count + 1
        let columns = edited.count + 1
        guard rows > 1, columns > 1 else { return [] }
        var lengths = [Int32](repeating: 0, count: rows * columns)
        for i in stride(from: source.count - 1, through: 0, by: -1) {
            for j in stride(from: edited.count - 1, through: 0, by: -1) {
                lengths[i * columns + j] = source[i].key == edited[j].key
                    ? lengths[(i + 1) * columns + j + 1] + 1
                    : max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < source.count, j < edited.count {
            if source[i].key == edited[j].key {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30
    ]

    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000,
                                                "billion": 1_000_000_000]

    private static func numberKey(_ piece: Substring) -> String {
        let plain = piece.replacing(",", with: "")
        if let value = Double(plain) { return format(value) }
        return plain.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0).map(String.init) }
            .joined(separator: ":")
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static let contractions: [String: [String]] = [
        "can't": ["can", "not"], "won't": ["will", "not"], "shan't": ["shall", "not"], "ain't": ["is", "not"],
        "let's": ["let", "us"], "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"],
        "kinda": ["kind", "of"], "sorta": ["sort", "of"], "lemme": ["let", "me"], "gimme": ["give", "me"]
    ]

    private static func expand(_ word: String) -> [String] {
        if let expanded = contractions[word] { return expanded }
        for (suffix, replacement) in [("n't", "not"), ("'re", "are"), ("'m", "am"), ("'ll", "will"),
                                      ("'ve", "have"), ("'d", "would"), ("'s", "is")]
        where word.hasSuffix(suffix) && word.count > suffix.count {
            return [String(word.dropLast(suffix.count)), replacement]
        }
        return [word]
    }

    /// "forty five" becomes one `#45` token; adjacent groups without a scale word stay separate.
    private static func collapsingSpokenNumbers(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var index = 0
        while index < tokens.count {
            guard numberWords[tokens[index].key] != nil else {
                result.append(tokens[index])
                index += 1
                continue
            }
            let start = tokens[index]
            var total = 0
            var current = 0
            var previous: Int?
            while index < tokens.count {
                let key = tokens[index].key
                if let value = numberWords[key] {
                    if let previous, previous < 20 || value >= 10 || previous % 10 != 0 { break }
                    current += value
                    previous = value
                } else if let scale = scales[key], previous != nil || current > 0 {
                    if scale == 100 { current = max(current, 1) * 100 } else {
                        total += max(current, 1) * scale
                        current = 0
                    }
                    previous = nil
                } else if key == "and", current >= 100 || total > 0,
                          index + 1 < tokens.count, numberWords[tokens[index + 1].key] != nil {
                    previous = nil
                } else {
                    break
                }
                index += 1
            }
            result.append(Token(
                key: "#\(total + current)", word: start.word, capitalized: false,
                startsSentence: start.startsSentence))
        }
        return result
    }
}
