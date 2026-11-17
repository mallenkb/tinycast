import CoreML
import Foundation

final class QwenRecognizer {
    private struct Configuration: Decodable {
        let hiddenSize: Int
        let maxSeqLength: Int
        let vocabSize: Int
    }

    private let encoder: MLModel
    private let embedding: MLModel
    private let decoder: MLModel
    private let tokenizer: DictationTokenizer
    private let mel: DictationMel
    private let width: Int
    private let capacity: Int
    private let vocabularySize: Int
    private let prefix: [Int]
    private let suffix: [Int]
    private let languageSuffixes: [String: [Int]]
    private let promptEmbeddings: [Int: [Float]]

    init(directory: URL) throws {
        let json = JSONDecoder()
        json.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try json.decode(
            Configuration.self,
            from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        guard [1024, 2048].contains(configuration.hiddenSize), configuration.maxSeqLength == 1024,
            configuration.vocabSize == 151936
        else { throw DictationInferenceError.incompatibleModel }
        width = configuration.hiddenSize
        capacity = configuration.maxSeqLength
        vocabularySize = configuration.vocabSize
        let tokenizer = try DictationTokenizer(
            vocabulary: Data(contentsOf: directory.appendingPathComponent("vocab.json")),
            merges: String(contentsOf: directory.appendingPathComponent("merges.txt"), encoding: .utf8),
            prompts: ["system\n", "user\n", "assistant\n"]
                + DictationLanguage.allCases.map { "language " + $0.rawValue })
        self.tokenizer = tokenizer
        mel = try DictationMel()
        encoder = try DictationTensor.load("encoder", at: directory)
        let embedding = try DictationTensor.load("embedding", at: directory, units: .cpuOnly)
        self.embedding = embedding
        decoder = try DictationTensor.load("decoder", at: directory, units: .cpuAndGPU)
        let prefix =
            [151644] + (try tokenizer.tokens(for: "system\n"))
            + [151645, 198, 151644] + (try tokenizer.tokens(for: "user\n")) + [151669]
        let suffix = [151670, 151645, 198, 151644] + (try tokenizer.tokens(for: "assistant\n"))
        self.prefix = prefix
        self.suffix = suffix
        var languageSuffixes = [String: [Int]]()
        for language in DictationLanguage.allCases {
            languageSuffixes[language.rawValue] =
                try tokenizer.tokens(for: "language " + language.rawValue) + [151704]
        }
        self.languageSuffixes = languageSuffixes
        var promptEmbeddings = [Int: [Float]]()
        for id in prefix + suffix + languageSuffixes.values.joined() where promptEmbeddings[id] == nil {
            promptEmbeddings[id] = try Self.embed(id, with: embedding, width: configuration.hiddenSize)
        }
        self.promptEmbeddings = promptEmbeddings
    }

    private static func embed(_ id: Int, with embedding: MLModel, width: Int) throws -> [Float] {
        let output = try DictationTensor.predict(
            embedding, ["token_id": DictationTensor.integer(id, shape: [1, 1])])
        let values = try DictationTensor.array("embedding", from: output)
        guard values.count == width else { throw DictationInferenceError.incompatibleModel }
        return MLShapedArray<Float>(converting: values).scalars
    }

    func transcribe(_ samples: [Float], language: String?) throws -> String {
        guard !samples.isEmpty, samples.count <= DictationWire.maximumSamples else {
            throw DictationInferenceError.invalidAudio
        }
        return try DictationAudioChunks.ranges(in: samples, maximum: 480_000).map { range in
            try autoreleasepool {
                try decode(samples[range], language: language)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.joined(separator: " ")
    }

    private func decode(_ samples: ArraySlice<Float>, language: String?) throws -> String {
        let spectrum = try mel.features(samples)
        let count = DictationMel.embeddingCount(frames: spectrum.frames)
        let state = decoder.makeState()
        let position = try DictationTensor.integer(0)
        let mask = try DictationTensor.zeros([1, 1, 1, capacity])
        mask.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            buffer.initialize(repeating: -10_000)
        }
        let vector = try DictationTensor.zeros([1, 1, width])
        var offset = 0
        func step(_ values: MLMultiArray) throws -> MLMultiArray {
            try DictationTensor.checkParent()
            guard offset < capacity else { throw DictationInferenceError.outputLimit }
            position[0] = NSNumber(value: offset)
            mask.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                buffer[offset] = 0
            }
            offset += 1
            let result = try decoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "input_embeds": values, "position": position, "attention_mask": mask
                ]), using: state)
            return try DictationTensor.array("logits", from: result)
        }
        func token(_ id: Int) throws -> MLMultiArray {
            let values = try promptEmbeddings[id] ?? Self.embed(id, with: embedding, width: width)
            vector.withUnsafeMutableBufferPointer(ofType: Float.self) { target, _ in
                _ = target.update(from: values)
            }
            return try step(vector)
        }
        var suffix = self.suffix
        if let language {
            suffix += try languageSuffixes[language]
                ?? (tokenizer.tokens(for: "language " + language) + [151704])
        }
        guard prefix.count + count + suffix.count < capacity - 32 else {
            throw DictationInferenceError.outputLimit
        }
        for id in prefix { _ = try token(id) }
        let input = try DictationTensor.zeros([1, 128, 100])
        for start in stride(from: 0, to: spectrum.frames, by: 100) {
            let frames = min(100, spectrum.frames - start)
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                buffer.initialize(repeating: -1.5)
                for band in 0..<128 {
                    for frame in 0..<frames {
                        buffer[band * 100 + frame] = spectrum.values[band * spectrum.length + start + frame]
                    }
                }
            }
            let output = try DictationTensor.predict(encoder, ["mel": input])
            let audio = try DictationTensor.array("audio_embeddings", from: output)
            guard audio.shape.count == 3, audio.shape[1].intValue == 13,
                audio.shape[2].intValue == width
            else { throw DictationInferenceError.incompatibleModel }
            let vectors = MLShapedArray<Float>(converting: audio)
            for frame in 0..<((frames + 7) / 8) {
                vectors.withUnsafeShapedBufferPointer { source, _, strides in
                    vector.withUnsafeMutableBufferPointer(ofType: Float.self) { target, _ in
                        for index in 0..<width {
                            target[index] = source[frame * strides[1] + index * strides[2]]
                        }
                    }
                }
                _ = try step(vector)
            }
        }
        var logits: MLMultiArray?
        for id in suffix { logits = try token(id) }
        var generated = [Int]()
        while let scores = logits {
            guard scores.count == vocabularySize else {
                throw DictationInferenceError.incompatibleModel
            }
            let id = try DictationTensor.indexOfMaximum(in: scores)
            if id == 151645 || id == 151643 {
                let textStart = generated.firstIndex(of: 151704).map { $0 + 1 } ?? 0
                return try tokenizer.decode(Array(generated.dropFirst(textStart)))
            }
            generated.append(id)
            logits = try token(id)
        }
        throw DictationInferenceError.outputLimit
    }
}
