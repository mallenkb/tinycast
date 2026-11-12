import Foundation

enum DictationPreviewSequence {
    struct CleanupBlock: Equatable, Sendable {
        let text: String
        let isLine: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isLine == rhs.isLine && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
    }

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

    static func cleanupBlocks(in text: String) -> [CleanupBlock] {
        let recent = text.utf8.suffix(4_096).drop { (0x80...0xBF).contains($0) }
        guard let window = String(bytes: recent, encoding: .utf8) else { return [] }
        var lineStart = recent.startIndex == text.utf8.startIndex ? window.startIndex : nil
        var sentenceStart = lineStart
        var blocks: [CleanupBlock] = []
        var sentences: [CleanupBlock] = []
        for index in window.indices {
            let next = window.index(after: index)
            let character = window[index]
            if character == "\n" {
                if let start = lineStart, let line = cleanupBlock(window[start..<index], isLine: true) {
                    blocks.append(line)
                } else {
                    blocks.append(contentsOf: sentences)
                }
                sentences.removeAll(keepingCapacity: true)
                lineStart = next
                sentenceStart = next
            } else if ".!?。！？".contains(character), next < window.endIndex, window[next].isWhitespace {
                if let start = sentenceStart,
                   let sentence = cleanupBlock(window[start..<next], isLine: false) {
                    sentences.append(sentence)
                }
                sentenceStart = next
            }
        }
        return Array((blocks + sentences).suffix(32))
    }

    private static func cleanupBlock(_ text: Substring, isLine: Bool) -> CleanupBlock? {
        guard text.utf8.count <= 1_024, text.contains(where: { !$0.isWhitespace }) else { return nil }
        return CleanupBlock(
            text: isLine ? String(text) : text.trimmingCharacters(in: .whitespacesAndNewlines), isLine: isLine)
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
