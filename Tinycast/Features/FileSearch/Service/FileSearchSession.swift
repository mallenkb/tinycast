import Foundation
import Synchronization

@MainActor
@Observable
final class FileSearchSession {
    typealias SearchOperation = @Sendable (String, FileSearchFilter) async -> [FileSearchResult]

    enum State: Equatable {
        case idle
        case searching
        case ready
    }

    private(set) var results: [FileSearchResult] = []
    private(set) var state: State = .idle
    /// The published search: the filter belongs to it, so narrowing re-runs the same words.
    private var request: Request?
    private var revision = 0
    @ObservationIgnored private var pending: (request: Request, revision: Int)?
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private var activeSearch: Task<[FileSearchResult], Never>?
    @ObservationIgnored private let searchOperation:
        @Sendable (String, FileSearchFilter, SearchDescription?) async -> [FileSearchResult]
    /// Kept across closes, so the blank screen opens on its rows instead of on nothing.
    @ObservationIgnored private var recent: [FileSearchResult]?
    @ObservationIgnored private var recentStamp = 0
    @ObservationIgnored private var recentRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var recentRefreshPending = false

    private struct Request: Equatable {
        static let recent = Request(query: "", filter: .all)

        let query: String
        let filter: FileSearchFilter
        var description: SearchDescription?
    }

    /// No debounce: a search costs milliseconds, and the worker already runs only the newest.
    init(index: FileIndex) {
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
    }

    /// An empty query is a request too: the blank screen lists what changed recently.
    func search(_ rawQuery: String, filter: FileSearchFilter = .all) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : rawQuery
        let request = Request(
            query: query, filter: filter,
            description: self.request?.query == query ? self.request?.description : nil)
        guard request != self.request else { return }
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
        guard request?.query == query else { return }
        let updated = Request(query: query, filter: filter, description: description)
        if updated != request { enqueue(updated) }
    }

    func clearDescription(resumingSearch: Bool) {
        guard var request, request.description != nil else { return }
        guard resumingSearch else { cancel(); return }
        request.description = nil
        enqueue(request)
    }

    /// Re-runs the published request; Recent's kept rows follow even behind a typed query.
    func refresh(clearingResults: Bool = false) {
        if clearingResults { results = [] }
        if let request { enqueue(request) }
        if request != .recent { refreshRecent() }
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
        guard request != nil else { return }
        revision &+= 1
        pending = nil
        activeSearch?.cancel()
        request = nil
        results = []
        state = .idle
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
            let task = Task { await run(next.request) }
            activeSearch = task
            let found = await task.value
            activeSearch = nil
            guard revision == next.revision, request == next.request else { continue }
            if results != found { results = found }
            state = .ready
        }
        workerTask = nil
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
