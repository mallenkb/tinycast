import CoreML
import Foundation

// The RNNT state and model interface follow FluidAudio's Unified decoder, licensed under Apache-2.0.
final class UnifiedRecognizer: DictationRecognizer {
    private static let windowSamples = 240_000
    private static let blank = 1024
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let vocabulary: [Int: String]

    init(directory: URL) throws {
        preprocessor = try DictationTensor.load("parakeet_unified_preprocessor", at: directory, units: .cpuOnly)
        encoder = try DictationTensor.load("parakeet_unified_encoder_int8", at: directory, units: .cpuAndNeuralEngine)
        decoder = try DictationTensor.load("parakeet_unified_decoder", at: directory, units: .cpuAndNeuralEngine)
        joint = try DictationTensor.load(
            "parakeet_unified_joint_decision_single_step", at: directory, units: .cpuAndNeuralEngine)
        let pieces = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        vocabulary = Dictionary(uniqueKeysWithValues: try pieces.map { key, value in
            guard let id = Int(key), String(id) == key else { throw DictationInferenceError.incompatibleModel }
            return (id, value)
        })
    }

    func transcribe(_ samples: [Float], language: String?) throws -> String {
        guard !samples.isEmpty, samples.count <= DictationWire.maximumSamples else {
            throw DictationInferenceError.invalidAudio
        }
        return try DictationAudioChunks.ranges(in: samples, maximum: Self.windowSamples).map { range in
            try autoreleasepool {
                try decode(samples[range]).joined().replacingOccurrences(of: "▁", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.joined(separator: " ")
    }

    private struct Prediction {
        let projection: MLMultiArray
        let hidden: MLMultiArray
        let cell: MLMultiArray
    }

    private func predict(_ token: Int, hidden: MLMultiArray, cell: MLMultiArray) throws -> Prediction {
        let output = try DictationTensor.predict(decoder, [
            "targets": DictationTensor.integer(token, shape: [1, 1]),
            "target_length": DictationTensor.integer(1), "h_in": hidden, "c_in": cell
        ])
        return try Prediction(projection: DictationTensor.array("decoder", from: output),
                              hidden: DictationTensor.array("h_out", from: output),
                              cell: DictationTensor.array("c_out", from: output))
    }

    private func decode(_ samples: ArraySlice<Float>) throws -> [String] {
        let audio = try DictationTensor.zeros([1, Self.windowSamples])
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for (index, sample) in samples.enumerated() { buffer[index] = sample }
        }
        let mel = try DictationTensor.predict(preprocessor, [
            "audio_signal": audio, "audio_length": DictationTensor.integer(samples.count)
        ])
        let encoded = try DictationTensor.predict(encoder, [
            "mel": DictationTensor.array("mel", from: mel),
            "mel_length": DictationTensor.array("mel_length", from: mel)
        ])
        let features = try DictationTensor.array("encoder", from: encoded)
        let count = try DictationTensor.array("encoder_length", from: encoded)[0].intValue
        guard features.shape.count == 3, features.shape[1].intValue == 1024,
              count > 0, count <= features.shape[2].intValue
        else { throw DictationInferenceError.incompatibleModel }
        let vectors = MLShapedArray<Float>(converting: features)
        let frame = try DictationTensor.zeros([1, 1024, 1])
        var prediction = try predict(Self.blank, hidden: DictationTensor.zeros([2, 1, 640]),
                                     cell: DictationTensor.zeros([2, 1, 640]))
        var pieces: [String] = []
        for time in 0..<count {
            vectors.withUnsafeShapedBufferPointer { source, _, strides in
                frame.withUnsafeMutableBufferPointer(ofType: Float.self) { target, _ in
                    for channel in 0..<1024 {
                        target[channel] = source[channel * strides[1] + time * strides[2]]
                    }
                }
            }
            for _ in 0..<10 {
                let result = try DictationTensor.predict(joint, [
                    "encoder_step": frame, "decoder_step": prediction.projection
                ])
                let token = try DictationTensor.array("token_id", from: result)[0].intValue
                guard (0...Self.blank).contains(token) else { throw DictationInferenceError.incompatibleModel }
                if token == Self.blank { break }
                if let piece = vocabulary[token], !piece.hasPrefix("<|") { pieces.append(piece) }
                prediction = try predict(token, hidden: prediction.hidden, cell: prediction.cell)
            }
        }
        return pieces
    }
}
