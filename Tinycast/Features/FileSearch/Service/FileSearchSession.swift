import Foundation
import Synchronization

@MainActor
@Observable
final class FileSearchSession {
    typealias SearchOperation = @Sendable (String, FileSearchFilter) async -> [FileSearchResult]
    typealias DocumentPaths = @MainActor @Sendable (String, [String]) async -> [String]

    typealias FilteredDocumentPaths = @MainActor @Sendable (SearchFileConstraints, [String]) async -> [String]

    enum State: Equatable {
        case idle
        case searching
        case ready
    }

    private(set) var results: [FileSearchResult] = []
    private(set) var state: State = .idle
    private(set) var isFetching = false
    private(set) var queryIssue: SearchFileQuery.Issue?
    var filters: SearchFileConstraints? { request?.description?.fileConstraints }
    /// The published search: the filter belongs to it, so narrowing re-runs the same words.
    private var request: Request?
    private var revision = 0
    @ObservationIgnored private var pending: (request: Request, revision: Int)?
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private var activeSearch: Task<Void, Never>?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var needsResume = false
    @ObservationIgnored private let searchOperation:
        @Sendable (String, FileSearchFilter, SearchDescription?) async -> [FileSearchResult]
    @ObservationIgnored private let documentSearch:
        (@MainActor (String, FileSearchFilter, SearchDescription?, UInt64) async -> [FileSearchResult])?
    @ObservationIgnored private var documentContentScope: UInt64?
    /// Kept across closes, so the blank screen opens on its rows instead of on nothing.
    @ObservationIgnored private var recent: [FileSearchResult]?
    @ObservationIgnored private var recentStamp = 0
    @ObservationIgnored private var recentRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var recentRefreshPending = false
    @ObservationIgnored var onWorkSettled: (() -> Void)?

    private struct Request: Equatable {
        static let recent = Request(query: "", filter: .all)

        let query: String
        let filter: FileSearchFilter
        var description: SearchDescription?
        var isInterpreted = false
    }

    /// No debounce: a search costs milliseconds, and the worker already runs only the newest.
    init(index: FileIndex, documentPaths: DocumentPaths? = nil, filteredDocumentPaths: FilteredDocumentPaths? = nil) {
        if let documentPaths {
            documentSearch = { query, filter, description, scope in
                if let filters = description?.fileConstraints {
                    guard !filters.content.isEmpty, let filteredDocumentPaths else { return [] }
                    let scopes = index.documentContentScopes(fingerprint: scope, folder: filters.folder)
                    guard !scopes.isEmpty else { return [] }
                    let paths = await filteredDocumentPaths(filters, scopes)
                    guard !Task.isCancelled else { return [] }
                    return await index.documentContentMatches(
                        paths: paths, description: description, filter: filter, fingerprint: scope)
                }
                let kind = description?.kind ?? .any
                guard !query.isEmpty, [.all, .documents, .spreadsheets, .presentations, .code].contains(filter),
                    [.any, .files, .documents, .text].contains(kind), description?.matchesFilenameOnly != true
                else { return [] }
                let text = description?.text ?? query
                guard !text.isEmpty else { return [] }
                let scopes = index.documentContentScopes(fingerprint: scope)
                guard !scopes.isEmpty else { return [] }
                let paths = await documentPaths(text, scopes)
                guard !Task.isCancelled, !paths.isEmpty else { return [] }
                return await index.documentContentMatches(
                    paths: paths, description: description, filter: filter, fingerprint: scope)
            }
        } else {
            documentSearch = nil
        }
        searchOperation = { query, filter, interpreted in
            let cancelled = Atomic(false)
            let worker = Task.detached(priority: .userInitiated) {
                    let isCancelled: @Sendable () -> Bool = { cancelled.load(ordering: .relaxed) }
                    let description = interpreted ?? SearchDescription(query, now: Date(), calendar: .current)
                    let ordinary: [FileSearchResult]
                    if let description {
                        ordinary = index.search(description: description, filter: filter, isCancelled: isCancelled)
                    } else if let prepared = FileSearchQuery.prepare(query) {
                        ordinary = index.search(prepared, filter: filter, isCancelled: isCancelled)
                    } else {
                        return index.recent(filter: filter, isCancelled: isCancelled)
                    }
                    let images = index.imageContentMatches(
                        query: query, description: description, filter: filter, isCancelled: isCancelled)
                    let ids = Set(ordinary.map(\.id))
                    return Array((ordinary + images.filter { !ids.contains($0.id) }).prefix(FileSearchQuery.resultLimit))
            }
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
                cancelled.store(true, ordering: .relaxed)
            }
        }
    }

    init(searchOperation: @escaping SearchOperation) {
        self.searchOperation = { query, filter, _ in await searchOperation(query, filter) }
        documentSearch = nil
    }

    /// An empty query is a request too: the blank screen lists what changed recently.
    func search(_ rawQuery: String, filter: FileSearchFilter = .all) {
        suspended = false
        let resume = needsResume
        needsResume = false
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : rawQuery
        let description: SearchDescription?
        var isInterpreted = false
        switch SearchFileQuery.parse(query, now: Date(), calendar: .current) {
        case .filters(let filters):
            description = SearchDescription(fileConstraints: filters)
        case .issue(let issue):
            cancel()
            queryIssue = issue
            results = []
            state = .ready
            return
        case .literal:
            let current = self.request?.query == query ? self.request : nil
            description = current?.description
            isInterpreted = current?.isInterpreted == true
        }
        queryIssue = nil
        let request = Request(query: query, filter: filter, description: description, isInterpreted: isInterpreted)
        guard request != self.request || resume else { return }
        enqueue(request)
        guard request == .recent, let recent else { return }
        results = recent
        state = .ready
    }

    func describedResults(for query: String) -> [FileSearchResult] {
        guard request?.query == query, state == .ready else { return [] }
        return results
    }

    func applyDescription(_ description: SearchDescription, for query: String, filter: FileSearchFilter) {
        guard let request, request.query == query, request.description == nil || request.isInterpreted,
            queryIssue == nil else { return }
        let updated = Request(query: query, filter: filter, description: description, isInterpreted: true)
        if updated != request { enqueue(updated) }
    }

    func clearDescription(resumingSearch: Bool) {
        guard var request, request.isInterpreted else { return }
        guard resumingSearch else { cancel(); return }
        request.description = nil
        request.isInterpreted = false
        enqueue(request)
    }

    /// Re-runs the published request; Recent's kept rows follow even behind a typed query.
    func refresh(clearingResults: Bool = false) {
        if clearingResults { results = [] }
        if let request {
            if suspended { needsResume = true } else { enqueue(request) }
        }
        if request != .recent { refreshRecent() }
    }

    func setDocumentContentScope(_ scope: UInt64?) {
        guard documentContentScope != scope else { return }
        documentContentScope = scope
        results.removeAll(where: \.matchesDocumentContent)
        if let request, !request.query.isEmpty {
            if suspended { needsResume = true } else { enqueue(request) }
        }
    }

    /// Only the kept rows move, so a list on screen never shifts under the pointer.
    func refreshRecent() {
        recentRefreshPending = true
        guard recentRefreshTask == nil else { return }
        recentRefreshTask = Task { [weak self] in
            guard let self else { return }
            while recentRefreshPending {
                recentRefreshPending = false
                await run(.recent)
            }
            recentRefreshTask = nil
        }
    }

    /// Idle already means no results and nothing that can publish, so it notifies no observer.
    func cancel() {
        queryIssue = nil
        needsResume = false
        isFetching = false
        guard request != nil else { return }
        revision &+= 1
        pending = nil
        activeSearch?.cancel()
        request = nil
        results = []
        state = .idle
    }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        isFetching = false
        if request != .recent, !results.isEmpty {
            results = []
            needsResume = request != nil
        }
        guard activeSearch != nil || pending != nil else { return }
        needsResume = request != nil
        revision &+= 1
        pending = nil
        activeSearch?.cancel()
    }

    /// A trashed row names a file that is gone, so it leaves the published results with it.
    func remove(_ result: FileSearchResult) {
        results.removeAll { $0.id == result.id }
        recent?.removeAll { $0.id == result.id }
    }

    private func enqueue(_ request: Request) {
        revision &+= 1
        if request != self.request, request.description != nil || self.request?.description != nil { results = [] }
        self.request = request
        state = .searching
        isFetching = true
        activeSearch?.cancel()
        pending = (request, revision)
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while let next = pending {
            pending = nil
            let task = Task { await publish(next.request, revision: next.revision) }
            activeSearch = task
            await task.value
            activeSearch = nil
        }
        workerTask = nil
        onWorkSettled?()
    }

    private func publish(_ request: Request, revision: Int) async {
        defer { if self.revision == revision { isFetching = false } }
        let found = await run(request)
        guard !Task.isCancelled, self.revision == revision, self.request == request else { return }
        if results != found { results = found }
        guard let scope = documentContentScope, let documentSearch, !request.query.isEmpty,
            found.count < FileSearchQuery.resultLimit
        else {
            state = .ready
            return
        }
        if !found.isEmpty { state = .ready }
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = request.description ?? SearchDescription(query, now: Date(), calendar: .current)
        let content = await documentSearch(query, request.filter, description, scope)
        guard !Task.isCancelled, self.revision == revision, self.request == request else { return }
        let ids = Set(results.map(\.id))
        let remaining = FileSearchQuery.resultLimit - results.count
        results.append(contentsOf: content.lazy.filter { !ids.contains($0.id) }.prefix(remaining))
        state = .ready
    }

    /// Recent's rows are kept whoever asked; stamped, so a late finisher never replaces newer rows.
    @discardableResult
    private func run(_ request: Request) async -> [FileSearchResult] {
        guard !Task.isCancelled else { return [] }
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request == .recent else { return await searchOperation(query, request.filter, request.description) }
        recentStamp &+= 1
        let stamp = recentStamp
        let found = await searchOperation(query, request.filter, request.description)
        if stamp == recentStamp, !Task.isCancelled { recent = found }
        return found
    }
}
