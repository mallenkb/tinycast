import Foundation

struct DictationCorrection: Codable, Identifiable, Sendable {
    private static let punctuation = ".,!?…;:()[]{}\"“”«»"

    let original: String
    let spelling: String
    private let addedManually: Bool?

    var id: String { Self.key(for: original) }
    var isManual: Bool { addedManually == true }

    init(original: String, spelling: String, isManual: Bool = false) {
        self.original = original
        self.spelling = spelling
        addedManually = isManual ? true : nil
    }

    static func manual(spelling: String, misspelling: String) -> Self? {
        let spelling = phrase(spelling)
        guard !spelling.isEmpty else { return nil }
        let misspelling = phrase(misspelling)
        return Self(original: misspelling.isEmpty ? spelling : misspelling, spelling: spelling, isManual: true)
    }

    static func infer(from inserted: String, to edited: String, recognized: String) -> Self? {
        let before = words(in: inserted)
        let after = words(in: edited)
        let source = words(in: recognized)
        guard before.count == after.count, before.count == source.count else { return nil }
        let changes = before.indices.filter { before[$0] != after[$0] }
        guard changes.count == 1, let index = changes.first else { return nil }
        let wrong = before[index]
        let right = after[index]
        guard
            (3...40).contains(wrong.count), (3...40).contains(right.count)
        else { return nil }
        let edits = right.lowercased().difference(from: wrong.lowercased())
        let changed = max(edits.insertions.count, edits.removals.count)
        let limit = min(wrong.count, right.count) < 5 ? 1 : 2
        guard (1...limit).contains(changed) else { return nil }

        var expected = inserted
        expected.replaceSubrange(wrong.startIndex..<wrong.endIndex, with: right)
        guard expected == edited else { return nil }
        return Self(original: String(source[index]), spelling: String(right))
    }

    static func applying(_ entries: [Self], to text: String) -> String {
        guard !entries.isEmpty else { return text }
        let replacements = Dictionary(entries.map { ($0.id, $0.spelling) }, uniquingKeysWith: { first, _ in first })
        let phrases = replacements.keys.sorted { $0.count > $1.count }.map { key in
            key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\h+")
        }.joined(separator: "|")
        let punctuation = Self.punctuation.unicodeScalars.map { "\\x{\(String($0.value, radix: 16))}" }.joined()
        let pattern = "(?<!\\S)[\(punctuation)]*?(\(phrases))(?=[\(punctuation)]*(?:\\s|$))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        var corrected = ""
        var remaining = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let range = Range(match.range(at: 1), in: text),
                let replacement = replacements[key(for: String(text[range]))]
            else { continue }
            corrected += text[remaining..<range.lowerBound]
            corrected += replacement
            remaining = range.upperBound
        }
        corrected += text[remaining...]
        return corrected
    }

    static func key(for text: String) -> String {
        phrase(text).folding(options: .caseInsensitive, locale: nil)
    }

    private static func phrase(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func words(in text: String) -> [Substring] {
        return text.split(whereSeparator: \.isWhitespace).compactMap { token in
            guard let start = token.firstIndex(where: { !punctuation.contains($0) }),
                let end = token.lastIndex(where: { !punctuation.contains($0) })
            else { return nil }
            let word = token[start...end]
            return word.allSatisfy(\.isLetter) ? word : nil
        }
    }
}
