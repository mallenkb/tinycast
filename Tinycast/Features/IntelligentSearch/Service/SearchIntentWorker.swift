import Darwin
import Foundation

nonisolated enum SearchIntentWorker {
    enum Failure: Error { case launch, output }

    private static let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/SearchIntentHelper")
    private static let queue = DispatchQueue(label: "com.tinycast.search-intent", qos: .userInitiated)

    static func resolve(_ request: SearchIntentRequest, executable: URL = executable) async throws -> SearchIntent? {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.launch }
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        let exit = try process.runObservingExit()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()

        let deadline = Task.detached(priority: .utility) {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            terminate(process)
        }
        defer { deadline.cancel() }
        let result: Result<SearchIntent?, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = Result { try collect(process, exit: exit, writer: writer, reader: reader, data: data) }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            terminate(process)
        }
        try Task.checkCancellation()
        return try result.get()
    }

    private static func collect(
        _ process: Process, exit: ProcessExit, writer: FileHandle, reader: FileHandle, data: Data
    ) throws -> SearchIntent? {
        defer {
            try? writer.close()
            try? reader.close()
            terminate(process)
            exit.wait()
        }
        try writer.write(contentsOf: data)
        try writer.close()
        var response = Data()
        while let chunk = try reader.read(upToCount: 8_192), !chunk.isEmpty {
            guard response.count + chunk.count <= 64 * 1024 else { throw Failure.output }
            response.append(chunk)
        }
        exit.wait()
        guard process.terminationStatus == 0 else { throw Failure.output }
        return try JSONDecoder().decode(SearchIntent?.self, from: response)
    }

    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }
}
