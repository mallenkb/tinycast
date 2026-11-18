import Foundation

/// Applies spoken take-backs such as "scrap that", which drop the sentence or clause they follow.
enum DictationRetraction {
    // The cue must stand alone, so "ignore that warning" and "don't forget that." stay as dictated.
    nonisolated(unsafe) private static let cuePattern = #/
        (?ix)
        (?<marker>(?:\b(?:oh|no|nope|sorry|wait|actually)[,\x20\t]+)*)
        \b(?:
            (?<ownWords>(?:ignore|disregard|forget|scratch|scrap|strike)[\x20\t]+what[\x20\t]+i[\x20\t]+
                (?:just[\x20\t]+)?said)
            | (?:scrap|scratch|strike|forget|ignore|disregard|delete|erase|remove|drop|undo|cancel)[\x20\t]+
                (?:that|this|the[\x20\t]+last[\x20\t]+(?:sentence|statement|part|bit|line|thing))
            | (?:i[\x20\t]+)?take[\x20\t]+(?:that|it)[\x20\t]+back
            | never[\x20\t]*mind(?:[\x20\t]+(?:that|this))?
            | let[\x20\t]+me[\x20\t]+(?:rephrase|restate|start[\x20\t]+(?:over|again)|try[\x20\t]+(?:that[\x20\t]+)?again)
            | start[\x20\t]+(?:over|again)
        )\b
        (?=[,.!?;:…]|[\x20\t]*$)
        [,.!?;:…\x20\t]*
    /#

    nonisolated(unsafe) private static let sentenceEndPattern = /[.!?…]+(?:[\x20\t]+|$)/

    static func applying(_ text: String) -> String {
        guard text.firstMatch(of: cuePattern) != nil else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.firstMatch(of: cuePattern) == nil ? String($0) : applying(toLine: $0) }
            .joined(separator: "\n")
    }

    private static func applying(toLine line: Substring) -> String {
        let sentences = sentences(in: line)
        var kept: [String] = []
        for (index, sentence) in sentences.enumerated() {
            guard let cue = sentence.firstMatch(of: cuePattern) else {
                kept.append(sentence)
                continue
            }
            let before = sentence[..<cue.range.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = sentence[cue.range.upperBound...].trimmingCharacters(in: .whitespaces)
            let opensSentence = before.isEmpty
            guard opensSentence || !cue.output.marker.isEmpty || [",", ";"].contains(before.last) else {
                kept.append(sentence)
                continue
            }
            let retracted = opensSentence ? kept.last : before
            let replacement = after.isEmpty ? sentences.dropFirst(index + 1).first : after
            // Each cue is also everyday speech to the reader; only a restatement proves a take-back.
            guard let retracted,
                  cue.output.ownWords != nil || replacement.map({ restates(retracted, with: $0) }) == true
            else {
                kept.append(sentence)
                continue
            }
            if opensSentence { kept.removeLast() }
            if !after.isEmpty { kept.append(capitalizingFirstLetter(after)) }
        }
        return kept.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A restatement repeats at least a third of the retracted words that carry meaning.
    private static func restates(_ retracted: String, with replacement: String) -> Bool {
        let original = contentWords(retracted)
        guard !original.isEmpty else { return false }
        let shared = original.intersection(contentWords(replacement)).count
        return shared * 3 >= original.count
    }

    private static func contentWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
            .filter { $0.count >= 3 && !functionWords.contains($0) })
    }

    private static let functionWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "you", "your", "our", "its", "it's", "this", "that",
        "with", "but", "not", "all", "any", "can", "has", "have", "had", "from", "they", "them", "then",
        "there", "here", "what", "when", "will", "would", "should", "could", "just", "about", "into",
    ]

    private static func sentences(in line: Substring) -> [String] {
        var sentences: [String] = []
        var rest = line
        while !rest.isEmpty {
            guard let end = rest.firstMatch(of: sentenceEndPattern) else {
                sentences.append(String(rest))
                break
            }
            sentences.append(String(rest[..<end.range.upperBound]))
            rest = rest[end.range.upperBound...]
        }
        return sentences
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }
}
