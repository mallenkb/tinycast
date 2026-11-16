import Foundation

@main
@MainActor
struct DictationCorrectionTest {
    enum Outcome: Equatable, CustomStringConvertible {
        case none
        case pending([String: String])
        case learned([String: String])

        var description: String {
            switch self {
            case .none: "none"
            case .pending(let pairs): "pending \(pairs)"
            case .learned(let pairs): "learned \(pairs)"
            }
        }
    }

    static var failures: [String] = []
    static let lexicon = Set("""
        a about affect and ann anna anne ask at board bring by call cluster day deploy desk doctor donald draft
        effect email every for friday full great hotel i in is it john lunch mary mc me meet met monday now of on
        open over plan please president put report restart sales samoa samuel send settings sure summary team
        that the their there this to today tomorrow tuesday use we whole will with zoe
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func isKnownWord(_ word: String) -> Bool { lexicon.contains(word.lowercased()) }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dictation-correction-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func fresh() -> DictationCorrectionStore {
            DictationCorrectionStore(fileURL: folder.appending(path: "\(UUID()).json"), isKnownWord: isKnownWord)
        }

        func dictate(
            _ recognized: String, edits: [String], store: DictationCorrectionStore
        ) throws -> Outcome {
            let inserted = DictationCorrection.applying(store.entries, to: recognized)
            let before = store.entries
            var session = DictationCorrectionSession(
                id: UUID(), inserted: inserted, recognized: recognized, baseline: store.entries,
                isKnownWord: isKnownWord)
            var pending: [String: String] = [:]
            for (index, edit) in edits.enumerated() {
                guard let detection = session.observe(edit, at: .seconds(10 * (index + 1)), flush: true)
                else { continue }
                session.learned = try store.learn(
                    detection.corrections, candidates: detection.candidates, sessionID: session.id,
                    replacing: session.learned, baseline: session.baseline)
                pending = Dictionary(
                    detection.candidates.map { ($0.original, $0.spelling) }, uniquingKeysWith: { first, _ in first })
            }
            let added = store.entries.filter { entry in !before.contains { $0.id == entry.id && $0.spelling == entry.spelling } }
            if !added.isEmpty {
                return .learned(Dictionary(added.map { ($0.original, $0.spelling) }, uniquingKeysWith: { first, _ in first }))
            }
            let unlearned = pending.filter { !store.entries.map(\.id).contains(DictationCorrection.key(for: $0.key)) }
            return unlearned.isEmpty ? .none : .pending(unlearned)
        }

        func scenario(_ name: String, _ recognized: String, _ edited: String, expect: Outcome) throws {
            let outcome = try dictate(recognized, edits: [edited], store: fresh())
            report(name, outcome == expect, "expected \(expect), got \(outcome)")
        }

        func notLearned(_ name: String, _ recognized: String, _ edited: String) throws {
            let outcome = try dictate(recognized, edits: [edited], store: fresh())
            if case .learned = outcome {
                report(name, false, "expected nothing learned, got \(outcome)")
            } else {
                report(name, true, "")
            }
        }

        try scenario("single misheard word", "Deploy the cubernetes cluster today.",
            "Deploy the Kubernetes cluster today.", expect: .learned(["cubernetes": "Kubernetes"]))
        try scenario("misheard name", "Tell Jhon the plan.", "Tell John the plan.", expect: .learned(["Jhon": "John"]))
        try scenario("multi-word mishearing", "Send it to Doctor there sure tomorrow.",
            "Send it to Doctor Thiessen tomorrow.", expect: .pending(["there sure": "Thiessen"]))
        try scenario("name merged", "Lunch at mc donald today.", "Lunch at McDonald today.",
            expect: .learned(["mc donald": "McDonald"]))
        try scenario("name split", "Ask Mary Ann about it.", "Ask MaryAnn about it.",
            expect: .learned(["Mary Ann": "MaryAnn"]))
        try scenario("sentence rewritten", "Send the report to Anna by Friday.",
            "Please email the summary to the whole team.", expect: .none)
        try scenario("meaning rewritten in place", "Send the draft to the team.", "Send the plan to the board.",
            expect: .none)
        try scenario("text deleted", "Send the report today please.", "Send the report.", expect: .none)
        try scenario("words added", "Send the report.", "Please send the full report now.", expect: .none)
        try scenario("casing-only term", "I use tinycast every day.", "I use Tinycast every day.",
            expect: .pending(["tinycast": "Tinycast"]))
        try scenario("casing at sentence start", "tinycast is great.", "Tinycast is great.", expect: .none)
        try scenario("casing of a common word", "We met the president.", "We met the President.", expect: .none)
        try scenario("punctuation only", "Send it now please", "Send it now, please!", expect: .none)
        try scenario("changed mind on weekday", "Call me on Monday.", "Call me on Tuesday.", expect: .none)
        try scenario("common word swap", "This will affect sales.", "This will effect sales.", expect: .none)
        try scenario("homophone swap", "Put it over their.", "Put it over there.", expect: .none)
        try notLearned("common word to name", "Ask Samoa about it.", "Ask Samuel about it.")
        try notLearned("app autocorrect to a word", "Ask Hubtel about it.", "Ask Hotel about it.")
        try scenario("number changed", "Meet at 3 pm.", "Meet at 4 pm.", expect: .none)
        try scenario("digit formatting", "It costs 1000 dollars.", "It costs 1,000 dollars.", expect: .none)
        try scenario("diacritic fix", "Ask Zoe about it.", "Ask Zoë about it.", expect: .learned(["Zoe": "Zoë"]))
        try scenario("CJK edit", "明日は渋谷で会議です。", "明日は渋谷駅で会議です。", expect: .none)
        try scenario("CJK spaced name", "Ask 田中 about it.", "Ask 田仲 about it.", expect: .none)
        try scenario("huge field", "Tell Jhon " + String(repeating: "a", count: 9_000),
            "Tell John " + String(repeating: "a", count: 9_000), expect: .none)

        do {
            let store = fresh()
            let outcome = try dictate(
                "Ask Kathrine about it.", edits: ["Ask Kathrine about it.", "Ask Kath about it.", "Ask Katherine about it."],
                store: store)
            report("mid-word pause then fix", outcome == .learned(["Kathrine": "Katherine"]), "got \(outcome)")
        }

        do {
            let store = fresh()
            _ = try dictate("Tell Jhon the plan.", edits: ["Tell John the plan."], store: store)
            let second = try dictate("Ask Jhon again.", edits: ["Ask John again."], store: store)
            report("same correction twice", second == .none && store.entries.count == 1, "got \(second), \(store.entries.count)")
        }

        do {
            let anchor = DictationInsertionAnchor(
                prefix: "Dear team,\n", suffix: "\nThanks", replaced: "", inserted: "Deploy the cubernetes cluster.")
            let shifted = anchor.locate(in: "Hi all. Dear team,\nDeploy the Kubernetes cluster.\nThanks, Sam")
            report("edit outside the inserted range", shifted == "Deploy the Kubernetes cluster.",
                "got \(String(describing: shifted))")
            let context = anchor.locate(in: "Dear crew,\nDeploy the Kubernetes cluster.\nThanks")
            report("edit to the text around the insertion", context == nil, "got \(String(describing: context))")
            report("insertion cleared", anchor.locate(in: "") == nil, "found text in an empty field")
            let document = String(repeating: "Earlier notes line.\n", count: 40)
            let long = DictationInsertionAnchor(
                prefix: Substring(document + "- "), suffix: "\n- next", replaced: "", inserted: "Ask Jhon.")
            let edited = "Edited. " + document + "- Ask John.\n- next"
            report("cursor moved, earlier text edited", long.locate(in: edited) == "Ask John.",
                "got \(String(describing: long.locate(in: edited)))")
            let repeated = DictationInsertionAnchor(prefix: "- ", suffix: "", replaced: "", inserted: "Ask Jhon.")
            report("short context before the insertion", repeated.locate(in: "- Ask John.") == "Ask John.", "lost the insertion")
            let whole = DictationInsertionAnchor(prefix: "", suffix: "", replaced: "", inserted: "Ask Jhon.")
            report("whole-field insertion", whole.locate(in: "Ask John.") == "Ask John.", "lost the field")
        }

        do {
            var session = DictationCorrectionSession(
                id: UUID(), inserted: "Ask Kathrine.", recognized: "Ask Kathrine.", baseline: [], isKnownWord: isKnownWord)
            _ = session.observe("Ask Kath.", at: .seconds(10))
            report("abandoned mid-edit", session.settleOnLoss(at: .milliseconds(10_400)) == nil, "learned a fragment")
            _ = session.observe("Ask Katherine.", at: .seconds(20))
            report("settles after a pause", session.nextCheck(at: .seconds(21), isObserved: true) == .seconds(1),
                "next check \(session.nextCheck(at: .seconds(21), isObserved: true))")
            let lost = session.settleOnLoss(at: .seconds(22))
            report("focus loss settles a paused edit", lost?.corrections.map(\.spelling) == ["Katherine"],
                "got \(String(describing: lost))")
            report("idle watcher stops", session.isExpired(at: .seconds(80)) && !session.isExpired(at: .seconds(79)),
                "quiet limit")
            report("watcher lifetime capped", session.isExpired(at: .seconds(300)), "lifetime")
            report("observed field polls slowly", session.nextCheck(at: .seconds(30), isObserved: true) == .seconds(5),
                "observed interval")
        }

        do {
            let store = fresh()
            let outcome = try dictate(
                "Deploy the cubernetes cluster.", edits: ["Deploy the Kubernetes cluster.", "Deploy the cubernetes cluster."],
                store: store)
            report("undo restores original", outcome == .none && store.entries.isEmpty,
                "got \(outcome), \(store.entries.map(\.spelling))")
        }

        do {
            let store = fresh()
            let first = try dictate("I use tinycast every day.", edits: ["I use Tinycast every day."], store: store)
            let second = try dictate("Open tinycast settings.", edits: ["Open Tinycast settings."], store: store)
            report("casing confirmed across dictations", first != .none && second == .learned(["tinycast": "Tinycast"]),
                "got \(first), then \(second)")
        }

        do {
            let store = fresh()
            let first = try dictate(
                "Send it to Doctor there sure tomorrow.", edits: ["Send it to Doctor Thiessen tomorrow."], store: store)
            let second = try dictate("Call Doctor there sure today.", edits: ["Call Doctor Thiessen today."], store: store)
            report("weak pair confirmed across dictations", first != .none && second == .learned(["there sure": "Thiessen"]),
                "got \(first), then \(second)")
        }

        do {
            let store = fresh()
            _ = try dictate("Deploy the cubernetes cluster.", edits: ["Deploy the Kubernetes cluster."], store: store)
            let inserted = DictationCorrection.applying(store.entries, to: "Restart cubernetes now.")
            let reverted = try dictate(
                "Restart cubernetes now.", edits: [inserted.replacing("Kubernetes", with: "cubernetes")], store: store)
            report("learned pair reverted next time", inserted == "Restart Kubernetes now." && store.entries.isEmpty,
                "inserted \(inserted), got \(reverted), entries \(store.entries.map(\.spelling))")
        }

        do {
            let store = fresh()
            _ = try dictate("Tell Jhon the plan.", edits: ["Tell John the plan."], store: store)
            let applied = DictationCorrection.applying(store.entries, to: "Jhonny met Jhon at Jhon's desk.")
            report("applied with word boundaries", applied == "Jhonny met John at John's desk.", "got \(applied)")
        }

        if failures.isEmpty {
            print("Dictation correction scenarios passed")
        } else {
            print("\(failures.count) dictation correction scenarios failed")
            exit(1)
        }
    }

    static func report(_ name: String, _ passed: Bool, _ detail: String) {
        print("\(passed ? "PASS" : "FAIL")  \(name)\(passed ? "" : ": \(detail)")")
        if !passed { failures.append(name) }
    }
}
