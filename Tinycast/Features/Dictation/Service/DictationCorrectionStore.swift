import Foundation

@MainActor
@Observable
final class DictationCorrectionStore {
    private struct Candidate {
        let correction: DictationCorrection
        let sessionID: UUID
    }

    private enum Failure: LocalizedError {
        case full
        case entryTooLong

        var errorDescription: String? {
            switch self {
            case .full: String(localized: "Remove a dictionary entry before adding another.")
            case .entryTooLong: String(localized: "Dictionary words and misspellings can be up to 60 characters.")
            }
        }
    }

    private static let limit = 100
    private let fileURL: URL
    @ObservationIgnored private var pending: [Candidate] = []
    private(set) var entries: [DictationCorrection]

    init(fileURL: URL = AppPaths.applicationSupport().appending(path: "dictation-corrections.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode([DictationCorrection].self, from: data)
        {
            entries = Array(stored.prefix(Self.limit))
        } else {
            entries = []
        }
    }

    func record(_ correction: DictationCorrection) throws {
        if !correction.isManual, entries.contains(where: { $0.isManual && $0.id == correction.id }) {
            return
        }
        var updated = entries.filter { $0.id != correction.id }
        if correction.isManual {
            guard correction.original.count <= 60, correction.spelling.count <= 60 else { throw Failure.entryTooLong }
            guard updated.lazy.filter(\.isManual).count < Self.limit else { throw Failure.full }
        }
        if correction.isManual || correction.id != DictationCorrection.key(for: correction.spelling) {
            updated.insert(correction, at: 0)
        }
        try save(Self.limited(updated))
        pending.removeAll { $0.correction.id == correction.id }
    }

    func remove(_ correction: DictationCorrection) throws {
        try save(entries.filter { $0.id != correction.id })
        pending.removeAll { $0.correction.id == correction.id }
    }

    func learn(
        _ corrections: [DictationCorrection], candidates: [DictationCorrection],
        sessionID: UUID, replacing previous: [DictationCorrection], baseline: [DictationCorrection]
    ) throws -> [DictationCorrection] {
        if corrections.isEmpty, candidates.isEmpty, previous.isEmpty {
            discardCandidates(for: sessionID)
            return []
        }
        let current = Self.byID(entries)
        let prior = Self.byID(previous)
        let starting = Self.byID(baseline)
        let direct = corrections.filter(Self.isLearnable).map { correction in
            let id = correction.id
            guard correction.context == nil, Self.storedValue(for: correction) != nil,
                let context = current[id]?.context ?? starting[id]?.context
            else { return correction }
            return DictationCorrection(original: correction.original, spelling: correction.spelling, context: context)
        }
        let directIDs = Set(direct.map(\.id))
        let speculative = candidates.filter(Self.isLearnable)
        let speculativeIDs = Set(speculative.map(\.id))
        var evidence = Dictionary(uniqueKeysWithValues: pending.map { ($0.correction.id, $0) })
        evidence = evidence.filter { id, candidate in
            !directIDs.contains(id) && current[id]?.isManual != true && starting[id]?.isManual != true
                && (candidate.sessionID != sessionID || speculativeIDs.contains(id))
        }
        var observations = direct
        var freshEvidenceIDs: [String] = []
        for correction in speculative {
            let id = correction.id
            guard !directIDs.contains(id), current[id]?.isManual != true, starting[id]?.isManual != true,
                Self.storedValue(for: correction) != nil
            else { continue }
            if Self.same(prior[id], correction) {
                observations.append(correction)
            } else if let earlier = evidence[id], earlier.sessionID != sessionID,
                earlier.correction.spelling == correction.spelling, earlier.correction.context == correction.context
            {
                observations.append(correction)
                evidence.removeValue(forKey: id)
            } else {
                evidence[id] = Candidate(correction: correction, sessionID: sessionID)
                freshEvidenceIDs.append(id)
            }
        }

        let observed = Self.byID(observations)
        var updated = current
        for correction in previous where observed[correction.id] == nil {
            let id = correction.id
            if current[id]?.isManual != true, starting[id]?.isManual != true,
                Self.same(current[id], Self.storedValue(for: correction))
            {
                updated[id] = starting[id]
            }
        }
        var changedIDs: [String] = []
        var active: [DictationCorrection] = []
        for correction in Self.orderedValues(observed, ids: observations.map(\.id)) {
            let id = correction.id
            let stored = Self.storedValue(for: correction)
            guard current[id]?.isManual != true, starting[id]?.isManual != true else { continue }
            if let prior = prior[id] {
                guard Self.same(current[id], Self.storedValue(for: prior)) else { continue }
            } else {
                guard !Self.same(current[id], stored) else { continue }
            }
            if !Self.same(updated[id], stored) {
                updated[id] = stored
                changedIDs.append(id)
            }
            if !Self.same(starting[id], stored) {
                active.append(correction)
            }
        }

        let ordered = Self.orderedValues(updated, ids: changedIDs + entries.map(\.id) + baseline.map(\.id))
        let next = Self.limited(ordered)
        if !next.elementsEqual(entries, by: Self.same) { try save(next) }
        pending = Array(Self.orderedValues(
            evidence, ids: freshEvidenceIDs + pending.map { $0.correction.id }
        ).prefix(Self.limit))
        let retained = Self.byID(next)
        return active.filter { Self.same(retained[$0.id], Self.storedValue(for: $0)) }
    }

    func discardCandidates(for sessionID: UUID) {
        pending.removeAll { $0.sessionID == sessionID }
    }

    private static func limited(_ entries: [DictationCorrection]) -> [DictationCorrection] {
        let manual = entries.filter(\.isManual)
        let learned = entries.lazy.filter { !$0.isManual }.prefix(Self.limit - manual.count)
        return manual + Array(learned)
    }

    private static func byID(_ entries: [DictationCorrection]) -> [String: DictationCorrection] {
        Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func orderedValues<Value>(_ values: [String: Value], ids: [String]) -> [Value] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return values[id]
        }
    }

    private static func isLearnable(_ correction: DictationCorrection) -> Bool {
        !correction.isManual && (1...60).contains(correction.original.count)
            && (1...60).contains(correction.spelling.count)
    }

    private static func same(_ left: DictationCorrection?, _ right: DictationCorrection?) -> Bool {
        left?.original == right?.original && left?.spelling == right?.spelling
            && left?.isManual == right?.isManual && left?.context == right?.context
    }

    private static func storedValue(for correction: DictationCorrection) -> DictationCorrection? {
        correction.id == DictationCorrection.key(for: correction.spelling) ? nil : correction
    }

    private func save(_ updated: [DictationCorrection]) throws {
        let data = try JSONEncoder().encode(updated)
        try data.write(to: fileURL, options: .atomic)
        entries = updated
    }
}
