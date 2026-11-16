import SwiftUI

/// Everything the launcher lists for one query, computed once and read by every palette event.
struct LauncherResults {
    let results: [AppEntry]
    let calc: CalcResult?
    let color: ColorValue?
    /// Only the empty query pins favorites — a category shows its sections without one of its own.
    let pinsFavorites: Bool
    let pinnedFavorites: [FavoritesStore.Item]
    /// The join card's meeting; nil unless one is due and the field is empty.
    let meeting: MeetingEvent?
    /// How many follow the favorites as Meetings; zero unless the field is empty.
    let meetingCount: Int
    /// How many follow the meetings as Suggestions; zero unless the field is empty.
    let suggestionCount: Int
    let matchCount: Int
    let files: [FileSearchResult]
    /// The `Use "…" with` section, below every result; empty unless something is typed.
    let fallbacks: [(fallback: Fallback, entry: AppEntry)]
    let rows: [LauncherScreen.Row]

    @MainActor
    init(
        appIndex: AppIndex, favorites: FavoritesStore, visibility: VisibilityStore,
        currencyRates: CurrencyRateStore, core: AppCore, vm: PaletteState, meeting: MeetingEvent?
    ) {
        // Listed even when hidden from search: the shortcut that opened it must still be answered.
        let pinned = vm.argumentEntryID.flatMap(core.customCommands.command(entryID:))
            .map(AppEntry.init).flatMap { $0.name == vm.query ? $0 : nil }
        let ordered =
            pinned.map { AppIndex.Results(entries: [$0], matchCount: 1) }
            ?? appIndex.orderedResults(
                query: vm.query, visibility: visibility, favorites: favorites, hotKeys: core.hotKeys)
        var results = ordered.entries
        var matchCount = ordered.matchCount
        // A typed web address leads: nothing the index holds answers it better.
        if pinned == nil, let browser = CommandCatalog.openInBrowser(for: vm.query),
            visibility.isVisible(browser)
        {
            results.insert(browser, at: 0)
            matchCount += 1
        }
        // No card over a pinned row: its fields hang off the selection, which must start on it.
        let calc =
            pinned == nil
            ? CalcMemo.evaluate(vm.query, rates: currencyRates.rates, format: core.calcNumberFormat) : nil
        // After the calculator: `#FF5733` is never arithmetic, so the two can't both answer.
        let color = calc == nil && pinned == nil ? ColorValue.parse(vm.query) : nil
        let files = pinned == nil ? core.fileSearchCoordinator.launcherFiles(for: vm.query) : []
        let fallbacks = core.fallbackCoordinator.entries(for: vm.query)
        let pinsFavorites = vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let pinnedFavorites = favorites.orderedItems(
            entries: Array(results.prefix(ordered.favoriteCount)),
            files: pinsFavorites ? core.fileSearchCoordinator.favoriteFiles : [])
        results.removeFirst(ordered.favoriteCount)
        let entries =
            pinnedFavorites.map(LauncherScreen.Row.init) + results.map(LauncherScreen.Row.entry)
            + files.map(LauncherScreen.Row.file)
            + fallbacks.map { LauncherScreen.Row.fallback($0.fallback, $0.entry) }
        // At most one of them leads, so the flat index keeps a single-row offset.
        let meeting = pinsFavorites ? meeting : nil
        self.meeting = meeting
        self.results = results
        self.calc = calc
        self.files = files
        self.fallbacks = fallbacks
        self.color = color
        self.pinsFavorites = pinsFavorites
        self.pinnedFavorites = pinnedFavorites
        self.meetingCount = pinsFavorites ? ordered.meetingCount : 0
        self.suggestionCount = pinsFavorites ? ordered.suggestionCount : 0
        self.matchCount = matchCount
        if let calc {
            self.rows = [.calc(calc)] + entries
        } else if let color {
            self.rows = [.color(color)] + entries
        } else if let meeting {
            self.rows = [.meeting(meeting)] + entries
        } else {
            self.rows = entries
        }
    }
}

/// Reuses the launcher's results until an input they read changes; Observation names the inputs.
@MainActor
@Observable
final class LauncherResultsCache {
    /// What Observation can't see: `AppIndex` re-ranks each minute, and the meeting arrives resolved.
    private struct Key: Equatable {
        let minute: Int
        let meeting: MeetingEvent?
    }

    /// Read on every lookup, so a view showing the results re-renders when they go stale.
    private var revision = 0
    @ObservationIgnored private var cached: (key: Key, results: LauncherResults)?

    func results(
        meeting: MeetingEvent?, now: Date = Date(), compute: () -> LauncherResults
    ) -> LauncherResults {
        _ = revision
        let key = Key(minute: Int(now.timeIntervalSince1970 / 60), meeting: meeting)
        if let cached, cached.key == key { return cached.results }
        let results = Signposts.interval("Launcher results") {
            withObservationTracking(compute, onChange: { [weak self] in
                // Every store the launcher reads is main-actor isolated, so its willSet runs here.
                MainActor.assumeIsolated { self?.invalidate() }
            })
        }
        cached = (key, results)
        return results
    }

    private func invalidate() {
        cached = nil
        revision += 1
    }
}
