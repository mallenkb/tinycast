import Foundation
import Observation

@MainActor
@Observable
final class DictionaryPronunciationSession {
    enum Source: CaseIterable, Hashable, Sendable {
        case nativeSpeech
        case recordedAudio
    }

    let speech: DictionarySpeechSession
    let recording: DictionaryRecordingSession
    var source = Source.nativeSpeech {
        didSet {
            guard source != oldValue else { return }
            stopPlayback()
        }
    }
    var slow = false {
        didSet {
            speech.slow = slow
            recording.slow = slow
        }
    }
    private(set) var term = ""
    private(set) var writtenPronunciation: String?

    var referenceRecording: DictionaryPronunciation.Recording? {
        switch source {
        case .recordedAudio:
            recording.selectedRecording
        case .nativeSpeech:
            speech.selectedVoice.flatMap { voice in
                recordingChoices.first {
                    DictionaryPronunciationDisplay.accentKey($0.title)
                        .caseInsensitiveCompare(voice.language) == .orderedSame
                }
            }
        }
    }

    var guide: String? {
        DictionaryPronunciationDisplay.guide(
            ipa: referenceRecording?.ipa,
            variants: referenceRecording?.ipaVariants ?? [], written: writtenPronunciation)
    }

    var recordingChoices: [DictionaryPronunciation.Recording] {
        DictionaryPronunciationDisplay.recordings(recording.recordings)
    }

    var isPlaying: Bool {
        switch source {
        case .nativeSpeech: speech.isPlaying
        case .recordedAudio: recording.isPlaying
        }
    }

    var sourceLoading: Bool {
        switch source {
        case .nativeSpeech: speech.loading
        case .recordedAudio: recording.loading || recording.loadingAudio
        }
    }

    var playbackAvailable: Bool {
        switch source {
        case .nativeSpeech:
            speech.isPlaying || (!term.isEmpty && !speech.loading && speech.selectedVoice != nil)
        case .recordedAudio:
            recording.isPlaying || recording.loadingAudio
                || (!term.isEmpty && !recording.loading && recording.selectedRecording != nil)
        }
    }

    var error: String? {
        guard !term.isEmpty else { return nil }
        switch source {
        case .nativeSpeech:
            if let error = speech.error { return error }
            return !speech.loading && speech.selectedVoice == nil
                ? LocalizedStringResource("No standard English voice is available.").resolved() : nil
        case .recordedAudio:
            if let error = recording.error { return error }
            return !sourceLoading && recording.selectedRecording == nil
                ? LocalizedStringResource("No recording available.").resolved() : nil
        }
    }

    convenience init(onResourcesReleased: @escaping @MainActor () -> Void = {}) {
        self.init(
            speech: DictionarySpeechSession(onResourcesReleased: onResourcesReleased),
            recording: DictionaryRecordingSession(onResourcesReleased: onResourcesReleased))
    }

    init(speech: DictionarySpeechSession, recording: DictionaryRecordingSession) {
        self.speech = speech
        self.recording = recording
        speech.slow = slow
        recording.slow = slow
    }

    func prepare(term query: String, writtenPronunciation: String? = nil) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query != term || writtenPronunciation != nil {
            self.writtenPronunciation = query.isEmpty ? nil : writtenPronunciation
        }
        term = query
        speech.prepare(term: term)
        recording.prepare(term: term)
    }

    func togglePlayback() {
        stopInactivePlayback()
        switch source {
        case .nativeSpeech: speech.togglePlayback()
        case .recordedAudio: recording.togglePlayback()
        }
    }

    func selectAccent(id: String) {
        stopInactivePlayback()
        switch source {
        case .nativeSpeech: speech.selectVoice(id: id)
        case .recordedAudio: recording.selectRecording(id: id)
        }
    }

    func retry() {
        stopInactivePlayback()
        switch source {
        case .nativeSpeech: speech.retry()
        case .recordedAudio: recording.retry()
        }
    }

    func reset() {
        speech.reset()
        recording.reset()
        term = ""
        writtenPronunciation = nil
    }

    private func stopPlayback() {
        if speech.isPlaying { speech.togglePlayback() }
        if recording.isPlaying || recording.loadingAudio { recording.togglePlayback() }
    }

    private func stopInactivePlayback() {
        switch source {
        case .nativeSpeech:
            if recording.isPlaying || recording.loadingAudio { recording.togglePlayback() }
        case .recordedAudio:
            if speech.isPlaying { speech.togglePlayback() }
        }
    }
}
