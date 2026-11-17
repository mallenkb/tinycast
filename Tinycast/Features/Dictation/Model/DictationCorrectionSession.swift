import Foundation

struct DictationCorrectionSession {
    typealias Observation = (corrections: [DictationCorrection], candidates: [DictationCorrection])

    static let settleDelay = Duration.seconds(2)
    static let lossSettleDelay = Duration.seconds(1)
    static let changeCoalescing = Duration.milliseconds(300)
    static let observedCheckInterval = Duration.seconds(5)
    static let polledCheckInterval = Duration.seconds(1)
    static let quietLimit = Duration.seconds(60)
    static let lifetime = Duration.seconds(300)
    private static let maximumFieldLength = 8_192

    let id: UUID
    let inserted: String
    let recognized: String
    let baseline: [DictationCorrection]
    var learned: [DictationCorrection] = []
    private let isKnownWord: (String) -> Bool
    private var previous: String
    private var evaluated: String
    private var changedAt: Duration = .zero

    init(
        id: UUID, inserted: String, recognized: String, baseline: [DictationCorrection],
        isKnownWord: @escaping (String) -> Bool
    ) {
        self.id = id
        self.inserted = inserted
        self.recognized = recognized
        self.baseline = baseline
        self.isKnownWord = isKnownWord
        previous = inserted
        evaluated = inserted
    }

    mutating func observe(_ edited: String, at elapsed: Duration, flush: Bool = false) -> Observation? {
        guard edited.utf16.count <= Self.maximumFieldLength else { return nil }
        if edited != previous {
            previous = edited
            changedAt = elapsed
        }
        guard flush || elapsed - changedAt >= Self.settleDelay else { return nil }
        return evaluate(edited)
    }

    /// The field closed or cleared: only an edit that had already paused counts, never one mid-word.
    mutating func settleOnLoss(at elapsed: Duration) -> Observation? {
        guard elapsed - changedAt >= Self.lossSettleDelay else { return nil }
        return evaluate(previous)
    }

    func isExpired(at elapsed: Duration) -> Bool {
        elapsed - changedAt >= Self.quietLimit || elapsed >= Self.lifetime
    }

    func nextCheck(at elapsed: Duration, isObserved: Bool) -> Duration {
        if previous != evaluated { return max(changedAt + Self.settleDelay - elapsed, .milliseconds(50)) }
        return isObserved ? Self.observedCheckInterval : Self.polledCheckInterval
    }

    private mutating func evaluate(_ edited: String) -> Observation? {
        guard edited != evaluated else { return nil }
        evaluated = edited
        let detection = DictationCorrection.detect(
            from: inserted, to: edited, recognized: recognized, isKnownWord: isKnownWord)
        let observed = Set(detection.corrections.map(\.id))
        let retained = detection.isReliable ? [] : learned.filter { !observed.contains($0.id) }
        return (detection.corrections + retained, detection.candidates)
    }
}
