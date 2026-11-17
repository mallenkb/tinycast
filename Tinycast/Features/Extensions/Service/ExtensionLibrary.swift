import Foundation

/// What is installed on disk and where it came from: installs, store updates and uninstalls.
@MainActor
@Observable
final class ExtensionLibrary {
    /// The store's newer version of each installed extension that has one, keyed by manifest name.
    private(set) var updates: [String: ExtensionListing] = [:]
    private(set) var updating: Set<String> = []
    let processGrants: ExtensionProcessGrantStore
    @ObservationIgnored private let storeVersions = ExtensionVersionStore(
        fileURL: ExtensionCatalog.storeVersionsFile())
    @ObservationIgnored private unowned let manager: ExtensionManager
    @ObservationIgnored private weak var coordinator: ExtensionCoordinator?

    init(manager: ExtensionManager, processGrants: ExtensionProcessGrantStore) {
        self.manager = manager
        self.processGrants = processGrants
    }

    func start(coordinator: ExtensionCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Install

    /// Throws `CancellationError` when the user turns the install down at review.
    func install(from source: URL) async throws {
        // Not a manifest is the catalog's error to report, in its own words.
        if let manifest = try? ExtensionManifest.load(directory: source) {
            let capabilities = await Task.detached(priority: .userInitiated) {
                ExtensionCapabilityScanner.scan(directory: source)
            }.value
            guard await review(manifest, capabilities) else { throw CancellationError() }
        }
        installed(try ExtensionCatalog.install(from: source).manifest.name, from: .local)
        await manager.refresh()
    }

    /// Scanned off-main: it reads a manifest per directory, and a full Raycast install is dozens.
    func raycastImportCandidates() async -> [RaycastImportCandidate] {
        let candidates = await Task.detached(priority: .userInitiated) {
            ExtensionCatalog.importableFromRaycast()
        }.value
        let have = Set(manager.installed.map(\.manifest.name))
        return candidates.map {
            RaycastImportCandidate(installed: $0, isInstalled: have.contains($0.manifest.name))
        }
    }

    func install(
        _ listing: ExtensionListing,
        onProgress: @Sendable @escaping (ExtensionInstaller.Progress) -> Void
    ) async throws {
        try await installFromStore(listing, reviewed: true, onProgress: onProgress)
        await manager.refresh()
    }

    /// Progress is reported per step: building from source can take minutes.
    @discardableResult
    func install(
        _ source: ExtensionGitHubSource, packageManager: ExtensionPackageManager,
        additionalSearchPaths: [String],
        onProgress: @Sendable @escaping (ExtensionInstaller.Progress) -> Void
    ) async throws -> InstalledExtension {
        let installer = ExtensionInstaller(
            packageManager: packageManager, additionalSearchPaths: additionalSearchPaths)
        let installed = try await installer.install(
            source, review: reviewer(), onProgress: onProgress)
        self.installed(installed.manifest.name, from: .local)
        await manager.refresh()
        return installed
    }

    /// Refreshes once at the end, and returns what failed so the pane can name it.
    @discardableResult
    func importAllFromRaycast(
        _ candidates: [InstalledExtension], onProgress: (Int) -> Void = { _ in }
    ) async -> [String] {
        var failed: [String] = []
        for (index, candidate) in candidates.enumerated() {
            do {
                let name = try ExtensionCatalog.install(from: candidate.directory).manifest.name
                installed(name, from: .raycast)
            } catch {
                failed.append(candidate.title)
            }
            onProgress(index + 1)
        }
        await manager.refresh()
        return failed
    }

    /// The install confirmation; nothing to name means nothing to ask.
    private func review(_ manifest: ExtensionManifest, _ found: Set<ExtensionCapability>) async -> Bool {
        guard !found.isEmpty else { return true }
        return await coordinator?.confirmInstall(title: manifest.title, capabilities: found) ?? false
    }

    private func reviewer() -> ExtensionInstaller.Review {
        { [weak self] manifest, found in await self?.review(manifest, found) ?? false }
    }

    /// A folder or GitHub install is the user's own copy, so the store has nothing to offer it.
    private enum Origin {
        case local
        /// Raycast kept it current; the first update check adopts the store's version.
        case raycast
        case store(commitSHA: String?)
    }

    /// New code, so any process grant the old code earned is withdrawn.
    private func installed(_ name: String, from origin: Origin) {
        switch origin {
        case .local: storeVersions.forget(name)
        case .raycast: storeVersions.record(nil, for: name)
        case .store(let commitSHA): storeVersions.record(commitSHA, for: name)
        }
        updates[name] = nil
        processGrants.revoke(name)
    }

    // MARK: - Updates

    /// Asked when Settings opens; a lookup that fails is skipped rather than reported.
    func checkForUpdates() async {
        guard manager.isEnabled else { return }
        let tracked = storeVersions.tracked
        let lookups = manager.installed.map(\.manifest).filter { tracked.contains($0.name) }
        let client = ExtensionStoreClient()
        let latest = await withTaskGroup(of: ExtensionListing?.self) { group in
            for manifest in lookups {
                let (handle, name) = (manifest.storeHandle, manifest.name)
                group.addTask { try? await client.lookup(handle: handle, name: name) }
            }
            var found: [ExtensionListing] = []
            for await listing in group {
                if let listing { found.append(listing) }
            }
            return found
        }
        guard !Task.isCancelled else { return }
        updates = Dictionary(
            storeVersions.reconcile(with: latest).map { ($0.name, $0) }, uniquingKeysWith: { $1 })
    }

    /// One at a time, like an import; returns the titles that failed so the pane can name them.
    func update(_ names: [String]) async -> [String] {
        updating.formUnion(names)
        var failed: [String] = []
        for name in names {
            defer { updating.remove(name) }
            guard let listing = updates[name] else { continue }
            do {
                try await installFromStore(listing, reviewed: false, onProgress: { _ in })
            } catch {
                failed.append(listing.title)
            }
        }
        await manager.refresh()
        return failed
    }

    /// Replaces only the extension's directory, so its preferences and storage carry over.
    private func installFromStore(
        _ listing: ExtensionListing, reviewed: Bool,
        onProgress: @Sendable @escaping (ExtensionInstaller.Progress) -> Void
    ) async throws {
        let accept: ExtensionInstaller.Review = { @Sendable _, _ in true }
        let review = reviewed ? reviewer() : accept
        let installed = try await ExtensionInstaller().install(
            listing, review: review, onProgress: onProgress)
        self.installed(installed.manifest.name, from: .store(commitSHA: listing.commitSHA))
    }

    // MARK: - Uninstall

    /// Takes everything keyed to it: files, storage, icon, grants and its shortcuts.
    func uninstall(_ installedExtension: InstalledExtension) async {
        let name = installedExtension.manifest.name
        await manager.release(extensionName: name)
        let entryIDs = installedExtension.manifest.commands.map {
            ExtensionCommandRef(extensionName: name, commandName: $0.name).entryID
        }
        try? ExtensionCatalog.uninstall(installedExtension)
        manager.storage.removeAll(extension: name)
        manager.commandMetadata.removeAll(extension: name)
        storeVersions.forget(name)
        updates[name] = nil
        processGrants.revoke(name)
        manager.appearances.set(nil, for: name)
        manager.onDidUninstall?(entryIDs)
        await manager.refresh()
    }
}
