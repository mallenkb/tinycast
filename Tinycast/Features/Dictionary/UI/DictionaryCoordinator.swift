import Foundation

/// The dictionary's action surface: open the screen on a term, and act on the entry it shows.
@MainActor
@Observable
final class DictionaryCoordinator {
    private let paletteCoordinator: PaletteCoordinator

    @ObservationIgnored private(set) lazy var applicationURL = DictionaryService.applicationURL
    let pronunciation: DictionaryPronunciationSession
    let session: DictionarySession
    private let settings: AppSettings

    var preferredSourceID: String { settings.dictionaryPreferredSource }

    init(
        paletteCoordinator: PaletteCoordinator, session: DictionarySession, settings: AppSettings,
        pronunciation: DictionaryPronunciationSession
    ) {
        self.paletteCoordinator = paletteCoordinator
        self.session = session
        self.pronunciation = pronunciation
        self.settings = settings
    }

    var orderedSources: [DictionaryEntry.Source] {
        let recent = [preferredSourceID] + settings.dictionaryRecentSources
        return session.sources.enumerated().sorted { left, right in
            let leftRank = recent.firstIndex(of: left.element.id) ?? recent.count
            let rightRank = recent.firstIndex(of: right.element.id) ?? recent.count
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
    }

    func selectSource(_ id: String) {
        if !id.isEmpty {
            let recent = settings.dictionaryRecentSources.filter { $0 != id }
            settings.dictionaryRecentSources = Array(([id] + recent).prefix(12))
        }
        settings.dictionaryPreferredSource = id
        session.configure(preferredSourceID: id)
    }

    func prepare(query: String) {
        session.configure(preferredSourceID: preferredSourceID)
        session.lookUp(query)
    }

    func reset() {
        pronunciation.reset()
        session.reset()
    }

    /// `term` is the fallback row's query, so the screen opens already showing its entry.
    func show(term: String = "") {
        paletteCoordinator.togglePalette(mode: .dictionary, seeding: term.isEmpty ? nil : term)
    }

    func copy(_ entry: DictionaryEntry) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(entry.text)
    }

    /// Dictionary.app shows the full entry, with every dictionary the reader has enabled.
    func openInDictionary(_ entry: DictionaryEntry) {
        guard let term = entry.term.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
            let url = URL(string: "dict://" + term)
        else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.open(url)
    }
}
