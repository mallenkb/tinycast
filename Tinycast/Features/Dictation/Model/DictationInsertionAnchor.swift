import Foundation

/// Finds a pasted insertion again by the text right around it, so edits elsewhere don't lose it.
struct DictationInsertionAnchor: Sendable {
    private static let contextLength = 48
    private static let slack = 256

    let inserted: String
    let replaced: String
    private let before: String
    private let after: String
    private let offset: Int

    init(prefix: Substring, suffix: Substring, replaced: Substring, inserted: String) {
        self.inserted = inserted
        self.replaced = String(replaced)
        before = String(prefix.suffix(Self.contextLength))
        after = String(suffix.prefix(Self.contextLength))
        offset = prefix.count
    }

    func locate(in text: String) -> Substring? {
        let starts: [String.Index]
        if before.isEmpty {
            starts = [text.startIndex]
        } else {
            starts = occurrences(of: before, in: text[...]).map(\.upperBound)
        }
        guard let start = nearest(starts, to: offset, in: text) else { return nil }
        let end: String.Index
        if after.isEmpty {
            end = text.endIndex
        } else {
            let ends = occurrences(of: after, in: text[start...]).map(\.lowerBound)
            let expected = text.distance(from: text.startIndex, to: start) + inserted.count
            guard let nearestEnd = nearest(ends, to: expected, in: text) else { return nil }
            end = nearestEnd
        }
        guard text.distance(from: start, to: end) <= inserted.count * 2 + Self.slack else { return nil }
        return text[start..<end]
    }

    private func nearest(_ indices: [String.Index], to target: Int, in text: String) -> String.Index? {
        let ranked = indices.map { ($0, abs(text.distance(from: text.startIndex, to: $0) - target)) }
        guard let best = ranked.min(by: { $0.1 < $1.1 }) else { return nil }
        return ranked.count(where: { $0.1 == best.1 }) == 1 ? best.0 : nil
    }

    private func occurrences(of needle: String, in text: Substring) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, options: .literal, range: remaining) {
            found.append(range)
            guard range.lowerBound < text.endIndex else { break }
            remaining = text.index(after: range.lowerBound)..<text.endIndex
        }
        return found
    }
}
