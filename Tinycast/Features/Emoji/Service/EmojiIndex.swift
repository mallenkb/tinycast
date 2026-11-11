import Foundation

/// The parsed catalog: sections precomputed at load, search memoized one query deep.
@MainActor
@Observable
final class EmojiIndex {
    private(set) var entries: [EmojiEntry] = []
    private(set) var categorySections: [(category: EmojiCategory, entries: [EmojiEntry])] = []

    /// `order` is the catalog index, the tie-break that keeps equal scores in catalog order.
    private struct ScoredEntry {
        let entry: EmojiEntry
        let score: Int
        let order: Int
    }

    /// An entry's text folded once at load, so a keystroke folds only the query.
    private struct FoldedEntry: Sendable {
        let name: FuzzyMatch.Candidate
        let keywords: FuzzyMatch.Candidate
        let keywordList: [FuzzyMatch.Candidate]

        init(_ entry: EmojiEntry) {
            let descriptions = Self.gestureDescriptions[entry.glyph] ?? ""
            let searchKeywords = [entry.keywords, descriptions].filter { !$0.isEmpty }.joined(separator: ",")
            name = FuzzyMatch.Candidate(entry.name)
            keywords = FuzzyMatch.Candidate(searchKeywords)
            keywordList = searchKeywords.split(separator: ",").map { FuzzyMatch.Candidate(String($0)) }
        }

        private static let gestureDescriptions: [String: String] = [
            "🤦": "hand on face,palm on forehead,covering face",
            "🤦‍♂️": "hand on face,palm on forehead,covering face",
            "🤦‍♀️": "hand on face,palm on forehead,covering face",
            "🫣": "hands on face,hands covering eyes,looking through fingers",
            "🤭": "hand on face,covering mouth,laughing behind hand",
            "🫢": "hand on face,covering mouth",
            "🤔": "hand on face,hand on chin",
            "🫡": "hand on forehead",
            "🙈": "hands covering eyes",
            "🙉": "hands covering ears",
            "🙊": "hands covering mouth"
        ]
    }

    private struct SearchKey: Equatable {
        let query: String
        let revision: Int
        let frequentID: ObjectIdentifier
        let frequentRevision: Int
        let limit: Int
    }

    struct DescriptionRequest: Equatable {
        let query: String
        let filter: EmojiCategoryFilter
        let allowsSuggestions: Bool

        var category: EmojiCategory? {
            if case .category(let category) = filter { return category }
            return nil
        }

        var canSuggest: Bool {
            allowsSuggestions && (filter == .all || category != nil)
        }

        func includes(_ entry: EmojiEntry) -> Bool {
            category.map { entry.category == $0 } ?? true
        }
    }

    private struct Suggestions {
        let request: DescriptionRequest
        var glyphs: [String]?
    }

    private var byGlyph: [String: EmojiEntry] = [:]
    /// Parallel to `entries`.
    private var foldedEntries: [FoldedEntry] = []
    @ObservationIgnored private var searchMemo = Memo<SearchKey, [EmojiEntry]>()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var descriptionCandidates: [EmojiDescriptionSearch.Candidate]?
    private var descriptionQuery = ""
    private var descriptionGlyphs: [String] = []
    private var suggestions: Suggestions?
    @ObservationIgnored private var descriptionGeneration = 0
    /// Bumped on each load, so the key above names the catalog it scored.
    private var revision = 0

    var isLoaded: Bool { !entries.isEmpty }

    func prepare(languages: [String] = [], bundle: Bundle = .main) {
        guard !isLoaded, loadTask == nil else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.load(EmojiData.raw, languages: languages, bundle: bundle, generation: generation)
            if self.loadGeneration == generation { self.loadTask = nil }
        }
    }

    @discardableResult
    func unload() -> Bool {
        let hadContent = isLoaded || loadTask != nil
        loadGeneration &+= 1
        guard hadContent else { return false }
        loadTask?.cancel()
        loadTask = nil
        entries = []
        categorySections = []
        byGlyph = [:]
        foldedEntries = []
        descriptionCandidates = nil
        descriptionQuery = ""
        descriptionGlyphs = []
        suggestions = nil
        descriptionGeneration &+= 1
        searchMemo = Memo()
        revision &+= 1
        return hadContent
    }

    /// `languages` pick which of the bundle's keyword packs join the catalog's English keywords.
    func load(_ raw: String = EmojiData.raw, languages: [String] = [], bundle: Bundle = .main) async {
        loadGeneration &+= 1
        await load(raw, languages: languages, bundle: bundle, generation: loadGeneration)
    }

    private func load(_ raw: String, languages: [String], bundle: Bundle, generation: Int) async {
        let worker = Task.detached(priority: .utility) { () -> ([EmojiEntry], [FoldedEntry])? in
            guard !Task.isCancelled else { return nil }
            let parsed = EmojiCatalog.parse(raw, localized: Self.keywordPacks(for: languages, in: bundle))
            guard !Task.isCancelled else { return nil }
            return (parsed, parsed.map(FoldedEntry.init))
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, loadGeneration == generation, let (parsed, folded) = result else { return }
        entries = parsed
        descriptionCandidates = nil
        descriptionQuery = ""
        descriptionGlyphs = []
        suggestions = nil
        descriptionGeneration &+= 1
        foldedEntries = folded
        var grouped: [EmojiCategory: [EmojiEntry]] = [:]
        for entry in parsed { grouped[entry.category, default: []].append(entry) }
        categorySections = EmojiCategory.allCases.compactMap { category in
            grouped[category].map { (category, $0) }
        }
        byGlyph = Dictionary(parsed.map { ($0.glyph, $0) }, uniquingKeysWith: { first, _ in first })
        revision &+= 1
    }

    /// Plain files let search follow macOS languages independently of the app's UI language.
    private nonisolated static func keywordPacks(for languages: [String], in bundle: Bundle) -> [String] {
        let urls = bundle.urls(forResourcesWithExtension: "txt", subdirectory: "EmojiKeywords") ?? []
        let byLanguage = Dictionary(
            urls.map { ($0.deletingPathExtension().lastPathComponent, $0) },
            uniquingKeysWith: { first, _ in first })
        return EmojiCatalog.keywordLanguages(available: byLanguage.keys.sorted(), preferred: languages)
            .compactMap { byLanguage[$0].flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
    }

    func entry(for glyph: String) -> EmojiEntry? { byGlyph[glyph] }

    func suggestedEntries(for request: DescriptionRequest) -> [EmojiEntry] {
        guard suggestions?.request == request else { return [] }
        return suggestions?.glyphs?.compactMap(entry(for:)) ?? []
    }

    func isSuggesting(for request: DescriptionRequest) -> Bool {
        suggestions?.request == request && suggestions?.glyphs == nil
    }

    func matchDescription(_ request: DescriptionRequest, frequent: FrequentEmojiStore) async {
        guard !Task.isCancelled else { return }
        descriptionGeneration &+= 1
        let generation = descriptionGeneration
        let catalogRevision = revision
        let normalized = FuzzyMatch.normalized(request.query)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        descriptionQuery = ""
        descriptionGlyphs = []
        suggestions = nil
        guard isLoaded, EmojiDescriptionSearch.accepts(normalized), !Task.isCancelled else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        guard !Task.isCancelled, generation == descriptionGeneration, catalogRevision == revision else { return }
        let canSuggest = request.canSuggest && EmojiDescriptionSearch.canSuggest
            && !search(request.query, frequent: frequent).contains(where: request.includes)
        if canSuggest { suggestions = Suggestions(request: request) }
        let result = await EmojiDescriptionSearch.search(
            normalized, entries: entries, candidates: descriptionCandidates,
            suggestionCategory: request.category, includeShortlist: canSuggest)
        guard !Task.isCancelled, generation == descriptionGeneration, catalogRevision == revision else { return }
        if let result {
            descriptionCandidates = result.candidates
            descriptionQuery = normalized
            descriptionGlyphs = result.glyphs
        }
        guard canSuggest, !search(request.query, frequent: frequent).contains(where: request.includes) else {
            suggestions = nil
            return
        }
        let glyphs = await EmojiDescriptionSearch.suggest(
            normalized, entries: entries.filter(request.includes), nearby: result?.nearby ?? [])
        guard !Task.isCancelled, generation == descriptionGeneration, catalogRevision == revision else { return }
        suggestions = Suggestions(request: request, glyphs: glyphs)
    }

    /// Ranked fuzzy matches over names and keywords; an empty query returns nothing.
    func search(_ query: String, frequent: FrequentEmojiStore, limit: Int = 320) -> [EmojiEntry] {
        let trimmed = FuzzyMatch.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped =
            trimmed.count > 2 && trimmed.first == ":" && trimmed.last == ":"
            ? String(trimmed.dropFirst().dropLast()) : trimmed
        let words = unwrapped.split(whereSeparator: \.isWhitespace).map(String.init)
        let q = words.joined(separator: " ")
        guard !q.isEmpty, limit > 0 else { return [] }
        let key = SearchKey(
            query: q, revision: revision, frequentID: ObjectIdentifier(frequent),
            frequentRevision: frequent.revision, limit: limit)
        let directResults = searchMemo.value(for: key) {
            let query = FuzzyMatch.Query(q)
            let terms = words.count > 1 ? words : []
            let descriptionWords = words.filter { !Self.descriptionFillers.contains($0) }
            let descriptionQuery = words.count > 1 && !descriptionWords.isEmpty && descriptionWords != words
                ? FuzzyMatch.Query(descriptionWords.joined(separator: " ")) : nil
            let descriptionTerms = descriptionWords.count > 1 ? descriptionWords : []
            let frequentGlyphs = frequent.top(Self.frecencyLimit)
            let frecency = Dictionary(
                frequentGlyphs.enumerated().map {
                    ($0.element, Self.frecencyLimit - $0.offset)
                }, uniquingKeysWith: max)
            var scored: [ScoredEntry] = []
            for (order, entry) in entries.enumerated() {
                let folded = foldedEntries[order]
                let directScore = Self.textScore(query, terms: terms, folded: folded)
                let fallbackScore = directScore == nil ? descriptionQuery.flatMap {
                    Self.textScore($0, terms: descriptionTerms, folded: folded)
                        .map { $0 - Self.descriptionPenalty }
                } : nil
                guard let textScore = directScore ?? fallbackScore else { continue }
                let score = textScore + (frecency[entry.glyph] ?? 0)
                scored.append(ScoredEntry(entry: entry, score: score, order: order))
            }
            return
                scored
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
                .prefix(limit)
                .map(\.entry)
        }
        guard descriptionQuery == q, directResults.count < limit else { return directResults }
        let directGlyphs = Set(directResults.map(\.glyph))
        let related = descriptionGlyphs.filter { !directGlyphs.contains($0) }.compactMap(entry(for:))
        return Array((directResults + related).prefix(limit))
    }

    /// Just under half a tier, so an equal-quality name match always wins.
    private static let keywordPenalty = 500
    private static let frecencyLimit = 100
    /// A complete leading name word: above an exact keyword, below the exact name.
    private static let leadingWordScore = 95_000
    /// Scattered query words rank below every literal phrase, name-only words first.
    private static let nameWordsScore = 60_000
    private static let mixedWordsScore = 50_000
    private static let descriptionPenalty = 200_000
    private static let descriptionFillers: Set<String> = [
        "a", "an", "the", "on", "of", "with", "in", "at", "to", "my", "your", "its"
    ]

    private static func textScore(
        _ query: FuzzyMatch.Query, terms: [String], folded: FoldedEntry
    ) -> Int? {
        var nameOnly = true
        for term in terms where !containsWordStart(term, in: folded.name.text) {
            guard !term.contains(","), containsWordStart(term, in: folded.keywords.text) else { return nil }
            nameOnly = false
        }

        let nameMatch = FuzzyMatch.match(query, candidate: folded.name)
        if nameMatch?.tier == .exact { return nameMatch?.score }
        var best = nameMatch?.score
        if let nameMatch, nameMatch.tier == .prefix,
            let next = folded.name.text.dropFirst(nameMatch.queryLength).first,
            !next.isLetter && !next.isNumber
        {
            best = leadingWordScore - nameMatch.candidateLength
        }
        if !terms.isEmpty {
            let ordered = nameMatch?.tier == .subsequence ? nameMatch?.score ?? 0 : 0
            best = max(best ?? Int.min, (nameOnly ? nameWordsScore : mixedWordsScore) + ordered)
        }
        guard !folded.keywordList.isEmpty, FuzzyMatch.score(query, candidate: folded.keywords) != nil
        else { return best }
        for keyword in folded.keywordList {
            guard let match = FuzzyMatch.match(query, candidate: keyword) else { continue }
            best = max(best ?? Int.min, min(match.score, leadingWordScore) - keywordPenalty)
            if match.tier == .exact { break }
        }
        return best
    }

    private static func containsWordStart(_ term: String, in candidate: String) -> Bool {
        var start = candidate.startIndex
        while let range = candidate.range(of: term, range: start..<candidate.endIndex) {
            if range.lowerBound == candidate.startIndex { return true }
            let previous = candidate[candidate.index(before: range.lowerBound)]
            if !previous.isLetter && !previous.isNumber { return true }
            start = candidate.index(after: range.lowerBound)
        }
        return false
    }
}
