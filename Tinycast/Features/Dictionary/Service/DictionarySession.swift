import Foundation

/// The dictionary screen's lookup: one term in flight, answered off the main actor.
@MainActor
@Observable
final class DictionarySession {
    struct Lookup: Equatable {
        let term: String
        let preferredSourceID: String
        /// Nil when no enabled dictionary knows the term.
        let entry: DictionaryEntry?
    }

    /// The last answered lookup; it stays up while the next term resolves, so typing never blanks.
    private(set) var lookup: Lookup?
    private(set) var sources: [DictionaryEntry.Source] = []
    @ObservationIgnored private var preferredSourceID = ""
    @ObservationIgnored private var term: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Coalesces a burst of keystrokes into the lookup for the word they settle on.
    private static let debounce = Duration.milliseconds(90)

    func configure(preferredSourceID: String) {
        guard self.preferredSourceID != preferredSourceID else { return }
        self.preferredSourceID = preferredSourceID
        refresh()
    }

    private func refresh() {
        let query = term ?? ""
        term = nil
        lookUp(query)
    }

    func lookUp(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term != self.term else { return }
        self.term = term
        task?.cancel()
        if term.isEmpty { lookup = nil }
        let preferredSourceID = preferredSourceID
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                DictionaryService.lookup(
                    term, preferredSourceID: preferredSourceID)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.sources = result.sources
            self?.lookup = Lookup(
                term: term, preferredSourceID: preferredSourceID,
                entry: result.entry)
            self?.task = nil
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        term = nil
        lookup = nil
        sources = []
    }
}
