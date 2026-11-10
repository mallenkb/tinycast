import Foundation

final class DictationWorker: Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let exit: ProcessExit
    private let queue = DispatchQueue(label: "com.tinycast.dictation-worker", qos: .userInitiated)

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

    func transcribe(
        _ samples: [Float], request: DictationWire.Request,
        onReady: @escaping @MainActor @Sendable () -> Void
    ) async throws -> String {
        guard (1...DictationWire.maximumSamples).contains(samples.count),
            let text = try await exchange(samples, request: request, onReady: onReady)
        else {
            throw DictationWire.Failure.unavailable
        }
        return text
    }

    func prepare(_ request: DictationWire.Request) async throws {
        _ = try await exchange([], request: request, onReady: nil)
    }

    private func exchange(
        _ samples: [Float], request: DictationWire.Request, onReady: (@MainActor @Sendable () -> Void)?
    ) async throws -> String? {
        try Task.checkCancellation()
        guard samples.count == request.sampleCount else { throw DictationWire.Failure.unavailable }
        let timeout = 60 + samples.count / DictationWire.sampleRate * 2
        let hasExtendedLoadTimeout = request.model == .phonon2
        return try await withTaskCancellationHandler {
            var deadline = terminationDeadline(after: hasExtendedLoadTimeout ? 180 : timeout)
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
                        continuation.yield(ready)
                        if request.isPreparation {
                            continuation.finish()
                            return
                        }
                        try samples.withUnsafeBytes { try self.input.write(contentsOf: $0) }
                        guard
                            let result = try DictationWire.read(
                                DictationWire.Response.self, from: self.output),
                            result.id == request.id, result.status == .result
                        else {
                            throw DictationWire.Failure.unavailable
                        }
                        continuation.yield(result)
                        continuation.finish()
                    } catch {
                        self.terminate()
                        continuation.finish(throwing: error)
                    }
                }
            }
            var text: String?
            for try await response in responses {
                if response.status == .ready {
                    if hasExtendedLoadTimeout, !request.isPreparation {
                        deadline.cancel()
                        deadline = terminationDeadline(after: timeout)
                    }
                    await onReady?()
                }
                if response.status == .result { text = response.text }
            }
            try Task.checkCancellation()
            return text
        } onCancel: {
            self.terminate()
        }
    }

    private func terminationDeadline(after seconds: Int) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self.terminate()
        }
    }

    func terminate() {
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
