import AppKit
import AVFoundation
import NaturalLanguage

@MainActor
@Observable
final class DictationCoordinator {
    private enum Phase { case idle, starting, listening, transcribing, stopping }

    private let settings: AppSettings
    private let hotKeys: HotKeyManager
    let models: DictationModelStore
    let corrections: DictationCorrectionStore
    private let capture = DictationCapture()
    private let cues = DictationCueRunner()
    private let panel = DictationPanelController()
    private let injector: TextInjector
    private let showMessage: (String, DialogTone) -> Void
    private let confirmEnable: () async -> Bool
    private let recordTranscript: (String, NSRunningApplication?) -> Void
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var enableTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var correctionTask: Task<Void, Never>?
    @ObservationIgnored private var applePreparation: Task<AppleDictationSession, Error>?
    @ObservationIgnored private var removesFillerWords = false
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var cueTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStartCue: UUID?
    @ObservationIgnored private var finishWhenStarted = false
    @ObservationIgnored private var shortcutMode: DictationMode?
    @ObservationIgnored private var target: InjectionTarget?
    /// The field a mic button is dictating into; nil for a shortcut's session.
    private(set) var field: DictationField?

    init(
        settings: AppSettings, hotKeys: HotKeyManager, models: DictationModelStore,
        corrections: DictationCorrectionStore,
        injector: TextInjector,
        confirmEnable: @escaping () async -> Bool,
        showMessage: @escaping (String, DialogTone) -> Void,
        recordTranscript: @escaping (String, NSRunningApplication?) -> Void
    ) {
        self.settings = settings
        self.hotKeys = hotKeys
        self.models = models
        self.corrections = corrections
        self.injector = injector
        self.confirmEnable = confirmEnable
        self.showMessage = showMessage
        self.recordTranscript = recordTranscript
        panel.onAccept = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        capture.onLevels = { [weak self] in
            guard let self else { return }
            panel.state.levels = $0
            if pendingStartCue == token { playStartCue() }
        }
        capture.onLimit = { [weak self] in self?.accept() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.dictationEnabled else { return }
        guard enabled else {
            settings.dictationEnabled = false
            enableTask?.cancel()
            cancel()
            return
        }
        guard enableTask == nil else { return }
        NSApp.activate()
        enableTask = Task { [weak self] in
            guard let self else { return }
            defer { enableTask = nil }
            guard await confirmEnable(), !Task.isCancelled else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled else { return }
            guard granted else {
                showMessage(
                    String(localized: "Allow Tinycast to use the microphone in System Settings"), .danger)
                return
            }
            settings.dictationEnabled = true
            Permissions.ensureAccessibility()
        }
    }

    func downloadModel(_ model: DictationModel) async {
        do { try await models.download(model) } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch { showMessage(error.localizedDescription, .danger) }
    }

    func removeModel(_ model: DictationModel) async {
        do { try await models.delete(model) } catch { showMessage(error.localizedDescription, .danger) }
    }

    var holdShortcutIssue: String? {
        guard let binding = hotKeys.binding(for: .dictationHold) else { return nil }
        guard binding.supportsHold else {
            return String(localized: "Record a single modifier or a key combination for hold to talk.")
        }
        if let owner = hotKeys.conflictOwner(of: binding, excluding: .dictationHold) {
            return String(localized: "This shortcut is also used by \(owner). Record another shortcut.")
        }
        return nil
    }

    func pressed(_ mode: DictationMode) {
        guard settings.dictationEnabled, phase != .stopping else { return }
        if phase != .idle {
            if mode == .toggle, shortcutMode != .pushToTalk { finish() }
            return
        }
        begin(target: InjectionTarget.current(), shortcutMode: mode)
    }

    var isEnabled: Bool { settings.dictationEnabled }
    var hasModel: Bool { settings.dictationUsesApple || models.isInstalled(settings.dictationModel) }

    /// A field's own mic: click to start and click to finish, whatever the shortcut's mode or focus.
    func toggle(into editor: any InjectableTextView) {
        guard settings.dictationEnabled, phase != .stopping else { return }
        guard phase == .idle else {
            if field?.editor == ObjectIdentifier(editor) { finish() }
            return
        }
        field = DictationField(editor: ObjectIdentifier(editor))
        begin(target: .ownEditor(editor))
    }

    private func finish() {
        if phase == .starting {
            finishWhenStarted = true
        } else {
            accept()
        }
    }

    private func begin(target: InjectionTarget?, shortcutMode: DictationMode? = nil) {
        stopCorrectionLearning()
        guard hasModel else {
            field = nil
            showMessage(String(localized: "Download the dictation model in Settings first"), .danger)
            return
        }
        token = UUID()
        let current = token
        phase = .starting
        self.shortcutMode = shortcutMode
        finishWhenStarted = false
        removesFillerWords = settings.dictationRemovesFillerWords
        self.target = target
        pendingStartCue = settings.dictationPlaysSounds ? current : nil
        let microphoneID = settings.dictationMicrophone
        startTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(microphoneID: microphoneID)
                guard token == current else { return }
                guard settings.dictationEnabled else { cancel(); return }
                phase = .listening
                if finishWhenStarted {
                    accept()
                } else {
                    panel.showListening()
                }
            } catch {
                guard token == current else { return }
                reset()
                showMessage(error.localizedDescription, .danger)
            }
        }
        if settings.dictationUsesApple {
            let vocabulary = Array(Set(corrections.entries.map(\.spelling)))
            applePreparation = Task { try await AppleDictationSession.prepare(vocabulary: vocabulary) }
        } else {
            models.beginRecording(settings.dictationModel)
        }
        panel.showStarting(style: settings.dictationIndicatorStyle)
    }

    /// A Bluetooth headset's output resumes up to a quarter second after the first samples.
    private static let bluetoothSettle = Duration.milliseconds(500)

    private func playStartCue() {
        pendingStartCue = nil
        let current = token
        cueTask = Task { [weak self] in
            guard let self else { return }
            if capture.isBluetooth { try? await Task.sleep(for: Self.bluetoothSettle) }
            guard token == current, phase == .starting || phase == .listening else { return }
            cues.play(.start)
        }
    }

    func releasedHold() {
        guard shortcutMode == .pushToTalk else { return }
        finish()
    }

    func cancelHold() {
        guard shortcutMode == .pushToTalk, !finishWhenStarted,
            phase == .starting || phase == .listening
        else { return }
        cancel()
    }

    func accept() {
        guard phase == .listening else { return }
        phase = .transcribing
        panel.showTranscribing()
        field?.isTranscribing = true
        if settings.dictationPlaysSounds { cues.play(.stop) }
        let current = token
        let model = settings.dictationModel
        let language = settings.dictationLanguage
        let applePreparation = self.applePreparation
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            guard token == current else { return }
            let samples = await capture.stop()
            guard token == current else { return }
            guard samples.count >= 1_600 else {
                reset(cancelTranscription: false)
                showMessage(String(localized: "No speech was recorded"), .danger)
                return
            }
            do {
                let transcript: String
                if let applePreparation {
                    let session = try await applePreparation.value
                    try Task.checkCancellation()
                    transcript = try await session.transcribe(samples)
                } else {
                    transcript = try await models.transcribe(samples, model: model, language: language)
                }
                guard token == current else { return }
                let formatted = DictationTextFormatter.format(
                    cleanTranscript(transcript, model: applePreparation == nil ? model : nil, language: language),
                    context: DictationInsertionContext.read(in: target),
                    adaptCapitalization: settings.dictationAdaptsCapitalization)
                let text = DictationCorrection.applying(corrections.entries, to: formatted)
                guard !text.isEmpty else { reset(cancelTranscription: false); return }
                panel.close()
                let probe = settings.dictationEnabled && settings.dictationAutoLearnsWords
                    ? DictationInsertionContext.correctionProbe(in: target, inserted: text) : nil
                injector.deliver(
                    InjectedText(text), target: target, expectedKeyword: nil,
                    keywordLength: 0, automaticGeneration: nil,
                    isValid: { [weak self] in self?.token == current },
                    onDelivered: { [weak self] in
                        guard let self, token == current else { return }
                        finishTranscript(text)
                        if let probe { learnCorrection(using: probe, recognized: formatted) }
                    },
                    onFailed: { [weak self] in
                        guard let self, token == current else { return }
                        finishTranscript(text, pasteFailed: true)
                    })
            } catch {
                guard token == current else { return }
                reset(cancelTranscription: false)
                showMessage(error.localizedDescription, .danger)
            }
        }
    }

    private func finishTranscript(_ transcript: String, pasteFailed: Bool = false) {
        let app = target?.externalApp ?? (target?.ownEditor == nil ? nil : NSRunningApplication.current)
        reset(cancelTranscription: false)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { recordTranscript(text, pasteFailed ? nil : app) }
        if pasteFailed {
            showMessage(String(localized: "Couldn't paste dictation into this app"), .danger)
        }
    }

    private func learnCorrection(using probe: DictationInsertionContext.CorrectionProbe, recognized: String) {
        guard settings.dictationEnabled, settings.dictationAutoLearnsWords,
            probe.readInsertion() == probe.inserted
        else { return }
        correctionTask = Task { [weak self] in
            defer { if !Task.isCancelled { self?.correctionTask = nil } }
            let deadline = ContinuousClock.now + .seconds(12)
            var previous = probe.inserted
            var lastChange = ContinuousClock.now
            while ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, ContinuousClock.now < deadline,
                    let self, settings.dictationEnabled, settings.dictationAutoLearnsWords,
                    let edited = probe.readInsertion()
                else { return }
                if edited != previous {
                    previous = edited
                    lastChange = .now
                    continue
                }
                guard edited != probe.inserted, lastChange.duration(to: .now) >= .seconds(1),
                    let correction = DictationCorrection.infer(from: probe.inserted, to: edited, recognized: recognized)
                else { continue }
                do { try corrections.record(correction) } catch {
                    showMessage(error.localizedDescription, .danger)
                }
                return
            }
        }
    }

    func stopCorrectionLearning() {
        correctionTask?.cancel()
        correctionTask = nil
    }

    func removeCorrection(_ correction: DictationCorrection) {
        do { try corrections.remove(correction) } catch {
            showMessage(error.localizedDescription, .danger)
        }
    }

    func addCorrection(_ correction: DictationCorrection) -> Bool {
        do {
            try corrections.record(correction)
            return true
        } catch {
            showMessage(error.localizedDescription, .danger)
            return false
        }
    }

    private func cleanTranscript(_ transcript: String, model: DictationModel?, language: String?) -> String {
        guard removesFillerWords else { return transcript }
        let cleaned = DictationTextFormatter.removingFillerWords(transcript)
        guard cleaned != transcript else { return transcript }
        if model == .v2 || model == .phonon2 { return cleaned }
        if model?.isQwen == true, let language {
            return language == DictationLanguage.english.rawValue ? cleaned : transcript
        }
        return NLLanguageRecognizer.dominantLanguage(for: transcript) == .english ? cleaned : transcript
    }

    func cancel(in editor: any InjectableTextView) {
        guard let target = target?.ownEditor, target === editor else { return }
        cancel()
    }

    func cancel() {
        stopCorrectionLearning()
        guard phase != .stopping, phase != .idle || !settings.dictationEnabled else { return }
        let pendingStart = startTask
        let pendingTranscription = transcriptionTask
        pendingStart?.cancel()
        reset()
        phase = .stopping
        let current = token
        stopTask = Task { [weak self] in
            guard let self else { return }
            await pendingStart?.value
            _ = await capture.stop()
            await pendingTranscription?.value
            if !settings.dictationEnabled { await models.stop() }
            if token == current { phase = .idle; stopTask = nil }
        }
    }

    func prepareForTermination() {
        enableTask?.cancel()
        cancel()
        cueTask?.cancel()
        models.prepareForTermination()
    }

    private func reset(cancelTranscription: Bool = true) {
        token = UUID()
        if cancelTranscription { transcriptionTask?.cancel() }
        applePreparation?.cancel()
        applePreparation = nil
        models.endRecording()
        startTask = nil
        transcriptionTask = nil
        phase = .idle
        shortcutMode = nil
        target = nil
        field = nil
        panel.close()
    }
}

/// Which editor a mic session belongs to, so only that field's button shows it running.
struct DictationField: Equatable {
    let editor: ObjectIdentifier
    var isTranscribing = false
}
