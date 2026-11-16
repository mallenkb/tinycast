import Foundation

@main
struct DictationInferenceTest {
    static func main() throws {
        var tied = [Float16](repeating: -1, count: 64)
        tied[7] = 4
        tied[32] = 4
        var wide = [Float16](repeating: -1, count: 151936)
        wide[151934] = 4
        let fixtures: [[Float16]] = [[-5, -1, -1, -3], [4, 4, -2], [-2, 0, 3], [7], tied, wide]
        for values in fixtures {
            let scores = try DictationTensor.zeros([1, 1, values.count], type: .float16)
            scores.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
                _ = buffer.update(from: values)
            }
            let expected = values.indices.reduce(0) { values[$1] > values[$0] ? $1 : $0 }
            guard try DictationTensor.indexOfMaximum(in: scores) == expected else {
                fatalError("Score selection changed the first maximum")
            }
        }
        for scores in [try DictationTensor.zeros([1, 2]), try DictationTensor.zeros([2, 2], type: .float16)] {
            do {
                _ = try DictationTensor.indexOfMaximum(in: scores)
                fatalError("Score selection accepted an incompatible tensor")
            } catch DictationInferenceError.incompatibleModel {}
        }

        var vocabulary = [String: Int]()
        var extra = 256
        for byte in 0...255 {
            let literal =
                (33...126).contains(byte) || (161...172).contains(byte) || (174...255).contains(byte)
            let scalar = Unicode.Scalar(literal ? byte : extra)!
            if !literal { extra += 1 }
            vocabulary[String(scalar)] = byte
        }
        vocabulary["ab"] = 256
        let prompts = ["ab", "Tinycast", "é 新 🍋", "two\nlines", "1, 2, 300"]
        let tokenizer = try DictationTokenizer(
            vocabulary: JSONEncoder().encode(vocabulary),
            merges: "#version: 0.2\na b\n", prompts: prompts + ["ab"])
        guard try tokenizer.tokens(for: "ab") == [256] else { fatalError("BPE merge failed") }
        for text in prompts {
            guard try tokenizer.decode(tokenizer.tokens(for: text)) == text else {
                fatalError("Tokenizer round trip failed")
            }
        }
        do {
            _ = try tokenizer.tokens(for: "not prepared")
            fatalError("Tokenizer accepted an unprepared prompt")
        } catch CocoaError.coderInvalidValue {}

        let mel = try DictationMel()
        let silence = try mel.features([Float](repeating: 0, count: 16_000)[...])
        guard silence.frames == 100, silence.values.allSatisfy({ $0 == -1.5 }),
            DictationMel.embeddingCount(frames: 3000) == 390,
            DictationMel.embeddingCount(frames: 1500) == 195
        else { fatalError("Mel shape or normalization failed") }
        for (frequency, expected) in [(440.0, 18), (2500.0, 80)] {
            let samples = (0..<16_000).map { Float(sin(2 * .pi * frequency * Double($0) / 16_000)) }
            let spectrum = try mel.features(samples[...])
            let peak = (0..<128).max { spectrum.values[$0 * 100 + 10] < spectrum.values[$1 * 100 + 10] }!
            guard abs(peak - expected) <= 1 else {
                fatalError("Fourier transform placed energy in the wrong band")
            }
        }
        let paddedAudio = (0..<11_111).map { Float(sin(Double($0) * 0.017)) }
        let padded = try mel.features(paddedAudio[...])
        let baseline = try referenceMel(paddedAudio, length: padded.length)
        guard zip(padded.values, baseline).allSatisfy({ abs($0 - $1) < 0.0001 }) else {
            fatalError("Skipping silent padding changed the mel spectrum")
        }

        let waveform = try DictationSpectrum()
        guard
            waveform.levels(for: [Float](repeating: 0, count: 512)[...]) == [Float](repeating: 0, count: 21),
            waveform.levels(for: [Float]()[...]).allSatisfy({ $0 == 0 })
        else {
            fatalError("Silent audio moved the waveform")
        }
        for (frequency, expected) in [(440.0, 11), (2500.0, 18)] {
            let tone = (0..<800).map { Float(0.2 * sin(2 * .pi * frequency * Double($0) / 16_000)) }
            let levels = waveform.levels(for: tone[...])
            let peak = levels.indices.max { levels[$0] < levels[$1] }!
            guard levels.count == 21, abs(peak - expected) <= 1,
                levels.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                levels == waveform.levels(for: tone.suffix(512))
            else {
                fatalError("Listening bands moved, saturated or retained old samples")
            }
        }

        var samples = [Float](repeating: 0.5, count: 480_001)
        for index in 210_000..<218_000 { samples[index] = 0 }
        let ranges = DictationAudioChunks.ranges(in: samples, maximum: 240_000)
        guard ranges.first?.lowerBound == 0, ranges.last?.upperBound == samples.count,
            ranges.first.map({ (210_000..<218_000).contains($0.upperBound) }) == true,
            ranges.allSatisfy({ !$0.isEmpty && $0.count <= 240_000 }),
            zip(ranges, ranges.dropFirst()).allSatisfy({ $0.upperBound == $1.lowerBound }),
            DictationAudioChunks.ranges(in: [], maximum: 240_000).isEmpty
        else {
            fatalError("Audio chunks lost, repeated or cut samples outside a pause")
        }
        testCohere()
        print(
            "Dictation scores, tokenizer, Fourier transform, mel features, listening bands, audio chunks"
                + " and Cohere features passed"
        )
    }

    private static func noise(_ count: Int, level: Float, seed: inout UInt64) -> [Float] {
        (0..<count).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * level * 1.732
        }
    }

    private static func speech(_ count: Int, level: Float, offset: Int = 0) -> [Float] {
        (0..<count).map { index in
            let time = Float(index + offset) / 16_000
            return level * sin(2 * .pi * 220 * time) * (0.6 + 0.4 * sin(2 * .pi * 3 * time))
        }
    }

    private static func testCohere() {
        let spectrogram = CohereMelSpectrogram()
        var seed: UInt64 = 11
        for count in [1, 159, 160, 4_321, 12_000] {
            let audio = zip(noise(count, level: 0.05, seed: &seed), speech(count, level: 0.3)).map { $0 + $1 }
            let output = spectrogram.compute(audio: audio)
            let reference = referenceCohereMel(audio)
            guard output.validFrames == count / 160, output.frames == reference.first?.count,
                output.mel.count == 128 * output.frames
            else { fatalError("Cohere mel features changed shape") }
            var largest: Float = 0
            for band in 0..<128 {
                for frame in 0..<output.frames {
                    largest = max(largest, abs(output.mel[band * output.frames + frame] - reference[band][frame]))
                }
            }
            guard largest < 1e-3 else { fatalError("Cohere mel features differ by \(largest)") }
        }

        var logits = [Float](repeating: 0, count: 16)
        CoherePipeline.applyNoRepeatNgram(&logits, history: [1, 2, 3, 1, 2], n: 6)
        guard !logits.contains(-1e9) else { fatalError("A short repeated phrase was banned") }
        CoherePipeline.applyNoRepeatNgram(&logits, history: [4, 5, 6, 7, 8, 9, 4, 5, 6, 7, 8], n: 6)
        guard logits[9] == -1e9, logits.filter({ $0 == -1e9 }).count == 1 else {
            fatalError("A repeated six-token loop was not banned")
        }
    }

    /// The scalar implementation the vectorised Cohere features replaced, kept as the reference.
    private static func referenceCohereMel(_ audio: [Float]) -> [[Float]] {
        let nFFT = 512, hop = 160, nMels = 128, nBins = 257, halfN = 256
        var samples = audio
        let validFrames = samples.count / hop
        if samples.count > 1 {
            var filtered = [Float](repeating: 0, count: samples.count)
            filtered[0] = samples[0]
            for index in 1..<samples.count { filtered[index] = samples[index] - 0.97 * samples[index - 1] }
            samples = filtered
        }
        var padded = [Float](repeating: 0, count: samples.count + nFFT)
        for index in samples.indices { padded[halfN + index] = samples[index] }
        let nFrames = 1 + (padded.count - nFFT) / hop
        var window = [Float](repeating: 0, count: nFFT)
        for index in 0..<400 { window[56 + index] = 0.5 * (1 - cos(2 * .pi * Float(index) / 399)) }
        var power = [Float](repeating: 0, count: nBins * nFrames)
        for frame in 0..<nFrames {
            for bin in 0..<nBins {
                var real: Double = 0, imaginary: Double = 0
                for index in 0..<nFFT {
                    let value = Double(padded[frame * hop + index] * window[index])
                    let angle = -2 * Double.pi * Double(bin * index) / Double(nFFT)
                    real += value * cos(angle)
                    imaginary += value * sin(angle)
                }
                power[bin * nFrames + frame] = Float(real * real + imaginary * imaginary)
            }
        }
        let filter = slaneyFilter(nBins: nBins, nMels: nMels)
        var mel = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: nMels)
        for band in 0..<nMels {
            for frame in 0..<nFrames {
                var sum: Float = 0
                for bin in 0..<nBins { sum += filter[band][bin] * power[bin * nFrames + frame] }
                mel[band][frame] = log(sum + 5.960_464_5e-08)
            }
        }
        for band in 0..<nMels {
            if validFrames > 1 {
                let mean = mel[band].prefix(validFrames).reduce(0, +) / Float(validFrames)
                let squares = mel[band].prefix(validFrames).reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                let deviation = sqrt(squares / Float(validFrames - 1))
                for frame in 0..<validFrames { mel[band][frame] = (mel[band][frame] - mean) / (deviation + 1e-5) }
            }
            for frame in validFrames..<nFrames { mel[band][frame] = 0 }
        }
        return mel
    }

    private static func slaneyFilter(nBins: Int, nMels: Int) -> [[Float]] {
        func melFromHz(_ hz: Float) -> Float { hz >= 1000 ? 15 + log(hz / 1000) / 0.068_751_777_42 : hz * 3 / 200 }
        func hzFromMel(_ mel: Float) -> Float { mel >= 15 ? 1000 * exp(0.068_751_777_42 * (mel - 15)) : mel * 200 / 3 }
        let step = (melFromHz(8000) - melFromHz(0)) / Float(nMels + 1)
        let points = (0..<(nMels + 2)).map { hzFromMel(melFromHz(0) + Float($0) * step) }
        return (0..<nMels).map { band in
            let lower = points[band], center = points[band + 1], upper = points[band + 2]
            return (0..<nBins).map { bin in
                let frequency = Float(16_000 * bin) / 512
                guard frequency >= lower, frequency <= upper else { return 0 }
                let weight = frequency <= center ? (frequency - lower) / max(center - lower, 1e-10)
                    : (upper - frequency) / max(upper - center, 1e-10)
                return weight * 2 / max(upper - lower, 1e-10)
            }
        }
    }

    private static func referenceMel(_ samples: [Float], length: Int) throws -> [Float] {
        let padded = samples + [Float](repeating: 0, count: length * 160 - samples.count)
        return try DictationMel().features(padded[...]).values
    }
}
