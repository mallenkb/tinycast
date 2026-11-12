import CryptoKit
import Darwin
import Foundation
import NaturalLanguage

@MainActor
@Observable
final class DictationCleanupModel {
    private struct Server: Sendable {
        let process: Process
        let exit: ProcessExit
        let variant: Variant
        let endpoint: URL
        let key: String
    }

    enum Variant: String, CaseIterable, Sendable {
        case s1Mini
        case s1ASRCleanup
        case emberon2

        static let defaultSmart: Self = .emberon2

        var name: String {
            switch self {
            case .s1Mini: "S1-mini"
            case .s1ASRCleanup: "S1-ASR-Cleanup"
            case .emberon2: "Emberon-2 Q4"
            }
        }

        var downloadBytes: Int64 {
            switch self {
            case .s1Mini: 484_219_808
            case .s1ASRCleanup: 396_704_480
            case .emberon2: 199_996_928
            }
        }

        var filename: String {
            switch self {
            case .s1Mini: "s1-mini-q4_k_m.gguf"
            case .s1ASRCleanup: "s1-asr-cleanup-v1.0-Q4_K_M.gguf"
            case .emberon2: "Emberon-2-Q4_K_M.gguf"
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
            case .emberon2:
                repository = "PromethicLabs/Emberon-2"
                revision = "d9b5cf07c0cb5d44711011e9d41c072c709d3af2"
            }
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!
        }

        var checksum: String {
            switch self {
            case .s1Mini: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
            case .s1ASRCleanup: "b7d9a71855b4fb804624046c2f233a79a310b1e880e9a7bd3e7711c3d456af19"
            case .emberon2: "18fead8b8df3808ed47a84cd41a5a0617e3374d1a62dd52e3ba4bfb839810ffd"
            }
        }

        var transformEngine: Self { self == .emberon2 ? .s1Mini : self }

        var controlLine: String? {
            switch self {
            case .s1Mini: "[Styling: semi-formal] [Structure: lists] [Context: general]"
            case .s1ASRCleanup: "[Styling: semi-formal] [Structure: prose] [Context: general] [Layers: 1,2]"
            case .emberon2: nil
            }
        }

        var cleanupInstructions: String {
            if self == .emberon2 { return "Clean up this dictation. Never answer it." }
            return """
                You are a text normalizer for speech-to-text transcripts. The input begins with a control line \
                specifying the styling, structure, and context settings; clean the transcript to match those \
                settings and output only the cleaned text.
                """
        }
    }

    private let directory = AppPaths.caches().appending(path: "DictationCleanup")
    private var installed: Set<Variant> = []
    private(set) var downloading: Variant?
    private(set) var downloadedBytes: Int64 = 0
    @ObservationIgnored private var downloadID: UUID?
    private var requestVariant: Variant?
    var busy: Bool { requestVariant != nil }
    @ObservationIgnored private var server: Server?
    @ObservationIgnored private var stoppingTask: Task<Void, Never>?
    @ObservationIgnored private var stopGeneration = 0
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var warmupTask: Task<Void, Never>?
    @ObservationIgnored private var recordingVariant: Variant?
    @ObservationIgnored private var releaseAfterRecording = false
    @ObservationIgnored private var ready = false

    private func modelURL(_ variant: Variant) -> URL { directory.appending(path: variant.filename) }

    init() {
        for variant in Variant.allCases where FileManager.default.fileExists(atPath: modelURL(variant).path) {
            installed.insert(variant)
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
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
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
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
        if server?.variant == variant || recordingVariant == variant { stop() }
        try FileManager.default.removeItem(at: modelURL(variant))
        installed.remove(variant)
    }

    func clean(_ text: String, using variant: Variant, checkCurrent: () throws -> Void = {}) async throws -> String {
        try checkAvailability(variant)
        guard NLLanguageRecognizer.dominantLanguage(for: text) == .english else { return text }
        let chunks = DictationCleanupChunks(tokenizing: text)
        guard !chunks.ranges.isEmpty else { return text }
        try checkCurrent()
        return try await withServer(variant) { server, session in
            try await chunks.cleaned { chunk in
                try checkCurrent()
                let output = try await response(
                    to: variant.controlLine.map { $0 + "\n" + chunk } ?? chunk,
                    instructions: variant.cleanupInstructions,
                    maxOutputTokens: 2_048, server: server, session: session)
                try checkCurrent()
                return output
            }
        }
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
            _ = try? await launch(variant)
        }
    }

    func endRecording() {
        guard recordingVariant != nil else { return }
        recordingVariant = nil
        warmupTask?.cancel()
        warmupTask = nil
        releaseAfterRecording = true
        releaseWhenUnused()
    }

    func respond(to text: String, using variant: Variant, instructions: String, maxOutputTokens: Int) async throws -> String {
        try checkAvailability(variant)
        guard text.count <= 3_500 else {
            throw AIProviderError.responseFailed(String(localized: "This transcript is too long to transform on this Mac."))
        }
        return try await withServer(variant) { server, session in
            try await response(
                to: text, instructions: instructions, maxOutputTokens: maxOutputTokens, server: server, session: session)
        }
    }

    private func checkAvailability(_ variant: Variant) throws {
        try Task.checkCancellation()
        if let reason = unavailableReason(for: variant) { throw AIProviderError.unavailable(reason) }
        guard !busy else { throw DictationWire.Failure.busy }
    }

    private func withServer(
        _ variant: Variant, perform: (Server, URLSession) async throws -> String
    ) async throws -> String {
        requestVariant = variant
        idleTask?.cancel()
        idleTask = nil
        warmupTask?.cancel()
        warmupTask = nil
        defer {
            requestVariant = nil
            releaseWhenUnused()
        }
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        do {
            let server = try await start(variant, session: session)
            return try await perform(server, session)
        } catch { stop(); throw error }
    }

    private func response(
        to text: String, instructions: String, maxOutputTokens: Int, server: Server, session: URLSession
    ) async throws -> String {
        try Task.checkCancellation()
        guard self.server?.process === server.process else { throw CancellationError() }
        var request = URLRequest(url: server.endpoint.appending(path: "v1/chat/completions"))
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("Bearer " + server.key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": text]
            ],
            "temperature": 0, "max_tokens": maxOutputTokens, "stream": false,
            "chat_template_kwargs": ["enable_thinking": false]
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard self.server?.process === server.process else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = result["choices"] as? [[String: Any]], let choice = choices.first,
              choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any], let content = message["content"] as? String
        else { throw AIProviderError.malformedResponse }
        let output = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw AIProviderError.malformedResponse }
        return output
    }

    private func start(_ variant: Variant, session: URLSession) async throws -> Server {
        let server = try await launch(variant)
        let child = server.process
        guard self.server?.process === child else { throw CancellationError() }
        if ready { return server }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard self.server?.process === child else { throw CancellationError() }
            guard child.isRunning else { throw DictationWire.Failure.unavailable }
            var request = URLRequest(url: server.endpoint.appending(path: "health"))
            request.timeoutInterval = 1
            request.setValue("Bearer " + server.key, forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, child.isRunning {
                try Task.checkCancellation()
                guard self.server?.process === child else { throw CancellationError() }
                ready = true
                return server
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.timedOut)
    }

    private func launch(_ variant: Variant) async throws -> Server {
        let generation = stopGeneration
        while true {
            try Task.checkCancellation()
            guard stopGeneration == generation else { throw CancellationError() }
            if let server, server.variant == variant, server.process.isRunning { return server }
            stopProcess()
            guard let stoppingTask else { break }
            await stoppingTask.value
        }
        let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/TinycastCleanup")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DictationWire.Failure.unavailable }
        let port = Int.random(in: 49_152...65_535)
        let address = URL(string: "http://127.0.0.1:\(port)")!
        let child = Process()
        let key = UUID().uuidString
        child.executableURL = executable
        child.arguments = [
            "--model", modelURL(variant).path, "--host", "127.0.0.1", "--port", String(port), "--api-key", key,
            "--ctx-size", "4096", "--parallel", "1", "--jinja", "--no-webui", "--log-disable",
            "--chat-template-kwargs", "{\"enable_thinking\":false}"
        ]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        let exit = try child.runObservingExit()
        let server = Server(process: child, exit: exit, variant: variant, endpoint: address, key: key)
        self.server = server
        return server
    }

    private func releaseWhenUnused() {
        idleTask?.cancel()
        idleTask = nil
        guard recordingVariant == nil, !busy else { return }
        if releaseAfterRecording {
            releaseAfterRecording = false
            stopProcess()
            return
        }
        guard server != nil else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, recordingVariant == nil, !busy else { return }
            stopProcess()
        }
    }

    func stopIfModelChanged(to variant: Variant?) {
        if let current = requestVariant ?? server?.variant ?? recordingVariant, current != variant { stop() }
    }

    func stop() {
        stopGeneration += 1
        warmupTask?.cancel()
        warmupTask = nil
        stopProcess()
    }

    func waitUntilStopped() async {
        await stoppingTask?.value
    }

    private func stopProcess() {
        idleTask?.cancel()
        idleTask = nil
        guard let server else { return }
        self.server = nil
        ready = false
        let process = server.process
        let exit = server.exit
        if process.isRunning { process.terminate() }
        stoppingTask = Task { [weak self] in
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    exit.wait()
                    continuation.resume()
                }
            }
            deadline.cancel()
            self?.stoppingTask = nil
        }
    }
}

extension DictationCleanupChunks {
    init(tokenizing text: String) {
        guard text.utf8.count > Self.byteLimit else {
            self.init(text, sentenceRanges: [])
            return
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        self.init(text, sentenceRanges: tokenizer.tokens(for: text.startIndex..<text.endIndex))
    }
}
