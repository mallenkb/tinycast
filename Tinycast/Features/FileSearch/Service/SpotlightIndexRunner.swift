import Foundation
import Synchronization

nonisolated enum SpotlightIndexRunner {
    enum Outcome: Sendable {
        case requested
        case cancelled
        case disabled
        case failed(String)
    }

    static func rebuildStartupDisk() async throws -> Outcome {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            try
                do shell script "LC_ALL=C /usr/bin/mdutil -E /" with administrator privileges
            on error messageText number errorNumber
                if errorNumber is -128 then return "TINYCAST_CANCELLED"
                error messageText number errorNumber
            end try
            """]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                        let exit = try process.runObservingExit()
                        if cancelled.withLock({ $0 }), process.isRunning { process.terminate() }
                        let deadline = DispatchWorkItem {
                            if process.isRunning { process.terminate() }
                        }
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: deadline)
                        defer { deadline.cancel() }
                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        exit.wait()
                        guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                        let text = (String(bytes: data, encoding: .utf8) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let outcome: Outcome
                        if process.terminationStatus != 0 {
                            outcome = .failed(text)
                        } else if text == "TINYCAST_CANCELLED" {
                            outcome = .cancelled
                        } else if text.localizedCaseInsensitiveContains("indexing disabled") {
                            outcome = .disabled
                        } else if text.localizedCaseInsensitiveContains("indexing enabled"),
                            !text.localizedCaseInsensitiveContains("error")
                        {
                            outcome = .requested
                        } else {
                            outcome = .failed(text)
                        }
                        continuation.resume(returning: outcome)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }
    }
}
