import Darwin
import Foundation
import OSLog

nonisolated enum SpotlightContentSearch {
    enum Failure: Error { case launch, output }

    private static let candidateLimit = 2_000
    private static let maximumPathBytes = 4_096
    private static let maximumOutputBytes = candidateLimit * (maximumPathBytes + 1)
    private static let queue = DispatchQueue(
        label: "com.tinycast.spotlight-content", qos: .userInitiated, attributes: .concurrent)
    private static let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/SpotlightContentHelper")
    private static let logger = Logger(subsystem: "com.tinycast", category: "SpotlightContent")

    @MainActor static func paths(matching text: String, scopes: [String]) async -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 2_048 else { return [] }
        return await search(SpotlightContentRequest(text: text, filters: nil, scopes: scopes))
    }

    @MainActor static func paths(filters: SearchFileConstraints, scopes: [String]) async -> [String] {
        guard !filters.content.isEmpty else { return [] }
        return await search(SpotlightContentRequest(text: nil, filters: filters, scopes: scopes))
    }

    private static func search(_ request: SpotlightContentRequest) async -> [String] {
        do {
            return try await run(request)
        } catch is CancellationError {
            return []
        } catch {
            logger.error("Spotlight helper failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    static func run(
        _ request: SpotlightContentRequest, executable: URL = executable, arguments: [String] = []
    ) async throws -> [String] {
        try Task.checkCancellation()
        let payload = try JSONEncoder().encode(request)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.launch }
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        guard let exit = try? process.runObservingExit() else { throw Failure.launch }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        if Task.isCancelled { terminate(process) }
        let deadline = Task.detached(priority: .utility) {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            terminate(process)
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: collect(
                        from: process, awaiting: exit, input: input, output: output, payload: payload))
                }
            }
        } onCancel: {
            terminate(process)
        }
        deadline.cancel()
        try Task.checkCancellation()
        return try result.get()
    }

    private static func collect(
        from process: Process, awaiting exit: ProcessExit, input: Pipe, output: Pipe, payload: Data
    ) -> Result<[String], Failure> {
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        defer {
            try? writer.close()
            try? reader.close()
            terminate(process)
            exit.wait()
        }
        var paths: [String] = []
        var path: [UInt8] = []
        var bytes = 0
        do {
            try writer.write(contentsOf: payload)
            try writer.close()
            while let chunk = try reader.read(upToCount: 8_192), !chunk.isEmpty {
                bytes += chunk.count
                guard bytes <= maximumOutputBytes else { return .failure(.output) }
                for byte in chunk {
                    if byte == 0 {
                        guard paths.count < candidateLimit, let value = String(bytes: path, encoding: .utf8),
                            value.hasPrefix("/") else { return .failure(.output) }
                        paths.append(value)
                        path.removeAll(keepingCapacity: true)
                    } else {
                        guard path.count < maximumPathBytes else { return .failure(.output) }
                        path.append(byte)
                    }
                }
            }
        } catch {
            return .failure(.output)
        }
        exit.wait()
        guard process.terminationStatus == 0, path.isEmpty else { return .failure(.output) }
        return .success(paths)
    }

    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }
}
