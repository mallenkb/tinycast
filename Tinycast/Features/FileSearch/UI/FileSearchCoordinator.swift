import AppKit

@MainActor
final class FileSearchCoordinator {
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let session: FileSearchSession
    private let indexer: FileIndexer
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let windowController: PaletteWindowController
    private var sharePicker: NSSharingServicePicker?
    private unowned let core: AppCore
    private var imageScope: UInt64?
    private var imageSearchEnabled = false

    init(
        settings: AppSettings, appIndex: AppIndex, session: FileSearchSession,
        indexer: FileIndexer, palette: PaletteState, paletteCoordinator: PaletteCoordinator,
        windowController: PaletteWindowController, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.session = session
        self.indexer = indexer
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.windowController = windowController
        self.core = core
        indexer.onIndexChanged = { [weak self] in
            self?.applyImageContent()
            self?.core.fileImageContentIndexer.schedule()
        }
        indexer.onRecentChanged = { [weak self] in
            self?.session.refreshRecent()
            self?.core.fileImageContentIndexer.schedule()
        }
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.searchFiles], settings.fileSearchEnabled)
        indexer.setEnabled(settings.fileSearchEnabled)
        applyImageContent()
        guard !settings.fileSearchEnabled else { return }
        session.cancel()
        if palette.mode == .fileSearch { palette.prepare(mode: .launcher) }
    }

    func applyPolicy() {
        let policy = FileSearchPolicy(
            scopes: settings.fileSearchScopes,
            ignorePatterns: settings.fileSearchEffectiveIgnorePatterns,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        if imageScope != policy.fingerprint {
            core.fileImageContentIndexer.setEnabled(false, purging: imageScope != nil || policy.roots.isEmpty)
            imageScope = policy.fingerprint
        }
        indexer.apply(policy)
        applyImageContent()
    }

    func applyImageContent() {
        let permitted = settings.fileSearchEnabled && settings.fileSearchImageContentEnabled
            && Permissions.hasFullDiskAccess()
        let enabled = permitted && indexer.hasIndex && indexer.index.snapshot?.fingerprint == imageScope
        core.fileImageContentIndexer.setEnabled(enabled, purging: !permitted)
        let clearingResults = imageSearchEnabled && !enabled
        imageSearchEnabled = enabled
        session.refresh(clearingResults: clearingResults)
    }

    var showsFilesInLauncher: Bool {
        settings.fileSearchEnabled && settings.fileSearchShowInLauncher
    }

    var favoriteFiles: [FileSearchResult] {
        guard settings.fileSearchEnabled else { return [] }
        return core.favorites.files(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Borrows the screen's session, so Search Files then opens on the request already answered.
    func searchFromLauncher(_ query: String) {
        guard showsFilesInLauncher, FileSearchQuery.answersLauncher(query) else {
            session.cancel()
            return
        }
        indexer.refreshAccess()
        session.search(query)
        if let description = core.searchIntentCoordinator.launcherFileDescription(for: query) {
            session.applyDescription(description, for: query, filter: .all)
        }
    }

    /// Checks the switch before reading the session, so with it off the launcher observes nothing.
    func launcherFiles(for query: String) -> [FileSearchResult] {
        guard settings.fileSearchEnabled, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }
        if core.searchIntentCoordinator.launcherFileDescription(for: query) != nil
            || SearchDescription(query, now: Date(), calendar: .current) != nil
        {
            return showsFilesInLauncher ? session.describedResults(for: query) : []
        }
        let results = showsFilesInLauncher && FileSearchQuery.answersLauncher(query) ? session.results : []
        return FileSearchQuery.launcherResults(query, favorites: favoriteFiles, indexed: results)
    }

    func applyLauncherFiles() {
        guard palette.mode == .launcher else { return }
        searchFromLauncher(palette.query)
    }

    func rebuildIndex() {
        indexer.rebuild()
    }

    func openFullDiskAccessSettings() {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Permissions.openFullDiskAccessSettings()
    }

    /// `query` is the fallback row's: the screen opens already narrowed to what was typed.
    func show(query: String = "") {
        guard settings.fileSearchEnabled else { return }
        indexer.refreshAccess()
        paletteCoordinator.togglePalette(mode: .fileSearch, seeding: query.isEmpty ? nil : query)
    }

    func open(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    result.url, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                await core.showNotice(
                    title: String(localized: "Couldn’t Open \(result.name)"),
                    message: error.localizedDescription,
                    symbol: result.isDirectory ? "folder" : "doc", tone: .danger)
            }
        }
    }

    func showInFinder(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(result.url)
    }

    /// macOS's own share sheet, anchored to the palette's trailing edge so the row stays beside it.
    func share(_ result: FileSearchResult) {
        guard let provider = NSItemProvider(contentsOf: result.url),
            let anchor = paletteCoordinator.anchorView
        else { return }
        let picker = NSSharingServicePicker(items: [provider])
        sharePicker = picker
        picker.show(
            relativeTo: CGRect(
                x: anchor.bounds.maxX, y: anchor.bounds.midY, width: 0, height: 0),
            of: anchor, preferredEdge: .maxX)
    }

    func copyPath(_ result: FileSearchResult) {
        Paster.copyPlainText(result.id)
        core.showMessage(String(localized: "Copied path"))
    }

    func copyName(_ result: FileSearchResult) {
        Paster.copyPlainText(result.name)
        core.showMessage(String(localized: "Copied name"))
    }

    /// The file itself rather than its path, so Finder and Mail paste a copy of it.
    func copyFile(_ result: FileSearchResult) {
        PasteboardFiles.write(result.url, to: .general)
        core.showMessage(String(localized: "Copied file"))
    }

    /// Into whichever app the palette was summoned over, which is what the row's title names.
    func pasteFile(_ result: FileSearchResult) {
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.pasteFile(result.url, previousApp: previous)
    }

    func trash(_ result: FileSearchResult) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.trashItem(at: result.url, resultingItemURL: nil)
                }.value
                session.remove(result)
                core.showMessage(String(localized: "Moved to Trash"))
            } catch {
                await core.showNotice(
                    title: String(localized: "Couldn’t Move \(result.name) to Trash"),
                    message: error.localizedDescription,
                    symbol: "trash", tone: .danger)
            }
        }
    }
}
