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

    static func words(in text: String) -> [Substring] {
        var words: [Substring] = []
        var end = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            words.append(contentsOf: text[end..<range.lowerBound].split(whereSeparator: \.isWhitespace))
            words.append(text[range])
            end = range.upperBound
        }
        words.append(contentsOf: text[end...].split(whereSeparator: \.isWhitespace))
        return Array(words.suffix(100))
    }

    enum WordEdit: Equatable {
        case kept(Int)
        case followsDeletion(Int)
        case replaced(Int)
        case inserted
    }

    static func wordEdits(from old: [Substring], to new: [Substring]) -> [WordEdit] {
        let diff = new.difference(from: old)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in diff {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        var edits: [WordEdit] = []
        var left = 0
        var right = 0
        while right < new.count {
            let firstRemoved = left
            while removed.contains(left) { left += 1 }
            var replacement = firstRemoved
            while inserted.contains(right) {
                edits.append(replacement < left ? .replaced(replacement) : .inserted)
                replacement += 1
                right += 1
            }
            if right < new.count {
                edits.append(replacement < left ? .followsDeletion(left) : .kept(left))
                left += 1
                right += 1
            }
        }
        return edits
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func bounded(_ words: [String]) -> String {
        words.suffix(100).joined(separator: " ")
    }
}
