import Foundation

/// Finds pauses and speech in mono 16 kHz audio relative to the recording's own noise floor.
enum DictationPausePolicy {
    struct Cut: Equatable, Sendable {
        /// The segment ends here, in the middle of a pause or at the quietest window.
        let end: Int
        /// The next search for the same segment start begins here.
        let resume: Int
    }

    static let sampleRate = 16_000
    static let frameSamples = sampleRate / 50
    static let minimumPauseFrames = 30
    static let minimumSegmentSamples = 10 * sampleRate
    static let maximumSegmentSamples = 30 * sampleRate
    /// After a rejected cut, the next forced cut comes at most this far past the resume point.
    static let extensionSamples = 5 * sampleRate
    static let quietLevel: Float = 0.003
    static let maximumQuietLevel: Float = 0.02
    static let voiceLevel: Float = 0.004
    private static let floorWindowSamples = 30 * sampleRate
    private static let quietMultiple: Float = 2
    private static let voiceMultiple: Float = 2.5
    private static let peakMultiple: Float = 10.0 / 3
    private static let forcedSearchSamples = 48_000
    private static let forcedWindowSamples = 3_200

    /// The next cut at or after `earliest` for a segment beginning at `start`, or nil to wait.
    static func nextCut(in samples: [Float], start: Int, earliest: Int) -> Cut? {
        let forcedLimit = max(start + maximumSegmentSamples, earliest + extensionSamples)
        let scanEnd = min(samples.count, forcedLimit)
        guard earliest < scanEnd else { return nil }
        let floorStart = max(start, scanEnd - floorWindowSamples)
        let floor = noiseFloor(samples[floorStart..<scanEnd])
        let quiet = min(max(quietLevel, floor * quietMultiple), maximumQuietLevel)
        let peak = quiet * peakMultiple
        var quietFrames = 0
        var frameStart = earliest
        while frameStart + frameSamples <= scanEnd {
            let frame = samples[frameStart..<(frameStart + frameSamples)]
            frameStart += frameSamples
            if rms(frame) < quiet, !frame.contains(where: { abs($0) > peak }) {
                quietFrames += 1
                continue
            }
            let run = quietFrames
            quietFrames = 0
            // Wait for audio to resume so a trailing pause stays available for final recognition.
            if run >= minimumPauseFrames {
                let resume = frameStart - frameSamples
                return Cut(end: resume - run * frameSamples / 2, resume: resume)
            }
        }
        guard samples.count >= forcedLimit else { return nil }
        if quietFrames >= minimumPauseFrames {
            return Cut(end: frameStart - quietFrames * frameSamples / 2, resume: frameStart)
        }
        let searchStart = max(earliest, forcedLimit - forcedSearchSamples)
        return Cut(
            end: DictationAudioChunks.quietestCut(
                in: samples, from: searchStart, to: forcedLimit, window: forcedWindowSamples),
            resume: forcedLimit)
    }

    /// The tenth-percentile frame level, or zero when there are too few frames to judge.
    static func noiseFloor(_ samples: ArraySlice<Float>) -> Float {
        var levels = [Float]()
        levels.reserveCapacity(samples.count / frameSamples)
        var index = samples.startIndex
        while index + frameSamples <= samples.endIndex {
            levels.append(rms(samples[index..<(index + frameSamples)]))
            index += frameSamples
        }
        guard levels.count >= 50 else { return 0 }
        levels.sort()
        return levels[levels.count / 10]
    }

    /// Whether any frame rises clearly above the noise floor.
    static func containsVoice(_ samples: ArraySlice<Float>, noiseFloor: Float) -> Bool {
        let threshold = max(voiceLevel, noiseFloor * voiceMultiple)
        var index = samples.startIndex
        while index < samples.endIndex {
            let end = min(index + frameSamples, samples.endIndex)
            if rms(samples[index..<end]) > threshold { return true }
            index = end
        }
        return false
    }

    static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        let energy = frame.reduce(Float.zero) { $0 + $1 * $1 }
        return (energy / Float(frame.count)).squareRoot()
    }
}
