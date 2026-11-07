import Foundation
import OSLog
import UniformTypeIdentifiers

@MainActor
final class FileImageContentIndexer {
    private let index: FileIndex
    private let store: ImageContentStore
    private let canRun: () -> Bool
    private let onContentChanged: () -> Void
    private let onAccessLost: () -> Void
    private var task: Task<Void, Never>?
    private var enabled = false
    private var purgeRequested = false
    private var revision = 0
    private(set) var isExtracting = false
    private static let logger = Logger(subsystem: "com.tinycast", category: "ImageContent")

    private enum Extraction: Sendable {
        case skipped
        case finished(saved: Bool)
        case accessLost
    }

    init(
        index: FileIndex, directory: URL, canRun: @escaping () -> Bool,
        onContentChanged: @escaping () -> Void, onAccessLost: @escaping () -> Void = {}
    ) {
        self.index = index
        store = ImageContentStore(url: directory.appending(path: "images.sqlite3"))
        self.canRun = canRun
        self.onContentChanged = onContentChanged
        self.onAccessLost = onAccessLost
    }

    isolated deinit { task?.cancel() }

    func setEnabled(_ enabled: Bool, purging: Bool = false) {
        if enabled != self.enabled || purging {
            self.enabled = enabled
            purgeRequested = purgeRequested || purging
            index.setImageContentURL(nil)
            task?.cancel()
        }
        start()
    }

    func schedule() {
        revision &+= 1
        start()
    }

    func stop() async {
        setEnabled(false)
        while let task { await task.value }
    }

    private func start() {
        guard task == nil, enabled || purgeRequested else { return }
        task = Task(priority: .background) { [weak self] in await self?.run() }
    }

    private func run() async {
        var shouldRestart = true
        defer {
            task = nil
            isExtracting = false
            if shouldRestart, Task.isCancelled { start() }
        }
        let store = store
        if purgeRequested {
            let removed = await Task.detached(priority: .background) { store.purge() }.value
            guard removed else {
                Self.logger.error("Could not remove the image content index")
                shouldRestart = false
                return
            }
            purgeRequested = false
        }
        guard enabled, !Task.isCancelled else { return }
        guard Permissions.hasFullDiskAccess() else { loseAccess(); return }
        let prepared = await Task.detached(priority: .background) { store.prepare() }.value
        guard !Task.isCancelled else { return }
        guard prepared else { Self.logger.error("Could not prepare the image content index"); return }
        index.setImageContentURL(store.url)
        await scan()
    }

    private func scan() async {
        var cursor = 0
        var observed = revision
        let index = index
        let store = store
        while enabled, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard Permissions.hasFullDiskAccess() else { loseAccess(); return }
            guard canRun() else {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                continue
            }
            if observed != revision { cursor = 0; observed = revision }
            let offset = cursor
            let batch = await Task.detached(priority: .background) { index.imageBatch(after: offset) }.value
            guard !Task.isCancelled, let scope = UInt64(batch.scope) else { return }
            if cursor == 0 {
                let cleanup = Task.detached(priority: .background) {
                    store.prune(scope: batch.scope, accepts: index.containsImagePath)
                }
                let changed = await withTaskCancellationHandler { await cleanup.value } onCancel: { cleanup.cancel() }
                guard !Task.isCancelled else { return }
                if changed { onContentChanged() }
            }
            for path in batch.paths {
                guard !Task.isCancelled, observed == revision else { break }
                while !canRun(), !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard Permissions.hasFullDiskAccess() else { loseAccess(); return }
                }
                guard !Task.isCancelled, observed == revision else { break }
                let version = ImageContentWorker.version
                isExtracting = true
                let work = Task.detached(priority: .background) {
                    await Self.extract(path: path, scope: scope, version: version, index: index, store: store)
                }
                let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                isExtracting = false
                guard !Task.isCancelled else { return }
                switch outcome {
                case .skipped:
                    await Task.yield()
                case .finished(let saved):
                    if saved { onContentChanged() }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                case .accessLost:
                    loseAccess()
                    return
                }
            }
            cursor = batch.next
            if batch.complete {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                cursor = 0
            }
        }
    }

    private func loseAccess() {
        setEnabled(false, purging: true)
        onAccessLost()
    }

    private nonisolated static func extract(
        path: String, scope: UInt64, version: Int, index: FileIndex, store: ImageContentStore
    ) async -> Extraction {
        let url = URL(fileURLWithPath: path)
        guard !Task.isCancelled, index.snapshot?.fingerprint == scope, index.containsImagePath(path),
            let fingerprint = ImageContentStore.Fingerprint(url: url),
            store.needsExtraction(path: path, scope: String(scope), fingerprint: fingerprint,
                                  version: version, now: Date())
        else { return .skipped }
        guard Permissions.hasFullDiskAccess() else { return .accessLost }
        let content: ImageContent?
        if version == 1, UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
            content = ImageContent(text: "", caption: nil)
        } else {
            do {
                content = try await ImageContentWorker.extract(at: url)
            } catch is CancellationError {
                return .skipped
            } catch {
                content = nil
            }
        }
        guard !Task.isCancelled, index.snapshot?.fingerprint == scope, index.containsImagePath(path),
            ImageContentStore.Fingerprint(url: url) == fingerprint
        else { return .skipped }
        guard Permissions.hasFullDiskAccess() else { return .accessLost }
        let saved = store.save(content, path: path, scope: String(scope), fingerprint: fingerprint,
                               version: version, now: Date())
        return .finished(saved: saved)
    }
}
