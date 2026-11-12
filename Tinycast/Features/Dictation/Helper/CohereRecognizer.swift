import Foundation

final class CohereRecognizer: DictationRecognizer {
    private let pipeline = CoherePipeline()
    private let models: CoherePipeline.LoadedModels

    init(directory: URL) throws {
        let quantized = directory.appendingPathComponent("q8", isDirectory: true)
        models = try CoherePipeline.loadModels(encoderDir: quantized, decoderDir: quantized, vocabDir: directory)
    }

    func transcribe(_ samples: [Float], language: String?) throws -> String {
        try DictationTensor.checkParent()
        guard !samples.isEmpty, samples.count <= DictationWire.maximumSamples else {
            throw DictationInferenceError.invalidAudio
        }
        let selected = CohereAsrConfig.Language.allCases.first {
            $0.englishName.caseInsensitiveCompare(language ?? "English") == .orderedSame
        }
        guard let selected else { throw DictationInferenceError.incompatibleModel }
        let result = try pipeline.transcribeLong(audio: samples, models: models, language: selected)
        guard result.cappedWindows == 0 else { throw DictationInferenceError.outputLimit }
        return result.text
    }
}
