import Foundation
import Synchronization

final class DictationWorker: Sendable {
    enum Purpose: Sendable {
        case preview, segment, final

        /// A dropped preview or segment keeps the loaded model; only its result is discarded.
        var survivesCancellation: Bool { self != .final }
    }

    /// A first Core ML compile of a large model can take minutes before the helper reports ready.
    static let loadTimeoutSeconds = 180

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let exit: ProcessExit
    private let queue = DispatchQueue(label: "com.tinycast.dictation-worker", qos: .userInitiated)
    private let terminated = Atomic(false)

    init(executable: URL = DictationWorker.executable, arguments: [String] = []) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(.EIO)
        }
        self.exit = try process.runObservingExit()
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    static var executable: URL {
        Bundle.main.bundleURL.appending(
            path: "Contents/Helpers/\(executableName).app/Contents/MacOS/\(executableName)")
    }

    private static var executableName: String {
        #if DEBUG
            "Tinycast Dev Dictation"
        #else
            "Tinycast Dictation"
        #endif
    }

    var isUsable: Bool { !terminated.load(ordering: .relaxed) && process.isRunning }

    func transcribe(
        _ samples: [Float], request: DictationWire.Request, purpose: Purpose = .final,
        onReady: @escaping @MainActor @Sendable () -> Void
    ) async throws -> DictationRecognition {
        guard (1...DictationWire.maximumSamples).contains(samples.count) else {
            throw DictationWire.Failure.unavailable
        }
        let text = try await Self.signposted(purpose) {
            try await exchange(samples, request: request, purpose: purpose, onReady: onReady)
        }
        guard let text else { throw DictationWire.Failure.unavailable }
        return text
    }

    func prepare(_ request: DictationWire.Request) async throws {
        _ = try await Signposts.interval("Dictation model load") {
            try await exchange([], request: request, purpose: .final, onReady: nil)
        }
    }

    private static func signposted<T>(
        _ purpose: Purpose, _ work: () async throws -> T
    ) async rethrows -> T {
        switch purpose {
        case .preview: try await Signposts.interval("Dictation preview transcription", around: work)
        case .segment: try await Signposts.interval("Dictation segment transcription", around: work)
        case .final: try await Signposts.interval("Dictation final transcription", around: work)
        }
    }

    private func exchange(
        _ samples: [Float], request: DictationWire.Request, purpose: Purpose,
        onReady: (@MainActor @Sendable () -> Void)?
    ) async throws -> DictationRecognition? {
        try Task.checkCancellation()
        guard samples.count == request.sampleCount else { throw DictationWire.Failure.unavailable }
        let progress = ExchangeProgress()
        let run = Task {
            try await self.run(samples, request: request, purpose: purpose, progress: progress, onReady: onReady)
        }
        return try await withTaskCancellationHandler {
            let text = try await run.value
            try Task.checkCancellation()
            return text
        } onCancel: {
            guard !purpose.survivesCancellation || !progress.isLoaded else { return }
            run.cancel()
            self.terminate()
        }
    }

    private func run(
        _ samples: [Float], request: DictationWire.Request, purpose: Purpose,
        progress: ExchangeProgress, onReady: (@MainActor @Sendable () -> Void)?
    ) async throws -> DictationRecognition? {
        let timeout = 60 + samples.count / DictationWire.sampleRate * 2
        var deadline = terminationDeadline(after: Self.loadTimeoutSeconds)
        defer { deadline.cancel() }
        let responses = AsyncThrowingStream<DictationWire.Response, Error>(
            bufferingPolicy: .bufferingOldest(2)
        ) { continuation in
            queue.async {
                do {
                    try DictationWire.write(request, to: self.input)
                    guard
                        let ready = try DictationWire.read(
                            DictationWire.Response.self, from: self.output),
                        ready.id == request.id, ready.status == .ready
                    else {
                        throw DictationWire.Failure.unavailable
                    }
                    progress.markLoaded()
                    continuation.yield(ready)
                    if request.isPreparation {
                        continuation.finish()
                        return
                    }
                    try samples.withUnsafeBytes { try self.input.write(contentsOf: $0) }
                    guard
                        let result = try DictationWire.read(
                            DictationWire.Response.self, from: self.output),
                        result.id == request.id
                    else {
                        throw DictationWire.Failure.unavailable
                    }
                    guard result.status == .result else {
                        if !purpose.survivesCancellation { self.terminate() }
                        continuation.finish(throwing: DictationWire.Failure.unavailable)
                        return
                    }
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    self.terminate()
                    continuation.finish(throwing: error)
                }
            }
        }
        var recognition: DictationRecognition?
        for try await response in responses {
            if response.status == .ready {
                if !request.isPreparation {
                    deadline.cancel()
                    deadline = terminationDeadline(after: timeout)
                }
                await onReady?()
            }
            if response.status == .result {
                recognition = DictationRecognition(text: response.text, pauses: response.pauses)
            }
        }
        return recognition
    }

    private func terminationDeadline(after seconds: Int) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self.terminate()
        }
    }

    func terminate() {
        terminated.store(true, ordering: .relaxed)
        if process.isRunning { process.terminate() }
    }

    func stop() async {
        terminate()
        await withCheckedContinuation { continuation in
            queue.async {
                self.exit.wait()
                try? self.input.close()
                try? self.output.close()
                continuation.resume()
            }
        }
    }
}

/// Set on the worker queue once the helper reports the model loaded for one exchange.
private final class ExchangeProgress: Sendable {
    private let loaded = Atomic(false)

    var isLoaded: Bool { loaded.load(ordering: .acquiring) }

    func markLoaded() { loaded.store(true, ordering: .releasing) }
}
