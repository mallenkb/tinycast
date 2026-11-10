import AVFoundation
import Speech

struct AppleDictationSession: Sendable {
    private enum Failure: LocalizedError {
        case unsupportedLanguage
        case invalidAudio

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage:
                String(localized: "Apple Dictation does not support your Mac’s preferred language.")
            case .invalidAudio:
                String(localized: "Apple Dictation could not read the recording.")
            }
        }
    }

    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat

    @concurrent
    static func prepare(vocabulary: [String]) async throws -> Self {
        let preferred = Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? .current
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred) else {
            throw Failure.unsupportedLanguage
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: captureFormat)
        else { throw Failure.invalidAudio }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        return Self(transcriber: transcriber, analyzer: analyzer, format: format)
    }

    @concurrent
    func transcribe(_ samples: [Float]) async throws -> String {
        let input = try makeInput(samples)
        let sequence = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(input)
            continuation.finish()
        }
        return try await withTaskCancellationHandler {
            async let text = collectResults()
            do {
                if let end = try await analyzer.analyzeSequence(sequence) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                try Task.checkCancellation()
                return try await text
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func collectResults() async throws -> String {
        var transcript = ""
        for try await result in transcriber.results where result.isFinal {
            transcript.append(contentsOf: result.text.characters)
        }
        return transcript
    }

    private static var captureFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: Double(DictationWire.sampleRate), channels: 1)
    }

    private func makeInput(_ samples: [Float]) throws -> AnalyzerInput {
        guard let source = Self.captureFormat else { throw Failure.invalidAudio }
        if source == format {
            let buffer = try Self.makeBuffer(format: source, frames: samples.count)
            try Self.fill(buffer, from: samples[...])
            return AnalyzerInput(buffer: buffer)
        }
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw Failure.invalidAudio
        }
        let outputFrames = Int(ceil(Double(samples.count) * format.sampleRate / source.sampleRate))
        let output = try Self.makeBuffer(format: format, frames: outputFrames + 4_096)
        var offset = 0
        var inputError: (any Error)?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { packets, status in
            let count = min(Int(packets), samples.count - offset)
            guard count > 0 else { status.pointee = .endOfStream; return nil }
            do {
                let buffer = try Self.makeBuffer(format: source, frames: count)
                try Self.fill(buffer, from: samples[offset..<(offset + count)])
                offset += count
                status.pointee = .haveData
                return buffer
            } catch {
                inputError = error
                status.pointee = .endOfStream
                return nil
            }
        }
        if let inputError { throw inputError }
        if let conversionError { throw conversionError }
        guard status != .error, offset == samples.count, output.frameLength > 0 else {
            throw Failure.invalidAudio
        }
        return AnalyzerInput(buffer: output)
    }

    private static func makeBuffer(format: AVAudioFormat, frames: Int) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw Failure.invalidAudio
        }
        return buffer
    }

    private static func fill(_ buffer: AVAudioPCMBuffer, from samples: ArraySlice<Float>) throws {
        guard let channel = buffer.floatChannelData?[0] else { throw Failure.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { values in
            if let base = values.baseAddress { channel.update(from: base, count: values.count) }
        }
    }
}
