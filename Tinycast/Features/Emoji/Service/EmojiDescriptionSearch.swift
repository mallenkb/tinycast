import Foundation
import FoundationModels
import NaturalLanguage

enum EmojiDescriptionSearch {
    struct Candidate: Sendable {
        let glyph: String
        let vector: [Float]
    }

    struct Result: Sendable {
        let candidates: [Candidate]
        let glyphs: [String]
        let nearby: [String]
    }

    static func accepts(_ query: String) -> Bool {
        query.count <= 200 && query.split(whereSeparator: \.isWhitespace).count >= 2
    }

    static func includes(_ category: EmojiCategory) -> Bool {
        switch category {
        case .smileysAndPeople, .animalsAndNature, .foodAndDrink, .activity,
            .travelAndPlaces, .objects, .symbols, .flags:
            true
        case .arrows, .currency, .math, .shapesAndPunctuation, .cjk, .keysAndTechnical:
            false
        }
    }

    @concurrent
    static func search(
        _ query: String, entries: [EmojiEntry], candidates: [Candidate]?,
        suggestionCategory: EmojiCategory? = nil, includeShortlist: Bool = false
    ) async -> Result? {
        guard !Task.isCancelled, accepts(query),
            NLLanguageRecognizer.dominantLanguage(for: query) == .english,
            let embedding = NLEmbedding.sentenceEmbedding(for: .english),
            let queryValues = embedding.vector(for: query),
            let queryVector = normalized(queryValues)
        else { return nil }

        var indexed = candidates ?? []
        if candidates == nil {
            for entry in entries where includes(entry.category) {
                guard !Task.isCancelled else { return nil }
                let description = entry.name + ". " + entry.keywords.replacingOccurrences(of: ",", with: ", ")
                guard let values = embedding.vector(for: description), let vector = normalized(values)
                else { continue }
                indexed.append(Candidate(glyph: entry.glyph, vector: vector))
            }
        }
        guard !Task.isCancelled else { return nil }
        let glyphs = matches(queryVector, candidates: indexed)
        var nearby: [String] = []
        if includeShortlist {
            let eligible = suggestionCategory.map { category in
                Set(entries.lazy.filter { $0.category == category }.map(\.glyph))
            }
            let scoped = eligible.map { glyphs in indexed.filter { glyphs.contains($0.glyph) } } ?? indexed
            nearby = matches(queryVector, candidates: scoped, minimum: -1, limit: 16)
        }
        return Result(candidates: indexed, glyphs: glyphs, nearby: nearby)
    }

    static func normalized(_ values: [Double]) -> [Float]? {
        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return values.map { Float($0 / magnitude) }
    }

    static func matches(
        _ query: [Float], candidates: [Candidate], minimum: Float = 0.6, limit: Int = 12
    ) -> [String] {
        candidates.enumerated().compactMap { order, candidate -> (String, Float, Int)? in
            guard candidate.vector.count == query.count, !query.isEmpty else { return nil }
            let similarity = zip(query, candidate.vector).reduce(Float.zero) { $0 + $1.0 * $1.1 }
            guard similarity >= minimum else { return nil }
            return (candidate.glyph, similarity, order)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        .prefix(limit)
        .map(\.0)
    }

    static var canSuggest: Bool { SystemLanguageModel.default.isAvailable }

    @concurrent
    static func suggest(_ query: String, entries: [EmojiEntry], nearby: [String]) async -> [String] {
        guard !Task.isCancelled, canSuggest else { return [] }
        let words = contentWords(query)
        let catalog = entries.filter { includes($0.category) }
        let byGlyph = Dictionary(catalog.map { ($0.glyph, $0) }, uniquingKeysWith: { first, _ in first })
        let lexical = catalog.enumerated().compactMap { offset, entry -> (EmojiEntry, Int, Int)? in
            let name = entry.name + " " + (poseDescriptions[entry.glyph] ?? "")
            let score = words.intersection(contentWords(name)).count * 2
                + words.intersection(contentWords(entry.keywords)).count
            return score > 0 ? (entry, score, offset) : nil
        }
        .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
        .prefix(8)
        .map(\.0)
        var seen: Set<String> = []
        let shortlist = (lexical + nearby.compactMap { byGlyph[$0] })
            .filter { seen.insert($0.glyph).inserted }
        guard !shortlist.isEmpty, !Task.isCancelled else { return [] }

        let choices = shortlist.enumerated().map { offset, entry in
            "\(offset + 1). \(entry.glyph) \(entry.name)"
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            Rank catalog emoji by how well they match the search phrase. Prefer an emoji that depicts
            the described subject and action. Return up to five relevant candidate IDs in descending
            relevance, separated by commas. Omit weak or unrelated candidates. Return 0 if none fit.
            """)
        do {
            let response = try await session.respond(
                to: "Search phrase: \(query.debugDescription)\nCatalog:\n\(choices)",
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 64))
            try Task.checkCancellation()
            var used: Set<Int> = []
            return response.content.split { $0.isWhitespace || $0 == "," }.compactMap { token -> String? in
                guard let id = Int(token), (1...shortlist.count).contains(id), used.insert(id).inserted
                else { return nil }
                return shortlist[id - 1].glyph
            }
            .prefix(5).map { $0 }
        } catch {
            return []
        }
    }

    private static func contentWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(["a", "an", "the", "on", "of", "with", "in", "at", "to", "my", "your", "its"])
    }

    private static let poseDescriptions = [
        "🧘": "person sitting seated cross legged",
        "🧘‍♂️": "man sitting seated cross legged",
        "🧘‍♀️": "woman sitting seated cross legged",
        "👨‍🦽": "man sitting seated",
        "👨‍🦼": "man sitting seated",
        "👩‍🦽": "woman sitting seated",
        "👩‍🦼": "woman sitting seated"
    ]
}
