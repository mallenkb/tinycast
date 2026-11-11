import CryptoKit
import Darwin
import Foundation
import NaturalLanguage

@MainActor
@Observable
final class DictationCleanupModel {
    enum Variant: String, Sendable {
        case s1Mini
        case s1ASRCleanup

        var name: String {
            switch self {
            case .s1Mini: "S1-mini"
            case .s1ASRCleanup: "S1-ASR-Cleanup"
            }
        }

        var downloadBytes: Int64 {
            switch self {
            case .s1Mini: 484_219_808
            case .s1ASRCleanup: 396_704_480
            }
        }

        var filename: String {
            switch self {
            case .s1Mini: "s1-mini-q4_k_m.gguf"
            case .s1ASRCleanup: "s1-asr-cleanup-v1.0-Q4_K_M.gguf"
            }
        }

        var downloadURL: URL {
            let repository: String
            let revision: String
            switch self {
            case .s1Mini:
                repository = "superwhisper/s1-mini-GGUF"
                revision = "34add00a48a2e5d24e5a4ee5405a99620a3a240c"
            case .s1ASRCleanup:
                repository = "danielrosehill/S1-ASR-Cleanup"
                revision = "6b38b1877e59b6524465b7206f92102f40744028"
            }
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!
        }

        var checksum: String {
            switch self {
            case .s1Mini: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
            case .s1ASRCleanup: "b7d9a71855b4fb804624046c2f233a79a310b1e880e9a7bd3e7711c3d456af19"
            }
        }

        var controlLine: String {
            switch self {
            case .s1Mini: "[Styling: semi-formal] [Structure: lists] [Context: general]"
            case .s1ASRCleanup: "[Styling: semi-formal] [Structure: prose] [Context: general] [Layers: 1,2]"
            }
        }
    }

    private let directory = AppPaths.caches().appending(path: "DictationCleanup")
    private let session: URLSession
    private var installed: Set<Variant> = []
    private(set) var downloading: Variant?
    private(set) var downloadedBytes: Int64 = 0
    @ObservationIgnored private var downloadID: UUID?
    private(set) var busy = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var runningVariant: Variant?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var warmupTask: Task<Void, Never>?
    @ObservationIgnored private var recordingVariant: Variant?
    @ObservationIgnored private var endpoint: URL?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var key = ""

    private func modelURL(_ variant: Variant) -> URL { directory.appending(path: variant.filename) }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
        for variant in [Variant.s1Mini, .s1ASRCleanup] where FileManager.default.fileExists(atPath: modelURL(variant).path) {
            installed.insert(variant)
        }
    }

    func isInstalled(_ variant: Variant) -> Bool { installed.contains(variant) }

    func download(_ variant: Variant) async throws {
        guard downloading == nil, !isInstalled(variant) else { return }
        downloading = variant
        downloadedBytes = 0
        let current = UUID()
        downloadID = current
        defer {
            downloading = nil
            downloadID = nil
        }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let response = try await DictationModelDownloader.downloadFile(
            from: variant.downloadURL, to: temporary, using: session
        ) { [weak self] received in
            Task { @MainActor in
                guard let self, self.downloadID == current else { return }
                self.downloadedBytes = max(self.downloadedBytes, min(received, variant.downloadBytes))
            }
        }
        try Task.checkCancellation()
        downloadedBytes = variant.downloadBytes
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try await Self.validate(temporary, checksum: variant.checksum)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = modelURL(variant)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        installed.insert(variant)
    }

    @concurrent private static func validate(_ url: URL, checksum: String) async throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == checksum else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func remove(_ variant: Variant) throws {
        guard !busy, downloading != variant else { return }
        if runningVariant == variant { stop() }
        try FileManager.default.removeItem(at: modelURL(variant))
        installed.remove(variant)
    }

    func clean(_ text: String, using variant: Variant) async throws -> String {
        let instructions = """
            You are a text normalizer for speech-to-text transcripts. The input begins with a control line \
            specifying the styling, structure, and context settings; clean the transcript to match those \
            settings and output only the cleaned text.
            """
        return try await respond(
            to: text, using: variant, instructions: instructions,
            controlLine: variant.controlLine, maxOutputTokens: 2_048)
    }

    func unavailableReason(for variant: Variant) -> String? {
        isInstalled(variant) ? nil : String(localized: "Download \(variant.name) to use this engine.")
    }

    func beginRecording(_ variant: Variant) {
        recordingVariant = variant
        idleTask?.cancel()
        idleTask = nil
        warmupTask?.cancel()
        warmupTask = Task(priority: .utility) { [weak self] in
            guard let self, !Task.isCancelled, !busy, isInstalled(variant) else { return }
            _ = try? launch(variant)
        }
    }

    func endRecording() {
        guard recordingVariant != nil else { return }
        recordingVariant = nil
        warmupTask?.cancel()
        warmupTask = nil
        scheduleIdleRelease()
    }

    func respond(
        to text: String, using variant: Variant, instructions: String,
        controlLine: String? = nil, maxOutputTokens: Int
    ) async throws -> String {
        try Task.checkCancellation()
        if let reason = unavailableReason(for: variant) { throw AIProviderError.unavailable(reason) }
        guard !busy else { throw DictationWire.Failure.busy }
        guard text.count <= 3_500 else {
            throw AIProviderError.responseFailed(String(localized: "This transcript is too long to transform on this Mac."))
        }
        if controlLine != nil, NLLanguageRecognizer.dominantLanguage(for: text) != .english { return text }
        busy = true
        idleTask?.cancel()
        idleTask = nil
        defer {
            busy = false
            scheduleIdleRelease()
        }
        do {
            let endpoint = try await start(variant)
            var request = URLRequest(url: endpoint.appending(path: "v1/chat/completions"))
            request.timeoutInterval = 20
            request.httpMethod = "POST"
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": controlLine.map { $0 + "\n" + text } ?? text]
                ],
                "temperature": 0, "max_tokens": maxOutputTokens, "stream": false,
                "chat_template_kwargs": ["enable_thinking": false]
            ])
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard self.endpoint == endpoint else { throw CancellationError() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = result["choices"] as? [[String: Any]], let choice = choices.first,
                  choice["finish_reason"] as? String == "stop",
                  let message = choice["message"] as? [String: Any], let content = message["content"] as? String
            else { throw AIProviderError.malformedResponse }
            let output = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw AIProviderError.malformedResponse }
            return output
        } catch { stop(); throw error }
    }

    private func start(_ variant: Variant) async throws -> URL {
        let address = try launch(variant)
        if ready { return address }
        guard let child = process else { throw DictationWire.Failure.unavailable }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process === child else { throw CancellationError() }
            guard child.isRunning else { throw DictationWire.Failure.unavailable }
            var request = URLRequest(url: address.appending(path: "health"))
            request.timeoutInterval = 1
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, child.isRunning {
                try Task.checkCancellation()
                guard process === child else { throw CancellationError() }
                ready = true
                return address
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.timedOut)
    }

    private func launch(_ variant: Variant) throws -> URL {
        if runningVariant == variant, let process, process.isRunning, let endpoint { return endpoint }
        stopProcess()
        let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/TinycastCleanup")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DictationWire.Failure.unavailable }
        let port = Int.random(in: 49_152...65_535)
        let address = URL(string: "http://127.0.0.1:\(port)")!
        let child = Process()
        key = UUID().uuidString
        child.executableURL = executable
        child.arguments = [
            "--model", modelURL(variant).path, "--host", "127.0.0.1", "--port", String(port), "--api-key", key,
            "--ctx-size", "4096", "--parallel", "1", "--jinja", "--no-webui", "--log-disable",
            "--chat-template-kwargs", "{\"enable_thinking\":false}"
        ]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        try child.run()
        process = child
        runningVariant = variant
        endpoint = address
        return address
    }

    private func scheduleIdleRelease() {
        idleTask?.cancel()
        idleTask = nil
        guard recordingVariant == nil, !busy, process != nil else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, recordingVariant == nil, !busy else { return }
            stopProcess()
        }
    }

    func stopIfModelChanged(to variant: Variant?) {
        if let current = runningVariant ?? recordingVariant, current != variant { stop() }
    }

    func stop() {
        warmupTask?.cancel()
        warmupTask = nil
        stopProcess()
    }

    private func stopProcess() {
        idleTask?.cancel()
        idleTask = nil
        if let process, process.isRunning {
            process.terminate()
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        runningVariant = nil
        endpoint = nil
        ready = false
        key = ""
    }
}
