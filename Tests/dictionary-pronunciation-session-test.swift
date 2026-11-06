import AVFAudio
import Foundation

@main
@MainActor
struct DictionaryPronunciationSessionTests {
    @MainActor private final class Engine: DictionarySpeechSession.Engine {
        weak var delegate: (any AVSpeechSynthesizerDelegate)?
        var utterance: AVSpeechUtterance?
        private(set) var stopped = false
        func speak(_ utterance: AVSpeechUtterance) { self.utterance = utterance }
        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
            stopped = true
            utterance = nil
            return true
        }
    }

    private final class SilentPlayer: AVAudioPlayer {
        private(set) var stopped = false
        override func play() -> Bool { true }
        override func stop() { stopped = true }
    }

    @MainActor private final class Gate<Value: Sendable> {
        var waits: [CheckedContinuation<Value, any Error>?] = []
        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { waits.append($0) }
        }
        func fail(_ error: any Error, at index: Int = 0) {
            let continuation = waits[index]
            waits[index] = nil
            continuation?.resume(throwing: error)
        }
        func finish(_ value: Value, at index: Int = 0) {
            let continuation = waits[index]
            waits[index] = nil
            continuation?.resume(returning: value)
        }
    }

    @MainActor private final class State {
        weak var engine: Engine?
        weak var player: SilentPlayer?
        var engineCreations = 0
        var playerCreations = 0
        var audioRequests = 0
        var words: [String] = []
        var available = [us, uk]
        func discover() -> [DictionarySpeechVoice] { available }
    }

    @MainActor private final class Fixture {
        let state = State()
        let session: DictionaryPronunciationSession
        init(
            lookup: DictionaryRecordingSession.Lookup? = nil,
            audio: DictionaryRecordingSession.AudioData? = nil
        ) {
            let state = state
            let speech = DictionarySpeechSession(
                discover: { await state.discover() },
                makeEngine: {
                    let engine = Engine()
                    state.engine = engine
                    state.engineCreations += 1
                    return engine
                },
                makeUtterance: { word, _, rate in
                    state.words.append(word)
                    let utterance = AVSpeechUtterance(string: word)
                    utterance.rate = rate
                    return utterance
                }, notificationCenter: NotificationCenter())
            let recording = DictionaryRecordingSession(
                lookup: lookup ?? { _ in result },
                audioData: audio ?? { _ in state.audioRequests += 1; return wave },
                makePlayer: { data in
                    let player = try SilentPlayer(data: data)
                    player.volume = 0
                    state.player = player
                    state.playerCreations += 1
                    return player
                }, debounce: .zero)
            session = DictionaryPronunciationSession(speech: speech, recording: recording)
        }
    }

    private static let us = DictionarySpeechVoice(id: "us", name: "US", language: "en-US", quality: 1)
    private static let uk = DictionarySpeechVoice(id: "uk", name: "UK", language: "en-GB", quality: 1)
    private static let result = DictionaryPronunciation(recordings: [
        recording("ga", title: "GA"), recording("us", title: "US"), recording("uk", title: "UK")
    ])
    private static let wave: Data = {
        let samples: UInt32 = 800
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(samples * 2 + 36)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8_000))
        append(UInt32(16_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(samples * 2)
        data.append(Data(count: Int(samples * 2)))
        return data
    }()
    private static var passes = 0
    private static var failures = 0

    private static func recording(_ id: String, title: String, ipa: String = "/ɹaɪs/")
        -> DictionaryPronunciation.Recording {
        DictionaryPronunciation.Recording(
            id: id, title: title, ipa: ipa,
            audioURL: URL(string: "https://upload.wikimedia.org/\(id).mp3")!,
            sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(id).ogg")!,
            author: "Fixture", licenseName: "CC0", licenseURL: nil, ipaVariants: [ipa])
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition { passes += 1 } else { failures += 1; print("FAIL: \(message)") }
    }

    private static func wait(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        expect(false, "operation completed within its deadline")
    }

    private static func nativeDoesNotWaitForMetadata() async {
        let gate = Gate<DictionaryPronunciation>()
        let fixture = Fixture(lookup: { _ in try await gate.wait() })
        let session = fixture.session
        session.prepare(term: "rice", writtenPronunciation: "native guide")
        await wait { !session.speech.loading && gate.waits.count == 1 }
        expect(session.recording.loading, "recorded metadata can still be pending")
        expect(session.source == .nativeSpeech && !session.sourceLoading, "native readiness ignores recorded metadata")
        expect(session.playbackAvailable && session.guide == "native guide", "native speech and written guide are ready")
        session.togglePlayback()
        expect(session.isPlaying && fixture.state.engineCreations == 1, "native Play starts without network metadata")
        expect(fixture.state.audioRequests == 0, "native Play downloads no audio")
        gate.finish(result)
        await wait { !session.recording.loading }
        expect(session.isPlaying && !session.recording.isPlaying, "metadata completion cannot start a second audio path")
        expect(session.recordingChoices.map(\.id) == ["ga", "uk"], "one raw recording per accent is offered")
        expect(session.guide == DictionaryPronunciationDisplay.guide(ipa: "/ɹaɪs/", variants: ["/ɹaɪs/"], written: nil),
               "a sourced guide replaces the written fallback")
        session.reset()
    }

    private static func sourceSwitching() async {
        let fixture = Fixture()
        let session = fixture.session
        session.prepare(term: "rice")
        await wait { !session.speech.loading && !session.recording.loading }
        session.togglePlayback()
        let native = fixture.state.engine
        session.source = .recordedAudio
        expect(native?.stopped == true && !session.speech.isPlaying, "switching sources stops native speech")
        expect(session.playbackAvailable, "recorded audio becomes independently available")
        session.togglePlayback()
        await wait { session.recording.isPlaying }
        let player = fixture.state.player
        expect(!session.speech.isPlaying && session.isPlaying, "only recorded audio is active")
        session.source = .nativeSpeech
        expect(player?.stopped == true && !session.recording.isPlaying, "switching back stops recorded playback")
        session.togglePlayback()
        expect(session.speech.isPlaying && !session.recording.isPlaying, "only native speech restarts")
        session.reset()
    }

    private static func pendingRecordedAudio() async {
        let gate = Gate<Data>()
        let fixture = Fixture(audio: { _ in try await gate.wait() })
        let session = fixture.session
        session.prepare(term: "rice")
        await wait { !session.speech.loading && !session.recording.loading }
        session.source = .recordedAudio
        session.togglePlayback()
        await wait { gate.waits.count == 1 }
        expect(session.sourceLoading && session.playbackAvailable, "pending recorded audio remains cancellable")
        session.source = .nativeSpeech
        expect(!session.recording.loadingAudio, "source switching cancels an outstanding audio request")
        session.togglePlayback()
        gate.finish(wave)
        for _ in 0..<10 { await Task.yield() }
        expect(session.speech.isPlaying && !session.recording.isPlaying, "late downloaded audio cannot overlap native speech")
        expect(fixture.state.playerCreations == 0, "a retired request never creates its player")
        session.reset()
    }

    private static func wordAndSelectionLifecycle() async {
        let fixture = Fixture()
        let session = fixture.session
        session.prepare(term: "rice", writtenPronunciation: "old guide")
        await wait { !session.speech.loading && !session.recording.loading }
        session.selectAccent(id: uk.id)
        expect(session.speech.selectedVoice == uk, "accent selection reaches the native backend")
        session.slow = true
        session.togglePlayback()
        let native = fixture.state.engine
        session.prepare(term: "bulwark")
        expect(native?.stopped == true && !session.isPlaying, "a new word stops the prior native utterance")
        expect(session.writtenPronunciation == nil && session.recording.selectedRecording == nil,
               "a new word discards the old written and recorded metadata")
        expect(session.speech.term == "bulwark" && session.recording.term == "bulwark", "both backends receive the new word")
        await wait { !session.recording.loading }
        session.prepare(term: "bulwark", writtenPronunciation: "current guide")
        session.prepare(term: " bulwark ")
        expect(session.writtenPronunciation == "current guide", "same-word preparation preserves an omitted written guide")
        session.source = .recordedAudio
        session.selectAccent(id: "uk")
        expect(session.recording.selectedRecording?.id == "uk", "accent selection reaches the recorded backend")
        session.togglePlayback()
        await wait { session.recording.isPlaying }
        let player = fixture.state.player
        session.prepare(term: "library")
        expect(player?.stopped == true && !session.isPlaying, "a new word stops the prior recorded player")
        session.reset()
        expect(session.term.isEmpty && session.writtenPronunciation == nil && session.guide == nil,
               "reset clears the displayed word and guide")
        expect(session.recording.recordings.isEmpty && session.recording.term.isEmpty && session.speech.term.isEmpty,
               "reset clears both word sessions and recorded metadata")
        expect(session.source == .recordedAudio && session.slow && session.speech.slow && session.recording.slow,
               "reset preserves source and synchronized speed preferences")
        expect(session.speech.selectedVoice == uk, "reset preserves the chosen native accent")
        expect(!session.playbackAvailable && !session.isPlaying && !session.sourceLoading,
               "reset leaves playback unavailable and idle")
    }

    private static func guideAccentMatching() async {
        let american = recording("american", title: "US", ipa: "/ˈmeɪ/")
        let british = recording("british", title: "UK", ipa: "/ˈmɑː/")
        let fixture = Fixture(lookup: { _ in DictionaryPronunciation(recordings: [american, british]) })
        let session = fixture.session
        session.prepare(term: "tomato", writtenPronunciation: "written guide")
        await wait { !session.speech.loading && !session.recording.loading }
        expect(session.referenceRecording == american && session.guide == "MAY", "native US speech uses the US guide")
        session.selectAccent(id: uk.id)
        expect(session.referenceRecording == british && session.guide == "MAH", "native UK speech uses the UK guide")
        expect(session.recording.selectedRecording == american,
               "native guide matching does not change recorded playback selection")
        session.source = .recordedAudio
        expect(session.referenceRecording == american && session.guide == "MAY", "recorded mode uses its own selected guide")
        session.selectAccent(id: british.id)
        expect(session.referenceRecording == british && session.guide == "MAH",
               "recorded guide follows recorded accent selection")
        session.reset()
        let missing = Fixture(lookup: { _ in DictionaryPronunciation(recordings: [american]) })
        missing.session.prepare(term: "tomato", writtenPronunciation: "written fallback")
        await wait { !missing.session.speech.loading && !missing.session.recording.loading }
        missing.session.selectAccent(id: uk.id)
        expect(missing.session.referenceRecording == nil && missing.session.guide == "written fallback",
               "missing matching recorded accents use the written guide instead of a different accent")
        missing.session.reset()
    }

    private static func errorRouting() async {
        let gate = Gate<DictionaryPronunciation>()
        let fixture = Fixture(lookup: { _ in try await gate.wait() })
        let session = fixture.session
        session.prepare(term: "rice", writtenPronunciation: "written guide")
        await wait { !session.speech.loading && gate.waits.count == 1 }
        gate.fail(URLError(.notConnectedToInternet))
        await wait { !session.recording.loading }
        expect(session.error == nil && session.playbackAvailable,
               "metadata failure cannot disable or report an error for native speech")
        session.source = .recordedAudio
        expect(session.error == session.recording.error && !session.playbackAvailable,
               "the recorded source reports its own metadata failure")
        session.retry()
        await wait { gate.waits.count == 2 }
        expect(session.sourceLoading && session.error == nil, "retry routes to the recorded metadata backend")
        gate.finish(DictionaryPronunciation(), at: 1)
        await wait { !session.recording.loading }
        expect(session.error == "No recording available.", "a completed empty recording lookup has an unavailable explanation")
        session.source = .nativeSpeech
        session.speech.selectVoice(id: "missing")
        expect(session.error == nil, "recorded unavailability does not leak into native playback")
        session.reset()
        expect(session.error == nil, "an inactive word has no unavailable tooltip")
        let missing = Fixture()
        missing.state.available = []
        missing.session.prepare(term: "rice")
        await wait { !missing.session.speech.loading && !missing.session.recording.loading }
        expect(missing.session.error == "No standard English voice is available.",
               "missing native voices have an unavailable explanation")
        missing.session.source = .recordedAudio
        expect(missing.session.error == nil && missing.session.playbackAvailable,
               "missing native voices do not disable recorded audio")
        missing.session.reset()
    }

    static func main() async {
        await nativeDoesNotWaitForMetadata()
        await sourceSwitching()
        await pendingRecordedAudio()
        await wordAndSelectionLifecycle()
        await errorRouting()
        await guideAccentMatching()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
