import Foundation

enum DictationModel: String, CaseIterable, Identifiable, Codable, Sendable {
    struct ParakeetConfiguration: Sendable {
        let encoder: String
        let encoderFunction: String?
        let joint: String
        let blankToken: Int
        let encoderUsesGPU: Bool
    }
    enum Family: String, CaseIterable, Identifiable {
        case parakeet = "Parakeet", qwen = "Qwen"
        var id: Self { self }
        var defaultModel: DictationModel { self == .parakeet ? .v3 : .qwenSmall }
        var summary: String {
            self == .parakeet
                ? String(localized: "Fast and memory-efficient")
                : String(localized: "More languages, but slower")
        }
    }
    case v3
    case ultra
    case redux
    case phonon2 = "phonon-2"
    case v2
    case qwenSmall = "qwen-0.6b"
    case qwenLarge = "qwen-1.7b"

    var id: Self { self }
    var title: String { "\(family.rawValue) · \(variantTitle)" }
    var variantTitle: String {
        switch self {
        case .ultra: "Ultra"
        case .redux: "Redux"
        case .v3: "V3"
        case .v2: "V2"
        case .phonon2: "Phonon-2"
        case .qwenSmall: "0.6B"
        case .qwenLarge: "1.7B"
        }
    }

    var summary: String {
        switch self {
        case .redux: String(localized: "Lightweight and efficient.")
        case .ultra: String(localized: "Higher accuracy, larger download.")
        case .v3: String(localized: "Automatically detects and transcribes 25 languages.")
        case .v2: String(localized: "Transcribes English with automatic punctuation and capitalization.")
        case .phonon2: String(localized: "Retrained from Parakeet V3 for English with a smaller download.")
        case .qwenSmall: String(localized: "Smaller and faster.")
        case .qwenLarge: String(localized: "Higher accuracy, more memory.")
        }
    }

    var family: Family {
        switch self {
        case .ultra, .redux, .v3, .v2, .phonon2: .parakeet
        case .qwenSmall, .qwenLarge: .qwen
        }
    }
    var isQwen: Bool { family == .qwen }
    var parakeetConfiguration: ParakeetConfiguration? {
        switch self {
        case .ultra, .redux:
            .init(
                encoder: "Encoder", encoderFunction: nil, joint: "JointDecisionv3",
                blankToken: 8192, encoderUsesGPU: self == .redux)
        case .v3:
            .init(
                encoder: "Encoder_v2", encoderFunction: nil, joint: "JointDecisionv3",
                blankToken: 8192, encoderUsesGPU: false)
        case .v2:
            .init(
                encoder: "Encoder", encoderFunction: nil, joint: "JointDecision",
                blankToken: 1024, encoderUsesGPU: false)
        case .phonon2:
            .init(
                encoder: "Encoder", encoderFunction: "enc_15000ms", joint: "JointDecisionv3",
                blankToken: 8192, encoderUsesGPU: false)
        case .qwenSmall, .qwenLarge: nil
        }
    }
    var coverage: String {
        switch self {
        case .ultra, .redux, .v3: String(localized: "25 languages")
        case .v2, .phonon2: String(localized: "English only")
        case .qwenSmall, .qwenLarge: String(localized: "30 languages and 22 Chinese dialects")
        }
    }
    var folderName: String { isQwen ? rawValue : "parakeet-\(rawValue)" }
    var approximateInstalledMegabytes: Int {
        switch self {
        case .ultra: 632
        case .redux: 220
        case .v3: 633
        case .v2: 464
        case .phonon2: 378
        case .qwenSmall: 940
        case .qwenLarge: 2352
        }
    }

    var components: Set<String> {
        if isQwen { return ["encoder.mlmodelc", "decoder.mlmodelc", "embedding.mlmodelc", "config.json"] }
        guard let configuration = parakeetConfiguration else { return [] }
        return [
            "Preprocessor.mlmodelc", configuration.encoder + ".mlmodelc", "Decoder.mlmodelc",
            configuration.joint + ".mlmodelc", "parakeet_vocab.json"
        ]
    }

    var requiredFiles: Set<String> { components.union(isQwen ? ["vocab.json", "merges.txt"] : []) }

    var repository: String {
        switch self {
        case .ultra, .redux: "FluidInference/\(folderName)-coreml"
        case .v3, .v2: "FluidInference/parakeet-tdt-0.6b-\(rawValue)-coreml"
        case .phonon2: "FluidInference/phonon-2-coreml"
        case .qwenSmall: "UniMocha/Qwen3-ASR-0.6B-CoreML-INT8"
        case .qwenLarge: "UniMocha/Qwen3-ASR-1.7B-CoreML-INT8"
        }
    }

    var revision: String {
        switch self {
        case .ultra: "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
        case .redux: "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9"
        case .v3: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
        case .v2: "ee09c569f73759e6d44c9bd16766f477b2b36d39"
        case .phonon2: "1702fc22e76f203d5ca464cd5d3ef130a45ce2c0"
        case .qwenSmall: "27b7a26835d7c2cd1cf774b4c490eb5519ca71a0"
        case .qwenLarge: "06312fbac1383cd22e1000c28b017634e03251a2"
        }
    }
}
