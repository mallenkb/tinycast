import CoreML
import Foundation

final class ParakeetRecognizer {
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let vocabulary: [Int: String]
    private let blank: Int
    private static let windowSamples = 240_000

    init(directory: URL, model: DictationModel) throws {
        guard let configuration = model.parakeetConfiguration else {
            throw DictationInferenceError.incompatibleModel
        }
        preprocessor = try DictationTensor.load("Preprocessor", at: directory, units: .cpuOnly)
        encoder = try DictationTensor.load(
            configuration.encoder, at: directory,
            units: configuration.encoderUsesGPU ? .cpuAndGPU : .cpuAndNeuralEngine,
            function: configuration.encoderFunction)
        decoder = try DictationTensor.load("Decoder", at: directory, units: .cpuAndNeuralEngine)
        joint = try DictationTensor.load(
            configuration.joint,
            at: directory, units: .cpuAndNeuralEngine)
        let pieces = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json")))
        vocabulary = Dictionary(
            uniqueKeysWithValues: try pieces.map { key, value in
                guard let id = Int(key), String(id) == key else {
                    throw DictationInferenceError.incompatibleModel
                }
                return (id, value)
            })
        blank = configuration.blankToken
    }

    func transcribe(_ samples: [Float]) throws -> DictationRecognition {
        guard !samples.isEmpty, samples.count <= DictationWire.maximumSamples else {
            throw DictationInferenceError.invalidAudio
        }
        var words: [String] = []
        var pauses: [DictationPause] = []
        var previousEnd: Int?
        for range in DictationAudioChunks.ranges(in: samples, maximum: Self.windowSamples) {
            let offset = range.lowerBound * 1_000 / DictationWire.sampleRate
            let chunk = try autoreleasepool { try decode(samples[range]) }
            for word in Self.timedWords(chunk) {
                let start = offset + word.start * Self.frameMilliseconds
                if let previousEnd, start - previousEnd >= 250 {
                    pauses.append(DictationPause(word: words.count, milliseconds: start - previousEnd))
                }
                words.append(word.text)
                previousEnd = offset + (word.end + 1) * Self.frameMilliseconds
            }
        }
        return DictationRecognition(text: words.joined(separator: " "), pauses: pauses)
    }

    private static let frameMilliseconds = 80

    /// Splits decoded pieces into whitespace-separated words with the frames that emitted them.
    private static func timedWords(_ pieces: [(text: String, frame: Int)]) -> [(text: String, start: Int, end: Int)] {
        var words: [(text: String, start: Int, end: Int)] = []
        var current: (text: String, start: Int, end: Int)?
        for piece in pieces {
            for character in piece.text.replacingOccurrences(of: "▁", with: " ") {
                if character.isWhitespace {
                    if let finished = current { words.append(finished) }
                    current = nil
                } else if current == nil {
                    current = (String(character), piece.frame, piece.frame)
                } else {
                    current?.text.append(character)
                    current?.end = piece.frame
                }
            }
        }
        if let current { words.append(current) }
        return words
    }

    private func decode(_ samples: ArraySlice<Float>) throws -> [(text: String, frame: Int)] {
        let audio = try DictationTensor.zeros([1, Self.windowSamples])
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for (index, sample) in samples.enumerated() { buffer[index] = sample }
        }
        let mel = try DictationTensor.predict(
            preprocessor,
            [
                "audio_signal": audio,
                "audio_length": DictationTensor.integer(samples.count)
            ])
        let encoded = try DictationTensor.predict(
            encoder,
            [
                "mel": DictationTensor.array("mel", from: mel),
                "mel_length": DictationTensor.array("mel_length", from: mel)
            ])
        let features = try DictationTensor.array("encoder", from: encoded)
        let length = try DictationTensor.array("encoder_length", from: encoded)[0].intValue
        guard features.shape.count == 3, features.shape[1].intValue == 1024,
            length > 0, length <= features.shape[2].intValue
        else {
            throw DictationInferenceError.incompatibleModel
        }
        let vectors = MLShapedArray<Float>(converting: features)
        var hidden = try DictationTensor.zeros([2, 1, 640])
        var cell = try DictationTensor.zeros([2, 1, 640])
        func advance(_ token: Int) throws -> MLMultiArray {
            let prediction = try DictationTensor.predict(
                decoder,
                [
                    "targets": DictationTensor.integer(token, shape: [1, 1]),
                    "target_length": DictationTensor.integer(1), "h_in": hidden, "c_in": cell
                ])
            hidden = try DictationTensor.array("h_out", from: prediction)
            cell = try DictationTensor.array("c_out", from: prediction)
            return try DictationTensor.array("decoder", from: prediction)
        }
        var projection = try advance(blank)
        let frame = try DictationTensor.zeros([1, 1024, 1])
        var time = 0
        var emissions = 0
        var pieces: [(text: String, frame: Int)] = []
        while time < length {
            vectors.withUnsafeShapedBufferPointer { source, _, strides in
                frame.withUnsafeMutableBufferPointer(ofType: Float.self) { target, _ in
                    for channel in 0..<1024 {
                        target[channel] = source[channel * strides[1] + time * strides[2]]
                    }
                }
            }
            let decision = try DictationTensor.predict(
                joint, ["encoder_step": frame, "decoder_step": projection])
            let token = try DictationTensor.array("token_id", from: decision)[0].intValue
            let duration = try DictationTensor.array("duration", from: decision)[0].intValue
            guard (0...blank).contains(token), (0...4).contains(duration) else {
                throw DictationInferenceError.incompatibleModel
            }
            if token != blank {
                if let piece = vocabulary[token], !piece.hasPrefix("<|") { pieces.append((piece, time)) }
                projection = try advance(token)
                emissions += 1
            }
            let step = token == blank || emissions >= 10 ? max(1, duration) : duration
            if step > 0 { time += step; emissions = 0 }
        }
        return pieces
    }
}
