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
        let cleanupStart = ContinuousClock.now
        var cleanupClockReads = 0
        check(
            DictationTextFormatter.basicCleanup(
                "The cost is 20 Ghana Sadis and 75 passe was. Call at nine thirty AM.", normalize: { $0 }, now: {
                    cleanupClockReads += 1
                    return cleanupClockReads < 3 ? cleanupStart : cleanupStart + .milliseconds(30)
                }),
            "The cost is GHS 20.75. Call at nine thirty AM.")
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
        let firstDetection = DictationCorrection.detect(from: recognized, to: edited, recognized: recognized)
        let secondDetection = DictationCorrection.detect(from: edited, to: "Try Wisper Flow.", recognized: recognized)
        guard let correction = (firstDetection.corrections + firstDetection.candidates).first,
            let updated = (secondDetection.corrections + secondDetection.candidates).first
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
        testLearningCorrections()
        testCorrectionAttribution()
        testCorrectionSession()
        stressCorrectionLearning()
        stressApplyingDictionary()
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
        print("Dictation formatting, model options, and correction learning passed")
    }

    private static func testLearningCorrections() {
        func check(_ recognized: String, _ edited: String, replay: String? = nil, pairs: [String: String]) {
            let result = DictationCorrection.detect(from: recognized, to: edited, recognized: recognized)
            let detected = result.corrections + result.candidates
            let spellings = Dictionary(detected.map { ($0.original, $0.spelling) }, uniquingKeysWith: { first, _ in first })
            precondition(detected.count == pairs.count && spellings == pairs,
                "Expected \(pairs) for \(edited.prefix(120).debugDescription), got \(spellings)")
            if let expected = replay ?? (pairs.isEmpty ? nil : edited) {
                precondition(DictationCorrection.applying(detected, to: recognized) == expected,
                    "Replaying detected corrections should produce \(expected.prefix(120).debugDescription)")
            }
        }

        check("Tell Jhon to bring Kathrine and Siobahn.", "Tell John to bring Katherine and Siobhan.",
            pairs: ["Jhon": "John", "Kathrine": "Katherine", "Siobahn": "Siobhan"])
        check("Ask (Christoper) and «Mckensie» for notes.", "Ask (Christopher) and «McKenzie» for notes.",
            pairs: ["Christoper": "Christopher", "Mckensie": "McKenzie"])
        check("Ask Christoper Mckensie for notes.", "Ask Christopher McKenzie for notes.",
            pairs: ["Christoper": "Christopher", "Mckensie": "McKenzie"])
        check("Try tiny cast next to OpenAI.", "Try Tinycast next to Open AI.",
            pairs: ["tiny cast": "Tinycast", "OpenAI": "Open AI"])
        check("Ask E\u{301}mile and Siobahn about it.", "Ask Émilie and Siobhán about it.",
            pairs: ["E\u{301}mile": "Émilie", "Siobahn": "Siobhán"])
        check("Use tiny cast and tiny cast.", "Use Tinycast and Tinycast.",
            pairs: ["tiny cast": "Tinycast"])
        check("Ask Jhon about notes and Jhon about files.", "Ask John about notes and Jhon about files.", pairs: [:])
        check("Ask Jhon about notes and Jhon about files.", "Ask John about notes and Johan about files.", pairs: [:])
        check("Ask Jhon to meet Jhon about Jhon.", "Ask Jhon to meet John about Jhon.", pairs: [:])
        check("Ask Émile and E\u{301}mile about it.", "Ask Émilie and E\u{301}mile about it.", pairs: [:])
        check("Tell Anna and Anne.", "Tell Anne and Anna.", pairs: [:])
        check("Tell Anna to call back and ask Anne.", "Tell Anne to call back and ask Anna.", pairs: [:])
        check("Tell Anne, Anna, and Anya.", "Tell Anna, Anya, and Anne.", pairs: [:])
        check("Ask Haptel.", "Ask (Haptel)!", pairs: [:])

        for (original, rewrite) in [
            ("to send 12 files.", "to send 13 files."),
            ("to send four files.", "to send five files."),
            ("to call on Monday.", "to call on Sunday."),
            ("that we can go.", "that we can't go."),
            ("that we should go.", "that we should not go."),
            ("that we can go.", "that we cannot go."),
            ("to send the files.", "to keep the files."),
            ("to send the files.", "to send the files!"),
            ("to use tinycast.", "to use Tinycast."),
        ] {
            check("Tell Jhon \(original)", "Tell John \(rewrite)", replay: "Tell John \(original)",
                pairs: ["Jhon": "John"])
        }

        let confidence = DictationCorrection.detect(
            from: "Ask Haptel about Samoa.", to: "Ask Hubtel about Samuel.", recognized: "Ask Haptel about Samoa.")
        precondition(confidence.corrections.map(\.spelling) == ["Hubtel"], "Hubtel should be learned immediately")
        precondition(confidence.candidates.map(\.spelling) == ["Samuel"], "Samuel should require a second observation")

        let unchanged = String(repeating: " notes for the next meeting", count: 250)
        check("Ask Jhon for\(unchanged) with Siobahn.", "Ask John for\(unchanged) with Siobhan.",
            pairs: ["Jhon": "John", "Siobahn": "Siobhan"])
        let oversized = String(repeating: "a", count: 8_192)
        check("Jhon \(oversized)", "John \(oversized)", pairs: [:])
    }

    private static func testCorrectionAttribution() {
        let prefixes = ["Please tell", "Tell, tell", "Élodie says", "聞いて", "📓 Note"]
        let bridges = ["and then ask", "before you ask", "and, and ask", "when you ask"]
        let endings = ["next to", "about the update from", "before we discuss", "alongside"]
        let names = [("Jhon", "John"), ("Kathrine", "Katherine"), ("Siobahn", "Siobhan"), ("E\u{301}mile", "Émilie")]

        for prefix in prefixes {
            for bridge in bridges {
                for ending in endings {
                    for (wrong, right) in names {
                        let recognized = "\(prefix) tiny cast \(bridge) \(wrong) \(ending) OpenAI."
                        let inserted = "\(prefix) Tinycast \(bridge) \(wrong) \(ending) Open AI."
                        let edited = "\(prefix) tiny cast \(bridge) \(right) \(ending) OpenAI."
                        let detection = DictationCorrection.detect(from: inserted, to: edited, recognized: recognized)
                        let spellings = Dictionary(uniqueKeysWithValues: detection.corrections.map { ($0.original, $0.spelling) })
                        precondition(spellings == ["tiny cast": "tiny cast", wrong: right, "OpenAI": "OpenAI"],
                            "Existing split and joined words should preserve source attribution for \(recognized)")
                    }
                }
            }
        }

        for (wrong, right) in names {
            let recognized = "Ask \(wrong) again, and ask \(wrong) about it."
            let matching = "Ask \(right) again, and ask \(right) about it."
            let consistent = DictationCorrection.detect(from: recognized, to: matching, recognized: recognized)
            precondition(consistent.corrections.count == 1 && consistent.corrections.first?.spelling == right,
                "Identical edits to repeated names should produce one dictionary entry")
            let divergent = "Ask \(right) again, and ask \(wrong) about it."
            let conflicting = DictationCorrection.detect(from: recognized, to: divergent, recognized: recognized)
            precondition(conflicting.corrections.isEmpty && conflicting.candidates.isEmpty,
                "An edit of one repeated name should not globally replace it")
        }
    }

    private static func testCorrectionSession() {
        let recognized = "Ask Haptel about Kathrine."
        var session = DictationCorrectionSession(id: UUID(), inserted: recognized, recognized: recognized, baseline: [])
        let firstEdit = "Ask Hubtel about Kathrine."
        let secondEdit = "Ask Hubtel about Katherine."
        precondition(session.observe(firstEdit, at: .milliseconds(100)) == nil, "A fresh edit has not settled")
        precondition(session.observe(secondEdit, at: .milliseconds(1_600)) == nil, "Another edit restarts the debounce")
        precondition(session.observe(secondEdit, at: .milliseconds(3_599)) == nil, "Both edits are still settling")
        let settled = session.observe(secondEdit, at: .milliseconds(3_600))
        precondition(Set(settled?.corrections.map(\.spelling) ?? []) == ["Hubtel", "Katherine"],
            "The settled edit includes both corrections")
        precondition(session.observe(secondEdit, at: .seconds(6)) == nil, "An unchanged edit is evaluated once")
        session.learned = settled?.corrections ?? []
        let punctuated = session.observe("Ask Hubtel about Katherine!", at: .seconds(7), flush: true)
        precondition(Set(punctuated?.corrections.map(\.spelling) ?? []) == ["Hubtel", "Katherine"],
            "A punctuation edit preserves the learned spellings")
        let rewritten = session.observe("Send the agenda by Friday.", at: .seconds(8), flush: true)
        precondition(Set(rewritten?.corrections.map(\.spelling) ?? []) == ["Hubtel", "Katherine"],
            "A semantic rewrite cannot erase already learned spellings")

        let undone = session.observe(recognized, at: .seconds(9), flush: true)
        precondition(undone?.corrections.isEmpty == true && undone?.candidates.isEmpty == true,
            "Undoing the entire edit yields an empty observation for the store")
        let oversized = String(repeating: "a", count: 8_193)
        precondition(session.observe(oversized, at: .seconds(10), flush: true) == nil, "An oversized edit is ignored")
        let flushed = session.observe(firstEdit, at: .seconds(11), flush: true)
        precondition(flushed?.corrections.map(\.spelling) == ["Hubtel"],
            "Starting another dictation can flush an unsettled edit")
    }

    private static func stressCorrectionLearning() {
        let recognized = "Ask Haptel for the latest tiny cast build and tell Kathrine to send it by Friday."
        let edited = "Ask Hubtel for the latest Tinycast build and tell Katherine to send it by Monday."
        let initialFootprint = footprint()
        let start = ContinuousClock.now
        var peakFootprint = initialFootprint
        var learnedCount = 0
        for index in 0..<1_000 {
            let result = DictationCorrection.detect(from: recognized, to: edited, recognized: recognized)
            learnedCount += result.corrections.count
            if index.isMultiple(of: 100) { peakFootprint = max(peakFootprint, footprint()) }
        }
        precondition(learnedCount == 3_000, "Each pass should detect the three spellings and skip the date change")
        let finalFootprint = footprint()
        peakFootprint = max(peakFootprint, finalFootprint)
        print("1,000 correction inferences completed in \(start.duration(to: .now))")
        print("Physical footprint (bytes) was \(initialFootprint) before, \(peakFootprint) sampled peak, \(finalFootprint) after")
    }

    private static func stressApplyingDictionary() {
        let context = DictationCorrection.Context(before: "ask", after: "about")
        let entries = (0..<100).map { index in
            DictationCorrection(original: "name\(index)", spelling: "Person\(index)",
                context: index.isMultiple(of: 2) ? context : nil)
        }
        let recognized = "Ask name98 about name99, then ignore name96."
        let edited = "Ask Person98 about Person99, then ignore name96."
        let initialFootprint = footprint()
        let start = ContinuousClock.now
        precondition(DictationCorrection.applying(entries, to: recognized) == edited)
        let first = start.duration(to: .now)
        let repeatedStart = ContinuousClock.now
        for _ in 0..<100 {
            precondition(DictationCorrection.applying(entries, to: recognized) == edited)
        }
        let repeated = repeatedStart.duration(to: .now)
        let finalFootprint = footprint()
        precondition(finalFootprint <= initialFootprint + 16 * 1_024 * 1_024,
            "Repeated dictionary application should retain less than 16 MiB of additional physical footprint")
        print("Applying a 100-entry dictionary took \(first) once and \(repeated) across 100 repeats")
        print("Dictionary application footprint (bytes) was \(initialFootprint) before and \(finalFootprint) after")
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return info.phys_footprint
    }
}
