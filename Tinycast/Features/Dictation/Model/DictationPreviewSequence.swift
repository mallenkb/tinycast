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

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func bounded(_ words: [String]) -> String {
        words.suffix(100).joined(separator: " ")
    }
}
