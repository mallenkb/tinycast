import Foundation
import Observation

@MainActor
@Observable
final class DictionaryPronunciationSession {
    enum Source: String, CaseIterable, Hashable, Sendable {
        case nativeSpeech
        case recordedAudio
    }

    struct Preferences: Equatable {
        var source = Source.nativeSpeech
        var slow = false
        var voiceID: String?
        var recordingAccent: String?
    }

    let speech: DictionarySpeechSession
    let recording: DictionaryRecordingSession
    private var preferences = Preferences()
    private let loadPreferences: (() -> Preferences)?
    private let savePreferences: (Preferences) -> Void

    var source: Source {
        get { preferences.source }
        set {
            var updated = preferences
            updated.source = newValue
            applyPreferences(updated, saving: true)
        }
    }
    var slow: Bool {
        get { preferences.slow }
        set {
            var updated = preferences
            updated.slow = newValue
            applyPreferences(updated, saving: true)
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

    convenience init(
        loadPreferences: (() -> Preferences)? = nil, savePreferences: @escaping (Preferences) -> Void = { _ in },
        onResourcesReleased: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            speech: DictionarySpeechSession(onResourcesReleased: onResourcesReleased),
            recording: DictionaryRecordingSession(onResourcesReleased: onResourcesReleased),
            loadPreferences: loadPreferences, savePreferences: savePreferences)
    }

    init(
        speech: DictionarySpeechSession, recording: DictionaryRecordingSession,
        loadPreferences: (() -> Preferences)? = nil, savePreferences: @escaping (Preferences) -> Void = { _ in }
    ) {
        self.speech = speech
        self.recording = recording
        self.loadPreferences = loadPreferences
        self.savePreferences = savePreferences
        speech.slow = slow
        recording.slow = slow
        if let loadPreferences { applyPreferences(loadPreferences()) }
    }

    func prepare(term query: String, writtenPronunciation: String? = nil) {
        if let loadPreferences { applyPreferences(loadPreferences()) }
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
        var updated = preferences
        switch source {
        case .nativeSpeech:
            guard speech.voices.contains(where: { $0.id == id }) else { return }
            updated.voiceID = id
        case .recordedAudio:
            guard let choice = recording.recordings.first(where: { $0.id == id }) else { return }
            updated.recordingAccent = DictionaryPronunciationDisplay.accentKey(choice.title)
        }
        applyPreferences(updated, saving: true)
    }

    private func applyPreferences(_ updated: Preferences, saving: Bool = false) {
        let previous = preferences
        guard updated != previous else { return }
        if updated.source != previous.source { stopPlayback() }
        preferences = updated
        if updated.voiceID != previous.voiceID { speech.preferVoice(id: updated.voiceID) }
        if updated.recordingAccent != previous.recordingAccent { recording.preferAccent(updated.recordingAccent) }
        if updated.slow != previous.slow {
            speech.slow = updated.slow
            recording.slow = updated.slow
        }
        if saving { savePreferences(updated) }
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
