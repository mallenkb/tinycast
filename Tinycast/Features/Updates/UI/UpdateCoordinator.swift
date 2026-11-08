import AppKit
import SwiftUI

/// The installer only performs an update the coordinator has decided is safe.
@MainActor
@Observable
final class UpdateCoordinator {
    /// One surface for prompt, progress and report: a download cannot move into a dialog.
    enum Stage: Equatable {
        case checking
        case upToDate
        /// A local build has no release stream to compare against, and says so rather than lying.
        case localBuild
        case available(AvailableRelease)
        case downloaded(AvailableRelease)
        case blocked(UpdateReadiness.Blocker, AvailableRelease)
        case installing(AvailableRelease, UpdateInstaller.Phase)
        case readyToRelaunch
        case failed(UpdateFailure)
    }

    private(set) var stage: Stage = .checking

    private let store: UpdateCheckStore
    /// Environment injection and activity reads only — never for state this type owns.
    private unowned let core: AppCore
    @ObservationIgnored private lazy var window = AppWindowController(
        title: String(localized: "Software Update"), contentSize: UpdateWindowView.initialSize,
        activation: core.activationPolicy)
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var automaticDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var deferredPresentationTask: Task<Void, Never>?
    @ObservationIgnored private var automaticDownloadIdentity = UUID()

    init(store: UpdateCheckStore, core: AppCore) {
        self.store = store
        self.core = core
    }

    var channel: ReleaseChannel { store.channel }
    var runningVersion: String { store.runningVersion?.description ?? String(localized: "unknown") }

    /// A local build has no release stream, so it does not advertise the command either.
    func applyEnabled() {
        core.appIndex.setCommandsVisible([.checkForUpdates], store.channel.updatesItself)
    }

    func applyAutomaticChecking() {
        if core.settings.automaticallyCheckForUpdates {
            store.start()
        } else {
            store.stop()
            cancelAutomaticDownload()
            store.reofferPendingUpdate()
            deferredPresentationTask?.cancel()
            deferredPresentationTask = nil
        }
    }

    func focusExisting() -> Bool {
        window.focus()
    }

    /// The window takes the height its content measured, so no stage pads itself out with space.
    func fit(height: CGFloat) {
        window.fitContent(width: UpdateWindowView.width, height: height)
    }

    // MARK: - Entry points

    /// The manual action: always opens the window and always asks GitHub.
    func checkForUpdates() {
        guard store.channel.updatesItself else {
            stage = .localBuild
            present()
            return
        }
        if case .installing = stage {
            present()
            return
        }
        stage = .checking
        present()
        Task { [weak self] in
            guard let self else { return }
            let answered = await store.check()
            guard case .checking = stage else { return }
            if let release = store.update {
                stage = installer.hasDownloaded(release) ? .downloaded(release) : .available(release)
            } else if answered {
                stage = .upToDate
            } else {
                stage = .failed(.downloadFailed(String(localized: "Tinycast could not reach GitHub.")))
            }
        }
    }

    /// The automatic path: `false` answers that it withheld the prompt, so the store re-offers it.
    func presentIfAvailable(_ release: AvailableRelease) -> Bool {
        guard core.settings.automaticallyCheckForUpdates else { return false }
        switch stage {
        case .installing, .readyToRelaunch:
            return true
        case .available(let current), .blocked(_, let current):
            guard current.version == release.version else { break }
            present()
            return true
        case .downloaded(let current):
            guard current.version == release.version else { break }
            guard UpdateReadiness.evaluate(core.currentActivity) == nil else { return false }
            present()
            return true
        case .checking, .upToDate, .localBuild, .failed:
            break
        }
        guard UpdateReadiness.evaluate(core.currentActivity) == nil else { return false }
        if installer.hasDownloaded(release) {
            stage = .downloaded(release)
            present()
        } else {
            downloadAutomatically(release)
        }
        return true
    }

    private func downloadAutomatically(_ release: AvailableRelease) {
        let identity = UUID()
        automaticDownloadIdentity = identity
        stage = .installing(release, .downloading(received: 0, expected: release.assetSize))
        let installer = self.installer
        let onProgress: @Sendable (UpdateInstaller.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase, for: release) }
        }
        automaticDownloadTask = Task { [weak self] in
            do {
                try await installer.download(release, onProgress: onProgress)
                guard let self, !Task.isCancelled,
                    self.automaticDownloadIdentity == identity
                else { return }
                self.automaticDownloadTask = nil
                self.stage = .downloaded(release)
                self.presentDownloadedWhenReady()
            } catch is CancellationError {
                return
            } catch let failure as UpdateFailure {
                guard let self, !Task.isCancelled,
                    self.automaticDownloadIdentity == identity
                else { return }
                self.automaticDownloadTask = nil
                self.stage = .failed(failure)
                self.presentFailureWhenReady()
            } catch {
                guard let self, !Task.isCancelled,
                    self.automaticDownloadIdentity == identity
                else { return }
                self.automaticDownloadTask = nil
                self.stage = .failed(.downloadFailed(error.localizedDescription))
                self.presentFailureWhenReady()
            }
        }
    }

    private func cancelAutomaticDownload() {
        guard automaticDownloadTask != nil else { return }
        automaticDownloadIdentity = UUID()
        automaticDownloadTask?.cancel()
        automaticDownloadTask = nil
        if case .installing(let release, .downloading) = stage {
            stage = .available(release)
        }
        store.reofferPendingUpdate()
    }

    private func presentDownloadedWhenReady() {
        guard case .downloaded = stage else { return }
        guard UpdateReadiness.evaluate(core.currentActivity) == nil else {
            deferPresentation { [weak self] in self?.presentDownloadedWhenReady() }
            return
        }
        deferredPresentationTask?.cancel()
        deferredPresentationTask = nil
        present()
    }

    private func presentFailureWhenReady() {
        guard case .failed = stage else { return }
        guard UpdateReadiness.evaluate(core.currentActivity) == nil else {
            deferPresentation { [weak self] in self?.presentFailureWhenReady() }
            return
        }
        deferredPresentationTask?.cancel()
        deferredPresentationTask = nil
        present()
    }

    private func deferPresentation(_ presentWhenReady: @escaping @MainActor () -> Void) {
        guard deferredPresentationTask == nil else { return }
        deferredPresentationTask = Task { @MainActor [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(120))
                guard let self, !Task.isCancelled else { return }
                guard UpdateReadiness.evaluate(self.core.currentActivity) == nil else { continue }
                self.deferredPresentationTask = nil
                presentWhenReady()
                return
            }
            self?.deferredPresentationTask = nil
        }
    }

    // MARK: - Actions

    func install() {
        guard let release = pendingRelease else { return }
        // Re-asked at the moment of the click, never read from a flag that could have gone stale.
        if let blocker = UpdateReadiness.evaluate(core.currentActivity) {
            stage = .blocked(blocker, release)
            return
        }
        stage = .installing(release, .downloading(received: 0, expected: release.assetSize))
        let installer = self.installer
        // Hoisted: nesting the hop inside the task body would re-capture its weak `self`.
        let onProgress: @Sendable (UpdateInstaller.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase, for: release) }
        }
        installTask = Task { [weak self] in
            do {
                try await installer.install(release, onProgress: onProgress)
                self?.store.recordInstall(of: release.version)
                self?.stage = .readyToRelaunch
            } catch is CancellationError {
                self?.stage = .available(release)
            } catch let failure as UpdateFailure {
                self?.stage = .failed(failure)
            } catch {
                self?.stage = .failed(.downloadFailed(error.localizedDescription))
            }
        }
    }

    func applyDownloadedAndRelaunch() {
        guard case .downloaded(let release) = stage else { return }
        if let blocker = UpdateReadiness.evaluate(core.currentActivity) {
            stage = .blocked(blocker, release)
            return
        }
        deferredPresentationTask?.cancel()
        deferredPresentationTask = nil
        stage = .installing(release, .extracting)
        let installer = self.installer
        let onProgress: @Sendable (UpdateInstaller.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase, for: release) }
        }
        installTask = Task { [weak self] in
            do {
                try await installer.applyDownloaded(release, onProgress: onProgress)
                guard let self else { return }
                self.store.recordInstall(of: release.version)
                self.core.relaunch()
            } catch is CancellationError {
                self?.stage = .downloaded(release)
            } catch let failure as UpdateFailure {
                self?.stage = .failed(failure)
            } catch {
                self?.stage = .failed(.downloadFailed(error.localizedDescription))
            }
        }
    }

    func dismissDownloaded() {
        deferredPresentationTask?.cancel()
        deferredPresentationTask = nil
        window.close()
    }

    /// Dismissing a version is what stops it asking again; a later one still will.
    func skip() {
        if let release = pendingRelease { store.skip(release) }
        window.close()
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        cancelAutomaticDownload()
    }

    func retry() {
        guard let release = pendingRelease else {
            checkForUpdates()
            return
        }
        if installer.hasDownloaded(release), case .blocked = stage {
            stage = .downloaded(release)
            return
        }
        stage = .available(release)
    }

    func dismiss() {
        window.close()
    }

    func relaunch() {
        core.relaunch()
    }

    // MARK: - Private

    private func report(_ phase: UpdateInstaller.Phase, for release: AvailableRelease) {
        guard case .installing = stage else { return }
        stage = .installing(release, phase)
    }

    private var pendingRelease: AvailableRelease? {
        switch stage {
        case .available(let release), .downloaded(let release), .blocked(_, let release),
            .installing(let release, _):
            return release
        case .checking, .upToDate, .localBuild, .readyToRelaunch, .failed:
            return store.update
        }
    }

    private var installer: UpdateInstaller {
        UpdateInstaller(
            bundleURL: Bundle.main.bundleURL,
            stagingDirectory: AppPaths.caches().appendingPathComponent("Updates", isDirectory: true))
    }

    private func present() {
        window.show {
            UpdateWindowView()
                .environment(self)
        }
    }
}
