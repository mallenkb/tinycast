import AppKit
import Foundation

enum ExtensionSessionState: Equatable {
    case idle
    case launching
    case rendered(RenderTree)
    case failed(String)
    case needsPreferences(String)
    /// A no-view command that ran to completion.
    case finished
}

/// Owns the installed set, the runtime and the running command.
@MainActor
@Observable
final class ExtensionManager: ExtensionRuntimeDelegate, ExtensionHostContext {
    private(set) var installed: [InstalledExtension] = []
    private(set) var menuBars: ExtensionMenuBarManager?
    private(set) var state: ExtensionSessionState = .idle
    private(set) var running: ExtensionCommandRef?
    /// The command waits on a browser sign-in; resetting the palette now would end it.
    var isSigningIn: Bool { bridge.isSigningIn }
    /// Toasts the running command asked for, newest last.
    private(set) var toasts: [ExtensionToast] = []
    /// Depth of the extension's own navigation stack; >1 means Escape should pop rather than close.
    private(set) var navigationDepth = 1
    /// Each search-bar dropdown's choice, keyed by node so a pushed screen keeps its own.
    private(set) var accessoryValues: [Int: String] = [:]

    /// Off means nothing scanned, published or held: the feature costs an unused stored property.
    private(set) var isEnabled = false
    /// Whether the commands reach the launcher at all; independent of `isEnabled`.
    private(set) var showsInLauncher = true

    let storage: ExtensionStorage
    /// Extension-scoped state the launcher and Settings read through here, like `storage`.
    let appearances = ExtensionAppearanceStore(defaults: AppPaths.preferences)
    let commandMetadata = ExtensionCommandMetadataStore(
        fileURL: ExtensionCatalog.commandMetadataFile())
    let processGrants = ExtensionProcessGrantStore(fileURL: ExtensionCatalog.processGrantsFile())
    @ObservationIgnored private(set) lazy var library = ExtensionLibrary(
        manager: self, processGrants: processGrants)
    @ObservationIgnored private lazy var scheduler = ExtensionBackgroundScheduler(
        manager: self, runtime: runtime, commandMetadata: commandMetadata)
    @ObservationIgnored private let runtime: ExtensionRuntime
    @ObservationIgnored private let bridge: ExtensionHostBridge
    @ObservationIgnored private weak var appIndex: AppIndex?
    @ObservationIgnored private weak var coordinator: ExtensionCoordinator?

    /// The entry ids an uninstall invalidated, so another feature can drop what it keyed to them.
    @ObservationIgnored var onDidUninstall: (([String]) -> Void)?

    @ObservationIgnored private var sessionID: String?
    /// One consent question at a time; a second asker is refused rather than queued.
    @ObservationIgnored private var isAskingProcessConsent = false
    @ObservationIgnored private var nextToastID = 1
    @ObservationIgnored private var searchState = ExtensionSearchState()

    init() {
        storage = ExtensionStorage(directory: ExtensionCatalog.storageDirectory())
        bridge = ExtensionHostBridge()
        runtime = ExtensionRuntime(hostAPI: bridge)
        bridge.context = self
    }

    /// Wires collaborators only; the coordinator decides whether anything scans.
    func start(appIndex: AppIndex, coordinator: ExtensionCoordinator) {
        self.appIndex = appIndex
        self.coordinator = coordinator
        library.start(coordinator: coordinator)
        runtime.setDelegate(self)
        // Not gated on `isEnabled`: a stranded workspace is ours whether or not the feature is on.
        let temp = FileManager.default.temporaryDirectory
        Task.detached(priority: .utility) { ExtensionCleanup.sweepWorkspaces(in: temp) }
    }

    // MARK: - The switches

    /// Idempotent both ways, so launch and the switch are the same call.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard enabled else {
            menuBars?.stop()
            menuBars = nil
            await stop()
            scheduler.cancel()
            installed = []
            appIndex?.setExtensionCommands([])
            return
        }
        if let coordinator {
            menuBars = ExtensionMenuBarManager(
                storage: storage,
                commandMetadata: commandMetadata,
                supportDirectory: ExtensionCatalog.supportRoot(),
                makeExecution: { [weak self, weak coordinator] owner, command, type in
                    guard let self, let coordinator else { return nil }
                    let host = ExtensionMenuBarHost(
                        owner: owner, command: command, launchType: type, storage: self.storage,
                        manager: self, coordinator: coordinator)
                    let bridge = self.bridge.scoped(to: host)
                    return .init(
                        runtime: ExtensionRuntime(
                            hostAPI: bridge,
                            priority: type == .background ? .utility : .userInitiated),
                        stop: {
                            bridge.context = nil
                        }, enableInteraction: { host.enableInteraction() })
                },
                onError: { [weak coordinator] message, owner, needsPreferences in
                    coordinator?.showHUD(message)
                    if needsPreferences { coordinator?.showExtensionSettings(for: owner) }
                })
        }
        await refresh()
        scheduler.ensureLoop()
    }

    func setShowsInLauncher(_ shows: Bool) {
        guard shows != showsInLauncher else { return }
        showsInLauncher = shows
        publishLauncherEntries()
    }

    // MARK: - Installed set

    func refresh() async {
        guard isEnabled else { return }
        let found = await Task.detached(priority: .utility) { ExtensionCatalog.scan() }.value
        guard isEnabled else { return }
        if found != installed {
            installed = found
            publishLauncherEntries()
            scheduler.restart()
        }
        menuBars?.synchronize(found)
    }

    func extensionNamed(_ name: String) -> InstalledExtension? {
        installed.first { $0.manifest.name == name }
    }

    /// Built from the installed set, not `AppIndex`: a shortcut can fire before a row ever exists.
    func launcherEntry(forEntryID entryID: String) -> AppEntry? {
        guard let reference = ExtensionCommandRef(entryID: entryID),
            let owner = extensionNamed(reference.extensionName),
            let command = owner.command(named: reference.commandName)
        else { return nil }
        return entry(for: command, in: owner)
    }

    func publishLauncherEntries() {
        guard isEnabled, showsInLauncher else {
            appIndex?.setExtensionCommands([])
            return
        }
        let entries =
            installed
            .flatMap { owner in owner.manifest.commands.map { entry(for: $0, in: owner) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        appIndex?.setExtensionCommands(entries)
    }

    /// One command as a row; a chosen appearance replaces the shipped icon for all of them.
    private func entry(for command: ExtensionCommand, in owner: InstalledExtension) -> AppEntry {
        let appearance = appearances.appearance(for: owner.manifest.name)
        let reference = ExtensionCommandRef(
            extensionName: owner.manifest.name, commandName: command.name)
        let metadata = commandMetadata.metadata(
            extension: owner.manifest.name, command: command.name)
        // A dropped `interval` retires the dot with it, however stale the stored flag is.
        let schedulable = ExtensionRefreshPolicy.isSchedulable(
            mode: command.mode, interval: command.interval)
        return AppEntry(
            id: reference.entryID,
            name: command.title,
            url: owner.directory,
            bundleID: nil,
            kind: .extensionCommand,
            subtitle: ExtensionRefreshPolicy.displaySubtitle(
                manifest: command.subtitle, override: metadata.subtitle, ownerTitle: owner.title),
            backgroundRefresh: ExtensionRefreshPolicy.indicator(
                schedulable: schedulable, backgroundEnabled: metadata.backgroundEnabled,
                lastError: metadata.lastError),
            keywords: command.keywords,
            iconOverride: icon(for: command, in: owner, appearance: appearance),
            ownerName: owner.title, installedAt: owner.installedAt)
    }

    /// Persist and re-publish, so rows change under the user rather than on the next scan.
    func setAppearance(_ appearance: ExtensionAppearance?, for extensionName: String) {
        appearances.set(appearance, for: extensionName)
        publishLauncherEntries()
    }

    private func icon(
        for command: ExtensionCommand, in owner: InstalledExtension,
        appearance: ExtensionAppearance?
    ) -> EntryIcon {
        if let appearance {
            return .tintedSymbol(name: appearance.symbol, tint: appearance.tint.symbolTint)
        }
        guard let path = commandIconPath(command, in: owner) ?? owner.iconPath else {
            return .symbol("puzzlepiece.extension")
        }
        return .artwork(path: path, extent: ExtensionIconCache.extent)
    }

    private func commandIconPath(_ command: ExtensionCommand, in owner: InstalledExtension) -> String? {
        guard let icon = command.icon else { return nil }
        let candidate = owner.directory.appendingPathComponent("assets").appendingPathComponent(icon)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    // MARK: - Running a command

    func resolve(_ entry: AppEntry) -> (InstalledExtension, ExtensionCommand)? {
        guard let reference = ExtensionCommandRef(entryID: entry.id),
            let owner = extensionNamed(reference.extensionName),
            let command = owner.command(named: reference.commandName)
        else { return nil }
        return (owner, command)
    }

    /// A deep link names owner/extension/command; the owner is a hint, the slug decides.
    func resolve(_ link: ExtensionDeepLink) -> (InstalledExtension, ExtensionCommand)? {
        let candidates = installed.filter { link.matches(manifestName: $0.manifest.name) }
        guard
            let owner = link.extensionCandidates.lazy.compactMap({ want in
                candidates.first { $0.manifest.name.lowercased() == want.lowercased() }
            }).first ?? candidates.first,
            let command = owner.manifest.commands.first(where: {
                $0.name.lowercased() == link.commandName.lowercased()
            })
        else { return nil }
        return (owner, command)
    }

    func run(_ entry: AppEntry, arguments: [String: String] = [:]) async {
        guard let (owner, command) = resolve(entry) else {
            state = .failed(ExtensionLaunchError.unknownCommand(entry.id).localizedDescription)
            return
        }
        await run(owner, command: command, arguments: arguments)
    }

    func run(
        _ owner: InstalledExtension, command: ExtensionCommand, arguments: [String: String] = [:],
        fallbackText: String? = nil, launchType: ExtensionLaunchType = .userInitiated,
        launchContext: [String: RenderValue] = [:]
    ) async {
        guard isEnabled else { return }
        if command.mode == .menuBar || (command.mode == .noView && launchType == .background) {
            menuBars?.run(
                owner, command: command, arguments: arguments, type: launchType, context: launchContext)
            return
        }
        await stop()
        guard isEnabled else { return }
        let schemas = owner.manifest.preferences + command.preferences
        let missing = storage.missingRequiredPreferences(
            extension: owner.manifest.name, schemas: schemas)
        guard missing.isEmpty else {
            running = ExtensionCommandRef(
                extensionName: owner.manifest.name, commandName: command.name)
            state = .needsPreferences(
                ExtensionLaunchError.missingPreferences(missing).localizedDescription)
            return
        }
        guard let bundle = owner.bundleURL(for: command) else {
            running = ExtensionCommandRef(
                extensionName: owner.manifest.name, commandName: command.name)
            state = .failed(ExtensionLaunchError.notBuilt(command.title).localizedDescription)
            return
        }

        running = ExtensionCommandRef(extensionName: owner.manifest.name, commandName: command.name)
        navigationDepth = 1
        state = .launching

        // The runtime holds one context: a background tick in flight yields to the manual run.
        await scheduler.abort()

        // Raycast activates the schedule on first manual open; the run itself is the first refresh.
        if ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval) {
            commandMetadata.activateBackgroundRefresh(
                extension: owner.manifest.name, command: command.name, now: Date())
            scheduler.restart()
        }

        let supportPath = ExtensionCatalog.supportPath(for: owner.manifest.name)
        try? FileManager.default.createDirectory(at: supportPath, withIntermediateDirectories: true)

        do {
            // No-op while a context is already up; after `stop()` this builds a fresh one.
            try await runtime.boot(config: .current(supportDirectory: supportPath))
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        // Reading a few hundred KB of bundle is IO; keep it off the main actor.
        let code = await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: bundle, encoding: .utf8)) ?? ""
        }.value
        guard !code.isEmpty else {
            state = .failed(ExtensionLaunchError.notBuilt(command.title).localizedDescription)
            return
        }

        let session = UUID().uuidString
        sessionID = session
        let context = makeLaunchContext(
            owner: owner, command: command, arguments: arguments, supportPath: supportPath,
            fallbackText: fallbackText,
            launchType: command.mode == .view ? .userInitiated : launchType,
            launchContext: launchContext)

        await runtime.start(
            session: session, code: code, file: bundle, mode: command.mode, context: context)
    }

    func makeLaunchContext(
        owner: InstalledExtension, command: ExtensionCommand, arguments: [String: String],
        supportPath: URL, fallbackText: String? = nil, launchType: ExtensionLaunchType,
        launchContext: [String: RenderValue] = [:]
    ) -> ExtensionLaunchContext {
        let schemas = owner.manifest.preferences + command.preferences
        return ExtensionLaunchContext(
            extensionName: owner.manifest.name,
            extensionTitle: owner.title,
            commandName: command.name,
            commandMode: command.mode,
            assetsPath: owner.assetsPath,
            supportPath: supportPath.path,
            preferences: storage.resolvedPreferences(
                extension: owner.manifest.name, schemas: schemas),
            caches: storage.caches(extension: owner.manifest.name),
            arguments: command.completeArguments(arguments),
            fallbackText: fallbackText,
            launchType: launchType,
            isDarkAppearance: NSApp.effectiveAppearance.isDark,
            launchContext: launchContext)
    }

    func stop() async {
        guard let sessionID else {
            resetSessionState()
            return
        }
        self.sessionID = nil
        await runtime.stop(session: sessionID)
        // Discard the context outright, so nothing left behind reaches the next run.
        runtime.shutdown()
        storage.flush()
        resetSessionState()
    }

    /// Everything an uninstall must end first: its menu item, its command, its refresh.
    func release(extensionName name: String) async {
        menuBars?.remove(extensionName: name)
        if running?.extensionName == name { await stop() }
        if scheduler.activeRef?.extensionName == name { await scheduler.abort() }
    }

    private func resetSessionState() {
        state = .idle
        running = nil
        toasts = []
        navigationDepth = 1
        accessoryValues = [:]
        searchState = ExtensionSearchState()
    }

    // MARK: - Background refresh

    func backgroundInfo(extension name: String, command: String) -> ExtensionCommandMetadata {
        commandMetadata.metadata(extension: name, command: command)
    }

    func setBackgroundEnabled(_ enabled: Bool, extension name: String, command: String) {
        commandMetadata.setBackgroundEnabled(enabled, extension: name, command: command)
        if !enabled { commandMetadata.clearBackgroundError(extension: name, command: command) }
        publishLauncherEntries()
        scheduler.restart()
    }

    func menuBarIsEnabled(_ reference: ExtensionCommandRef) -> Bool {
        commandMetadata.metadata(
            extension: reference.extensionName, command: reference.commandName
        ).menuBarEnabled
    }

    /// Switching one on runs it: the item it draws is whatever that run renders.
    func setMenuBarEnabled(_ enabled: Bool, reference: ExtensionCommandRef) {
        guard enabled else {
            menuBars?.disable(reference.entryID)
            return
        }
        guard let owner = extensionNamed(reference.extensionName),
            let command = owner.command(named: reference.commandName)
        else { return }
        menuBars?.run(owner, command: command)
    }

    func isBackgroundSchedulable(for entry: AppEntry) -> Bool {
        guard let (_, command) = resolve(entry) else { return false }
        return ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval)
    }

    func isBackgroundEnabled(for entry: AppEntry) -> Bool {
        guard let reference = ExtensionCommandRef(entryID: entry.id) else { return false }
        return commandMetadata.metadata(
            extension: reference.extensionName, command: reference.commandName
        ).backgroundEnabled
    }

    func toggleBackgroundRefresh(for entry: AppEntry) {
        guard let reference = ExtensionCommandRef(entryID: entry.id),
            isBackgroundSchedulable(for: entry)
        else { return }
        let enabled = commandMetadata.metadata(
            extension: reference.extensionName, command: reference.commandName
        ).backgroundEnabled
        setBackgroundEnabled(!enabled, extension: reference.extensionName, command: reference.commandName)
    }

    /// One headless run right now, without touching the enable flag or the palette.
    func refreshNow(_ entry: AppEntry) {
        guard let (owner, command) = resolve(entry),
            ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval)
        else { return }
        let reference = ExtensionCommandRef(
            extensionName: owner.manifest.name, commandName: command.name)
        if let refusal = ExtensionRefreshPolicy.refreshNowRefusal(
            foregroundRunning: running != nil,
            refreshingCommand: scheduler.activeRef?.entryID,
            command: reference.entryID)
        {
            coordinator?.showHUD(refusal)
            return
        }
        Task { [weak self] in
            await self?.scheduler.run(owner, command: command)
            self?.scheduler.restart()
        }
    }

    // MARK: - Events from the palette

    func dispatch(handler: String, arguments: [Any] = []) {
        guard let sessionID else { return }
        let payload = ExtensionRuntime.jsonString(from: arguments)
        Task { await runtime.dispatch(session: sessionID, handler: handler, payload: payload) }
    }

    func searchQueryChanged(to query: String) {
        searchState.queryChanged(to: query)
    }

    func landingSelection(for query: String, rowCount: Int) -> Int {
        searchState.landingSelection(for: query, rowCount: rowCount)
    }

    // MARK: - Search-bar dropdowns

    /// What the dropdown shows: the extension's own `value` when it controls one, else the pick.
    func accessorySelection(_ accessory: ExtensionSearchAccessory) -> String? {
        accessory.controlledValue ?? accessoryValues[accessory.nodeID]
    }

    /// A pick persists where the dropdown asked it to, then tells the extension.
    func chooseAccessorySelection(_ accessory: ExtensionSearchAccessory, value: String) {
        accessoryValues[accessory.nodeID] = value
        if let key = accessory.storageKey, let name = running?.extensionName {
            storage.setAccessoryValue(extension: name, key: key, value: value)
        }
        guard let handler = accessory.onChange else { return }
        dispatch(handler: handler, arguments: [value])
    }

    /// Raycast reports a dropdown's opening choice through `onChange`, and an extension that
    /// filters its rows by that value draws nothing until it arrives. A controlled one needs none.
    private func seedSearchBarAccessory(in tree: RenderTree) {
        guard
            let accessory = ExtensionSearchAccessory(
                node: tree.activeRoot?.node("searchBarAccessory")),
            accessory.controlledValue == nil, accessoryValues[accessory.nodeID] == nil,
            let value = accessory.initialValue(stored: storedAccessoryValue(accessory))
        else { return }
        accessoryValues[accessory.nodeID] = value
        guard let handler = accessory.onChange else { return }
        dispatch(handler: handler, arguments: [value])
    }

    private func storedAccessoryValue(_ accessory: ExtensionSearchAccessory) -> String? {
        guard let key = accessory.storageKey, let name = running?.extensionName else { return nil }
        return storage.accessoryValue(extension: name, key: key)
    }

    /// Pops the extension's stack; false when there is nothing to pop and the palette should close.
    func popNavigation() async -> Bool {
        guard let sessionID, navigationDepth > 1 else { return false }
        return await runtime.popNavigation(session: sessionID)
    }

    func runToastAction(token: String) {
        Task { await runtime.runToastAction(token: token) }
    }

    // MARK: - ExtensionRuntimeDelegate

    func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree) {
        guard session == sessionID else { return }
        if let current = coordinator?.extensionSearch,
            let search = searchState.navigate(to: tree.depth, current: current)
        {
            coordinator?.showExtensionSearch(search, tree: tree)
        }
        state = .rendered(tree)
        navigationDepth = tree.depth
        seedSearchBarAccessory(in: tree)
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String) {
        if scheduler.runFailed(session: session, message: message) { return }
        guard session == sessionID else { return }
        state = .failed(message)
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth depth: Int) {
        guard session == sessionID else { return }
        navigationDepth = depth
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void) {
        if scheduler.runFinished(session: session) { return }
        guard session == sessionID else { return }
        // A no-view command is done: the palette is already closing, so just release the session.
        state = .finished
        Task { await stop() }
    }

    func runtime(_ runtime: ExtensionRuntime, log level: String, message: String) {
        #if DEBUG
            print("[extension \(level)] \(message)")
        #endif
    }

    // MARK: - ExtensionHostContext

    var activeExtensionName: String? { scheduler.activeRef?.extensionName ?? running?.extensionName }
    var activeLaunchType: ExtensionLaunchType {
        scheduler.sessionID != nil ? .background : .userInitiated
    }
    var pasteTarget: NSRunningApplication? { coordinator?.pasteTarget }
    var applicationURLs: [URL] { coordinator?.applicationURLs ?? [] }

    func closeMainWindow(clearRootSearch: Bool) {
        coordinator?.closeMainWindow()
    }

    func reopenPalette() {
        coordinator?.reopenPalette(hasRunningCommand: running != nil)
    }

    func popToRoot() {
        coordinator?.popExtensionToRoot()
    }

    func clearSearchBar() {
        coordinator?.clearSearchBar()
    }

    func openPreferences(scope: String) {
        guard let running, let owner = extensionNamed(running.extensionName) else { return }
        coordinator?.showExtensionSettings(for: owner)
    }

    /// The running command's row metadata; a missing key leaves the subtitle alone.
    func updateCommandMetadata(subtitle: String?) {
        guard let reference = scheduler.activeRef ?? running else { return }
        updateCommandMetadata(subtitle: subtitle, for: reference)
    }

    func updateCommandMetadata(subtitle: String?, for reference: ExtensionCommandRef) {
        commandMetadata.setSubtitle(
            subtitle, extension: reference.extensionName, command: reference.commandName)
        publishLauncherEntries()
    }

    func present(toast: ExtensionToast) -> Int {
        var stamped = toast
        stamped.id = nextToastID
        nextToastID += 1
        // A no-view command's toast has no palette to appear in, so show a HUD.
        guard coordinator?.isPaletteVisible == true else {
            coordinator?.showHUD(
                [toast.title, toast.message].compactMap { $0 }.joined(separator: " — "))
            return stamped.id
        }
        toasts = [stamped]
        // Non-animated toasts self-dismiss; an animated one stays until the command hides it.
        if stamped.style != .animated { scheduleToastDismissal(id: stamped.id) }
        return stamped.id
    }

    func update(toast id: Int, with toast: ExtensionToast) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        var stamped = toast
        stamped.id = id
        toasts[index] = stamped
        if stamped.style != .animated { scheduleToastDismissal(id: id) }
    }

    func hide(toast id: Int) {
        toasts.removeAll { $0.id == id }
    }

    private func scheduleToastDismissal(id: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.hide(toast: id)
        }
    }

    func showHUD(_ text: String) {
        coordinator?.showHUD(text)
    }

    func confirmAlert(_ alert: ExtensionAlert) async -> Bool {
        await coordinator?.confirmExtensionAlert(alert) ?? false
    }

    var processesGranted: Bool {
        activeExtensionName.map(processGrants.contains) ?? false
    }

    func askProcessConsent() async -> Bool {
        guard let name = activeExtensionName else { return false }
        return await askProcessConsent(for: name)
    }

    /// Shared with the menu lane, so both ask the one question and remember it in one place.
    func askProcessConsent(for name: String) async -> Bool {
        guard !isAskingProcessConsent, let owner = extensionNamed(name), let coordinator else {
            return false
        }
        isAskingProcessConsent = true
        defer { isAskingProcessConsent = false }
        switch await coordinator.askProcessConsent(title: owner.title) {
        case .always:
            processGrants.grant(name)
            return true
        case .once: return true
        case .deny: return false
        }
    }

    func openWithPicker(path: String) async {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: target)
        guard candidates.count > 1 else {
            NSWorkspace.shared.open(target)
            return
        }
        let choices = Array(candidates.prefix(4))
        guard let coordinator,
            let chosen = await coordinator.chooseApplication(choices, toOpen: target)
        else { return }
        NSWorkspace.shared.open(
            [target], withApplicationAt: chosen,
            configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// `launchCommand` from a running command: same extension unless it names another.
    func launch(
        command name: String, extensionName: String?, arguments: [String: String],
        fallbackText: String?, launchType: ExtensionLaunchType, launchContext: [String: RenderValue]
    ) throws {
        let owningName = extensionName ?? activeExtensionName
        guard let owningName, let owner = extensionNamed(owningName),
            let command = owner.command(named: name)
        else { throw ExtensionLaunchError.unknownCommand(name) }
        guard isEnabled else { throw ExtensionLaunchError.unsupported("Extensions are disabled.") }
        guard launchType != .background || command.mode != .view else {
            throw ExtensionLaunchError.unsupported("A view command cannot run in the background.")
        }
        coordinator?.runExtensionCommand(
            entry(for: command, in: owner), arguments: arguments, fallbackText: fallbackText,
            launchType: launchType, launchContext: launchContext)
    }

    func launch(_ link: ExtensionDeepLink) throws {
        guard let (owner, command) = resolve(link) else {
            throw ExtensionLaunchError.unknownCommand(link.commandName)
        }
        coordinator?.runExtensionCommand(
            entry(for: command, in: owner), arguments: link.arguments,
            fallbackText: link.fallbackText, launchType: link.launchType,
            launchContext: link.launchContext)
    }
}
