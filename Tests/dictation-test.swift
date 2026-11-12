import Foundation

@main
struct DictationTest {
    static func main() throws {
        let locale = Locale(identifier: "en_US")
        func check(_ actual: String, _ expected: String) {
            guard actual == expected else {
                print("Expected \(expected.debugDescription), got \(actual.debugDescription)")
                exit(1)
            }
        }

        typealias Context = DictationTextFormatter.Context
        check(DictationTextFormatter.removingFillerWords("Um, I, uh, like this."), "I like this.")
        check(DictationTextFormatter.removingFillerWords("I think um."), "I think.")
        check(DictationTextFormatter.removingFillerWords("Let's go. Um."), "Let's go.")
        check(DictationTextFormatter.removingFillerWords("Um, uh."), "")
        check(DictationTextFormatter.removingFillerWords("She said “um” on the album."), "She said “um” on the album.")
        check(DictationTextFormatter.format("  Hello. \n", context: nil), "Hello.")
        check(DictationTextFormatter.format("hello", context: Context(before: "", after: "")), "Hello")
        check(DictationTextFormatter.format("World", context: Context(before: "Hello", after: "")), " world")
        check(DictationTextFormatter.format("world", context: Context(before: "Hello.", after: "")), " World")
        check(DictationTextFormatter.format("hello", context: Context(before: "Wait. ", after: "")), "Hello")
        check(
            DictationTextFormatter.format("hello", context: Context(before: "Wait\n  ", after: "")), "Hello")
        check(
            DictationTextFormatter.format("World", context: Context(before: "Hello ", after: "again")),
            "world ")
        check(DictationTextFormatter.format("hello", context: Context(before: "(", after: ")")), "hello")
        check(
            DictationTextFormatter.format("application", context: Context(before: "l’", after: "")),
            "application")
        check(
            DictationTextFormatter.format(
                "Tinycast", context: Context(before: "Use", after: "again"),
                adaptCapitalization: false), " Tinycast ")
        check(
            DictationTextFormatter.format(
                "world", context: Context(before: "Hello.", after: ""),
                adaptCapitalization: false), " world")
        check(
            DictationTextFormatter.format(
                "hello", context: Context(before: "", after: ""),
                adaptCapitalization: false), "hello")
        check(
            DictationTextFormatter.format(
                "World.", context: Context(before: "Hello ", after: ")"),
                adaptCapitalization: false), "World.")
        let document = "prefix. Text to replace suffix"
        check(
            DictationTextFormatter.format(
                "world",
                context: Context(
                    before: document.prefix(7), after: document.suffix(6))), " World ")
        let recognized = "Try Whisper Flow."
        let edited = "Try Wispr Flow."
        guard let correction = DictationCorrection.infer(from: recognized, to: edited, recognized: recognized),
            let updated = DictationCorrection.infer(from: edited, to: "Try Wisper Flow.", recognized: recognized)
        else { fatalError("Expected a spelling correction and an update to it") }
        check(correction.original, "Whisper")
        check(correction.spelling, "Wispr")
        check(updated.original, "Whisper")
        check(updated.spelling, "Wisper")
        check(
            DictationCorrection.applying([correction], to: "WHISPER, whisper.ai, whisper@example.com."),
            "Wispr, whisper.ai, whisper@example.com.")
        guard let phrase = DictationCorrection.manual(spelling: "Tinycast", misspelling: "tiny cast"),
            let short = DictationCorrection.manual(spelling: "Small", misspelling: "tiny"),
            let word = DictationCorrection.manual(spelling: "  OpenAI  ", misspelling: ""),
            let punctuation = DictationCorrection.manual(spelling: ".NET", misspelling: "")
        else { fatalError("Expected valid manual dictionary entries") }
        check(
            DictationCorrection.applying([short, phrase, word, punctuation], to: "Try (TINY  CAST), openai, and .net."),
            "Try (Tinycast), OpenAI, and .NET.")
        let oldEntry = try JSONDecoder().decode(
            DictationCorrection.self, from: Data(#"{"original":"Wisper","spelling":"Wispr"}"#.utf8))
        guard !oldEntry.isManual else { fatalError("Existing corrections should still be treated as learned") }
        for rewrite in ["Use Wispr Flow.", "Try Wispr Flow!", "Try Wispr Flow. Extra text."] {
            guard DictationCorrection.infer(from: recognized, to: rewrite, recognized: recognized) == nil
            else { fatalError("An edit outside the corrected word must not be learned") }
        }
        check(DictationModel.redux.folderName, "parakeet-redux")
        check(DictationModel.ultra.folderName, "parakeet-ultra")
        check(DictationModel.redux.title, "Parakeet · Redux")
        check(DictationModel.ultra.title, "Parakeet · Ultra")
        check(DictationIdleRelease.allCases.map(\.rawValue).description, "[-1, 0, 1, 2, 5, 10, 15, 20, 30, 60]")
        check(DictationIdleRelease.never.title(locale: locale), "Never")
        check(DictationIdleRelease.oneHour.title(locale: locale), "1 hour")
        check(DictationIdleRelease.oneHour.title(locale: Locale(identifier: "fr_FR")), "1\u{00a0}heure")
        check(DictationLanguage.english.displayName(locale: locale), "English")
        check(DictationLanguage.english.displayName(locale: Locale(identifier: "de_DE")), "Englisch")
        check(DictationLanguage.english.rawValue, "English")
        check(DictationModel.qwenSmall.folderName, "qwen-0.6b")
        check(DictationModel.qwenLarge.folderName, "qwen-1.7b")
        for family in DictationModel.Family.allCases {
            guard DictationModel.allCases.contains(where: { $0.family == family }) else {
                fatalError("Every engine should expose at least one model")
            }
        }
        for model in DictationModel.allCases {
            guard !model.components.isEmpty, model.revision.count == 40,
                model.requiredFiles.isSuperset(of: model.components)
            else {
                fatalError("Model installation metadata is incomplete")
            }
            if let configuration = model.parakeetConfiguration {
                guard model.family == .parakeet,
                    configuration.blankToken == (model == .v2 ? 1024 : 8192),
                    configuration.encoderUsesGPU == (model == .redux),
                    model.components.contains(configuration.encoder + ".mlmodelc"),
                    model.components.contains(configuration.joint + ".mlmodelc")
                else {
                    fatalError("Parakeet download and inference disagree")
                }
            } else if model == .unified {
                guard model.family == .parakeet,
                    model.components.contains("parakeet_unified_encoder_int8.mlmodelc")
                else { fatalError("Unified Parakeet installation metadata is incomplete") }
            } else if !model.isQwen && !model.isCohere {
                fatalError("Missing Parakeet decoding configuration")
            }
        }
        print("Dictation text formatting passed")
    }
}
