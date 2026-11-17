import Foundation

/// Scheduled `no-view` refreshes: one loop doing date math, borrowing the palette's runtime.
@MainActor
final class ExtensionBackgroundScheduler {
    private unowned let manager: ExtensionManager
    private let runtime: ExtensionRuntime
    private let commandMetadata: ExtensionCommandMetadataStore

    private(set) var sessionID: String?
    /// The command a headless run belongs to, while one is in flight.
    private(set) var activeRef: ExtensionCommandRef?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var failure: String?
    private var task: Task<Void, Never>?

    init(
        manager: ExtensionManager, runtime: ExtensionRuntime,
        commandMetadata: ExtensionCommandMetadataStore
    ) {
        self.manager = manager
        self.runtime = runtime
        self.commandMetadata = commandMetadata
    }

    /// Starts the loop once, and only when a command wants it: with nothing enabled there is
    /// no task at all, so an unused schedule costs nothing.
    func ensureLoop() {
        guard manager.isEnabled, task == nil, hasEnabledCommands else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func restart() {
        cancel()
        ensureLoop()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private var hasEnabledCommands: Bool {
        schedulableCommands().contains { owner, command in
            commandMetadata.metadata(extension: owner.manifest.name, command: command.name)
                .backgroundEnabled
        }
    }

    private func loop() async {
        try? await Task.sleep(for: .seconds(5))
        while !Task.isCancelled {
            guard manager.isEnabled else { return }
            await runDueCommands()
            if Task.isCancelled { return }
            // The last schedule going away stops the loop itself; enabling restarts it.
            guard hasEnabledCommands else {
                task = nil
                return
            }
            try? await Task.sleep(for: .seconds(nextDelay()))
        }
    }

    private func schedulableCommands() -> [(InstalledExtension, ExtensionCommand)] {
        manager.installed.flatMap { owner in
            owner.manifest.commands.compactMap { command in
                guard
                    ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval)
                else { return nil }
                return (owner, command)
            }
        }
    }

    /// Due commands within one window fire as a batch, so close ticks share a single wakeup.
    private func runDueCommands() async {
        guard manager.running == nil, sessionID == nil else { return }
        let now = Date()
        let due = schedulableCommands().filter { owner, command in
            let reference = ExtensionCommandRef(
                extensionName: owner.manifest.name, commandName: command.name)
            let metadata = commandMetadata.metadata(
                extension: owner.manifest.name, command: command.name)
            guard metadata.backgroundEnabled, let interval = command.interval else { return false }
            return ExtensionRefreshPolicy.nextDue(
                lastRun: metadata.lastRun, now: now, interval: interval,
                consecutiveFailures: metadata.consecutiveFailures, entryID: reference.entryID)
                <= now.addingTimeInterval(ExtensionRefreshPolicy.coalescingWindow)
        }
        guard !due.isEmpty else { return }
        for (owner, command) in due {
            guard !Task.isCancelled, manager.isEnabled, manager.running == nil else { break }
            await run(owner, command: command)
        }
    }

    /// Capped, so an install or a toggle surfaces without anyone restarting the loop.
    private func nextDelay() -> TimeInterval {
        guard manager.running == nil else { return ExtensionRefreshPolicy.coalescingWindow }
        let now = Date()
        var delay = ExtensionRefreshPolicy.idleHeartbeat
        for (owner, command) in schedulableCommands() {
            let reference = ExtensionCommandRef(
                extensionName: owner.manifest.name, commandName: command.name)
            let metadata = commandMetadata.metadata(
                extension: owner.manifest.name, command: command.name)
            guard metadata.backgroundEnabled, let interval = command.interval else { continue }
            let due = ExtensionRefreshPolicy.nextDue(
                lastRun: metadata.lastRun, now: now, interval: interval,
                consecutiveFailures: metadata.consecutiveFailures, entryID: reference.entryID)
            delay = min(delay, max(due.timeIntervalSince(now), 5))
        }
        return delay
    }

    /// A headless `no-view` run: the palette never moves and no feedback fires, only the subtitle can.
    func run(_ owner: InstalledExtension, command: ExtensionCommand) async {
        guard sessionID == nil, manager.running == nil, let interval = command.interval else {
            return
        }
        guard let bundle = owner.bundleURL(for: command) else { return }
        let reference = ExtensionCommandRef(
            extensionName: owner.manifest.name, commandName: command.name)
        let supportPath = ExtensionCatalog.supportPath(for: owner.manifest.name)
        try? FileManager.default.createDirectory(at: supportPath, withIntermediateDirectories: true)

        let session = UUID().uuidString
        sessionID = session
        activeRef = reference
        failure = nil
        var succeeded = false
        defer {
            // Gone mid-run means uninstalled: recording would resurrect its storage file.
            if manager.extensionNamed(reference.extensionName) != nil {
                commandMetadata.recordBackgroundResult(
                    extension: reference.extensionName, command: reference.commandName,
                    success: succeeded,
                    error: succeeded ? nil : (failure ?? String(localized: "Timed out.")),
                    now: Date())
            }
            sessionID = nil
            activeRef = nil
            failure = nil
            continuation = nil
            manager.publishLauncherEntries()
            manager.storage.flush()
            commandMetadata.flush()
        }

        do {
            try await runtime.boot(config: .current(supportDirectory: supportPath))
        } catch {
            failure = error.localizedDescription
            return
        }
        let code = await Task.detached(priority: .utility) {
            (try? String(contentsOf: bundle, encoding: .utf8)) ?? ""
        }.value
        guard !code.isEmpty else {
            failure = ExtensionLaunchError.notBuilt(command.title).localizedDescription
            return
        }
        let context = manager.makeLaunchContext(
            owner: owner, command: command, arguments: [:], supportPath: supportPath,
            launchType: .background)
        await runtime.start(
            session: session, code: code, file: bundle, mode: command.mode, context: context)
        succeeded = await waitForResult(timeout: ExtensionRefreshPolicy.timeout(interval: interval))
        // An abort already tore the session down; touching the runtime here would take the
        // manual run's fresh context with it.
        guard sessionID == session else { return }
        await runtime.stop(session: session)
        runtime.shutdown()
    }

    private func waitForResult(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { [weak self] in await self?.settled() ?? false }
            group.addTask { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    // Cancelling the loop preempts the tick; only a real timeout is a failure.
                    await self?.resume(with: true)
                    return true
                }
                await self?.resume(with: false)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    /// Suspends until the run settles, times out, or is preempted; `resume` is every exit.
    private func settled() async -> Bool {
        await withCheckedContinuation { continuation in self.continuation = continuation }
    }

    /// Ends the in-flight run as a success so its schedule survives the preemption.
    func abort() async {
        guard let session = sessionID else { return }
        sessionID = nil
        activeRef = nil
        await runtime.stop(session: session)
        runtime.shutdown()
        resume(with: true)
    }

    /// True when `session` was this scheduler's run, which the failure then ends.
    func runFailed(session: String, message: String) -> Bool {
        guard session == sessionID else { return false }
        failure = message
        resume(with: false)
        return true
    }

    func runFinished(session: String) -> Bool {
        guard session == sessionID else { return false }
        resume(with: true)
        return true
    }

    /// Main-actor serial, so no two of those exits can resume the same continuation.
    private func resume(with result: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
