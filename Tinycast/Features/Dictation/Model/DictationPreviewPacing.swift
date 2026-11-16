import Foundation

/// Decides when the live preview asks for recognition, so silence and stable text cost less.
struct DictationPreviewPacing {
    /// Multiplies the model's preview cadence while recognized text stays the same.
    private(set) var stretch = 1
    private var noiseFloor: Float?
    private var lastRequest: ContinuousClock.Instant?
    private var settledAfterVoice = false
    private var lastText: String?
    private var unchangedResults = 0
    private static let floorRise: Float = 1.05
    private static let resultsPerStretch = 3
    private static let maximumStretch = 3

    /// Skips quiet audio once a request has already covered the end of speech.
    mutating func shouldRequest(_ window: [Float], at now: ContinuousClock.Instant) -> Bool {
        let floor = DictationPausePolicy.noiseFloor(window[...])
        if floor > 0 { noiseFloor = noiseFloor.map { min(floor, $0 * Self.floorRise) } ?? floor }
        let fresh = lastRequest.map { Self.sampleCount(in: now - $0) } ?? window.count
        let hasVoice = DictationPausePolicy.containsVoice(
            window.suffix(min(window.count, fresh)), noiseFloor: noiseFloor ?? 0)
        guard hasVoice || !settledAfterVoice else { return false }
        settledAfterVoice = !hasVoice
        lastRequest = now
        return true
    }

    mutating func received(_ text: String) {
        unchangedResults = text == lastText ? unchangedResults + 1 : 0
        lastText = text
        stretch = min(Self.maximumStretch, 1 + unchangedResults / Self.resultsPerStretch)
    }

    mutating func failed() {
        settledAfterVoice = false
        lastText = nil
        unchangedResults = 0
        stretch = 1
    }

    private static func sampleCount(in duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        let rate = Int64(DictationPausePolicy.sampleRate)
        return max(0, Int(seconds * rate + attoseconds / (1_000_000_000_000_000_000 / rate)))
    }
}
