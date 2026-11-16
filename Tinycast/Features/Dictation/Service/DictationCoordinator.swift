import AppKit
import ApplicationServices
import AVFoundation
import OSLog

@MainActor
@Observable
final class DictationCoordinator {
    private enum Phase { case idle, starting, listening, transcribing, stopping }

    private struct RecognizedPrefix: Sendable {
        let end: Int
        let text: String
        let model: DictationModel
        let language: String?
    }

    private struct RecordingSource {
        let model: DictationModel
        let language: String?
        let usesApple: Bool
    }

    private struct Recording {
        let samples: [Float]
        let source: RecordingSource
        let cleanupMode: DictationCleanupMode
    }

    /// What the last insertion changed, so undo can prove the field still holds exactly that.
    private struct LastInsertion {
        weak var editor: (any InjectableTextView)?
        let app: NSRunningApplication?
        let element: AXUIElement?
        let expected: String
        let replaced: String
        let insertedRange: NSRange
    }

    private static let minimumSamples = DictationWire.sampleRate / 4
    private static let retention = Duration.seconds(60)
    private static let confirmedDiscardLength = Duration.seconds(30)
    private static let discardWindow = Duration.seconds(2)

    private let settings: AppSettings
    private let hotKeys: HotKeyManager
    let models: DictationModelStore
    let corrections: DictationCorrectionStore
    private let capture = DictationCapture()
    @ObservationIgnored private lazy var cues = DictationCueRunner()
    private let panel: DictationPanelController
    private let injector: TextInjector
    private let focusedTarget: @MainActor () -> InjectionTarget?
    private let showMessage: (String, DialogTone) -> Void
    private let confirmEnable: () async -> Bool
    private let setupModels: () async -> Void
    var onRecordingStarted: ((_ targetBundleID: String?) -> Void)?
    var onRecordingEnded: (() -> Void)?
    var onStableTranscript: ((String, Bool?) -> Void)?
    var processTranscript: ((String, Bool?) async -> String)?
    private let recordTranscript: (String, String?, NSRunningApplication?) -> Void
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var enableTask: Task<Void, Never>?
    private(set) var isSettingUpModels = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionTask: Task<RecognizedPrefix?, Never>?
    @ObservationIgnored private var previewDelay: Task<Void, Error>?
    @ObservationIgnored private var previewCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var previousCleanupBlocks: [DictationPreviewSequence.CleanupBlock] = []
    @ObservationIgnored private var attemptedCleanupBlocks: [DictationPreviewSequence.CleanupBlock] = []
    @ObservationIgnored private var preparedCleanup: [DictationLocalCleanup.PreparedBlock] = []
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var correctionTask: Task<Void, Never>?
    @ObservationIgnored private var correctionSession: DictationCorrectionSession?
    @ObservationIgnored private var correctionProbe: DictationInsertionContext.CorrectionProbe?
    @ObservationIgnored private var correctionStarted: ContinuousClock.Instant?
    @ObservationIgnored private var correctionEditor: ObjectIdentifier?
    @ObservationIgnored private var correctionObservation: DictationInsertionContext.CorrectionObservation?
    @ObservationIgnored private var applePreparation: Task<AppleDictationSession, Error>?
    @ObservationIgnored private var appleStreaming: Task<String, Error>?
    @ObservationIgnored private var cleanupMode: DictationCleanupMode = .off
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var cueTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStartCue: UUID?
    @ObservationIgnored private var finishWhenStarted = false
    @ObservationIgnored private var shortcutMode: DictationMode?
    @ObservationIgnored private var target: InjectionTarget?
    @ObservationIgnored private var source: RecordingSource?
    @ObservationIgnored private var capturedRecording: Recording?
    @ObservationIgnored private var retained: Recording?
    @ObservationIgnored private var retainedExpiry: Task<Void, Never>?
    @ObservationIgnored private var listeningStarted: ContinuousClock.Instant?
    @ObservationIgnored private var pendingDiscard: ContinuousClock.Instant?
    @ObservationIgnored private var lastInsertion: LastInsertion?
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
        self.panel = DictationPanelController(settings: settings)
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
        panel.onCancel = { [weak self] in self?.escapePressed() }
        panel.onStart = { [weak self] in self?.pressed(.toggle) }
        capture.onLevels = { [weak self] in
            guard let self else { return }
            panel.state.levels = $0
            if pendingStartCue == token { playStartCue() }
        }
        capture.onCountdown = { [weak self] seconds in
            guard let self, phase == .listening else { return }
            panel.showCountdown(seconds)
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
        guard settings.dictationEnabled else { return }
        switch phase {
        case .idle: begin(shortcutMode: mode)
        case .transcribing, .stopping: reportBusy()
        case .starting, .listening: if mode == .toggle, shortcutMode != .pushToTalk { finish() }
        }
    }

    private func reportBusy() {
        showMessage(String(localized: "Still finishing the last dictation"), .neutral)
    }

    var isEnabled: Bool { settings.dictationEnabled }
    var hasModel: Bool { settings.dictationUsesApple || models.isInstalled(settings.dictationModel) }

    /// A field's own mic: click to start and click to finish, whatever the shortcut's mode or focus.
    func toggle(into editor: any InjectableTextView) {
        guard settings.dictationEnabled else { return }
        guard phase == .idle else {
            if field?.editor == ObjectIdentifier(editor) {
                if phase != .stopping { finish() }
            } else if phase == .transcribing || phase == .stopping {
                reportBusy()
            }
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
        _ = pollCorrectionLearning(flush: true)
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
        let targetBundleID = (target ?? InjectionTarget.current())?.externalApp?.bundleIdentifier
        cleanupMode = DictationAppOverride.resolve(bundleID: targetBundleID, in: settings.dictationAppOverrides)?
            .cleanup ?? settings.dictationCleanupMode
        self.target = target
        pendingStartCue = settings.dictationPlaysSounds ? current : nil
        let microphoneID = settings.dictationMicrophone
        let usesApple = settings.dictationUsesApple
        let model = settings.dictationModel
        let language = settings.dictationLanguage
        source = RecordingSource(model: model, language: language, usesApple: usesApple)
        let progressive = usesApple && settings.dictationLivePreview
        let audio = progressive ? AsyncStream<[Float]>.makeStream() : nil
        if usesApple {
            let vocabulary = Array(Set(corrections.entries.filter { $0.context == nil }.map(\.spelling)))
            let preparation = Task {
                try await AppleDictationSession.prepare(vocabulary: vocabulary, progressive: progressive)
            }
            applePreparation = preparation
            if let audio {
                appleStreaming = Task(priority: .userInitiated) { [weak self] in
                    let session = try await preparation.value
                    try Task.checkCancellation()
                    do {
                        return try await session.transcribe(audio.stream) { [weak self] text in
                            guard let self, token == current, phase == .listening else { return }
                            receivePreview(text, cumulative: true, isEnglish: nil)
                        }
                    } catch {
                        if let self, token == current { resetPreviewCleanup() }
                        throw error
                    }
                }
            }
        } else {
            models.beginRecording(model)
        }
        startTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(microphoneID: microphoneID, stream: audio?.continuation)
                guard token == current else { return }
                guard settings.dictationEnabled else { cancel(); return }
                phase = .listening
                listeningStarted = .now
                if !usesApple { startRecognition(model: model, language: language) }
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
        onRecordingStarted?(targetBundleID)
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
        guard phase == .listening, let source else { return }
        phase = .transcribing
        previewDelay?.cancel()
        previewCleanupTask?.cancel()
        previousCleanupBlocks.removeAll()
        attemptedCleanupBlocks.removeAll()
        if !settings.dictationLivePreview { preparedCleanup.removeAll() }
        panel.showTranscribing()
        field?.isTranscribing = true
        if settings.dictationPlaysSounds { cues.play(.stop) }
        let current = token
        let stoppedIn = shortcutMode == nil ? nil : Self.processID(of: focusedTarget())
        let applePreparation = self.applePreparation
        let appleStreaming = self.appleStreaming
        let cleanupMode = self.cleanupMode
        transcriptionTask = Task { [weak self] in
            guard let self, token == current else { return }
            let recording = Recording(samples: await capture.stop(), source: source, cleanupMode: cleanupMode)
            guard token == current else { return retain(recording) }
            let prefix = await recognitionTask?.value
            guard token == current else { return retain(recording) }
            await finishRecording(
                recording, prefix: prefix,
                applePreparation: applePreparation, appleStreaming: appleStreaming,
                stoppedIn: stoppedIn, token: current)
        }
    }

    /// Runs the kept recording again; it is copied instead if focus leaves `destination`'s app.
    func retryLastRecording(into destination: InjectionTarget?) {
        guard settings.dictationEnabled else { return }
        guard phase == .idle else { return reportBusy() }
        guard let recording = retained else {
            showMessage(String(localized: "No recent recording to try again"), .neutral)
            return
        }
        retained = nil
        retainedExpiry?.cancel()
        retainedExpiry = nil
        _ = pollCorrectionLearning(flush: true)
        stopCorrectionLearning()
        token = UUID()
        let current = token
        phase = .transcribing
        shortcutMode = .toggle
        target = nil
        source = recording.source
        cleanupMode = recording.cleanupMode
        let stoppedIn = Self.processID(of: destination)
        if !recording.source.usesApple { models.beginRecording(recording.source.model) }
        panel.showStarting(style: settings.dictationIndicatorStyle)
        panel.showTranscribing()
        onRecordingStarted?(destination?.externalApp?.bundleIdentifier)
        transcriptionTask = Task { [weak self] in
            guard let self, token == current else { return }
            await finishRecording(
                recording, prefix: nil, applePreparation: nil, appleStreaming: nil, stoppedIn: stoppedIn, token: current)
        }
    }

    private func finishRecording(
        _ recording: Recording, prefix: RecognizedPrefix?,
        applePreparation: Task<AppleDictationSession, Error>?, appleStreaming: Task<String, Error>?,
        stoppedIn: pid_t?, token current: UUID
    ) async {
        guard recording.samples.count >= Self.minimumSamples else {
            reset(cancelTranscription: false)
            return
        }
        capturedRecording = recording
        let transcript: String
        let usedApple: Bool
        let fellBack: Bool
        do {
            (transcript, usedApple, fellBack) = try await recognize(
                recording, prefix: prefix, applePreparation: applePreparation, appleStreaming: appleStreaming)
        } catch {
            guard token == current else { return }
            reset(cancelTranscription: false)
            Logger(subsystem: "com.tinycast.app", category: "Dictation")
                .error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            retain(recording)
            showMessage(
                String(localized: "Transcription failed; run Retry Last Dictation within a minute to try again"),
                .danger)
            return
        }
        guard token == current else { return }
        capturedRecording = nil
        models.endRecording()
        if fellBack {
            showMessage(String(localized: "The speech model failed, so Apple Dictation transcribed this"), .neutral)
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reset(cancelTranscription: false)
            showMessage(String(localized: "No speech detected"), .neutral)
            return
        }
        let isEnglish = englishOverride(
            model: usedApple ? nil : recording.source.model, language: recording.source.language)
        let cleaned = await cleanTranscript(transcript, isEnglish: isEnglish)
        guard token == current, !Task.isCancelled else { return }
        let processed = await processTranscript?(cleaned, isEnglish) ?? cleaned
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
        let switchedApps = followsFocus && stoppedIn != nil && Self.processID(of: destination) != stoppedIn
        let insertion = switchedApps
            ? nil : DictationInsertionContext.read(in: destination, learnsCorrections: settings.dictationEnabled)
        let formatted = DictationTextFormatter.format(
            processed,
            context: insertion?.context,
            adaptCapitalization: settings.dictationAdaptsCapitalization,
            properNouns: Set(corrections.entries.map(\.spelling)))
        let text = DictationCorrection.applying(corrections.entries, to: formatted)
        let original = processed == transcript && text == formatted ? nil : transcript
        guard !text.isEmpty else {
            reset(cancelTranscription: false)
            showMessage(String(localized: "No speech detected"), .neutral)
            return
        }
        guard !switchedApps else {
            copyTranscript(text, original: original, message: String(localized: "Copied dictation because you switched apps"))
            return
        }
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
                recordInsertion(text, snapshot: insertion, target: destination)
                if let probe {
                    learnCorrection(using: probe, recognized: formatted, editor: destination?.ownEditor)
                }
            },
            onFailed: { [weak self] _ in
                guard let self, token == current else { return }
                copyTranscript(
                    text, original: original, message: String(localized: "Couldn't paste here, so the dictation was copied"))
            })
    }

    private func recognize(
        _ recording: Recording, prefix: RecognizedPrefix?,
        applePreparation: Task<AppleDictationSession, Error>?, appleStreaming: Task<String, Error>?
    ) async throws -> (text: String, usedApple: Bool, fellBack: Bool) {
        let samples = recording.samples
        if let appleStreaming {
            do {
                let final = try await appleStreaming.value
                guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DictationWire.Failure.unavailable
                }
                return (final, true, false)
            } catch {
                try Task.checkCancellation()
                return (try await appleTranscription(samples), true, false)
            }
        }
        if let applePreparation {
            let session = try await applePreparation.value
            try Task.checkCancellation()
            return (try await session.transcribe(samples), true, false)
        }
        if recording.source.usesApple { return (try await appleTranscription(samples), true, false) }
        do {
            let text = try await transcribe(
                samples, prefix: prefix, model: recording.source.model, language: recording.source.language)
            return (text, false, false)
        } catch {
            try Task.checkCancellation()
            Logger(subsystem: "com.tinycast.app", category: "Dictation")
                .error("Speech model failed: \(error.localizedDescription, privacy: .public)")
            return (try await appleTranscription(samples), true, true)
        }
    }

    private func appleTranscription(_ samples: [Float]) async throws -> String {
        let vocabulary = Array(Set(corrections.entries.filter { $0.context == nil }.map(\.spelling)))
        let session = try await AppleDictationSession.prepare(vocabulary: vocabulary)
        try Task.checkCancellation()
        return try await session.transcribe(samples)
    }

    private func retain(_ recording: Recording) {
        guard settings.dictationEnabled, !terminating, recording.samples.count >= Self.minimumSamples else { return }
        retained = recording
        retainedExpiry?.cancel()
        retainedExpiry = Task { [weak self] in
            do { try await Task.sleep(for: Self.retention) } catch { return }
            self?.retained = nil
            self?.retainedExpiry = nil
        }
    }

    private func finishTranscript(_ transcript: String, original: String?, destination: InjectionTarget? = nil) {
        let app = destination?.externalApp ?? (destination?.ownEditor == nil ? nil : NSRunningApplication.current)
        reset(cancelTranscription: false)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { recordTranscript(text, original, app) }
    }

    /// History already keeps the transcript; the clipboard puts it one paste away.
    private func copyTranscript(_ transcript: String, original: String?, message: String) {
        finishTranscript(transcript, original: original)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Paster.copyPlainText(text)
        showMessage(message, .neutral)
    }

    func pasteLastTranscript(_ transcript: String?, into destination: InjectionTarget?) {
        guard let transcript, !transcript.isEmpty else {
            showMessage(String(localized: "No dictation to paste yet"), .neutral)
            return
        }
        guard let destination else {
            Paster.copyPlainText(transcript)
            showMessage(String(localized: "Couldn't paste here, so the dictation was copied"), .neutral)
            return
        }
        let insertion = DictationInsertionContext.read(in: destination, learnsCorrections: false)
        let text = DictationTextFormatter.format(
            transcript, context: insertion?.context, adaptCapitalization: settings.dictationAdaptsCapitalization,
            properNouns: Set(corrections.entries.map(\.spelling)))
        injector.deliver(
            InjectedText(text), target: destination, expectedKeyword: nil,
            keywordLength: 0, automaticGeneration: nil,
            onDelivered: { [weak self] in
                guard let self else { return }
                _ = pollCorrectionLearning(flush: true)
                stopCorrectionLearning()
                recordInsertion(text, snapshot: insertion, target: destination)
            },
            onFailed: { [weak self] _ in
                Paster.copyPlainText(transcript)
                self?.showMessage(String(localized: "Couldn't paste here, so the dictation was copied"), .neutral)
            })
    }

    private func recordInsertion(
        _ inserted: String, snapshot: DictationInsertionContext.Snapshot?, target: InjectionTarget?
    ) {
        lastInsertion = nil
        guard let snapshot, let target, Range(snapshot.range, in: snapshot.text) != nil else { return }
        let before = snapshot.text as NSString
        lastInsertion = LastInsertion(
            editor: target.ownEditor, app: target.externalApp, element: snapshot.element,
            expected: before.replacingCharacters(in: snapshot.range, with: inserted),
            replaced: before.substring(with: snapshot.range),
            insertedRange: NSRange(location: snapshot.range.location, length: (inserted as NSString).length))
    }

    /// Removes the last insertion only while its field provably holds nothing typed since.
    func undoLastInsertion() {
        let unavailable = String(localized: "Can't undo the last dictation here")
        guard let last = lastInsertion, !injector.isDelivering else { return showMessage(unavailable, .neutral) }
        if let editor = last.editor {
            guard editor.window?.isVisible == true, editor.isEditable, !editor.hasMarkedText(),
                editor.string.utf16.elementsEqual(last.expected.utf16),
                Range(last.insertedRange, in: editor.string) != nil
            else { return showMessage(unavailable, .neutral) }
            editor.insertText(last.replaced, replacementRange: last.insertedRange)
            let restored = (last.expected as NSString).replacingCharacters(in: last.insertedRange, with: last.replaced)
            guard editor.string == restored else { return showMessage(unavailable, .neutral) }
        } else {
            guard let app = last.app, let element = last.element,
                AccessibilityTextReplacer.restoreInsertion(
                    in: app, element: element, expected: last.expected,
                    insertedRange: last.insertedRange, replaced: last.replaced)
            else { return showMessage(unavailable, .neutral) }
        }
        lastInsertion = nil
        rollbackCorrectionLearning()
    }

    private static func processID(of target: InjectionTarget?) -> pid_t? {
        switch target {
        case .external(let app): app.processIdentifier
        case .ownEditor: ProcessInfo.processInfo.processIdentifier
        case nil: nil
        }
    }

    private func escapePressed() {
        if phase == .listening, let listeningStarted,
            listeningStarted.duration(to: .now) > Self.confirmedDiscardLength
        {
            guard let pendingDiscard, pendingDiscard.duration(to: .now) <= Self.discardWindow else {
                pendingDiscard = .now
                showMessage(String(localized: "Press Esc again to discard this recording"), .neutral)
                return
            }
        }
        cancel(dismissIndicator: true)
    }

    private func learnCorrection(
        using probe: DictationInsertionContext.CorrectionProbe, recognized: String,
        editor: (any InjectableTextView)?
    ) {
        stopCorrectionLearning()
        guard settings.dictationEnabled, probe.readInsertion() == probe.inserted else { return }
        let identity = UUID()
        correctionSession = DictationCorrectionSession(
            id: identity, inserted: probe.inserted, recognized: recognized, baseline: corrections.entries,
            isKnownWord: corrections.isKnownWord)
        correctionProbe = probe
        correctionStarted = .now
        correctionEditor = editor.map { ObjectIdentifier($0) }
        correctionObservation = probe.observeChanges { [weak self] in
            guard let self, correctionSession?.id == identity else { return }
            scheduleCorrectionCheck(after: DictationCorrectionSession.changeCoalescing, identity: identity)
        }
        scheduleCorrectionCheck(after: DictationCorrectionSession.polledCheckInterval, identity: identity)
    }

    private func scheduleCorrectionCheck(after delay: Duration, identity: UUID) {
        correctionTask?.cancel()
        correctionTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, correctionSession?.id == identity, pollCorrectionLearning(),
                let session = correctionSession, let started = correctionStarted
            else { return }
            let next = session.nextCheck(at: started.duration(to: .now), isObserved: correctionObservation != nil)
            scheduleCorrectionCheck(after: next, identity: identity)
        }
    }

    private func pollCorrectionLearning(flush: Bool = false) -> Bool {
        guard settings.dictationEnabled, var session = correctionSession,
            let started = correctionStarted, let probe = correctionProbe
        else {
            stopCorrectionLearning()
            return false
        }
        let elapsed = started.duration(to: .now)
        let edited = probe.readInsertion()
        if let edited, probe.restoresSelection(edited) {
            rollbackCorrectionLearning()
            return false
        }
        guard let edited, !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let observation = session.settleOnLoss(at: elapsed) { learn(observation, in: &session) }
            stopCorrectionLearning()
            return false
        }
        if let observation = session.observe(edited, at: elapsed, flush: flush) {
            guard learn(observation, in: &session) else { return false }
        }
        guard !session.isExpired(at: elapsed) else {
            stopCorrectionLearning()
            return false
        }
        correctionSession = session
        return true
    }

    @discardableResult
    private func learn(
        _ observation: DictationCorrectionSession.Observation, in session: inout DictationCorrectionSession
    ) -> Bool {
        let previous = session.learned
        do {
            session.learned = try corrections.learn(
                observation.corrections, candidates: observation.candidates, sessionID: session.id,
                replacing: session.learned, baseline: session.baseline)
        } catch {
            stopCorrectionLearning()
            showMessage(error.localizedDescription, .danger)
            return false
        }
        let added = session.learned.filter { entry in
            entry.original != entry.spelling
                && !previous.contains { $0.id == entry.id && $0.spelling == entry.spelling }
        }
        if let first = added.first {
            let message = added.count == 1
                ? String(localized: "Learned “\(first.original)” → “\(first.spelling)”")
                : String(localized: "Learned new dictionary words")
            showMessage(message, .success)
        }
        return true
    }

    private func rollbackCorrectionLearning() {
        if var session = correctionSession {
            corrections.discardCandidates(for: session.id)
            _ = learn((corrections: [], candidates: []), in: &session)
        }
        stopCorrectionLearning()
    }

    func stopCorrectionLearning() {
        correctionTask?.cancel()
        correctionTask = nil
        correctionObservation?.invalidate()
        correctionObservation = nil
        correctionSession = nil
        correctionProbe = nil
        correctionStarted = nil
        correctionEditor = nil
    }

    func removeCorrection(_ correction: DictationCorrection) {
        stopCorrectionLearning()
        do { try corrections.remove(correction) } catch {
            showMessage(error.localizedDescription, .danger)
        }
    }

    func addCorrection(_ correction: DictationCorrection) -> Bool {
        stopCorrectionLearning()
        do {
            try corrections.record(correction)
            return true
        } catch {
            showMessage(error.localizedDescription, .danger)
            return false
        }
    }

    private func englishOverride(model: DictationModel?, language: String?) -> Bool? {
        if model == .v2 || model == .phonon2 || model == .unified {
            true
        } else if model?.isCohere == true, language == nil {
            true
        } else if (model?.isQwen == true || model?.isCohere == true), let language {
            language == DictationLanguage.english.rawValue
        } else {
            nil
        }
    }

    func cancel(in editor: any InjectableTextView) {
        if correctionEditor == ObjectIdentifier(editor) { stopCorrectionLearning() }
        guard let target = target?.ownEditor, target === editor else { return }
        cancel()
    }

    func cancel(dismissIndicator: Bool = false) {
        stopCorrectionLearning()
        guard phase != .stopping, phase != .idle || !settings.dictationEnabled else { return }
        let inFlight = capturedRecording
        let source = self.source
        let cleanupMode = self.cleanupMode
        let pendingStart = startTask
        let pendingTranscription = transcriptionTask
        let pendingRecognition = recognitionTask
        pendingStart?.cancel()
        reset(showIdleIndicator: false)
        phase = .stopping
        let current = token
        stopTask = Task { [weak self] in
            guard let self else { return }
            await pendingStart?.value
            let captured = await capture.stop()
            if let recording = inFlight
                ?? source.map({ Recording(samples: captured, source: $0, cleanupMode: cleanupMode) })
            {
                retain(recording)
            }
            await pendingTranscription?.value
            _ = await pendingRecognition?.value
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
        recognitionTask?.cancel()
        recognitionTask = nil
        previewDelay?.cancel()
        previewDelay = nil
        resetPreviewCleanup()
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
        source = nil
        capturedRecording = nil
        listeningStarted = nil
        pendingDiscard = nil
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

    private static let previewSeconds = 5
    private static let maximumSegmentFailures = 3

    private func startRecognition(model: DictationModel, language: String?) {
        guard !model.isCohere else { return }
        let current = token
        let isEnglish = englishOverride(model: model, language: language)
        let cadence = Duration.milliseconds(model.isQwen ? 500 : 350)
        recognitionTask = Task { [weak self] in
            guard let self else { return nil }
            var prefix: RecognizedPrefix?
            var canRecognizeSegments = true
            var segmentFailures = 0
            var hadPreview = settings.dictationLivePreview
            var failures = 0
            var preview = DictationPreviewPacing()
            var nextRequest = ContinuousClock.now + .milliseconds(350)
            while token == current, phase == .listening, !Task.isCancelled {
                let deadline = nextRequest
                let delay = Task { try await Task.sleep(until: deadline, clock: .continuous) }
                previewDelay = delay
                do { try await delay.value } catch { break }
                previewDelay = nil
                guard token == current, phase == .listening, !Task.isCancelled else { break }
                let hasPreview = settings.dictationLivePreview
                if hadPreview && !hasPreview {
                    panel.hidePreview()
                    resetPreviewCleanup()
                }
                hadPreview = hasPreview
                let wantsPreview = hasPreview && failures < 3
                nextRequest = .now + (wantsPreview ? cadence * preview.stretch : .milliseconds(500))
                if canRecognizeSegments, let segment = await capture.nextSegment(after: prefix?.end ?? 0) {
                    guard token == current, phase == .listening, !Task.isCancelled else { break }
                    let text: String
                    do {
                        text = try await models.transcribe(
                            segment.samples, model: model, language: language, purpose: .segment)
                        guard !text.isEmpty else { throw DictationWire.Failure.unavailable }
                    } catch {
                        guard token == current, !Task.isCancelled else { return nil }
                        // The next segment from the same start covers the dropped audio again.
                        segmentFailures += 1
                        canRecognizeSegments = segmentFailures < Self.maximumSegmentFailures
                        continue
                    }
                    guard token == current, !Task.isCancelled else { return nil }
                    segmentFailures = 0
                    if let previous = prefix, Self.continuesAmount(text, after: previous.text) {
                        prefix = nil
                        canRecognizeSegments = false
                        continue
                    }
                    guard !Self.endsAtUnfinishedPhrase(text) else { continue }
                    let cumulative = prefix.map { $0.text + " " + text } ?? text
                    prefix = RecognizedPrefix(end: segment.end, text: cumulative, model: model, language: language)
                    if phase == .listening { onStableTranscript?(cumulative, isEnglish) }
                    continue
                }
                guard token == current, phase == .listening, !Task.isCancelled else { break }
                guard wantsPreview, settings.dictationLivePreview else { continue }
                do {
                    let samples = await capture.recentSamples(seconds: Self.previewSeconds)
                    guard token == current, phase == .listening else { break }
                    guard samples.count >= DictationWire.sampleRate / 4 else { continue }
                    guard preview.shouldRequest(samples, at: .now) else { continue }
                    let text = try await models.transcribe(
                        samples, model: model, language: language, purpose: .preview)
                    guard token == current, phase == .listening, !Task.isCancelled else { break }
                    guard settings.dictationLivePreview else { continue }
                    failures = 0
                    preview.received(text)
                    receivePreview(text, cumulative: false, isEnglish: isEnglish)
                } catch {
                    guard token == current, phase == .listening, !Task.isCancelled else { break }
                    panel.hidePreview()
                    resetPreviewCleanup()
                    failures += 1
                    preview.failed()
                    nextRequest = .now + .milliseconds(1500)
                    Logger(subsystem: "com.tinycast.app", category: "DictationPreview")
                        .error("Live preview failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return prefix
        }
    }

    private func transcribe(
        _ samples: [Float], prefix: RecognizedPrefix?, model: DictationModel, language: String?
    ) async throws -> String {
        if let prefix, prefix.model == model, prefix.language == language,
            (DictationWire.sampleRate / 4...DictationCapture.maximumSegmentSamples).contains(samples.count - prefix.end)
        {
            do {
                let tail = try await models.transcribe(Array(samples[prefix.end...]), model: model, language: language)
                if !tail.isEmpty, !Self.continuesAmount(tail, after: prefix.text) {
                    return prefix.text + " " + tail
                }
            } catch {
                try Task.checkCancellation()
            }
        }
        return try await models.transcribe(samples, model: model, language: language)
    }

    private static let amountWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "trillion", "quadrillion", "half", "quarter"
    ]

    private static func endsAtUnfinishedPhrase(_ text: String) -> Bool {
        guard let last = boundaryWords(text.suffix(80)).last else { return true }
        return isAmountWord(last) || ["and", "or", "point", "dot", "minus", "negative", "to"].contains(last)
    }

    private static func continuesAmount(_ text: String, after preceding: String) -> Bool {
        let leading = boundaryWords(text.prefix(80)).prefix(3)
        guard let first = leading.first,
            isAmountWord(first) || (first == "and" && leading.dropFirst().contains(where: isAmountWord))
        else { return false }
        return boundaryWords(preceding.suffix(80)).suffix(4).contains(where: isAmountWord)
    }

    private static func boundaryWords(_ text: Substring) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    private static func isAmountWord(_ word: Substring) -> Bool {
        word.contains(where: \.isNumber) || amountWords.contains(String(word))
    }

    private func receivePreview(_ text: String, cumulative: Bool, isEnglish: Bool?) {
        guard settings.dictationLivePreview else {
            panel.hidePreview()
            resetPreviewCleanup()
            return
        }
        panel.showPreview(text, twoLines: settings.dictationTwoLinePreview, cumulative: cumulative)
        guard isEnglish != false, cleanupMode == .basic || cleanupMode == .advanced else { return }
        let blocks = DictationPreviewSequence.cleanupBlocks(in: text)
        let previous = previousCleanupBlocks
        previousCleanupBlocks = blocks
        guard previewCleanupTask == nil, let block = blocks.reversed().first(where: { block in
            previous.contains(block) && !attemptedCleanupBlocks.contains(block)
        }) else { return }
        let mode = cleanupMode
        let current = token
        previewCleanupTask = Task(priority: .background) { [weak self] in
            let prepared = await DictationLocalCleanup.prepare(block, mode: mode)
            guard let self else { return }
            previewCleanupTask = nil
            guard token == current, phase == .listening, !Task.isCancelled else { return }
            if attemptedCleanupBlocks.count == 32 { attemptedCleanupBlocks.removeFirst() }
            attemptedCleanupBlocks.append(block)
            if prepared.isUseful {
                if preparedCleanup.count == 16 { preparedCleanup.removeFirst() }
                preparedCleanup.append(prepared)
            }
        }
    }

    private func cleanTranscript(_ transcript: String, isEnglish: Bool?) async -> String {
        let prepared = preparedCleanup
        preparedCleanup.removeAll()
        return await DictationLocalCleanup.clean(transcript, mode: cleanupMode, isEnglish: isEnglish, prepared: prepared)
    }

    private func resetPreviewCleanup() {
        previewCleanupTask?.cancel()
        previousCleanupBlocks.removeAll()
        attemptedCleanupBlocks.removeAll()
        preparedCleanup.removeAll()
    }
}

/// Which editor a mic session belongs to, so only that field's button shows it running.
struct DictationField: Equatable {
    let editor: ObjectIdentifier
    var isTranscribing = false
}
