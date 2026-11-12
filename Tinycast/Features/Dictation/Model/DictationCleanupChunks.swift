import Foundation

struct DictationCleanupChunks {
    static let byteLimit = 1_800

    private let text: String
    let ranges: [Range<String.Index>]

    init(_ text: String, sentenceRanges: [Range<String.Index>]) {
        self.text = text
        let sentenceEnds = Set(sentenceRanges.compactMap { range -> String.Index? in
            guard let last = text[range].lastIndex(where: { !$0.isWhitespace }) else { return nil }
            let end = text.index(after: last)
            guard end == text.endIndex || text[end].isWhitespace || "。！？".contains(text[last]) else { return nil }
            return end
        })
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while let contentStart = text[start...].firstIndex(where: { !$0.isWhitespace }) {
            var end = contentStart
            var bytes = 0
            var lineBreak: String.Index?
            var sentenceBreak: String.Index?
            var earlySentenceBreak: String.Index?
            var wordBreak: String.Index?
            var previous: Character?
            while end < text.endIndex {
                let character = text[end]
                let endsSentence = sentenceEnds.contains(end)
                if end > contentStart {
                    if bytes >= Self.byteLimit / 2 {
                        if character.isNewline { lineBreak = end }
                        if endsSentence { sentenceBreak = end }
                    }
                    if endsSentence { earlySentenceBreak = end }
                    if character.isWhitespace, previous?.isWhitespace == false, previous != "." || endsSentence {
                        wordBreak = end
                    }
                }
                let next = text.index(after: end)
                bytes += text[end..<next].utf8.count
                guard bytes <= Self.byteLimit else { break }
                previous = character
                end = next
            }
            if end < text.endIndex {
                guard let boundary = lineBreak ?? sentenceBreak ?? wordBreak ?? earlySentenceBreak else {
                    let searchStart = end == contentStart ? text.index(after: end) : end
                    start = text[searchStart...].indices.first {
                        text[$0].isWhitespace || sentenceEnds.contains($0)
                    } ?? text.endIndex
                    continue
                }
                end = boundary
            }
            if let last = text[contentStart..<end].lastIndex(where: { !$0.isWhitespace }) {
                ranges.append(contentStart..<text.index(after: last))
            }
            start = end
        }
        self.ranges = ranges
    }

    nonisolated(nonsending) func cleaned(using edit: (String) async throws -> String) async throws -> String {
        var output = ""
        var end = text.startIndex
        for range in ranges {
            try Task.checkCancellation()
            output += text[end..<range.lowerBound]
            output += try await edit(String(text[range]))
            end = range.upperBound
        }
        try Task.checkCancellation()
        output += text[end...]
        return output
    }

    static func hasProtectedValue(_ text: Substring) -> Bool {
        text.firstMatch(of: #/
            (?ix:
                [\p{N}\p{Sc}@\x22\x60“”]|\b(?:https?://|www\.)|\b(?:
                    zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|
                    fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|
                    sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion|quadrillion|
                    lakh|crore|half|quarters?|percent|noon|midnight|today|tomorrow|yesterday|
                    (?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth)|
                    cedis?|pesewas?|dollars?|euros?|yen|rupees?|dinars?|riyals?|pesos?|francs?|pence|cents?|
                    january|february|april|june|july|august|september|october|november|december
                )\b
            )
            /#) != nil
    }

    static func acceptsSmartEdit(_ output: String, source: String) -> Bool {
        guard !output.isEmpty, !hasProtectedValue(output[...]) else { return false }
        let negation = /(?i:\b(?:no|not|never|none|nothing|nobody|without|cannot)\b|n['’]t\b)/
        guard source.matches(of: negation).count == output.matches(of: negation).count else { return false }
        let tokens: (String) -> [String] = {
            $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        let original = tokens(source)
        let edited = tokens(output)
        guard !original.isEmpty else { return false }
        var counts = Dictionary(edited.map { ($0, 1) }, uniquingKeysWith: +)
        var retained = 0
        for word in original where counts[word, default: 0] > 0 {
            counts[word, default: 0] -= 1
            retained += 1
        }
        return retained >= max(1, (original.count * 4 + 4) / 5) && edited.count <= original.count * 2
    }
}
