import Foundation

/// Applies spoken take-backs such as "scrap that", which drop the sentence or clause they follow.
struct DictationRetraction {
    // The cue must stand alone, so "ignore that warning" and "don't forget that." stay as dictated.
    nonisolated(unsafe) private static let cuePattern = #/
        (?ix)
        (?<marker>(?:\b(?:oh|no|nope|sorry|wait|actually)[,\x20\t]+)*)
        \b(?:
            (?<direct>(?:scratch|scrap|strike)[\x20\t]+that)\b
                (?:(?<joined>[\x20\t]+)(?=\p{L})|(?=[,.!?;:…\r\n]|[\x20\t]*$))
            | (?:
                (?<ownWords>(?:ignore|disregard|forget|scratch|scrap|strike)[\x20\t]+what[\x20\t]+i[\x20\t]+
                    (?:just[\x20\t]+)?said)
                | (?:scrap|scratch|strike|forget|ignore|disregard|delete|erase|remove|drop|undo|cancel)[\x20\t]+
                    (?:that|this|the[\x20\t]+last[\x20\t]+(?:sentence|statement|part|bit|line|thing))
                | (?:i[\x20\t]+)?take[\x20\t]+(?:that|it)[\x20\t]+back
                | never[\x20\t]*mind(?:[\x20\t]+(?:that|this))?
                | let[\x20\t]+me[\x20\t]+(?:rephrase|restate|start[\x20\t]+(?:over|again)|try[\x20\t]+(?:that[\x20\t]+)?again)
                | start[\x20\t]+(?:over|again)
            )\b(?=[,.!?;:…\r\n]|[\x20\t]*$)
        )
        [,.!?;:…\x20\t]*
    /#

    private struct Edit {
        let range: Range<String.Index>
        let confirmed: Bool
        let explicitUndo: Bool
    }

    private let source: String
    private var edits: [Edit] = []
    private(set) var contexts: [Range<String.Index>] = []
    var hasCues: Bool { !contexts.isEmpty }

    init(_ source: String) {
        self.source = source
        let cues = source.matches(of: Self.cuePattern)
        var quoted = false
        var scanned = source.startIndex
        var previousEnd = source.startIndex
        for (index, cue) in cues.enumerated() {
            let before = source[previousEnd..<cue.range.lowerBound]
            for character in source[scanned..<cue.range.lowerBound] {
                if character.isNewline { quoted = false }
                if "\"“”`".contains(character) { quoted.toggle() }
            }
            scanned = cue.range.upperBound
            let next = index + 1 < cues.count ? cues[index + 1].range.lowerBound : source.endIndex
            let after = source[cue.range.upperBound..<next]
            let targetEnd = before.lastIndex { !$0.isWhitespace && !",;:.!?…".contains($0) }
            let end = targetEnd.map { source.index(after: $0) } ?? cue.range.lowerBound
            let prefix = before[..<end]
            let boundary = prefix.indices.reversed().first { Self.isBoundary($0, in: source) }
            let start = boundary.map { source.index(after: $0) } ?? previousEnd
            let clause = source[start..<end].drop(while: \.isWhitespace)
            let replacementEnd = after.indices.first { Self.isBoundary($0, in: source) } ?? next
            let replacement = after[..<replacementEnd]
            let target = Self.repeatedClause(in: clause, replacement: replacement)
            let repeatsOpening = Self.repeatsOpening(of: target, in: replacement)
            if cue.output.joined != nil, !repeatsOpening || quoted { continue }
            let contextEnd = replacementEnd < next ? source.index(after: replacementEnd) : replacementEnd
            let context = clause.startIndex..<max(cue.range.upperBound, contextEnd)
            if let last = contexts.last, last.upperBound >= context.lowerBound {
                contexts[contexts.count - 1] = last.lowerBound..<context.upperBound
            } else {
                contexts.append(context)
            }
            previousEnd = cue.range.upperBound
            guard !target.isEmpty, !quoted,
                  !source[end..<cue.range.lowerBound].contains(where: \.isNewline) else { continue }
            let delimiter = before.last(where: { !$0.isWhitespace })
            let separated = !cue.output.marker.isEmpty || delimiter.map { ",;.!?…".contains($0) } == true
            let ownWords = cue.output.ownWords != nil
            if !separated {
                guard cue.output.direct != nil, repeatsOpening else { continue }
            }
            if Self.isConditional(clause) {
                guard delimiter.map({ ".!?…".contains($0) }) == true, ownWords || repeatsOpening else { continue }
            }
            guard ownWords || replacement.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            edits.append(Edit(range: target.startIndex..<cue.range.upperBound,
                              confirmed: ownWords || Self.restates(target, with: replacement), explicitUndo: ownWords))
        }
    }

    private static func isBoundary(_ index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if character.isNewline || ";!?…".contains(character) { return true }
        guard ".,".contains(character) else { return false }
        let next = text.index(after: index)
        return next == text.endIndex || text[next].isWhitespace
    }

    private static func repeatedClause(in clause: Substring, replacement: Substring) -> Substring {
        let words = /[\p{L}\p{M}]+/
        guard let first = replacement.firstMatch(of: words)?.output else { return clause }
        for conjunction in clause.matches(of: /(?i:\b(?:and|then)\s+)/).reversed() {
            let tail = clause[conjunction.range.upperBound...]
            if tail.prefixMatch(of: words)?.output.lowercased() == first.lowercased() { return tail }
        }
        return clause
    }

    private static func repeatsOpening(of clause: Substring, in replacement: Substring) -> Bool {
        let word = /[\p{L}\p{M}]+/
        guard let first = clause.prefixMatch(of: word)?.output.lowercased(),
              first.count >= 3, !functionWords.contains(first) else { return false }
        return replacement.prefixMatch(of: word)?.output.lowercased() == first
    }

    private static func isConditional(_ clause: Substring) -> Bool {
        clause.lowercased().firstMatch(of: /\b(?:if|unless|when|whenever|otherwise|in case)\b/) != nil
    }

    static func containsCue(_ text: String) -> Bool {
        guard let first = text.firstMatch(of: cuePattern) else { return false }
        return first.output.joined == nil || Self(text).hasCues
    }

    func crossesBoundary(_ boundary: String.Index) -> Bool {
        contexts.contains { $0.lowerBound < boundary && boundary < $0.upperBound }
    }

    func keepingContext(in sections: [Range<String.Index>]) -> [Range<String.Index>] {
        guard hasCues else { return sections }
        var iterator = sections.makeIterator()
        var section = iterator.next()
        var result: [Range<String.Index>] = []
        for context in contexts {
            while let current = section, current.upperBound <= context.lowerBound {
                result.append(current)
                section = iterator.next()
            }
            if let current = section, current.lowerBound <= context.lowerBound,
               current.upperBound >= context.upperBound { continue }
            if let current = section, current.lowerBound < context.lowerBound {
                result.append(current.lowerBound..<context.lowerBound)
            }
            result.append(context)
            while let current = section, current.upperBound <= context.upperBound { section = iterator.next() }
            if let current = section, current.lowerBound < context.upperBound {
                section = context.upperBound..<current.upperBound
            }
        }
        if let section { result.append(section) }
        result.append(contentsOf: iterator)
        return result
    }

    static let instructions = """
        Resolve a spoken take-back only when the speaker corrects their own words. Keep earlier clauses and the final \
        replacement. Keep ordinary instructions such as "If the build fails, start over."
        """

    static func applying(_ text: String) -> String { Self(text).localResult }

    var localResult: String {
        var result = ""
        var cursor = source.startIndex
        var capitalizesNext = false
        for edit in edits where edit.confirmed {
            let prefix = source[cursor..<edit.range.lowerBound]
            result += capitalizesNext ? Self.capitalizingFirstLetter(prefix) : String(prefix)
            capitalizesNext = result.last(where: { !$0.isWhitespace }).map { ".!?…".contains($0) } ?? true
            cursor = edit.range.upperBound
        }
        guard cursor != source.startIndex else { return source }
        let tail = source[cursor...]
        result += capitalizesNext ? Self.capitalizingFirstLetter(tail) : String(tail)
        return result.trimmingCharacters(in: .whitespaces)
    }

    // Each cue permits one contiguous deletion. Everything between deletions must match in order.
    func accepts(_ output: String) -> Bool {
        let words = Self.validationWords(output[...])
        var positions: Set<Int> = [0]
        var cursor = source.startIndex
        func advance(_ piece: Substring, optional: Bool) {
            let keys = Self.validationWords(piece)
            let matches = positions.compactMap { index in
                words[index...].starts(with: keys) ? index + keys.count : nil
            }
            if optional { positions.formUnion(matches) } else { positions = Set(matches) }
        }
        for edit in edits {
            advance(source[cursor..<edit.range.lowerBound], optional: false)
            if positions.isEmpty { return false }
            if !edit.explicitUndo { advance(source[edit.range], optional: true) }
            cursor = edit.range.upperBound
        }
        advance(source[cursor...], optional: false)
        return positions.contains(words.count)
    }

    private static func validationWords(_ text: Substring) -> [String] {
        text.lowercased().matches(of: /[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*|[.,]?\d+(?:[.,:\/]\d+)*|[^\s.,;:!?…]/)
            .map { String($0.output).replacing("’", with: "'") }
    }

    private static func restates(_ retracted: Substring, with replacement: Substring) -> Bool {
        let original = contentWords(retracted)
        guard !original.isEmpty else { return false }
        return original.intersection(contentWords(replacement)).count * 3 >= original.count
    }

    private static func contentWords(_ text: Substring) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
            .filter { $0.count >= 3 && !functionWords.contains($0) })
    }

    private static let functionWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "you", "your", "our", "its", "it's", "this", "that",
        "with", "but", "not", "all", "any", "can", "has", "have", "had", "from", "they", "them", "then",
        "there", "here", "what", "when", "will", "would", "should", "could", "just", "about", "into",
    ]

    private static func capitalizingFirstLetter(_ text: Substring) -> String {
        guard let first = text.first, first.isLetter else { return String(text) }
        return first.uppercased() + text.dropFirst()
    }
}
