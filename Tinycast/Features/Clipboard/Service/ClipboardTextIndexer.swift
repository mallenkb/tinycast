import CoreGraphics
import OSLog

@MainActor
final class ClipboardTextIndexer {
    private let store: ClipboardStore
    private let canRun: () -> Bool
    private let extract: @Sendable (ClipboardItem) async throws -> ImageContent
    private let retryDelay: TimeInterval
    private let delay: Duration
    private var task: Task<Void, Never>?
    private var isEnabled = false
    private var waitingForRetry = false
    private(set) var isExtracting = false
    /// Recognition only starts in a lull, and a busy Mac is rechecked no sooner than the same lull.
    private static let idleWindow: TimeInterval = 2
    private static let logger = Logger(subsystem: "com.tinycast", category: "ClipboardText")

    init(
        store: ClipboardStore, delay: Duration = .milliseconds(250), retryDelay: TimeInterval = 30,
        canRun: @escaping () -> Bool,
        extract: (@Sendable (ClipboardItem) async throws -> String)? = nil
    ) {
        self.store = store
        self.delay = delay
        self.retryDelay = retryDelay
        self.canRun = canRun
        if let extract {
            self.extract = { ImageContent(text: try await extract($0), caption: "") }
        } else {
            self.extract = ImageContentWorker.extract
        }
    }

    isolated deinit {
        task?.cancel()
    }

    static var isSystemIdle: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) >= idleWindow
    }

    func start() {
        isEnabled = true
        schedule()
    }

    func stop() {
        isEnabled = false
        task?.cancel()
    }

    func waitUntilStopped() async {
        await task?.value
    }

    func schedule() {
        guard isEnabled else { return }
        if waitingForRetry {
            task?.cancel()
            return
        }
        guard task == nil else { return }
        let delay = delay
        task = Task(priority: .background) { [weak self] in
            defer {
                self?.task = nil
                self?.waitingForRetry = false
                self?.isExtracting = false
                if Task.isCancelled, self?.isEnabled == true { self?.schedule() }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.isEnabled else { return }
                let version = ImageContentWorker.version
                guard let item = self.store.nextExtractionItem(version: version) else {
                    guard let retry = self.store.nextExtractionRetry(version: version) else { return }
                    self.waitingForRetry = true
                    do { try await Task.sleep(for: .seconds(max(0, retry.timeIntervalSinceNow))) } catch {
                        return
                    }
                    self.waitingForRetry = false
                    continue
                }
                guard self.canRun() else {
                    do { try await Task.sleep(for: .seconds(Self.idleWindow)) } catch { return }
                    continue
                }
                let generation = self.store.extractionGeneration
                let extract = self.extract
                self.isExtracting = true
                let worker = Task.detached(priority: .background) { try await extract(item) }
                do {
                    let content = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    try Task.checkCancellation()
                    self.store.setExtractedText(
                        content.searchText, for: item, generation: generation,
                        version: content.version, completed: content.version >= version)
                    if content.version < version {
                        self.store.recordExtractionFailure(
                            for: item, generation: generation, retryAt: Date().addingTimeInterval(self.retryDelay))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    Self.logger.error(
                        "Clipboard text extraction failed: \(String(describing: error), privacy: .private)")
                    self.store.recordExtractionFailure(
                        for: item, generation: generation,
                        retryAt: Date().addingTimeInterval(self.retryDelay))
                }
                self.isExtracting = false
            }
        }
    }
}
