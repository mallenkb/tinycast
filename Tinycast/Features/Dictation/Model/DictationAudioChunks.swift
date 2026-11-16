import Foundation

enum DictationAudioChunks {
    static func ranges(in samples: [Float], maximum: Int) -> [Range<Int>] {
        precondition(maximum > 0)
        var ranges = [Range<Int>]()
        var start = 0
        while start < samples.count {
            var end = min(start + maximum, samples.count)
            if end < samples.count, end - start >= 3200 {
                end = quietestCut(in: samples, from: max(start, end - 48_000), to: end, window: 3200)
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// The centre of the last quietest `window` within `from..<to`, scanned in 10 ms steps.
    static func quietestCut(in samples: [Float], from: Int, to: Int, window: Int) -> Int {
        guard to - from >= window else { return (from + to) / 2 }
        var quietest: Float = .infinity
        var cut = to - window / 2
        for offset in stride(from: from, through: to - window, by: 160) {
            let energy = samples[offset..<(offset + window)].reduce(Float.zero) { $0 + $1 * $1 }
            if energy <= quietest { quietest = energy; cut = offset + window / 2 }
        }
        return cut
    }
}
