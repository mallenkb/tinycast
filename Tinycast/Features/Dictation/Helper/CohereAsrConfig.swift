// Adapted from FluidAudio (Apache-2.0), revision d653a34a620c013febd7530427b4963ae18064b2.
import Foundation

public enum CohereAsrConfig {
    public static let sampleRate: Int = 16000

    public static let maxAudioSeconds: Float = 35.0

    public static let maxSamples: Int = 560_000

    public static let chunkOverlapSeconds: Float = 5.0

    public static var chunkHopSeconds: Float { maxAudioSeconds - chunkOverlapSeconds }

    public static let pauseChunkSeconds: Float = 20.0

    public static let pauseSearchSeconds: Float = 10.0

    public static let pauseEnergyWindowSamples: Int = 1_600

    public static let vocabSize: Int = 16_384

    public static let encoderHiddenSize: Int = 1280

    public static let decoderHiddenSize: Int = 1024

    public static let numEncoderLayers: Int = 48

    public static let numDecoderLayers: Int = 8

    public static let numDecoderHeads: Int = 8

    public static let headDim: Int = 128

    public static let maxSeqLen: Int = 108

    public static let numMelBins: Int = 128

    public enum MelSpec {
        public static let nFFT: Int = 512
        public static let hopLength: Int = 160
        public static let nMels: Int = 128
        public static let fMin: Float = 0.0
        public static let fMax: Float = 8000.0
        public static let preemphasis: Float = 0.97
    }

    public enum SpecialTokens {
        public static let unkToken: Int = 0
        public static let noSpeechToken: Int = 1
        public static let padToken: Int = 2
        public static let eosToken: Int = 3
        public static let startToken: Int = 4
        public static let startOfContext: Int = 7
        public static let emoUndefined: Int = 16
        public static let pnc: Int = 5
        public static let noitn: Int = 9
        public static let notimestamp: Int = 11
        public static let nodiarize: Int = 13
        public static let wordBoundary: Int = 13764
    }

    public enum Language: String, CaseIterable, Sendable {
        case english = "en"
        case french = "fr"
        case german = "de"
        case spanish = "es"
        case italian = "it"
        case portuguese = "pt"
        case dutch = "nl"
        case polish = "pl"
        case greek = "el"
        case arabic = "ar"
        case japanese = "ja"
        case chinese = "zh"
        case vietnamese = "vi"
        case korean = "ko"

        public var writesWithoutSpaces: Bool {
            self == .japanese || self == .chinese
        }

        public var englishName: String {
            switch self {
            case .english: return "English"
            case .french: return "French"
            case .german: return "German"
            case .spanish: return "Spanish"
            case .italian: return "Italian"
            case .portuguese: return "Portuguese"
            case .dutch: return "Dutch"
            case .polish: return "Polish"
            case .greek: return "Greek"
            case .arabic: return "Arabic"
            case .japanese: return "Japanese"
            case .chinese: return "Chinese"
            case .vietnamese: return "Vietnamese"
            case .korean: return "Korean"
            }
        }

        public var tokenId: Int {
            switch self {
            case .english: return 62
            case .french: return 69
            case .german: return 76
            case .spanish: return 169
            case .italian: return 97
            case .portuguese: return 149
            case .dutch: return 60
            case .polish: return 148
            case .greek: return 77
            case .arabic: return 28
            case .japanese: return 98
            case .chinese: return 50
            case .vietnamese: return 194
            case .korean: return 110
            }
        }

        public var promptSequence: [Int] {
            let langToken = tokenId
            return [
                SpecialTokens.wordBoundary,  // ▁
                SpecialTokens.startOfContext,  // <|startofcontext|>
                SpecialTokens.startToken,  // <|startoftranscript|>
                SpecialTokens.emoUndefined,  // <|emo:undefined|>
                langToken,  // <|en|> (or other language)
                langToken,  // <|en|> (repeated)
                SpecialTokens.pnc,  // <|pnc|>
                SpecialTokens.noitn,  // <|noitn|>
                SpecialTokens.notimestamp,  // <|notimestamp|>
                SpecialTokens.nodiarize,  // <|nodiarize|>
            ]
        }
    }
}
