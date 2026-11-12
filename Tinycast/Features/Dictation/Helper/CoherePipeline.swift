// Adapted from FluidAudio (Apache-2.0), revision d653a34a620c013febd7530427b4963ae18064b2.
import Accelerate
@preconcurrency import CoreML
import Foundation

public enum CohereAsrError: Error, LocalizedError {
    case modelNotFound(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case invalidInput(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg): return "Model not found: \(msg)"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .invalidInput(let msg): return "Invalid input: \(msg)"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        }
    }
}

@available(macOS 14, iOS 17, *)
public final class CohereMelSpectrogram {

    public struct Config: Sendable {
        public let sampleRate: Int
        public let winLength: Int
        public let hopLength: Int
        public let nMels: Int
        public let fMin: Float
        public let fMax: Float
        public let preemph: Float
        public let magPower: Float
        public let logZeroGuard: Float
        public let cmvnEpsilon: Float

        public init(
            sampleRate: Int = 16_000,
            winLength: Int = 400,
            hopLength: Int = 160,
            nMels: Int = 128,
            fMin: Float = 0.0,
            fMax: Float = 8_000.0,
            preemph: Float = 0.97,
            magPower: Float = 2.0,
            logZeroGuard: Float = 5.960_464_5e-08,  // 2^-24
            cmvnEpsilon: Float = 1.0e-5
        ) {
            self.sampleRate = sampleRate
            self.winLength = winLength
            self.hopLength = hopLength
            self.nMels = nMels
            self.fMin = fMin
            self.fMax = fMax
            self.preemph = preemph
            self.magPower = magPower
            self.logZeroGuard = logZeroGuard
            self.cmvnEpsilon = cmvnEpsilon
        }
    }

    public let config: Config
    public let nFFT: Int
    private let paddedWindow: [Float]
    private let melFilter: [[Float]]
    private let fftSetup: vDSP.FFT<DSPSplitComplex>

    public init(config: Config = Config()) {
        self.config = config
        self.nFFT = Self.nextPowerOfTwo(atLeast: config.winLength)

        var hann = [Float](repeating: 0, count: config.winLength)
        if config.winLength > 1 {
            let denom = Float(config.winLength - 1)
            for n in 0..<config.winLength {
                hann[n] = 0.5 * (1.0 - cos(2.0 * .pi * Float(n) / denom))
            }
        }

        var padded = [Float](repeating: 0, count: self.nFFT)
        if config.winLength < self.nFFT {
            let padLeft = (self.nFFT - config.winLength) / 2
            for n in 0..<config.winLength { padded[padLeft + n] = hann[n] }
        } else {
            padded = hann
        }
        self.paddedWindow = padded

        self.melFilter = Self.slaneyMelFilter(
            sampleRate: config.sampleRate, nFFT: self.nFFT,
            nMels: config.nMels, fMin: config.fMin, fMax: config.fMax)

        let log2n = vDSP_Length(Int(log2(Double(self.nFFT))))
        guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("vDSP.FFT setup failed for n=\(self.nFFT)")
        }
        self.fftSetup = setup
    }

    public func validFrameCount(forSamples n: Int) -> Int { max(0, n) / config.hopLength }

    public struct Output {
        public let mel: [[Float]]  // (nMels, nFrames)
        public let validFrames: Int
    }

    public func compute(audio: [Float]) -> Output {
        var samples = audio
        let validFrames = validFrameCount(forSamples: samples.count)

        if config.preemph != 0, samples.count > 1 {
            var filtered = [Float](repeating: 0, count: samples.count)
            filtered[0] = samples[0]
            for i in 1..<samples.count {
                filtered[i] = samples[i] - config.preemph * samples[i - 1]
            }
            samples = filtered
        }

        let padSize = nFFT / 2
        var padded = [Float](repeating: 0, count: samples.count + 2 * padSize)
        for i in 0..<samples.count { padded[padSize + i] = samples[i] }

        let nFrames = 1 + (padded.count - nFFT) / config.hopLength
        let nBins = nFFT / 2 + 1

        var power = [Float](repeating: 0, count: nBins * nFrames)

        let halfN = nFFT / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var windowed = [Float](repeating: 0, count: nFFT)

        for frame in 0..<nFrames {
            let start = frame * config.hopLength
            padded.withUnsafeBufferPointer { source in
                vDSP_vmul(
                    source.baseAddress!.advanced(by: start), 1,
                    paddedWindow, 1,
                    &windowed, 1,
                    vDSP_Length(nFFT))
            }

            windowed.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                base.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cbuf in
                    realp.withUnsafeMutableBufferPointer { rBuf in
                        imagp.withUnsafeMutableBufferPointer { iBuf in
                            var split = DSPSplitComplex(
                                realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                            vDSP_ctoz(cbuf, 2, &split, 1, vDSP_Length(halfN))
                        }
                    }
                }
            }

            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(
                        realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    fftSetup.forward(input: split, output: &split)
                }
            }

            let scale: Float = 0.5
            let dcMag = abs(realp[0] * scale)
            power[0 * nFrames + frame] = pow(dcMag, config.magPower)
            let nyMag = abs(imagp[0] * scale)
            power[(nBins - 1) * nFrames + frame] = pow(nyMag, config.magPower)
            for k in 1..<halfN {
                let r = realp[k] * scale
                let im = imagp[k] * scale
                let mag = sqrt(r * r + im * im)
                power[k * nFrames + frame] = pow(mag, config.magPower)
            }
        }

        var mel = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: config.nMels)
        for m in 0..<config.nMels {
            let filt = melFilter[m]
            for f in 0..<nFrames {
                var sum: Float = 0
                for k in 0..<nBins { sum += filt[k] * power[k * nFrames + f] }
                mel[m][f] = sum
            }
        }

        for m in 0..<config.nMels {
            for f in 0..<nFrames {
                mel[m][f] = log(mel[m][f] + config.logZeroGuard)
            }
        }

        if validFrames > 1 {
            for m in 0..<config.nMels {
                var mean: Float = 0
                for f in 0..<validFrames { mean += mel[m][f] }
                mean /= Float(validFrames)
                var ssq: Float = 0
                for f in 0..<validFrames {
                    let d = mel[m][f] - mean
                    ssq += d * d
                }
                let variance = ssq / Float(validFrames - 1)
                var std = sqrt(variance)
                if !std.isFinite { std = 0.0 }
                let denom = std + config.cmvnEpsilon
                for f in 0..<validFrames { mel[m][f] = (mel[m][f] - mean) / denom }
            }
        }

        if validFrames < nFrames {
            for m in 0..<config.nMels {
                for f in validFrames..<nFrames { mel[m][f] = 0 }
            }
        }

        return Output(mel: mel, validFrames: validFrames)
    }

    public static func padOrTruncate(
        mel: [[Float]], validFrames: Int, fixedFrames: Int = 3_500
    ) -> (mel: [[Float]], featureLength: Int) {
        let nMels = mel.count
        guard nMels > 0 else { return (mel, 0) }
        let cur = mel[0].count
        if cur == fixedFrames { return (mel, min(validFrames, fixedFrames)) }
        if cur > fixedFrames {
            return (mel.map { Array($0.prefix(fixedFrames)) }, min(validFrames, fixedFrames))
        }
        let padLen = fixedFrames - cur
        let padded: [[Float]] = mel.map { $0 + [Float](repeating: 0, count: padLen) }
        return (padded, min(validFrames, fixedFrames))
    }

    private static func nextPowerOfTwo(atLeast n: Int) -> Int {
        var x = 1
        while x < n { x <<= 1 }
        return x
    }

    private static func slaneyMelFilter(
        sampleRate: Int, nFFT: Int, nMels: Int, fMin: Float, fMax: Float
    ) -> [[Float]] {
        let nBins = nFFT / 2 + 1
        var fftFreqs = [Float](repeating: 0, count: nBins)
        for k in 0..<nBins { fftFreqs[k] = Float(sampleRate) * Float(k) / Float(nFFT) }

        let melMin = hzToMelSlaney(fMin)
        let melMax = hzToMelSlaney(fMax)
        var melPoints = [Float](repeating: 0, count: nMels + 2)
        let step = (melMax - melMin) / Float(nMels + 1)
        for i in 0..<(nMels + 2) { melPoints[i] = melMin + Float(i) * step }
        let hzPoints = melPoints.map { melToHzSlaney($0) }

        var fb = [[Float]](repeating: [Float](repeating: 0, count: nBins), count: nMels)
        for m in 0..<nMels {
            let lower = hzPoints[m]
            let center = hzPoints[m + 1]
            let upper = hzPoints[m + 2]
            let leftDen = max(center - lower, 1e-10)
            let rightDen = max(upper - center, 1e-10)
            for k in 0..<nBins {
                let f = fftFreqs[k]
                if f < lower || f > upper { continue }
                fb[m][k] = (f <= center) ? (f - lower) / leftDen : (upper - f) / rightDen
            }
            let enorm: Float = 2.0 / max(upper - lower, 1e-10)
            for k in 0..<nBins { fb[m][k] *= enorm }
        }
        return fb
    }

    private static let slaneyMinLogHz: Float = 1000.0
    private static let slaneyMinLogMel: Float = 15.0
    private static let slaneyLogStep: Float = 0.06875177742  // log(6.4) / 27

    private static func hzToMelSlaney(_ hz: Float) -> Float {
        let fSp: Float = 200.0 / 3.0
        if hz >= slaneyMinLogHz {
            return slaneyMinLogMel + log(hz / slaneyMinLogHz) / slaneyLogStep
        }
        return hz / fSp
    }

    private static func melToHzSlaney(_ mel: Float) -> Float {
        let fSp: Float = 200.0 / 3.0
        if mel >= slaneyMinLogMel {
            return slaneyMinLogHz * exp(slaneyLogStep * (mel - slaneyMinLogMel))
        }
        return fSp * mel
    }
}

@available(macOS 14, iOS 17, *)
public final class CoherePipeline {

    public struct LoadedModels: Sendable {
        public let encoder: MLModel
        public let decoder: MLModel
        public let vocabulary: [Int: String]
        public let decoderVariant: DecoderVariant
        public let cacheLength: Int
        public let cacheDataType: MLMultiArrayDataType
        public let encoderComputeUnits: MLComputeUnits
        public let decoderComputeUnits: MLComputeUnits
    }

    private let melExtractor: CohereMelSpectrogram

    public init(mel: CohereMelSpectrogram = CohereMelSpectrogram()) {
        self.melExtractor = mel
    }

    public enum DecoderVariant: Sendable {
        case v3
        case v2
        case v1

        public var compiledFileName: String {
            switch self {
            case .v3: return "cohere_decoder_cache_external_v3.mlmodelc"
            case .v2: return "cohere_decoder_cache_external_v2.mlmodelc"
            case .v1: return "cohere_decoder_cache_external.mlmodelc"
            }
        }

        public var usesStaticSelfMask: Bool {
            switch self {
            case .v3, .v2: return true
            case .v1: return false
            }
        }
    }

    public static let defaultEncoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    public static let defaultDecoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    public static func loadModels(
        encoderDir: URL,
        decoderDir: URL,
        vocabDir: URL,
        decoderVariant: DecoderVariant = .v3,
        computeUnits: MLComputeUnits? = nil,
        encoderComputeUnits: MLComputeUnits? = nil,
        decoderComputeUnits: MLComputeUnits? = nil
    ) throws -> LoadedModels {
        let units = resolveComputeUnits(
            shared: computeUnits, encoder: encoderComputeUnits, decoder: decoderComputeUnits)
        let encoderConfig = MLModelConfiguration()
        encoderConfig.computeUnits = units.encoder
        let decoderConfig = MLModelConfiguration()
        decoderConfig.computeUnits = units.decoder

        let encoderURL = encoderDir.appendingPathComponent(
            "cohere_encoder.mlmodelc")
        let decoderURL = decoderDir.appendingPathComponent(decoderVariant.compiledFileName)

        guard FileManager.default.fileExists(atPath: decoderURL.path) else {
            throw CohereAsrError.modelNotFound(
                "Decoder not found at \(decoderURL.path) (variant: \(decoderVariant)).")
        }

        let encoder = try MLModel(contentsOf: encoderURL, configuration: encoderConfig)

        let decoder = try MLModel(contentsOf: decoderURL, configuration: decoderConfig)

        let cacheLength = try Self.probeCacheLength(
            decoder: decoder, variant: decoderVariant, path: decoderURL.path)
        let cacheDataType =
            decoder.modelDescription.inputDescriptionsByName["k_cache_0"]?
            .multiArrayConstraint?.dataType ?? .float16

        let vocab = try loadVocabulary(vocabDir: vocabDir)
        return LoadedModels(
            encoder: encoder,
            decoder: decoder,
            vocabulary: vocab,
            decoderVariant: decoderVariant,
            cacheLength: cacheLength,
            cacheDataType: cacheDataType,
            encoderComputeUnits: units.encoder,
            decoderComputeUnits: units.decoder)
    }

    static func resolveComputeUnits(
        shared: MLComputeUnits?, encoder: MLComputeUnits?, decoder: MLComputeUnits?
    ) -> (encoder: MLComputeUnits, decoder: MLComputeUnits) {
        return (
            encoder: encoder ?? shared ?? defaultEncoderComputeUnits,
            decoder: decoder ?? shared ?? defaultDecoderComputeUnits
        )
    }

    public static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "cpu-only"
        case .cpuAndGPU: return "cpu-gpu"
        case .cpuAndNeuralEngine: return "cpu-ane"
        case .all: return "all"
        @unknown default: return "unknown"
        }
    }

    static func probeCacheLength(
        decoder: MLModel, variant: DecoderVariant, path: String
    ) throws -> Int {
        let inputs = decoder.modelDescription.inputDescriptionsByName
        guard let kDesc = inputs["k_cache_0"], kDesc.type == .multiArray,
            let kConstraint = kDesc.multiArrayConstraint, kConstraint.shape.count == 4
        else {
            throw CohereAsrError.decodingFailed(
                "Decoder at \(path) is not cache-external (missing rank-4 k_cache_0).")
        }
        let slots = Self.maxExtent(of: kConstraint, dimension: 2)
        guard slots > 0 else {
            throw CohereAsrError.decodingFailed(
                "Decoder at \(path) declares an empty KV cache (k_cache_0 shape \(kConstraint.shape)).")
        }
        if variant.usesStaticSelfMask {
            guard let mDesc = inputs["attention_mask"], mDesc.type == .multiArray,
                let mConstraint = mDesc.multiArrayConstraint, !mConstraint.shape.isEmpty,
                Self.maxExtent(of: mConstraint, dimension: mConstraint.shape.count - 1) == slots
            else {
                throw CohereAsrError.decodingFailed(
                    "Decoder at \(path): static attention_mask length does not match the "
                        + "\(slots)-slot KV cache (variant \(variant)).")
            }
        }
        return slots
    }

    static func maxExtent(of constraint: MLMultiArrayConstraint, dimension: Int) -> Int {
        return maxExtent(
            shape: constraint.shape,
            shapeConstraint: constraint.shapeConstraint,
            dimension: dimension)
    }

    static func maxExtent(
        shape: [NSNumber], shapeConstraint: MLMultiArrayShapeConstraint?, dimension: Int
    ) -> Int {
        guard dimension >= 0, dimension < shape.count else { return 0 }
        guard let shapeConstraint else { return shape[dimension].intValue }
        switch shapeConstraint.type {
        case .range:
            let ranges = shapeConstraint.sizeRangeForDimension
            guard dimension < ranges.count else { return shape[dimension].intValue }
            let range = ranges[dimension].rangeValue
            return range.location + range.length - 1
        case .enumerated:
            let widest = shapeConstraint.enumeratedShapes.compactMap { shape -> Int? in
                dimension < shape.count ? shape[dimension].intValue : nil
            }.max()
            return widest ?? shape[dimension].intValue
        case .unspecified:
            return shape[dimension].intValue
        @unknown default:
            return shape[dimension].intValue
        }
    }

    private static func loadVocabulary(vocabDir: URL) throws -> [Int: String] {
        let vocabURL = vocabDir.appendingPathComponent("vocab.json")
        let data = try Data(contentsOf: vocabURL)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: String] else {
            throw CohereAsrError.modelNotFound("Invalid vocab.json format")
        }
        var vocab: [Int: String] = [:]
        vocab.reserveCapacity(dict.count)
        for (key, value) in dict {
            if let tokenId = Int(key) { vocab[tokenId] = value }
        }

        return vocab
    }

    public struct TranscriptionResult: Sendable {
        public let text: String
        public let tokenIds: [Int]
        public let encoderSeconds: Double
        public let decoderSeconds: Double
        public let totalSeconds: Double
        public let cappedWindows: Int
    }

    static func resolveMaxNewTokens(
        requested: Int?, cacheLength: Int, promptCount: Int
    ) -> Int {
        let capacity = max(0, cacheLength - promptCount + 1)
        guard let requested = requested else { return capacity }
        return max(0, min(requested, capacity))
    }

    static func decodeStepCount(maxNewTokens: Int, promptCount: Int, cacheLength: Int) -> Int {
        return max(0, min(maxNewTokens + promptCount - 1, cacheLength))
    }

    public func transcribe(
        audio: [Float],
        models: LoadedModels,
        language: CohereAsrConfig.Language = .english,
        maxNewTokens: Int? = nil,
        repetitionPenalty: Float = 1.1,
        noRepeatNgram: Int = 3
    ) throws -> TranscriptionResult {
        let total0 = CFAbsoluteTimeGetCurrent()

        let melOut = melExtractor.compute(audio: audio)
        let (paddedMel, featureLength) = CohereMelSpectrogram.padOrTruncate(
            mel: melOut.mel, validFrames: melOut.validFrames, fixedFrames: 3_500)
        guard featureLength > 0 else {
            throw CohereAsrError.invalidInput("Audio too short to extract mel features")
        }

        let enc0 = CFAbsoluteTimeGetCurrent()
        let (encoderHidden, encoderValid) = try runEncoder(
            paddedMel: paddedMel, featureLength: featureLength, encoder: models.encoder)
        let encoderSecs = CFAbsoluteTimeGetCurrent() - enc0

        let dec0 = CFAbsoluteTimeGetCurrent()
        let budget = Self.resolveMaxNewTokens(
            requested: maxNewTokens,
            cacheLength: models.cacheLength,
            promptCount: language.promptSequence.count)
        let decoded = try decodeCacheExternal(
            encoderHidden: encoderHidden,
            encoderValidFrames: encoderValid,
            language: language,
            maxNewTokens: budget,
            repetitionPenalty: repetitionPenalty,
            noRepeatNgram: noRepeatNgram,
            decoder: models.decoder,
            cacheLength: models.cacheLength,
            cacheDType: models.cacheDataType,
            useStaticSelfMask: models.decoderVariant.usesStaticSelfMask)
        let decoderSecs = CFAbsoluteTimeGetCurrent() - dec0

        let text = Self.convertTokensToText(decoded.tokens, vocabulary: models.vocabulary)

        return TranscriptionResult(
            text: text,
            tokenIds: decoded.tokens,
            encoderSeconds: encoderSecs,
            decoderSeconds: decoderSecs,
            totalSeconds: CFAbsoluteTimeGetCurrent() - total0,
            cappedWindows: decoded.hitCap ? 1 : 0)
    }

    public func transcribeLong(
        audio: [Float],
        models: LoadedModels,
        language: CohereAsrConfig.Language = .english,
        maxNewTokens: Int? = nil,
        repetitionPenalty: Float = 1.1,
        noRepeatNgram: Int = 3
    ) throws -> TranscriptionResult {
        let total0 = CFAbsoluteTimeGetCurrent()

        let sr = CohereAsrConfig.sampleRate
        let chunkSamples = Int(CohereAsrConfig.maxAudioSeconds) * sr
        let hopSamples = Int(CohereAsrConfig.chunkHopSeconds) * sr

        if audio.count <= chunkSamples {
            return try transcribe(
                audio: audio,
                models: models,
                language: language,
                maxNewTokens: maxNewTokens,
                repetitionPenalty: repetitionPenalty,
                noRepeatNgram: noRepeatNgram)
        }

        if language.writesWithoutSpaces {
            return try transcribePauseChunks(
                audio: audio,
                models: models,
                language: language,
                maxNewTokens: maxNewTokens,
                repetitionPenalty: repetitionPenalty,
                noRepeatNgram: noRepeatNgram,
                startTime: total0)
        }

        var mergedTokens: [Int] = []
        var encoderSecs: Double = 0
        var decoderSecs: Double = 0
        var cappedWindows = 0
        var start = 0

        while start < audio.count {
            let end = min(start + chunkSamples, audio.count)
            let chunk = Array(audio[start..<end])

            if start > 0, (end - start) <= (chunkSamples - hopSamples) {
                break
            }

            let result = try transcribe(
                audio: chunk,
                models: models,
                language: language,
                maxNewTokens: maxNewTokens,
                repetitionPenalty: repetitionPenalty,
                noRepeatNgram: noRepeatNgram)

            encoderSecs += result.encoderSeconds
            decoderSecs += result.decoderSeconds
            cappedWindows += result.cappedWindows

            mergedTokens = Self.mergeTokenStreams(prefix: mergedTokens, suffix: result.tokenIds)

            if end >= audio.count { break }
            start += hopSamples
        }

        let text = Self.convertTokensToText(mergedTokens, vocabulary: models.vocabulary)
        return TranscriptionResult(
            text: text,
            tokenIds: mergedTokens,
            encoderSeconds: encoderSecs,
            decoderSeconds: decoderSecs,
            totalSeconds: CFAbsoluteTimeGetCurrent() - total0,
            cappedWindows: cappedWindows)
    }

    private func transcribePauseChunks(
        audio: [Float],
        models: LoadedModels,
        language: CohereAsrConfig.Language,
        maxNewTokens: Int?,
        repetitionPenalty: Float,
        noRepeatNgram: Int,
        startTime: CFAbsoluteTime
    ) throws -> TranscriptionResult {
        let sr = CohereAsrConfig.sampleRate
        let chunks = Self.pauseAlignedChunks(
            audio,
            maxChunkSamples: Int(CohereAsrConfig.pauseChunkSeconds * Float(sr)),
            searchSamples: Int(CohereAsrConfig.pauseSearchSeconds * Float(sr)),
            windowSamples: CohereAsrConfig.pauseEnergyWindowSamples)

        var tokens: [Int] = []
        var texts: [String] = []
        var encoderSecs: Double = 0
        var decoderSecs: Double = 0
        var cappedWindows = 0
        for range in chunks {
            let result = try transcribe(
                audio: Array(audio[range]),
                models: models,
                language: language,
                maxNewTokens: maxNewTokens,
                repetitionPenalty: repetitionPenalty,
                noRepeatNgram: noRepeatNgram)

            encoderSecs += result.encoderSeconds
            decoderSecs += result.decoderSeconds
            cappedWindows += result.cappedWindows

            tokens += result.tokenIds
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
        }

        return TranscriptionResult(
            text: texts.joined(),
            tokenIds: tokens,
            encoderSeconds: encoderSecs,
            decoderSeconds: decoderSecs,
            totalSeconds: CFAbsoluteTimeGetCurrent() - startTime,
            cappedWindows: cappedWindows)
    }

    static func pauseAlignedChunks(
        _ audio: [Float],
        maxChunkSamples: Int,
        searchSamples: Int,
        windowSamples: Int
    ) -> [Range<Int>] {
        guard audio.count > maxChunkSamples, maxChunkSamples > 0 else {
            return audio.isEmpty ? [] : [0..<audio.count]
        }

        var chunks: [Range<Int>] = []
        var start = 0
        while start < audio.count {
            let limit = start + maxChunkSamples
            if limit >= audio.count {
                chunks.append(start..<audio.count)
                break
            }
            let cut = quietestWindowStart(
                audio, from: max(start, limit - searchSamples), to: limit, windowSamples: windowSamples)
            let end = max(start + 1, cut)
            chunks.append(start..<end)
            start = end
        }
        return chunks
    }

    static func quietestWindowStart(
        _ audio: [Float], from: Int, to: Int, windowSamples: Int
    ) -> Int {
        guard to - from > windowSamples, windowSamples > 0 else { return (from + to) / 2 }
        var quietest = from
        var lowest = Float.infinity
        audio.withUnsafeBufferPointer { samples in
            var offset = from
            while offset + windowSamples < to {
                var energy: Float = 0
                vDSP_svesq(samples.baseAddress! + offset, 1, &energy, vDSP_Length(windowSamples))
                if energy < lowest {
                    lowest = energy
                    quietest = offset
                }
                offset += windowSamples
            }
        }
        return quietest
    }

    static func mergeTokenStreams(
        prefix: [Int],
        suffix: [Int],
        windowTokens: Int = 48,
        minMatch: Int = 4
    ) -> [Int] {
        if prefix.isEmpty { return suffix }
        if suffix.isEmpty { return prefix }

        let pTail = Array(prefix.suffix(windowTokens))
        let sHead = Array(suffix.prefix(windowTokens))
        let m = pTail.count
        let n = sHead.count
        if m == 0 || n == 0 { return prefix + suffix }

        var dp = [Int](repeating: 0, count: n + 1)
        var bestLen = 0
        var bestPEnd = 0  // index in pTail (exclusive) where the match ends
        var bestSEnd = 0  // index in sHead (exclusive) where the match ends
        for i in 1...m {
            var prev = 0
            for j in 1...n {
                let temp = dp[j]
                if pTail[i - 1] == sHead[j - 1] {
                    dp[j] = prev + 1
                    if dp[j] > bestLen || (dp[j] == bestLen && i > bestPEnd) {
                        bestLen = dp[j]
                        bestPEnd = i
                        bestSEnd = j
                    }
                } else {
                    dp[j] = 0
                }
                prev = temp
            }
        }

        guard bestLen >= minMatch else { return prefix + suffix }
        let prefixDrop = m - bestPEnd
        guard prefixDrop + bestSEnd <= windowTokens else { return prefix + suffix }

        return Array(prefix.prefix(prefix.count - prefixDrop)) + Array(suffix.dropFirst(bestSEnd))
    }

    private func runEncoder(
        paddedMel: [[Float]], featureLength: Int, encoder: MLModel
    ) throws -> (hidden: MLMultiArray, encoderValidFrames: Int) {
        let nMels = CohereAsrConfig.numMelBins
        let nFrames = 3_500

        let mel = try MLMultiArray(
            shape: [1, NSNumber(value: nMels), NSNumber(value: nFrames)], dataType: .float32)
        let melPtr = mel.dataPointer.bindMemory(to: Float.self, capacity: nMels * nFrames)
        for m in 0..<nMels {
            let row = paddedMel[m]
            for f in 0..<nFrames { melPtr[m * nFrames + f] = row[f] }
        }

        let featLen = try MLMultiArray(shape: [1], dataType: .int32)
        featLen[0] = NSNumber(value: featureLength)

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_features": MLFeatureValue(multiArray: mel),
            "feature_length": MLFeatureValue(multiArray: featLen),
        ])
        let out = try encoder.prediction(from: provider)
        guard let hidden = out.featureValue(for: "hidden_states")?.multiArrayValue else {
            throw CohereAsrError.encodingFailed("Encoder output missing 'hidden_states'")
        }
        let encoderSeqLen = hidden.shape[1].intValue
        let encoderValid = Self.encoderValidFrames(
            featureLength: featureLength, encoderSeqLen: encoderSeqLen)
        return (hidden, encoderValid)
    }

    public static func encoderValidFrames(
        featureLength: Int, encoderSeqLen: Int,
        melFrames: Int = 3_500, encoderFrames: Int = 438
    ) -> Int {
        let raw = Int((Double(featureLength * encoderFrames) / Double(melFrames)).rounded(.up))
        return max(1, min(raw, encoderSeqLen))
    }

    private struct DecodeOutput {
        let tokens: [Int]
        let hitCap: Bool
    }

    private func decodeCacheExternal(
        encoderHidden: MLMultiArray,
        encoderValidFrames: Int,
        language: CohereAsrConfig.Language,
        maxNewTokens: Int,
        repetitionPenalty: Float,
        noRepeatNgram: Int,
        decoder: MLModel,
        cacheLength: Int,
        cacheDType: MLMultiArrayDataType,
        useStaticSelfMask: Bool
    ) throws -> DecodeOutput {
        let cacheShape: [NSNumber] = [
            1,
            NSNumber(value: CohereAsrConfig.numDecoderHeads),
            NSNumber(value: cacheLength),
            NSNumber(value: CohereAsrConfig.headDim),
        ]

        var kCaches: [MLMultiArray] = []
        var vCaches: [MLMultiArray] = []
        kCaches.reserveCapacity(CohereAsrConfig.numDecoderLayers)
        vCaches.reserveCapacity(CohereAsrConfig.numDecoderLayers)
        for _ in 0..<CohereAsrConfig.numDecoderLayers {
            let k = try MLMultiArray(shape: cacheShape, dataType: cacheDType)
            let v = try MLMultiArray(shape: cacheShape, dataType: cacheDType)
            Self.zeroFill(k)
            Self.zeroFill(v)
            kCaches.append(k)
            vCaches.append(v)
        }

        let encoderSeqLen = encoderHidden.shape[1].intValue
        let crossMask = try Self.buildCrossAttentionMask(
            encoderSeqLen: encoderSeqLen,
            encoderValid: encoderValidFrames,
            dtype: cacheDType)

        let prompt = language.promptSequence
        var allTokens: [Int] = []
        var outputTokens: [Int] = []
        var currentToken = prompt[0]
        var sawEos = false
        let effectiveMax = Self.decodeStepCount(
            maxNewTokens: maxNewTokens, promptCount: prompt.count, cacheLength: cacheLength)

        for step in 0..<effectiveMax {
            try DictationTensor.checkParent()
            if step < prompt.count { currentToken = prompt[step] }

            let inputId = try MLMultiArray(shape: [1, 1], dataType: .int32)
            inputId[0] = NSNumber(value: currentToken)

            let positionId = try MLMultiArray(shape: [1, 1], dataType: .int32)
            positionId[0] = NSNumber(value: step)

            let selfMask = try Self.buildSelfAttentionMask(
                step: step, length: cacheLength, useStatic: useStaticSelfMask, dtype: cacheDType)

            var inputs: [String: MLFeatureValue] = [
                "input_id": MLFeatureValue(multiArray: inputId),
                "position_id": MLFeatureValue(multiArray: positionId),
                "encoder_hidden_states": MLFeatureValue(multiArray: encoderHidden),
                "cross_attention_mask": MLFeatureValue(multiArray: crossMask),
                "attention_mask": MLFeatureValue(multiArray: selfMask),
            ]
            for i in 0..<CohereAsrConfig.numDecoderLayers {
                inputs["k_cache_\(i)"] = MLFeatureValue(multiArray: kCaches[i])
                inputs["v_cache_\(i)"] = MLFeatureValue(multiArray: vCaches[i])
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
            let out = try decoder.prediction(from: provider)

            guard let logits = out.featureValue(for: "logits")?.multiArrayValue else {
                throw CohereAsrError.decodingFailed("Decoder output missing 'logits'")
            }

            var logitBuf = Self.copyLogitsFloat32(logits)
            Self.applyRepetitionPenalty(&logitBuf, history: allTokens, penalty: repetitionPenalty)
            Self.applyNoRepeatNgram(&logitBuf, history: allTokens, n: noRepeatNgram)

            let nextToken = Self.argmax(logitBuf)
            allTokens.append(currentToken)

            if step >= prompt.count - 1, nextToken == CohereAsrConfig.SpecialTokens.eosToken {
                sawEos = true
                break
            }
            if step >= prompt.count - 1 {
                outputTokens.append(nextToken)
            }

            for i in 0..<CohereAsrConfig.numDecoderLayers {
                guard
                    let kOut = out.featureValue(for: "k_cache_\(i)_out")?.multiArrayValue,
                    let vOut = out.featureValue(for: "v_cache_\(i)_out")?.multiArrayValue
                else {
                    throw CohereAsrError.decodingFailed(
                        "Missing updated cache for layer \(i)")
                }
                kCaches[i] = kOut
                vCaches[i] = vOut
            }

            currentToken = (step < prompt.count - 1) ? prompt[step + 1] : nextToken
        }

        return DecodeOutput(tokens: outputTokens, hitCap: !sawEos)
    }

    static func buildSelfAttentionMask(
        step: Int, length: Int, useStatic: Bool, dtype: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        if !useStatic {
            let mask = try MLMultiArray(
                shape: [1, 1, 1, NSNumber(value: step + 1)], dataType: dtype)
            zeroFill(mask)
            return mask
        }

        let mask = try MLMultiArray(
            shape: [1, 1, 1, NSNumber(value: length)], dataType: dtype)
        zeroFill(mask)
        let firstBlocked = step + 1
        guard firstBlocked < length else { return mask }

        let invalidValue: Float = -1.0e4
        switch dtype {
        case .float32:
            let ptr = mask.dataPointer.bindMemory(to: Float.self, capacity: length)
            for i in firstBlocked..<length { ptr[i] = invalidValue }
        case .float16:
            let ptr = mask.dataPointer.bindMemory(to: UInt16.self, capacity: length)
            let bits = float16Bits(invalidValue)
            for i in firstBlocked..<length { ptr[i] = bits }
        default:
            for i in firstBlocked..<length {
                mask[[0, 0, 0, NSNumber(value: i)] as [NSNumber]] = NSNumber(value: invalidValue)
            }
        }
        return mask
    }

    static func buildCrossAttentionMask(
        encoderSeqLen: Int, encoderValid: Int, dtype: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        let mask = try MLMultiArray(
            shape: [1, 1, 1, NSNumber(value: encoderSeqLen)], dataType: dtype)
        zeroFill(mask)
        let valid = max(0, min(encoderValid, encoderSeqLen))
        guard valid < encoderSeqLen else { return mask }

        let invalidValue: Float = -1.0e4
        switch dtype {
        case .float32:
            let ptr = mask.dataPointer.bindMemory(to: Float.self, capacity: encoderSeqLen)
            for i in valid..<encoderSeqLen { ptr[i] = invalidValue }
        case .float16:
            let ptr = mask.dataPointer.bindMemory(to: UInt16.self, capacity: encoderSeqLen)
            let bits = float16Bits(invalidValue)
            for i in valid..<encoderSeqLen { ptr[i] = bits }
        default:
            for i in valid..<encoderSeqLen {
                mask[[0, 0, 0, NSNumber(value: i)] as [NSNumber]] = NSNumber(value: invalidValue)
            }
        }
        return mask
    }

    private static func float16Bits(_ value: Float) -> UInt16 {
        var v = value
        var dst: UInt16 = 0
        withUnsafeMutablePointer(to: &v) { srcPtr in
            withUnsafeMutablePointer(to: &dst) { dstPtr in
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(srcPtr),
                    height: 1, width: 1, rowBytes: MemoryLayout<Float>.size)
                var dstBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(dstPtr),
                    height: 1, width: 1, rowBytes: MemoryLayout<UInt16>.size)
                _ = vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, 0)
            }
        }
        return dst
    }

    static func copyLogitsFloat32(_ logits: MLMultiArray) -> [Float] {
        let count = logits.count
        var out = [Float](repeating: 0, count: count)
        switch logits.dataType {
        case .float32:
            let src = logits.dataPointer.bindMemory(to: Float.self, capacity: count)
            out.withUnsafeMutableBufferPointer { buf in
                _ = memcpy(buf.baseAddress, src, count * MemoryLayout<Float>.size)
            }
        case .float16:
            let src = logits.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            out.withUnsafeMutableBufferPointer { buf in
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src),
                    height: 1, width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<UInt16>.size)
                var dstBuf = vImage_Buffer(
                    data: buf.baseAddress, height: 1,
                    width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<Float>.size)
                _ = vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, 0)
            }
        default:
            for i in 0..<count { out[i] = logits[i].floatValue }
        }
        return out
    }

    static func applyRepetitionPenalty(
        _ logits: inout [Float], history: [Int], penalty: Float
    ) {
        guard penalty != 1.0, !history.isEmpty else { return }
        var seen = Set<Int>()
        seen.reserveCapacity(history.count)
        for t in history where t >= 0 && t < logits.count { seen.insert(t) }
        for t in seen {
            let v = logits[t]
            logits[t] = (v >= 0) ? v / penalty : v * penalty
        }
    }

    static func applyNoRepeatNgram(_ logits: inout [Float], history: [Int], n: Int) {
        guard n > 0, history.count >= n - 1 else { return }
        if n == 1 {
            for t in history where t >= 0 && t < logits.count { logits[t] = -1e9 }
            return
        }
        let prefix = Array(history.suffix(n - 1))
        var forbidden = Set<Int>()
        let upper = history.count - (n - 1)
        if upper <= 0 { return }
        for i in 0..<upper {
            var match = true
            for j in 0..<(n - 1) where history[i + j] != prefix[j] {
                match = false
                break
            }
            if match {
                let idx = i + (n - 1)
                if idx < history.count { forbidden.insert(history[idx]) }
            }
        }
        for t in forbidden where t >= 0 && t < logits.count { logits[t] = -1e9 }
    }

    static func argmax(_ logits: [Float]) -> Int {
        var maxIdx: vDSP_Length = 0
        var maxVal: Float = 0
        logits.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_maxvi(base, 1, &maxVal, &maxIdx, vDSP_Length(logits.count))
        }
        return Int(maxIdx)
    }

    static func zeroFill(_ array: MLMultiArray) {
        let count = array.count
        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            memset(ptr, 0, count * MemoryLayout<Float>.size)
        case .float16:
            let ptr = array.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            memset(ptr, 0, count * MemoryLayout<UInt16>.size)
        case .int32:
            let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: count)
            memset(ptr, 0, count * MemoryLayout<Int32>.size)
        default:
            for i in 0..<count {
                array[i] = NSNumber(value: 0)
            }
        }
    }

    static func convertTokensToText(_ tokenIds: [Int], vocabulary: [Int: String]) -> String {
        guard !tokenIds.isEmpty else { return "" }
        var out = ""
        var byteBuf: [UInt8] = []

        @inline(__always) func flushBytes() {
            if !byteBuf.isEmpty {
                // swiftlint:disable:next optional_data_string_conversion
                out.append(String(decoding: byteBuf, as: UTF8.self))
                byteBuf.removeAll(keepingCapacity: true)
            }
        }

        for tokenId in tokenIds {
            if tokenId <= 4 || tokenId == CohereAsrConfig.SpecialTokens.eosToken { continue }
            guard let piece = vocabulary[tokenId], !piece.isEmpty else { continue }
            if piece.hasPrefix("<|") { continue }
            if let b = parseByteFallback(piece) {
                byteBuf.append(b)
                continue
            }
            flushBytes()
            out.append(piece)
        }
        flushBytes()
        return out.replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func parseByteFallback(_ piece: String) -> UInt8? {
        guard piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">") else { return nil }
        let start = piece.index(piece.startIndex, offsetBy: 3)
        let end = piece.index(piece.endIndex, offsetBy: -1)
        return UInt8(piece[start..<end], radix: 16)
    }
}
