import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
final class DictionarySpeechSession {
    @MainActor protocol Engine: AnyObject {
        var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
        func speak(_ utterance: AVSpeechUtterance)
        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    }

    typealias Discovery = @Sendable () async -> [DictionarySpeechVoice]
    typealias UtteranceFactory = @MainActor (String, DictionarySpeechVoice, Float) throws -> AVSpeechUtterance

    nonisolated private final class Completion: NSObject, AVSpeechSynthesizerDelegate, Sendable {
        let generation: UUID
        let finish: @Sendable (UUID) -> Void

        init(generation: UUID, finish: @escaping @Sendable (UUID) -> Void) {
            self.generation = generation
            self.finish = finish
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            finish(generation)
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            finish(generation)
        }
    }

    private(set) var term = ""
    private(set) var voices: [DictionarySpeechVoice] = []
    private(set) var loading = false
    private(set) var isPlaying = false
    private(set) var error: String?
    private var selectedVoiceID: String?
    var slow = false {
        didSet {
            guard slow != oldValue, isPlaying else { return }
            stopSpeech()
            startSpeech()
        }
    }

    var selectedVoice: DictionarySpeechVoice? { voices.first { $0.id == selectedVoiceID } }

    @ObservationIgnored private let discover: Discovery
    @ObservationIgnored private let makeEngine: @MainActor () -> any Engine
    @ObservationIgnored private let makeUtterance: UtteranceFactory
    @ObservationIgnored private let onResourcesReleased: @MainActor () -> Void
    @ObservationIgnored private var discovered = false
    @ObservationIgnored private var discoveryIdentity = UUID()
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var engine: (any Engine)?
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    @ObservationIgnored private var completion: Completion?
    @ObservationIgnored private var voiceChanges: NotificationToken?

    convenience init(
        notificationCenter: NotificationCenter = .default,
        onResourcesReleased: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            discover: { await Self.installedVoices() },
            makeEngine: { AVSpeechSynthesizer() },
            notificationCenter: notificationCenter,
            onResourcesReleased: onResourcesReleased)
    }

    init(
        discover: @escaping Discovery,
        makeEngine: @escaping @MainActor () -> any Engine,
        makeUtterance: @escaping UtteranceFactory = { text, voice, rate in
            guard let nativeVoice = AVSpeechSynthesisVoice(identifier: voice.id) else {
                throw URLError(.resourceUnavailable)
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = nativeVoice
            utterance.rate = rate
            return utterance
        },
        notificationCenter: NotificationCenter = .default,
        onResourcesReleased: @escaping @MainActor () -> Void = {}
    ) {
        self.discover = discover
        self.makeEngine = makeEngine
        self.makeUtterance = makeUtterance
        self.onResourcesReleased = onResourcesReleased
        voiceChanges = NotificationToken(
            notificationCenter.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.installedVoicesChanged() }
            }, center: notificationCenter)
    }

    func prepare(term query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != term else { return }
        stopSpeech()
        term = query
        error = nil
        guard !query.isEmpty else {
            cancelDiscovery()
            return
        }
        if !discovered, discoveryTask == nil { refreshVoices() }
    }

    func selectVoice(id: String) {
        guard selectedVoiceID != id, voices.contains(where: { $0.id == id }) else { return }
        stopSpeech()
        selectedVoiceID = id
        error = nil
    }

    func togglePlayback() {
        if isPlaying { stopSpeech() } else { startSpeech() }
    }

    func retry() {
        stopSpeech()
        error = nil
        guard !term.isEmpty else { return }
        refreshVoices()
    }

    func reset() {
        stopSpeech()
        cancelDiscovery()
        term = ""
        error = nil
    }

    private func refreshVoices() {
        cancelDiscovery()
        loading = true
        let identity = discoveryIdentity
        let discover = discover
        discoveryTask = Task { [weak self] in
            defer { self?.onResourcesReleased() }
            let available = await discover()
            guard !Task.isCancelled, let self, self.discoveryIdentity == identity else { return }
            var preferred = DictionarySpeechVoice.preferred(from: available)
            if let selected = available.first(where: { $0.id == self.selectedVoiceID && $0.quality == 1 }),
                let index = preferred.firstIndex(where: {
                    $0.language.caseInsensitiveCompare(selected.language) == .orderedSame
                })
            {
                preferred[index] = selected
            }
            if self.isPlaying, !preferred.contains(where: { $0.id == self.selectedVoiceID }) {
                self.stopSpeech()
            }
            self.voices = preferred
            if !self.voices.contains(where: { $0.id == self.selectedVoiceID }) {
                self.selectedVoiceID = self.voices.first?.id
            }
            self.discovered = true
            self.loading = false
            self.discoveryTask = nil
        }
    }

    private func installedVoicesChanged() {
        discovered = false
        if term.isEmpty {
            cancelDiscovery()
        } else {
            refreshVoices()
        }
    }

    private func cancelDiscovery() {
        discoveryIdentity = UUID()
        discoveryTask?.cancel()
        discoveryTask = nil
        loading = false
    }

    private func startSpeech() {
        guard !loading, !term.isEmpty, let voice = selectedVoice else { return }
        error = nil
        do {
            let rate = AVSpeechUtteranceDefaultSpeechRate * (slow ? 0.75 : 1)
            let utterance = try makeUtterance(term, voice, rate)
            let engine = makeEngine()
            let completion = Completion(generation: generation) { [weak self] generation in
                Task { @MainActor [weak self] in self?.finished(generation: generation) }
            }
            self.utterance = utterance
            self.engine = engine
            self.completion = completion
            engine.delegate = completion
            isPlaying = true
            engine.speak(utterance)
        } catch {
            stopSpeech()
            self.error = LocalizedStringResource("This pronunciation could not be played.").resolved()
        }
    }

    private func stopSpeech() {
        generation = UUID()
        engine?.delegate = nil
        _ = engine?.stopSpeaking(at: .immediate)
        engine = nil
        utterance = nil
        completion = nil
        isPlaying = false
        onResourcesReleased()
    }

    private func finished(generation: UUID) {
        guard self.generation == generation, engine != nil else { return }
        stopSpeech()
    }

    @concurrent private static func installedVoices() async -> [DictionarySpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }.map {
            DictionarySpeechVoice(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue)
        }
    }

    isolated deinit {
        discoveryTask?.cancel()
        engine?.delegate = nil
        _ = engine?.stopSpeaking(at: .immediate)
    }
}

extension AVSpeechSynthesizer: DictionarySpeechSession.Engine {}
