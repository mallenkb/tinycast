import Foundation

struct DictationCorrectionSession {
    let id: UUID
    let inserted: String
    let recognized: String
    let baseline: [DictationCorrection]
    var learned: [DictationCorrection] = []
    private var previous: String
    private var evaluated: String
    private var changedAt: Duration = .zero

    init(id: UUID, inserted: String, recognized: String, baseline: [DictationCorrection]) {
        self.id = id
        self.inserted = inserted
        self.recognized = recognized
        self.baseline = baseline
        previous = inserted
        evaluated = inserted
    }

    mutating func observe(
        _ edited: String, at elapsed: Duration, flush: Bool = false
    ) -> (corrections: [DictationCorrection], candidates: [DictationCorrection])? {
        guard edited.utf16.count <= 8_192 else { return nil }
        if edited != previous {
            previous = edited
            changedAt = elapsed
        }
        guard edited != evaluated, flush || elapsed - changedAt >= .seconds(2) else { return nil }
        evaluated = edited
        let detection = DictationCorrection.detect(from: inserted, to: edited, recognized: recognized)
        let observed = Set(detection.corrections.map(\.id))
        let retained = detection.isReliable ? [] : learned.filter { !observed.contains($0.id) }
        return (detection.corrections + retained, detection.candidates)
    }
}
