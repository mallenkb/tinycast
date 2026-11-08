import AVFAudio
import Foundation
import Observation

@main
@MainActor
struct DictionaryRecordingSessionTests {
    private final class SilentPlayer: AVAudioPlayer {
        override func play() -> Bool { true }
        override func stop() {}
    }

    private final class RejectingPlayer: AVAudioPlayer {
        override func play() -> Bool { false }
        override func stop() {}
    }

    @MainActor private final class Players {
        weak var latest: SilentPlayer?
        var creations = 0

        func make(_ data: Data) throws -> AVAudioPlayer {
            let player = try SilentPlayer(data: data)
            player.volume = 0
            latest = player
            creations += 1
            return player
        }
    }

    @MainActor private final class Gate<Value: Sendable> {
        var waits: [CheckedContinuation<Value, any Error>?] = []

        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { waits.append($0) }
        }

        func finish(_ value: Value, at index: Int) {
            let continuation = waits[index]
            waits[index] = nil
            continuation?.resume(returning: value)
        }

        func fail(_ error: any Error, at index: Int) {
            let continuation = waits[index]
            waits[index] = nil
            continuation?.resume(throwing: error)
        }
    }

    @MainActor private final class Flag {
        var value = false
    }

    private static var failures = 0
    private static var passes = 0
    private static let wave = waveData(seconds: 1)

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        expect(false, "asynchronous operation completed before its deadline")
    }

    private static func recording(_ id: String) -> DictionaryPronunciation.Recording {
        DictionaryPronunciation.Recording(
            id: id, title: id, ipa: "/test/",
            audioURL: URL(string: "https://upload.wikimedia.org/\(id).mp3")!,
            sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(id).ogg")!,
            author: "Fixture", licenseName: "CC0", licenseURL: nil)
    }

    private static func result(_ ids: String...) -> DictionaryPronunciation {
        DictionaryPronunciation(recordings: ids.map(recording))
    }

    private static func waveData(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8_000
        let bytes = sampleRate * UInt32(seconds) * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(bytes + 36)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }

    private static func finish(_ player: AVAudioPlayer) {
        player.delegate?.audioPlayerDidFinishPlaying?(player, successfully: true)
    }

    private static func failDecoding(_ player: AVAudioPlayer) {
        player.delegate?.audioPlayerDecodeErrorDidOccur?(player, error: URLError(.cannotDecodeContentData))
    }

    private static func debounceAndSelection() async {
        let players = Players()
        var queries: [String] = []
        var audioRequests = 0
        let session = DictionaryRecordingSession(
            lookup: { queries.append($0); return result("US", "UK") },
            audioData: { _ in audioRequests += 1; return wave }, makePlayer: players.make)
        session.prepare(term: " old ")
        session.prepare(term: " library ")
        try? await Task.sleep(for: .milliseconds(50))
        expect(queries.isEmpty && session.loading, "metadata waits for the debounce")
        await waitUntil { !session.loading }
        expect(queries == ["library"], "typing cancels the prior lookup and trims the term")
        expect(session.term == "library", "the resolved term remains available")
        expect(session.selectedRecording?.id == "US", "the first recording is selected")
        expect(audioRequests == 0 && players.creations == 0, "metadata does not load or prepare audio")
        let selectionChanged = Flag()
        withObservationTracking {
            _ = session.selectedRecording
        } onChange: {
            Task { @MainActor in selectionChanged.value = true }
        }
        session.selectRecording(id: "UK")
        await waitUntil { selectionChanged.value }
        expect(session.selectedRecording?.id == "UK", "recording selection is observable")
        session.selectRecording(id: "missing")
        expect(session.selectedRecording?.id == "UK", "an unknown selection is ignored")
        session.prepare(term: "library")
        expect(queries.count == 1, "preparing the same term does not fetch again")
        session.reset()
        expect(session.term.isEmpty && session.recordings.isEmpty && !session.loading,
               "reset clears metadata")
    }

    private static func staleMetadataAndOwnerLifetime() async {
        let gate = Gate<DictionaryPronunciation>()
        let players = Players()
        var releases = 0
        var session: DictionaryRecordingSession? = DictionaryRecordingSession(
            lookup: { _ in try await gate.wait() }, audioData: { _ in wave },
            makePlayer: players.make, debounce: .zero, onResourcesReleased: { releases += 1 })
        session?.prepare(term: "old")
        await waitUntil { gate.waits.count == 1 }
        session?.prepare(term: "new")
        await waitUntil { gate.waits.count == 2 }
        gate.finish(result("new"), at: 1)
        await waitUntil { session?.selectedRecording?.id == "new" }
        let beforeDiscard = releases
        gate.finish(result("old"), at: 0)
        try? await Task.sleep(for: .milliseconds(10))
        expect(session?.selectedRecording?.id == "new", "late metadata cannot replace a newer term")
        expect(releases > beforeDiscard, "discarded metadata schedules resource relief")
        session?.prepare(term: "pending")
        await waitUntil { gate.waits.count == 3 }
        weak let owner = session
        session = nil
        expect(owner == nil, "an in-flight metadata request does not retain its session")
        gate.finish(result("pending"), at: 2)
    }

    private static func playbackLifecycle() async {
        let players = Players()
        var audioRequests = 0
        var releases = 0
        let session = DictionaryRecordingSession(
            lookup: { _ in result("US", "UK") },
            audioData: { _ in audioRequests += 1; return wave },
            makePlayer: players.make, debounce: .zero, onResourcesReleased: { releases += 1 })
        session.prepare(term: "test")
        await waitUntil { !session.loading }
        expect(releases >= 1, "metadata completion schedules resource relief")
        session.slow = true
        session.togglePlayback()
        await waitUntil { session.isPlaying }
        expect(players.latest?.rate == 0.75, "slow playback is applied before play")
        expect(players.latest?.enableRate == true, "rate adjustment is enabled")
        session.slow = false
        expect(players.latest?.rate == 1, "changing speed updates the current player")
        let beforeFinish = releases
        finish(players.latest!)
        await waitUntil { !session.isPlaying }
        expect(players.latest == nil, "successful completion releases the player and audio data")
        expect(releases > beforeFinish, "playback completion schedules resource relief")
        session.togglePlayback()
        await waitUntil { session.isPlaying }
        var oldPlayer: SilentPlayer? = players.latest
        let oldDelegate = oldPlayer?.delegate
        session.selectRecording(id: "UK")
        expect(!session.isPlaying && oldPlayer?.delegate == nil,
               "selecting another recording stops playback and detaches the delegate")
        session.togglePlayback()
        await waitUntil { session.isPlaying }
        oldPlayer = nil
        oldDelegate?.audioPlayerDidFinishPlaying?(players.latest!, successfully: false)
        try? await Task.sleep(for: .milliseconds(10))
        expect(session.isPlaying && session.error == nil, "a stale delegate cannot stop the new player")
        failDecoding(players.latest!)
        await waitUntil { !session.isPlaying }
        expect(players.latest == nil && session.error != nil, "decode failure releases the player")
        session.retry()
        await waitUntil { session.isPlaying }
        expect(session.error == nil, "retry clears the playback error")
        session.togglePlayback()
        expect(!session.isPlaying && players.latest == nil, "tapping a playing recording stops and releases")
        session.togglePlayback()
        await waitUntil { session.isPlaying }
        session.reset()
        expect(!session.isPlaying && players.latest == nil, "closing the result releases playback")
        expect(audioRequests == 5, "each new playback downloads only its selected recording")
    }

    private static func staleAudioAndOwnerLifetime() async {
        let gate = Gate<Data>()
        let players = Players()
        var releases = 0
        var session: DictionaryRecordingSession? = DictionaryRecordingSession(
            lookup: { _ in result("US", "UK") }, audioData: { _ in try await gate.wait() },
            makePlayer: players.make, debounce: .zero, onResourcesReleased: { releases += 1 })
        session?.prepare(term: "test")
        await waitUntil { session?.loading == false }
        session?.togglePlayback()
        await waitUntil { gate.waits.count == 1 }
        session?.selectRecording(id: "UK")
        session?.togglePlayback()
        await waitUntil { gate.waits.count == 2 }
        let beforeDiscard = releases
        gate.finish(wave, at: 0)
        try? await Task.sleep(for: .milliseconds(10))
        expect(players.creations == 0, "late audio for an old selection never creates a player")
        expect(releases > beforeDiscard, "discarded audio schedules resource relief")
        gate.finish(wave, at: 1)
        await waitUntil { session?.isPlaying == true }
        expect(players.creations == 1, "only the current selection creates a player")
        session?.togglePlayback()
        session?.togglePlayback()
        await waitUntil { gate.waits.count == 3 }
        session?.togglePlayback()
        expect(session?.loadingAudio == false, "tapping while loading cancels the download")
        gate.finish(wave, at: 2)
        try? await Task.sleep(for: .milliseconds(10))
        expect(players.creations == 1, "a cancelled download cannot restart playback")
        session?.togglePlayback()
        await waitUntil { gate.waits.count == 4 }
        weak let owner = session
        session = nil
        expect(owner == nil && players.latest == nil, "an audio request does not retain its session")
        gate.finish(wave, at: 3)
    }

    private static func failuresAndResourceLimits() async {
        let players = Players()
        var lookups = 0
        var audioRequests = 0
        let session = DictionaryRecordingSession(
            lookup: { _ in
                lookups += 1
                if lookups == 1 { throw URLError(.notConnectedToInternet) }
                return result("US")
            }, audioData: { _ in
                audioRequests += 1
                if audioRequests == 1 { throw URLError(.timedOut) }
                return wave
            }, makePlayer: players.make, debounce: .zero)
        session.prepare(term: "test")
        await waitUntil { !session.loading }
        expect(session.error != nil && session.recordings.isEmpty, "metadata failure is visible")
        session.retry()
        await waitUntil { !session.loading }
        expect(session.error == nil && session.recordings.count == 1, "metadata retry can recover")
        session.togglePlayback()
        await waitUntil { !session.loadingAudio }
        expect(session.error != nil && !session.isPlaying, "audio failure is visible")
        session.retry()
        await waitUntil { session.isPlaying }
        expect(players.creations == 1 && session.error == nil, "audio retry can recover")
        session.reset()
        for data in [Data(), Data(count: 2_097_153), Data("invalid audio".utf8), waveData(seconds: 31)] {
            let limited = DictionaryRecordingSession(
                lookup: { _ in result("US") }, audioData: { _ in data },
                makePlayer: players.make, debounce: .zero)
            limited.prepare(term: "test")
            await waitUntil { !limited.loading }
            limited.togglePlayback()
            await waitUntil { !limited.loadingAudio }
            expect(limited.error != nil && !limited.isPlaying && players.latest == nil,
                   "empty, oversized, invalid or overlong audio cannot retain playback")
        }
        let rejecting = DictionaryRecordingSession(
            lookup: { _ in result("US") }, audioData: { _ in wave },
            makePlayer: { try RejectingPlayer(data: $0) }, debounce: .zero)
        rejecting.prepare(term: "test")
        await waitUntil { !rejecting.loading }
        rejecting.togglePlayback()
        await waitUntil { !rejecting.loadingAudio }
        expect(!rejecting.isPlaying && rejecting.error != nil, "a failed play call clears playback state")
        var owned: DictionaryRecordingSession? = DictionaryRecordingSession(
            lookup: { _ in result("US") }, audioData: { _ in wave },
            makePlayer: players.make, debounce: .zero)
        owned?.prepare(term: "test")
        await waitUntil { owned?.loading == false }
        owned?.togglePlayback()
        await waitUntil { owned?.isPlaying == true }
        weak let owner = owned
        owned = nil
        expect(owner == nil && players.latest == nil, "session teardown releases an active player")
    }

    private static func sharedRetryCooldown() async {
        let players = Players()
        var lookups = 0
        var audioRequests = 0
        var lastLookup: ContinuousClock.Instant?
        var retryAfterIssued: ContinuousClock.Instant?
        let session = DictionaryRecordingSession(
            lookup: { _ in
                lookups += 1
                lastLookup = ContinuousClock().now
                return result("US")
            },
            audioData: { _ in
                audioRequests += 1
                if audioRequests == 1 {
                    retryAfterIssued = ContinuousClock().now
                    throw DictionaryPronunciationProvider.RetryAfterError(delay: 0.25)
                }
                return wave
            }, makePlayer: players.make, debounce: .zero)
        session.prepare(term: "first")
        await waitUntil { !session.loading }
        session.togglePlayback()
        await waitUntil { !session.loadingAudio }
        session.retry()
        try? await Task.sleep(for: .milliseconds(20))
        expect(audioRequests == 1 && session.loadingAudio, "audio retry honors the provider cooldown")
        session.reset()
        session.prepare(term: "second")
        await waitUntil { !session.loading }
        let lookupDelay = retryAfterIssued.flatMap { start in lastLookup.map { start.duration(to: $0) } }
        expect(lookupDelay.map { $0 >= .milliseconds(250) } == true,
               "reset preserves the audio cooldown and shares it with metadata lookup")
        expect(lookups == 2, "metadata resumes after the shared cooldown expires")
        session.togglePlayback()
        await waitUntil { session.isPlaying }
        expect(audioRequests == 2, "the canceled audio retry does not issue a request later")
        session.reset()

        var metadataRequests = 0
        var longWait: DictionaryRecordingSession? = DictionaryRecordingSession(
            lookup: { _ in
                metadataRequests += 1
                throw DictionaryPronunciationProvider.RetryAfterError(delay: 1e100)
            }, audioData: { _ in wave }, makePlayer: players.make, debounce: .zero)
        longWait?.prepare(term: "first")
        await waitUntil { longWait?.loading == false }
        longWait?.reset()
        longWait?.prepare(term: "second")
        try? await Task.sleep(for: .milliseconds(20))
        expect(metadataRequests == 1 && longWait?.loading == true,
               "a very large Retry-After remains valid without overflowing a sleep duration")
        weak let owner = longWait
        longWait = nil
        expect(owner == nil, "a cooldown sleep does not retain its session")

        let gate = Gate<DictionaryPronunciation>()
        let stale = DictionaryRecordingSession(
            lookup: { _ in try await gate.wait() }, audioData: { _ in wave },
            makePlayer: players.make, debounce: .zero)
        stale.prepare(term: "old")
        await waitUntil { gate.waits.count == 1 }
        stale.reset()
        gate.fail(DictionaryPronunciationProvider.RetryAfterError(delay: 0.25), at: 0)
        try? await Task.sleep(for: .milliseconds(10))
        stale.prepare(term: "new")
        try? await Task.sleep(for: .milliseconds(20))
        expect(gate.waits.count == 1, "a canceled request's Retry-After still delays the next lookup")
        await waitUntil { gate.waits.count == 2 }
        gate.finish(result("new"), at: 1)
        await waitUntil { !stale.loading }
    }

    static func main() async {
        await debounceAndSelection()
        await staleMetadataAndOwnerLifetime()
        await playbackLifecycle()
        await staleAudioAndOwnerLifetime()
        await failuresAndResourceLimits()
        await sharedRetryCooldown()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
