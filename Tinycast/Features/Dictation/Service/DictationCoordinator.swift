import AppKit
import AVFoundation
import OSLog

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
    private let focusedTarget: @MainActor () -> InjectionTarget?
    private let showMessage: (String, DialogTone) -> Void
    private let confirmEnable: () async -> Bool
    private let setupModels: () async -> Void
    var onRecordingStarted: (() -> Void)?
    var onRecordingEnded: (() -> Void)?
    var processTranscript: ((String, Bool?) async -> String)?
    private let recordTranscript: (String, String?, NSRunningApplication?) -> Void
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var enableTask: Task<Void, Never>?
    private(set) var isSettingUpModels = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewDelay: Task<Void, Error>?
    @ObservationIgnored private var previewCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var previousPreview = ""
    @ObservationIgnored private var preparedCleanup: (source: String, result: String)?
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var correctionTask: Task<Void, Never>?
    @ObservationIgnored private var applePreparation: Task<AppleDictationSession, Error>?
    @ObservationIgnored private var appleStreaming: Task<String, Error>?
    @ObservationIgnored private var cleanupMode: DictationCleanupMode = .off
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
        focusedTarget: @escaping @MainActor () -> InjectionTarget? = InjectionTarget.current,
        confirmEnable: @escaping () async -> Bool,
        setupModels: @escaping () async -> Void = { _ = Permissions.ensureAccessibility() },
        showMessage: @escaping (String, DialogTone) -> Void,
        recordTranscript: @escaping (String, String?, NSRunningApplication?) -> Void
    ) {
        self.settings = settings
        self.hotKeys = hotKeys
        self.models = models
        self.corrections = corrections
        self.injector = injector
        self.focusedTarget = focusedTarget
        self.confirmEnable = confirmEnable
        self.setupModels = setupModels
        self.showMessage = showMessage
        self.recordTranscript = recordTranscript
        panel.onAccept = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel(dismissIndicator: true) }
        panel.onStart = { [weak self] in self?.pressed(.toggle) }
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
            isSettingUpModels = true
            defer { isSettingUpModels = false }
            await setupModels()
        }
    }

    func cancelModelSetup() { enableTask?.cancel() }

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
        begin(shortcutMode: mode)
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

    private func begin(target: InjectionTarget? = nil, shortcutMode: DictationMode? = nil) {
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
        cleanupMode = settings.dictationCleanupMode
        self.target = target
        pendingStartCue = settings.dictationPlaysSounds ? current : nil
        let microphoneID = settings.dictationMicrophone
        let usesApple = settings.dictationUsesApple
        let progressive = usesApple && settings.dictationLivePreview
        let audio = progressive ? AsyncStream<[Float]>.makeStream() : nil
        if usesApple {
            let vocabulary = Array(Set(corrections.entries.map(\.spelling)))
            let preparation = Task {
                try await AppleDictationSession.prepare(vocabulary: vocabulary, progressive: progressive)
            }
            applePreparation = preparation
            if let audio {
                appleStreaming = Task(priority: .userInitiated) { [weak self] in
                    let session = try await preparation.value
                    try Task.checkCancellation()
                    return try await session.transcribe(audio.stream) { [weak self] text in
                        guard let self, token == current, phase == .listening else { return }
                        receivePreview(text, cumulative: true, isEnglish: nil)
                    }
                }
            }
        } else {
            models.beginRecording(settings.dictationModel)
        }
        startTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(microphoneID: microphoneID, stream: audio?.continuation)
                guard token == current else { return }
                guard settings.dictationEnabled else { cancel(); return }
                phase = .listening
                if !usesApple { startPreview() }
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
        panel.state.animatesTranscript = settings.dictationAnimateTranscript
        panel.state.twoLinePreview = settings.dictationTwoLinePreview
        panel.showStarting(style: settings.dictationIndicatorStyle)
        onRecordingStarted?()
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
        previewDelay?.cancel()
        panel.showTranscribing()
        field?.isTranscribing = true
        if settings.dictationPlaysSounds { cues.play(.stop) }
        let current = token
        let model = settings.dictationModel
        let language = settings.dictationLanguage
        let applePreparation = self.applePreparation
        let appleStreaming = self.appleStreaming
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            guard token == current else { return }
            let samples = await capture.stop()
            await previewTask?.value
            guard token == current else { return }
            guard samples.count >= 1_600 else {
                reset(cancelTranscription: false)
                showMessage(String(localized: "No speech was recorded"), .danger)
                return
            }
            do {
                let transcript: String
                if let appleStreaming {
                    do {
                        let final = try await appleStreaming.value
                        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw DictationWire.Failure.unavailable
                        }
                        transcript = final
                    } catch {
                        try Task.checkCancellation()
                        let vocabulary = Array(Set(corrections.entries.map(\.spelling)))
                        let session = try await AppleDictationSession.prepare(vocabulary: vocabulary)
                        transcript = try await session.transcribe(samples)
                    }
                } else if let applePreparation {
                    let session = try await applePreparation.value
                    try Task.checkCancellation()
                    transcript = try await session.transcribe(samples)
                } else {
                    transcript = try await models.transcribe(samples, model: model, language: language)
                }
                guard token == current else { return }
                models.endRecording()
                let isEnglish = englishOverride(model: applePreparation == nil ? model : nil, language: language)
                let cleaned: String
                if let preparedCleanup, preparedCleanup.source == transcript {
                    cleaned = preparedCleanup.result
                } else {
                    cleaned = await DictationLocalCleanup.clean(transcript, mode: cleanupMode, isEnglish: isEnglish)
                }
                guard token == current, !Task.isCancelled else { return }
                let corrected = DictationCorrection.applying(corrections.entries, to: cleaned)
                let processed = await processTranscript?(corrected, isEnglish) ?? corrected
                guard token == current, !Task.isCancelled else { return }
                let followsFocus = shortcutMode != nil
                if followsFocus, injector.isDelivering {
                    await injector.drain()
                    guard token == current, !Task.isCancelled else { return }
                }
                if settings.dictationEnabled && settings.dictationIdleIndicator && !terminating {
                    panel.showIdle(style: settings.dictationIndicatorStyle)
                } else {
                    panel.close()
                }
                let destination = followsFocus ? focusedTarget() : target
                let insertion = DictationInsertionContext.read(
                    in: destination, learnsCorrections: settings.dictationEnabled && settings.dictationAutoLearnsWords)
                let original = processed == transcript ? nil : transcript
                let formatted = DictationTextFormatter.format(
                    processed,
                    context: insertion?.context,
                    adaptCapitalization: settings.dictationAdaptsCapitalization)
                let text = DictationCorrection.applying(corrections.entries, to: formatted)
                guard !text.isEmpty else { reset(cancelTranscription: false); return }
                let probe = insertion?.correctionProbe(inserted: text)
                injector.deliver(
                    InjectedText(text), target: destination, expectedKeyword: nil,
                    keywordLength: 0, automaticGeneration: nil, activateTarget: !followsFocus,
                    isValid: { [weak self] in
                        guard let self, token == current else { return false }
                        guard followsFocus, let editor = destination?.ownEditor else { return true }
                        return focusedTarget()?.ownEditor === editor
                    },
                    onDelivered: { [weak self] in
                        guard let self, token == current else { return }
                        finishTranscript(text, original: original, destination: destination)
                        if let probe { learnCorrection(using: probe, recognized: formatted) }
                    },
                    onFailed: { [weak self] in
                        guard let self, token == current else { return }
                        finishTranscript(text, original: original, pasteFailed: true)
                    })
            } catch {
                guard token == current else { return }
                reset(cancelTranscription: false)
                showMessage(error.localizedDescription, .danger)
            }
        }
    }

    private func finishTranscript(
        _ transcript: String, original: String?, destination: InjectionTarget? = nil, pasteFailed: Bool = false
    ) {
        let app = destination?.externalApp ?? (destination?.ownEditor == nil ? nil : NSRunningApplication.current)
        reset(cancelTranscription: false)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { recordTranscript(text, original, pasteFailed ? nil : app) }
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
            let deadline = ContinuousClock.now + .seconds(60)
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

    private func englishOverride(model: DictationModel?, language: String?) -> Bool? {
        if model == .v2 || model == .phonon2 {
            true
        } else if model?.isQwen == true, let language {
            language == DictationLanguage.english.rawValue
        } else {
            nil
        }
    }

    func cancel(in editor: any InjectableTextView) {
        guard let target = target?.ownEditor, target === editor else { return }
        cancel()
    }

    func cancel(dismissIndicator: Bool = false) {
        stopCorrectionLearning()
        guard phase != .stopping, phase != .idle || !settings.dictationEnabled else { return }
        let pendingStart = startTask
        let pendingTranscription = transcriptionTask
        let pendingPreview = previewTask
        pendingStart?.cancel()
        reset(showIdleIndicator: false)
        phase = .stopping
        let current = token
        stopTask = Task { [weak self] in
            guard let self else { return }
            await pendingStart?.value
            _ = await capture.stop()
            await pendingTranscription?.value
            await pendingPreview?.value
            if !settings.dictationEnabled { await models.stop() }
            if token == current {
                phase = .idle
                stopTask = nil
                if !dismissIndicator { applyIdleIndicator() }
            }
        }
    }

    func prepareForTermination() {
        terminating = true
        enableTask?.cancel()
        cancel()
        cueTask?.cancel()
        models.prepareForTermination()
    }

    private func reset(cancelTranscription: Bool = true, showIdleIndicator: Bool = true) {
        token = UUID()
        previewTask?.cancel()
        previewTask = nil
        previewDelay?.cancel()
        previewDelay = nil
        previewCleanupTask?.cancel()
        previewCleanupTask = nil
        previousPreview = ""
        preparedCleanup = nil
        if cancelTranscription { transcriptionTask?.cancel() }
        applePreparation?.cancel()
        applePreparation = nil
        appleStreaming?.cancel()
        appleStreaming = nil
        models.endRecording()
        onRecordingEnded?()
        startTask = nil
        transcriptionTask = nil
        phase = .idle
        shortcutMode = nil
        target = nil
        field = nil
        if showIdleIndicator {
            applyIdleIndicator()
        } else {
            panel.close()
        }
    }

    func applyIdleIndicator() {
        guard phase == .idle else { return }
        if settings.dictationEnabled, settings.dictationIdleIndicator, !terminating {
            panel.showIdle(style: settings.dictationIndicatorStyle)
        } else {
            panel.close()
        }
    }

    private func startPreview() {
        guard settings.dictationLivePreview else { return }
        let current = token
        let model = settings.dictationModel
        let language = settings.dictationLanguage
        let isEnglish = englishOverride(model: model, language: language)
        let cadence = Duration.milliseconds(model.isQwen ? 500 : 350)
        previewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == current, phase == .listening, !settings.dictationLivePreview {
                    panel.hidePreview()
                }
            }
            var failures = 0
            var nextRequest = ContinuousClock.now + .milliseconds(350)
            while token == current, phase == .listening, settings.dictationLivePreview {
                do {
                    let deadline = nextRequest
                    let delay = Task { try await Task.sleep(until: deadline, clock: .continuous) }
                    previewDelay = delay
                    try await delay.value
                    previewDelay = nil
                    guard token == current, phase == .listening, settings.dictationLivePreview else { return }
                    nextRequest = .now + cadence
                    let samples = await capture.recentSamples(seconds: 5)
                    guard token == current, phase == .listening else { return }
                    guard samples.count >= DictationWire.sampleRate / 4 else { continue }
                    let text = try await models.transcribe(samples, model: model, language: language)
                    guard token == current, phase == .listening, settings.dictationLivePreview, !Task.isCancelled
                    else { return }
                    failures = 0
                    receivePreview(text, cumulative: false, isEnglish: isEnglish)
                } catch {
                    guard token == current, phase == .listening, !Task.isCancelled else { return }
                    panel.hidePreview()
                    failures += 1
                    nextRequest = .now + .milliseconds(1500)
                    Logger(subsystem: "com.tinycast.app", category: "DictationPreview")
                        .error("Live preview failed: \(error.localizedDescription, privacy: .public)")
                    guard failures < 3 else { return }
                }
            }
        }
    }

    private func receivePreview(_ text: String, cumulative: Bool, isEnglish: Bool?) {
        guard settings.dictationLivePreview else {
            panel.hidePreview()
            return
        }
        panel.showPreview(text, twoLines: settings.dictationTwoLinePreview, cumulative: cumulative)
        guard cleanupMode != .off else { return }
        let snapshot = cumulative ? text : panel.state.transcript
        let stable = DictationPreviewSequence.stableCleanupInput(previous: previousPreview, incoming: snapshot)
        previousPreview = snapshot
        guard let stable, stable != preparedCleanup?.source, previewCleanupTask == nil else { return }
        let mode = cleanupMode
        let current = token
        previewCleanupTask = Task(priority: .utility) { [weak self] in
            let cleaned = await DictationLocalCleanup.clean(stable, mode: mode, isEnglish: isEnglish)
            guard let self, token == current, !Task.isCancelled else { return }
            preparedCleanup = (stable, cleaned)
            previewCleanupTask = nil
        }
    }
}

/// Which editor a mic session belongs to, so only that field's button shows it running.
struct DictationField: Equatable {
    let editor: ObjectIdentifier
    var isTranscribing = false
}
