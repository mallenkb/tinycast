import Foundation

@MainActor
@Observable
final class SearchIntentCoordinator {
    private(set) var isResolving = false
    private var describedLauncher: (query: String, description: SearchDescription)?
    @ObservationIgnored private unowned let core: AppCore
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var active: Task<SearchIntent?, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var resolved: (request: Request, intent: SearchIntent)?

    private struct Request: Equatable {
        let rawQuery: String
        let context: SearchIntent.Context

        var query: String { rawQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    init(core: AppCore) { self.core = core }

    func update() {
        guard let next = currentRequest() else {
            let palette = core.palette
            cancel(resumingFileSearch: palette.isVisible && (palette.mode == .launcher || palette.mode == .fileSearch))
            return
        }
        guard next != request else { return }
        active?.cancel()
        deadline?.cancel()
        deadline = nil
        pending = nil
        request = next

        let carried = resolved.flatMap { previous in
            previous.request.context == .launcher && previous.request.rawQuery == next.rawQuery
                && previous.intent.destination.rawValue == next.context.rawValue ? previous.intent : nil
        }
        resolved = nil
        clearInterpretation(keepingFileDescription: carried?.destination == .files)
        if let carried {
            isResolving = false
            apply(carried, to: next)
            return
        }
        guard next.context != .launcher
            || !core.appIndex.hasExactSearchMatch(next.rawQuery, visibility: core.visibility)
        else {
            isResolving = false
            return
        }
        if next.context == .launcher, core.settings.clipboardEnabled,
            SearchIntentPolicy.isDirectClipboardLinkQuery(next.query),
            let direct = SearchIntentPolicy.intent(
                destination: .clipboard, query: next.query, kind: "links", website: nil,
                time: nil, websites: core.clipboardStore.knownWebsiteHosts, now: Date(), calendar: .current)
        {
            isResolving = false
            apply(direct, to: next)
            return
        }
        if next.context == .files || (next.context == .launcher && core.settings.fileSearchEnabled) {
            switch SearchFileQuery.parse(next.query, now: Date(), calendar: .current) {
            case .filters(let filters) where next.context == .launcher
                && filters.clauses.contains(where: { $0.field != .category }):
                isResolving = false
                let direct = SearchIntent(
                    destination: .files, description: SearchDescription(fileConstraints: filters), commandID: nil)
                apply(direct, to: next)
                return
            case .filters where next.context == .files, .issue where next.context == .files:
                isResolving = false
                return
            default:
                break
            }
        }
        guard SearchIntentPolicy.allowsInterpretation(next.query) else {
            isResolving = false
            return
        }
        pending = next
        isResolving = true
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, request == next else { return }
            pending = nil
            active?.cancel()
            isResolving = false
            deadline = nil
        }
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    func cancel(resumingFileSearch: Bool = false) {
        guard request != nil else { return }
        request = nil
        pending = nil
        resolved = nil
        active?.cancel()
        deadline?.cancel()
        deadline = nil
        isResolving = false
        clearInterpretation(resumingFileSearch: resumingFileSearch)
    }

    func openSearchResult(_ entryID: String, query: String?) -> Bool {
        guard let query, let resolved, resolved.request.context == .launcher,
            resolved.request == currentRequest(), resolved.request.rawQuery == query,
            core.appIndex.isInterpretedLauncherCommand(entryID, for: query, visibility: core.visibility)
        else { return false }
        switch resolved.intent.destination {
        case .clipboard where entryID == CommandID.clipboardHistory.rawValue:
            guard core.settings.clipboardEnabled else { return false }
            core.paletteCoordinator.togglePalette(mode: .clipboard, seeding: query)
        case .files where entryID == CommandID.searchFiles.rawValue:
            guard core.settings.fileSearchEnabled else { return false }
            core.fileSearchCoordinator.show(query: query)
        default: return false
        }
        update()
        return true
    }

    func launcherFileDescription(for query: String) -> SearchDescription? {
        guard let describedLauncher, describedLauncher.query == query else { return nil }
        return describedLauncher.description
    }

    private func currentRequest() -> Request? {
        let palette = core.palette
        guard palette.isVisible, !palette.isComposing else { return nil }
        let context: SearchIntent.Context
        switch palette.mode {
        case .launcher: context = .launcher
        case .clipboard where core.settings.clipboardEnabled: context = .clipboard
        case .fileSearch where core.settings.fileSearchEnabled: context = .files
        default: return nil
        }
        let request = Request(rawQuery: palette.query, context: context)
        let query = request.query
        guard query.first != "\"", query.first != "“", query.utf8.count <= 2048, query.count <= 512,
            query.split(whereSeparator: \.isWhitespace).count >= 2
        else { return nil }
        return request
    }

    private func clearInterpretation(keepingFileDescription: Bool = false, resumingFileSearch: Bool = true) {
        core.appIndex.setInterpretedCommand(nil, for: "")
        core.clipboardStore.setInterpretedQuery(nil, for: "")
        if !keepingFileDescription { core.fileSearch.clearDescription(resumingSearch: resumingFileSearch) }
        describedLauncher = nil
    }

    private func run() async {
        while let next = pending {
            pending = nil
            let generation = Task<SearchIntent?, Never> { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(450))
                    guard let self, next == self.currentRequest() else { return nil }
                    let commands = next.context == .launcher
                        ? core.appIndex.searchIntentCommands(visibility: core.visibility) : []
                    let websites = next.context != .files && core.settings.clipboardEnabled
                        ? core.clipboardStore.knownWebsiteHosts : []
                    return try await SearchIntentWorker.resolve(SearchIntentRequest(
                        query: next.query, context: next.context, commands: commands,
                        websites: websites, now: Date(), calendar: .current))
                } catch {
                    return nil
                }
            }
            active = generation
            let intent = await generation.value
            active = nil
            guard !generation.isCancelled, let intent, next == request, next == currentRequest() else { continue }
            apply(intent, to: next)
        }
        worker = nil
        deadline?.cancel()
        deadline = nil
        isResolving = false
    }

    private func apply(_ intent: SearchIntent, to request: Request) {
        let query = request.rawQuery
        switch request.context {
        case .launcher:
            guard core.palette.selection == 0, !core.palette.menuOpen else { return }
            let id: String?
            switch intent.destination {
            case .command: id = intent.commandID
            case .clipboard where core.settings.clipboardEnabled: id = CommandID.clipboardHistory.rawValue
            case .files where core.settings.fileSearchEnabled: id = CommandID.searchFiles.rawValue
            default: return
            }
            guard let id, core.appIndex.visibleSearchEntry(id, visibility: core.visibility) != nil,
                !core.appIndex.hasExactSearchMatch(query, visibility: core.visibility)
            else { return }
            core.appIndex.setInterpretedCommand(id, for: query)
            resolved = (request, intent)
            if intent.destination == .files, let description = intent.description {
                describedLauncher = (query, description)
                core.fileSearchCoordinator.searchFromLauncher(query)
            }
        case .clipboard:
            guard intent.destination == .clipboard, let description = intent.description else { return }
            let kind: ClipboardItem.Kind?
            switch description.kind {
            case .images: kind = .image
            case .files, .documents, .video: kind = .file
            case .text, .links: kind = .text
            default: kind = nil
            }
            core.clipboardStore.setInterpretedQuery(
                ClipboardStore.DescriptionQuery(
                    text: description.text, kind: kind, dates: description.dates,
                    alternativeTexts: description.alternativeTexts,
                    linksOnly: description.kind == .links, website: description.website,
                    videosOnly: description.kind == .video),
                for: query)
        case .files:
            guard intent.destination == .files, let description = intent.description else { return }
            let filter = core.palette.fileSearchFilter
            core.fileSearch.search(query, filter: filter)
            core.fileSearch.applyDescription(description, for: query, filter: filter)
        }
    }
}
