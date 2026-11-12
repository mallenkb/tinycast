import Foundation

enum DictationPreviewSequence {
    private struct Cell {
        var score = 0
        var matches = 0
        var start = 0
        var edits = 0
    }

    static func merge(_ previous: String, _ incoming: String) -> String {
        let old = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = incoming.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !new.isEmpty else { return previous }
        guard !old.isEmpty else { return bounded(new) }
        let lhs = old.map(normalized)
        let rhs = new.map(normalized)
        if rhs.count <= lhs.count, Array(lhs.suffix(rhs.count)) == rhs { return previous }
        if lhs.count <= rhs.count, Array(rhs.prefix(lhs.count)) == lhs { return bounded(new) }
        var row = (0...rhs.count).map { Cell(score: -2 * $0, edits: $0) }
        for i in lhs.indices {
            var next = [Cell(start: i + 1)]
            for j in rhs.indices {
                let equal = !lhs[i].isEmpty && lhs[i] == rhs[j]
                var diagonal = row[j]
                diagonal.score += equal ? 3 : -2
                diagonal.matches += equal ? 1 : 0
                diagonal.edits += equal ? 0 : 1
                var deletion = row[j + 1]
                deletion.score -= 2
                deletion.edits += 1
                var insertion = next[j]
                insertion.score -= 2
                insertion.edits += 1
                next.append([diagonal, deletion, insertion].max { $0.score < $1.score } ?? diagonal)
            }
            row = next
        }
        let candidates = row.dropFirst().filter { $0.matches >= 2 && $0.matches >= 2 * $0.edits }
        guard let overlap = candidates.max(by: { $0.score < $1.score }) else {
            // An uncertain overlap replaces the recent preview instead of duplicating spoken words.
            return bounded(new)
        }
        return bounded(Array(old.prefix(overlap.start)) + new)
    }

    static func stableCleanupInput(previous: String, incoming: String) -> String? {
        guard !previous.isEmpty, !incoming.isEmpty, incoming.utf8.prefix(16_385).count <= 16_384 else { return nil }
        if previous == incoming { return incoming }
        let count = zip(previous, incoming).prefix { $0.0 == $0.1 }.count
        let stable = incoming.prefix(count)
        let boundaries = ".!?。！？"
        guard let end = stable.indices.last(where: { index in
            guard boundaries.contains(stable[index]) else { return false }
            let next = stable.index(after: index)
            return next < stable.endIndex && stable[next].isWhitespace
        }) else { return nil }
        return String(stable[...end])
    }

    static func revealStart(previous: String, incoming: String, limit: Int) -> Int {
        let count = incoming.count
        let floor = max(0, count - limit)
        if incoming.hasPrefix(previous) { return max(floor, previous.count) }
        let old = previous.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
        let words = incoming.split(whereSeparator: \.isWhitespace)
        let new = words.map { normalized(String($0)) }
        guard !new.isEmpty, old.last != new.last else { return count }
        var bestLength = 1
        var firstNewWord = 0
        for left in old.indices.suffix(8).reversed() {
            for right in new.indices.reversed() where old[left] == new[right] && !old[left].isEmpty {
                var length = 1
                while left >= length, right >= length,
                    old[left - length] == new[right - length], !old[left - length].isEmpty
                {
                    length += 1
                }
                if length > bestLength {
                    bestLength = length
                    firstNewWord = right + 1
                }
            }
        }
        guard firstNewWord < words.count else { return count }
        let index = words[firstNewWord].startIndex
        return max(floor, incoming.distance(from: incoming.startIndex, to: index))
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func bounded(_ words: [String]) -> String {
        words.suffix(100).joined(separator: " ")
    }
}
