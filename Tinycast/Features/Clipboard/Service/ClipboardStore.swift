import Foundation

@MainActor
@Observable
final class ClipboardStore {
    enum UpdateError: Error { case tooLong, writeFailed }

    struct DescriptionQuery: Sendable, Equatable {
        let text: String
        let kind: ClipboardItem.Kind?
        let dates: DateInterval?
        let alternativeTexts: [String]
        let linksOnly: Bool
        let videosOnly: Bool
        let website: String?

        init(
            text: String, kind: ClipboardItem.Kind?, dates: DateInterval?, alternativeTexts: [String] = [],
            linksOnly: Bool = false, website: String? = nil, videosOnly: Bool = false
        ) {
            self.text = text
            self.kind = kind
            self.dates = dates
            self.alternativeTexts = alternativeTexts
            self.linksOnly = linksOnly
            self.videosOnly = videosOnly
            self.website = website
        }

        func matches(_ item: ClipboardItem) -> Bool {
            if videosOnly { return item.filePath.map { ClipboardFileKind.of(path: $0) == .movie } ?? false }
            guard linksOnly else { return true }
            guard item.textForm == .link, let text = item.text else { return false }
            guard let website else { return true }
            let candidate = text.contains("://") ? text : "https://" + text
            guard let host = URLComponents(string: candidate)?.host?.lowercased() else { return false }
            if website.contains(".") { return host == website || host.hasSuffix("." + website) }
            let labels = host.split(separator: ".")
            return labels.count >= 2 && labels[labels.count - 2] == website
        }
    }

    /// Newest-first with pins in place, every pin resident. docs/features/clipboard.md
    private(set) var items: [ClipboardItem] = [] {
        didSet {
            if !textSearchMatches.isEmpty {
                let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                textSearchMatches = textSearchMatches.map { current[$0.id] ?? $0 }
            }
            invalidateSearch(preservingMatches: true)
            onItemsChanged?()
        }
    }
    @ObservationIgnored var onItemsChanged: (() -> Void)?
    @ObservationIgnored var onSearchResultsChanged: ((String, [ClipboardItem], [ClipboardItem]) -> Void)?
    /// Rotated whenever the history is replaced, so a helper's late answer lands on nothing.
    @ObservationIgnored private(set) var extractionGeneration = UUID()
    @ObservationIgnored private(set) var captureGeneration = UUID()
    /// The only thing a view observes for search freshness; `items` cannot speak for OCR.
    private var searchRevision = 0
    @ObservationIgnored private(set) var textSearchEnabled = false
    @ObservationIgnored private var textSearchActive = true
    @ObservationIgnored private var textSearchTask: Task<Void, Never>?
    @ObservationIgnored private var textSearchNeedsRefresh = false
    @ObservationIgnored private var textSearchKey: SearchKey?
    @ObservationIgnored private var textSearchRequest: UUID?
    @ObservationIgnored private var textSearchMatches: [ClipboardItem] = []

    @ObservationIgnored private var interpretedQuery: (raw: String, description: DescriptionQuery)?
    @ObservationIgnored private let describeQuery: (String) -> DescriptionQuery?

    var maxAge: TimeInterval = ClipboardRetention.threeMonths.maxAge

    /// One-entry memo so repeated renders reuse the FTS result; cleared when `items` changes.
    @ObservationIgnored private var searchCache: (key: SearchKey, result: [ClipboardItem])?
    /// Same memo for the empty query, so the pinned split runs once per mutation.
    @ObservationIgnored private var orderedCache: [ClipboardItem]?

    private struct SearchKey: Equatable {
        let query: String
        let filter: ClipboardFilter
        let description: DescriptionQuery?
    }

    /// Longest text history holds; a longer copy is skipped, since truncation would lose the tail.
    nonisolated static let maxTextLength = 32_000

    @ObservationIgnored private let database: ClipboardDatabase
    /// Stored lets, so a backup can read both off the main actor.
    let imagesDir: URL
    let dbURL: URL

    /// `directory` defaults to the per-channel store; the harness passes a throwaway one.
    init(directory: URL? = nil, describeQuery: @escaping (String) -> DescriptionQuery? = { _ in nil }) {
        self.describeQuery = describeQuery
        database = ClipboardDatabase(directory: directory ?? Self.defaultDirectory)
        imagesDir = database.imagesDir
        dbURL = database.url
    }

    /// Idempotent, so the coordinator can re-open the file when the feature is switched back on.
    func open() {
        database.open()
    }

    /// Every accessor is statement-guarded, so a closed store answers as an empty history.
    func close() {
        setTextSearchEnabled(false)
        interpretedQuery = nil
        invalidateSearch()
        extractionGeneration = UUID()
        captureGeneration = UUID()
        database.close()
        items = []
    }

    /// Application Support, not Caches: a history the OS may reclaim is not a history.
    private static var defaultDirectory: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    // Isolated so teardown may touch the main-actor task; the release is already on main.
    isolated deinit {
        textSearchTask?.cancel()
    }

    func load() {
        invalidateSearch()
        extractionGeneration = UUID()
        guard let loaded = database.loadWindow() else { return }
        items = loaded
        database.removeOrphanedCopies()
        // Age passes while the app isn't running; insert-time pruning alone can't catch that.
        enforceLimits()
    }

    func enforceLimits() {
        prune()
    }

    func addText(_ text: String, sourceBundleID: String?) {
        if items.first?.kind == .text, items.first?.text == text { return }
        insert(ClipboardItem(text: text, sourceBundleID: sourceBundleID))
    }

    /// One row per file. Batched, so a multi-file copy prunes once rather than once per file.
    func addFiles(_ paths: [String], sourceBundleID: String?) {
        // Only a single file can be a ⌘C repeat, which is the case `addText` also guards.
        if paths.count == 1, items.first?.kind == .file, items.first?.text == paths[0] { return }
        for path in paths {
            let item = ClipboardItem(filePath: path, sourceBundleID: sourceBundleID)
            database.insert(item)
            items.insert(item, at: 0)
            trimWindow()
        }
        prune()
    }

    func addImage(_ data: Data, sourceBundleID: String?, capture: UUID) {
        guard capture == captureGeneration else { return }
        let url = database.newBlobURL()
        let item = ClipboardItem(imagePath: url.path, sourceBundleID: sourceBundleID)
        // The blob write is multi-MB I/O; only the row insert returns to the main actor.
        Task.detached(priority: .utility) { [weak self] in
            guard ClipboardDatabase.writeBlob(data, to: url) else { return }
            await self?.insertCapture(item, from: capture)
        }
    }

    private func insertCapture(_ item: ClipboardItem, from capture: UUID) {
        guard capture == captureGeneration else {
            database.deleteBlob(item)
            return
        }
        insert(item)
    }

    /// Bulk-insert from an import: original timestamps, external image paths, deduped.
    @discardableResult
    func importEntries(_ entries: [ClipboardItem]) -> Int {
        // Oldest first so newest ends up with the highest rowid (load orders by rowid DESC).
        let inserted = ClipboardDatabase.importStoredItems(
            inDatabaseAt: dbURL, entries.sorted { $0.createdAt < $1.createdAt })
        load()
        return inserted
    }

    func promote(_ item: ClipboardItem) {
        // A pinned row holds its place, so re-recencying it would rewrite for no change.
        guard !item.isPinned, items.first?.id != item.id else { return }
        reinsert(item.with(createdAt: Date(), pinnedAt: nil))
    }

    func togglePinned(_ item: ClipboardItem) {
        if item.isPinned { unpin(item) } else { pin(item) }
    }

    func updateText(_ text: String, of item: ClipboardItem) throws(UpdateError) -> ClipboardItem? {
        guard item.kind == .text else { return nil }
        guard text.count <= Self.maxTextLength else { throw .tooLong }
        guard try database.updateText(text, id: item.id) else { return nil }
        let index = items.firstIndex { $0.id == item.id }
        let current = index.map { items[$0] } ?? item
        let edited = ClipboardItem(
            id: current.id, kind: .text, text: text, imagePath: nil, createdAt: current.createdAt,
            sourceBundleID: current.sourceBundleID, pinnedAt: current.pinnedAt)
        if let index {
            items[index] = edited
        } else {
            // An FTS hit past the memory window: only the memo still holds the old text.
            invalidateSearch()
            searchRevision += 1
        }
        return edited
    }

    func remove(_ item: ClipboardItem) {
        textSearchMatches.removeAll { $0.id == item.id }
        database.delete(item)
        items.removeAll { $0.id == item.id }
        database.deleteBlob(item)
    }

    /// A pin is a deliberate keep, so it outlives the bulk clear; `remove` is the way to drop one.
    func clearAll() {
        invalidateSearch()
        extractionGeneration = UUID()
        captureGeneration = UUID()
        database.deleteUnpinned()
        // Every pinned row is resident however old, so the window stays whole without a reload.
        items = items.filter(\.isPinned)
    }

    @discardableResult
    func setTextSearchEnabled(_ enabled: Bool) -> Bool {
        guard enabled != textSearchEnabled else { return true }
        if enabled {
            guard database.createExtractionSchema() else { return false }
        }
        textSearchEnabled = enabled
        extractionGeneration = UUID()
        invalidateSearch()
        searchRevision += 1
        return true
    }

    struct ExtractionScope: Equatable {
        var filter: ClipboardFilter = .all
        var residentOnly = false
    }

    func nextExtractionItem(
        now: Date = Date(), version: Int = 1, scope: ExtractionScope = .init()
    ) -> ClipboardItem? {
        guard textSearchEnabled else { return nil }
        return database.nextExtractionItem(now: now, version: version, scope: scope)
    }

    func nextExtractionRetry(version: Int = 1, scope: ExtractionScope = .init()) -> Date? {
        guard textSearchEnabled else { return nil }
        return database.nextExtractionRetry(version: version, scope: scope)
    }

    func recordExtractionFailure(for item: ClipboardItem, generation: UUID, retryAt: Date) {
        guard textSearchEnabled, generation == extractionGeneration else { return }
        database.recordExtractionFailure(for: item, retryAt: retryAt)
    }

    @discardableResult
    func setExtractedText(
        _ text: String, for item: ClipboardItem, generation: UUID, version: Int = 1, completed: Bool = true
    ) -> Bool {
        guard textSearchEnabled, generation == extractionGeneration,
            database.setExtractedText(text, for: item, version: version, completed: completed)
        else { return false }
        invalidateSearch(preservingMatches: true)
        searchRevision += 1
        return true
    }

    /// Only an owned blob is immutable and ours, so only it may grow downscaled copies.
    func ownsImage(of item: ClipboardItem) -> Bool {
        item.imagePath.map(database.owns) ?? false
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let path = item.imagePath else { return nil }
        return URL(filePath: path, directoryHint: .inferFromPath)
    }

    func fileURL(for item: ClipboardItem) -> URL? {
        guard let path = item.filePath else { return nil }
        return URL(filePath: path, directoryHint: .inferFromPath)
    }

    /// Display order for `query` under `filter`: pinned entries first, each block newest-first.
    func search(_ query: String, filter: ClipboardFilter) -> [ClipboardItem] {
        // Load-bearing: a settled OCR query changes the answer without `items` changing.
        _ = searchRevision
        let q = query.trimmingCharacters(in: .whitespaces)
        let interpreted = interpretedQuery?.raw == query ? interpretedQuery?.description : nil
        let description = interpreted ?? describeQuery(q)
        let key = SearchKey(query: q, filter: filter, description: description)
        updateTextSearch(key, rawQuery: query)
        // The filter joins the key: `rows` rebuilds per render, so a query-only memo goes stale.
        if let searchCache, searchCache.key == key {
            return searchCache.result
        }
        // Filtering after the split leaves a matching pin in the Pinned section, in pin order.
        let result = filter.apply(to: description == nil ? unfiltered(q, filter: filter) : textSearchMatches)
        searchCache = (key, result)
        return result
    }

    func setInterpretedQuery(_ description: DescriptionQuery?, for raw: String) {
        guard interpretedQuery?.description != description || (description != nil && interpretedQuery?.raw != raw)
        else { return }
        interpretedQuery = description.map { (raw, $0) }
        invalidateSearch()
        searchRevision += 1
    }

    var knownWebsiteHosts: [String] {
        var hosts = Set<String>()
        for item in items where item.textForm == .link {
            guard let text = item.text else { continue }
            let candidate = text.contains("://") ? text : "https://" + text
            if let host = URLComponents(string: candidate)?.host?.lowercased() {
                hosts.insert(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            }
            if hosts.count >= 48 { break }
        }
        return hosts.sorted()
    }

    /// Row index of `item` as currently listed, so the palette can follow a row that moved.
    func rowIndex(of item: ClipboardItem, in query: String, filter: ClipboardFilter) -> Int? {
        search(query, filter: filter).firstIndex { $0.id == item.id }
    }

    /// The Nth visible pinned entry under `query` and `filter`, where 0 is the first pinned row.
    func pinnedItem(at index: Int, in query: String, filter: ClipboardFilter) -> ClipboardItem? {
        guard index >= 0 else { return nil }
        return search(query, filter: filter).prefix(while: \.isPinned).dropFirst(index).first
    }

    /// Where a reset lands: past the pins to the newest clip, or on the first match once typed.
    func landingIndex(in query: String, filter: ClipboardFilter) -> Int {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
        return search(query, filter: filter).firstIndex { !$0.isPinned } ?? 0
    }

    private func unfiltered(_ q: String, filter: ClipboardFilter) -> [ClipboardItem] {
        guard !q.isEmpty else { return orderedItems }
        // Pins are matched in memory: all resident, and the LIMIT would otherwise drop one.
        let ordinary = pinnedItems.filter { $0.matches(q) } + runSearch(q).filter { !$0.isPinned }
        guard !textSearchMatches.isEmpty else { return ordinary }
        let ordinaryIDs = Set(ordinary.map(\.id))
        let additional = textSearchMatches.filter { !ordinaryIDs.contains($0.id) }
        let pins = (ordinary + additional).filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantFuture) < ($1.pinnedAt ?? .distantFuture) }
        let unpinned = ordinary.filter { !$0.isPinned }
        // OCR-only rows fill what is left of the budget the FTS `LIMIT` gives ordinary ones.
        let remaining = max(0, ClipboardDatabase.searchLimit - filter.apply(to: unpinned).count)
        // `Array(…)` spelled out: left open, `prefix` resolves as `Sequence` and the chain fails.
        let extra = Array(filter.apply(to: additional.filter { !$0.isPinned }).prefix(remaining))
        return pins + unpinned + extra
    }

    private func runSearch(_ q: String) -> [ClipboardItem] {
        database.search(q) ?? fallbackSearch(q)
    }

    private func invalidateSearch(preservingMatches: Bool = false) {
        searchCache = nil
        orderedCache = nil
        textSearchTask?.cancel()
        textSearchTask = nil
        textSearchRequest = nil
        textSearchNeedsRefresh = preservingMatches && textSearchKey != nil
        if !preservingMatches {
            textSearchKey = nil
            textSearchMatches = []
        }
    }

    func setTextSearchActive(_ active: Bool) {
        guard textSearchActive != active else { return }
        textSearchActive = active
        invalidateSearch()
        searchRevision += 1
    }

    private func updateTextSearch(_ key: SearchKey, rawQuery: String) {
        let (query, filter, description) = (key.query, key.filter, key.description)
        guard textSearchActive, database.isOpen, !query.isEmpty,
            description != nil || (textSearchEnabled && filter.searchesExtractedContent)
        else {
            if textSearchKey != nil { invalidateSearch() }
            return
        }
        guard textSearchKey != key || textSearchNeedsRefresh else { return }
        invalidateSearch(preservingMatches: textSearchKey == key)
        textSearchNeedsRefresh = false
        textSearchKey = key
        let request = UUID()
        textSearchRequest = request
        let url = dbURL
        let residentIDs = query.count < 3 ? Set(items.map(\.id)) : nil
        let includeRecognizedText = textSearchEnabled
        textSearchTask = Task(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                if let description {
                    return ClipboardDatabase.describedMatches(
                        in: url, description: description, filter: filter,
                        includeRecognizedText: includeRecognizedText)
                }
                return ClipboardDatabase.extractedMatches(in: url, query: query, filter: filter, residentIDs: residentIDs)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.textSearchRequest == request else { return }
            let previous = self.searchCache
            self.textSearchMatches = matches
            self.textSearchTask = nil
            self.searchCache = nil
            self.searchRevision += 1
            if let previous, previous.key == key {
                let current = self.search(rawQuery, filter: filter)
                self.onSearchResultsChanged?(query, previous.result, current)
            }
        }
    }

    // MARK: - Private

    private func fallbackSearch(_ q: String) -> [ClipboardItem] {
        items.filter { $0.matches(q) }
    }

    private var orderedItems: [ClipboardItem] {
        if let orderedCache { return orderedCache }
        let pinned = pinnedItems
        // An unpinned history renders `items` as-is, so it never pays for the split.
        let result = pinned.isEmpty ? items : pinned + items.filter { !$0.isPinned }
        orderedCache = result
        return result
    }

    /// The Pinned section in pin order, so a new pin joins the end rather than the head.
    private var pinnedItems: [ClipboardItem] {
        items.filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantFuture) < ($1.pinnedAt ?? .distantFuture) }
    }

    /// The row keeps its place and gains a stamp, which heads the Pinned section.
    private func pin(_ item: ClipboardItem) {
        let stamp = Date()
        let current = items.first { $0.id == item.id } ?? item
        let pinned = current.with(pinnedAt: stamp)
        database.pin(item, at: stamp)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = pinned
        } else {
            // Pinned from an FTS hit outside the window, so splice it in by recency.
            let index = items.firstIndex { $0.createdAt < pinned.createdAt } ?? items.count
            items.insert(pinned, at: index)
        }
    }

    /// Unpinning rejoins as the newest entry. See docs/features/clipboard.md#pinned-entries.
    private func unpin(_ item: ClipboardItem) {
        reinsert(item.with(createdAt: Date(), pinnedAt: nil))
    }

    private func reinsert(_ updated: ClipboardItem) {
        database.moveToFront(updated)
        // Array ops also cover items surfaced by FTS from beyond the in-memory window.
        items.removeAll { $0.id == updated.id }
        items.insert(updated, at: 0)
        trimWindow()
    }

    /// Cap the in-memory window, but never drop a pinned row: those render however old they are.
    private func trimWindow() {
        guard items.count > ClipboardDatabase.memoryWindow,
            let index = items.lastIndex(where: { !$0.isPinned })
        else { return }
        items.remove(at: index)
    }

    private func insert(_ item: ClipboardItem) {
        database.insert(item)
        items.insert(item, at: 0)
        trimWindow()
        prune()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        textSearchMatches.removeAll { $0.createdAt < cutoff && !$0.isPinned }
        if database.deleteUnpinned(olderThan: cutoff) {
            invalidateSearch(preservingMatches: true)
            searchRevision += 1
        }
        // Against the oldest unpinned row: an exempt pin would make this permanently true.
        if items.last(where: { !$0.isPinned }).map({ $0.createdAt < cutoff }) == true {
            items.removeAll { $0.createdAt < cutoff && !$0.isPinned }
        }
    }
}
