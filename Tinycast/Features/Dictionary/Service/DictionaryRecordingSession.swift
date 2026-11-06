import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
final class DictionaryRecordingSession {
    typealias Lookup = @MainActor (String) async throws -> DictionaryPronunciation
    typealias AudioData = @MainActor (DictionaryPronunciation.Recording) async throws -> Data
    typealias PlayerFactory = @MainActor (Data) throws -> AVAudioPlayer

    nonisolated private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, Sendable {
        let identity: UUID
        let completion: @Sendable (UUID, Bool) -> Void

        init(identity: UUID, completion: @escaping @Sendable (UUID, Bool) -> Void) {
            self.identity = identity
            self.completion = completion
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            completion(identity, flag)
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            completion(identity, false)
        }
    }

    private(set) var term = ""
    private(set) var recordings: [DictionaryPronunciation.Recording] = []
    private(set) var loading = false
    private(set) var loadingAudio = false
    private(set) var isPlaying = false
    private(set) var error: String?
    private var selectedID: String?
    var slow = false {
        didSet { player?.rate = slow ? 0.75 : 1 }
    }

    var selectedRecording: DictionaryPronunciation.Recording? {
        recordings.first { $0.id == selectedID }
    }

    @ObservationIgnored private let lookup: Lookup
    @ObservationIgnored private let audioData: AudioData
    @ObservationIgnored private let makePlayer: PlayerFactory
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let onResourcesReleased: @MainActor () -> Void
    @ObservationIgnored private var lookupIdentity = UUID()
    @ObservationIgnored private var audioIdentity = UUID()
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playbackCompletion: PlaybackDelegate?
    @ObservationIgnored private var cooldown: (started: ContinuousClock.Instant, delay: TimeInterval)?

    convenience init(onResourcesReleased: @escaping @MainActor () -> Void = {}) {
        let provider = DictionaryPronunciationProvider()
        self.init(
            lookup: { try await provider.lookup($0) },
            audioData: { try await provider.audioData(for: $0) },
            onResourcesReleased: onResourcesReleased)
    }

    init(
        lookup: @escaping Lookup, audioData: @escaping AudioData,
        makePlayer: @escaping PlayerFactory = { try AVAudioPlayer(data: $0) },
        debounce: Duration = .milliseconds(350),
        onResourcesReleased: @escaping @MainActor () -> Void = {}
    ) {
        self.lookup = lookup
        self.audioData = audioData
        self.makePlayer = makePlayer
        self.debounce = debounce
        self.onResourcesReleased = onResourcesReleased
    }

    func prepare(term query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term != query else { return }
        reset()
        term = query
        guard !query.isEmpty else { return }
        loading = true
        let identity = lookupIdentity
        let lookup = lookup
        let debounce = debounce
        lookupTask = Task { [weak self] in
            defer { self?.onResourcesReleased() }
            do {
                try await Task.sleep(for: debounce)
                while let delay = self?.cooldownDelay {
                    try await Task.sleep(for: delay)
                }
                try Task.checkCancellation()
                let result = try await lookup(query)
                guard !Task.isCancelled, let self, self.lookupIdentity == identity,
                    self.term == query
                else { return }
                self.recordings = result.recordings
                self.selectedID = result.recordings.first?.id
                self.loading = false
                self.lookupTask = nil
            } catch {
                self?.recordCooldown(error)
                guard !Task.isCancelled, let self, self.lookupIdentity == identity else { return }
                self.loading = false
                self.lookupTask = nil
                self.error = LocalizedStringResource("Pronunciations could not be loaded.").resolved()
            }
        }
    }

    func selectRecording(id: String) {
        guard selectedID != id, recordings.contains(where: { $0.id == id }) else { return }
        stopPlayback()
        selectedID = id
        error = nil
    }

    func togglePlayback() {
        if loadingAudio || isPlaying {
            stopPlayback()
            return
        }
        guard let recording = selectedRecording else { return }
        error = nil
        loadingAudio = true
        let identity = audioIdentity
        let audioData = audioData
        audioTask = Task { [weak self] in
            defer { self?.onResourcesReleased() }
            do {
                while let delay = self?.cooldownDelay {
                    try await Task.sleep(for: delay)
                }
                try Task.checkCancellation()
                let data = try await audioData(recording)
                guard !Task.isCancelled, let self, self.audioIdentity == identity,
                    self.selectedRecording?.id == recording.id
                else { return }
                self.audioTask = nil
                try self.startPlayback(data)
            } catch {
                self?.recordCooldown(error)
                guard !Task.isCancelled, let self, self.audioIdentity == identity else { return }
                self.stopPlayback()
                self.error = LocalizedStringResource("This pronunciation could not be played.").resolved()
            }
        }
    }

    func retry() {
        if recordings.isEmpty {
            let query = term
            term = ""
            prepare(term: query)
        } else {
            togglePlayback()
        }
    }

    func reset() {
        lookupIdentity = UUID()
        lookupTask?.cancel()
        lookupTask = nil
        stopPlayback()
        term = ""
        recordings = []
        selectedID = nil
        loading = false
        error = nil
    }

    private var cooldownRemaining: TimeInterval {
        guard let cooldown else { return 0 }
        let elapsed = cooldown.started.duration(to: ContinuousClock().now).components
        return max(0, cooldown.delay - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18)
    }

    private var cooldownDelay: Duration? {
        let remaining = cooldownRemaining
        return remaining > 0 ? .seconds(min(remaining, 60)) : nil
    }

    private func recordCooldown(_ error: any Error) {
        guard let retry = error as? DictionaryPronunciationProvider.RetryAfterError,
            retry.delay.isFinite, retry.delay > 0
        else { return }
        cooldown = (ContinuousClock().now, max(cooldownRemaining, retry.delay))
    }

    private func startPlayback(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 2_097_152 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let player = try makePlayer(data)
        guard player.duration.isFinite, player.duration > 0, player.duration <= 30 else {
            throw URLError(.cannotDecodeContentData)
        }
        let delegate = PlaybackDelegate(identity: audioIdentity) { [weak self] identity, successfully in
            Task { @MainActor [weak self] in
                self?.playbackFinished(identity: identity, successfully: successfully)
            }
        }
        playbackCompletion = delegate
        player.delegate = delegate
        player.enableRate = true
        player.rate = slow ? 0.75 : 1
        self.player = player
        loadingAudio = false
        guard player.play() else { throw URLError(.cannotDecodeContentData) }
        isPlaying = true
    }

    private func stopPlayback() {
        audioIdentity = UUID()
        audioTask?.cancel()
        audioTask = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        playbackCompletion = nil
        isPlaying = false
        loadingAudio = false
        onResourcesReleased()
    }

    private func playbackFinished(identity: UUID, successfully: Bool) {
        guard audioIdentity == identity, player != nil else { return }
        stopPlayback()
        if !successfully {
            error = LocalizedStringResource("This pronunciation could not be played.").resolved()
        }
    }

    isolated deinit {
        lookupTask?.cancel()
        audioTask?.cancel()
        player?.delegate = nil
        player?.stop()
    }
}
