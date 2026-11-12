import AppKit
import SwiftUI

@main
@MainActor
struct DictationFieldTest {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await testDelivery()
        try await testShortcutOwnership()
        try await testShortcutFollowsFocusDuringProcessing()
        try await testScopedCancellation()
        try await testChatSwitch()
        try await testWindowClose()
        try await testQueuedCancellation(closing: false)
        try await testQueuedCancellation(closing: true)
        try await testDeliveryFailure()
        try await testSoundsOff()
        try await testSounds()
        try await testCancelSilently()
        try await testCancelDuringStartCue()
        try await testBluetoothStartCue()
        print("ALL PASSED")
    }

    private static func testDelivery() async throws {
        let fixture = Fixture()
        let editor = ComposerTextView()
        try await fixture.start(into: editor)
        fixture.coordinator.releasedHold()
        fixture.coordinator.cancelHold()
        expect(fixture.capture.isRecording, "A hold gesture cannot stop the field mic")
        fixture.coordinator.toggle(into: editor)
        try await wait { fixture.models.pending != nil }
        fixture.models.finish("Spoken words")
        try await wait { fixture.coordinator.field == nil }
        expect(editor.string == "Spoken words", "The field mic inserts its transcript")
        expect(Paster.copies.isEmpty, "A field mic leaves the clipboard alone")
        expect(fixture.transcripts == ["Spoken words"], "A field mic saves its transcript once")
        expect(fixture.pasteAppIDs == [NSRunningApplication.current.processIdentifier], "History records the editor's app")
    }

    private static func testShortcutOwnership() async throws {
        let toggle = Fixture()
        toggle.coordinator.pressed(.toggle)
        try await wait { toggle.capture.isRecording }
        toggle.coordinator.pressed(.pushToTalk)
        toggle.coordinator.releasedHold()
        toggle.coordinator.cancelHold()
        expect(toggle.capture.isRecording, "A hold gesture leaves the toggle recording active")
        toggle.coordinator.pressed(.toggle)
        try await wait { toggle.models.pending != nil }
        toggle.coordinator.cancel()
        toggle.models.finish("")
        try await wait { toggle.models.finished }

        let hold = Fixture()
        hold.coordinator.pressed(.pushToTalk)
        try await wait { hold.capture.isRecording }
        hold.coordinator.pressed(.toggle)
        expect(hold.capture.isRecording, "Toggle leaves a held recording active")
        hold.coordinator.releasedHold()
        try await wait { hold.models.pending != nil }
        hold.coordinator.cancel()
        hold.models.finish("")
        try await wait { hold.models.finished }
    }

    private static func testShortcutFollowsFocusDuringProcessing() async throws {
        let fixture = Fixture()
        let original = ComposerTextView()
        let destination = ComposerTextView()
        fixture.focusedTarget = .ownEditor(original)
        fixture.coordinator.pressed(.toggle)
        try await wait { fixture.capture.isRecording }
        fixture.coordinator.pressed(.toggle)
        try await wait { fixture.models.pending != nil }
        fixture.focusedTarget = .ownEditor(destination)
        fixture.models.finish("Switched inputs")
        try await wait { !fixture.transcripts.isEmpty }
        expect(original.string.isEmpty, "Shortcut dictation leaves the original input untouched")
        expect(destination.string == "Switched inputs", "Shortcut dictation inserts into the newly focused input")
        expect(fixture.messages.isEmpty, "Switching inputs during processing does not report a paste failure")
    }

    private static func testScopedCancellation() async throws {
        let fixture = Fixture()
        let editor = ComposerTextView()
        fixture.coordinator.toggle(into: editor)
        expect(fixture.panel.isVisible && !fixture.capture.isRecording, "The pill opens during microphone setup")
        fixture.coordinator.cancel(in: editor)
        expect(!fixture.panel.isVisible, "Cancelling startup closes the pill immediately")
        try await wait { fixture.capture.stopCount > 0 }
        expect(fixture.coordinator.field == nil, "Cancellation covers a recording still starting")
        expect(!fixture.capture.isRecording, "A canceled start cannot leave recording active")

        try await fixture.start(into: editor)
        fixture.coordinator.cancel(in: ComposerTextView())
        expect(fixture.capture.isRecording, "Another editor cannot cancel this session")
        expect(fixture.coordinator.field != nil, "Unrelated teardown preserves the field owner")
        fixture.coordinator.cancel(in: editor)
        try await wait { !fixture.capture.isRecording }
    }

    private static func testChatSwitch() async throws {
        let fixture = Fixture()
        let state = SurfaceState()
        let first = state.chat
        let second = Draft("Second draft")
        let surface = Surface(state: state, dictation: fixture.coordinator)
        defer { surface.close() }
        try await wait { surface.editor != nil }
        let editor = surface.editor!
        try await fixture.start(into: editor)
        fixture.coordinator.accept()
        try await wait { fixture.models.pending != nil }
        state.chat = second
        try await wait { surface.editor?.string == second.text }
        expect(surface.editor === editor, "Chat switching exercises the same reused editor")
        expect(fixture.coordinator.field == nil, "Rebinding cancels the old chat's transcription")
        fixture.models.finish("Late speech for the first chat")
        try await wait { fixture.models.finished }
        await fixture.queue.drain()
        expect(first.text == "First draft", "Canceled transcription leaves the original draft intact")
        expect(second.text == "Second draft", "Canceled transcription cannot enter the new chat")
        expect(fixture.messages.isEmpty, "Destination cancellation does not report an insertion error")
    }

    private static func testWindowClose() async throws {
        let fixture = Fixture()
        let state = SurfaceState()
        let surface = Surface(state: state, dictation: fixture.coordinator)
        try await wait { surface.editor != nil }
        let oldEditor = surface.editor!
        try await fixture.start(into: oldEditor)
        surface.close()
        try await wait { fixture.coordinator.field == nil && !fixture.capture.isRecording }
        expect(!oldEditor.isEditable, "Teardown rejects delayed in-process writes")
        expect(oldEditor.delegate == nil, "Teardown releases the old draft binding")
        expect(oldEditor.onDropFiles == nil, "Teardown releases attachment callbacks")

        let reopened = Surface(state: state, dictation: fixture.coordinator)
        defer { reopened.close() }
        try await wait { reopened.editor != nil }
        expect(reopened.editor !== oldEditor, "Reopening creates a fresh editor")
        try await fixture.start(into: reopened.editor!)
        expect(fixture.capture.isRecording, "The reopened field can start its own recording")
        fixture.coordinator.cancel(in: reopened.editor!)
        try await wait { !fixture.capture.isRecording }
    }

    private static func testQueuedCancellation(closing: Bool) async throws {
        let fixture = Fixture()
        let state = SurfaceState()
        let first = state.chat
        let surface = Surface(state: state, dictation: fixture.coordinator)
        defer { surface.close() }
        try await wait { surface.editor != nil }
        let editor = surface.editor!
        var release: CheckedContinuation<Void, Never>?
        fixture.queue.enqueue(isAutomatic: false) {
            await withCheckedContinuation { release = $0 }
        }
        try await wait { release != nil }
        try await fixture.start(into: editor)
        fixture.coordinator.accept()
        try await wait { fixture.models.pending != nil }
        fixture.models.finish("Already transcribed")
        try await wait { !fixture.panel.isVisible }
        expect(fixture.coordinator.field?.isTranscribing == true, "Queued insertion retains its session")

        if closing {
            surface.close()
        } else {
            state.chat = Draft("New chat")
            try await wait { surface.editor?.string == "New chat" }
        }
        try await wait { fixture.coordinator.field == nil }
        release?.resume()
        await fixture.queue.drain()
        expect(first.text == "First draft", "Queued speech cannot write into its canceled draft")
        expect(state.chat.text == (closing ? "First draft" : "New chat"), "Queued speech cannot cross chats")
        expect(fixture.messages.isEmpty, "Discarding queued speech is silent")
    }

    private static func testDeliveryFailure() async throws {
        let fixture = Fixture()
        let editor = ComposerTextView()
        try await fixture.start(into: editor)
        editor.isEditable = false
        fixture.coordinator.accept()
        try await wait { fixture.models.pending != nil }
        fixture.models.finish("Spoken words")
        try await wait { !fixture.messages.isEmpty }
        expect(
            fixture.messages == ["Couldn't paste dictation into this app"],
            "A failed paste is reported once")
        expect(fixture.transcripts == ["Spoken words"], "A failed paste still saves its completed transcript")
        expect(fixture.pasteAppIDs == [nil], "History leaves the app blank when a paste fails")
        expect(Paster.copies.isEmpty, "A failed paste leaves the clipboard alone")
    }

    private static func testSoundsOff() async throws {
        let fixture = Fixture()
        fixture.settings.dictationPlaysSounds = false
        let editor = ComposerTextView()
        AudioEvents.log = []
        fixture.coordinator.toggle(into: editor)
        expect(AudioEvents.log.isEmpty, "Without sounds, recording starts quietly")
        try await wait { fixture.capture.isRecording }
        fixture.coordinator.toggle(into: editor)
        try await wait { fixture.models.pending != nil }
        fixture.models.finish("Spoken words")
        try await wait { fixture.coordinator.field == nil }
        expect(
            !AudioEvents.log.contains("start cue") && !AudioEvents.log.contains("stop cue"),
            "No cue plays unless sounds are on")
    }

    private static func testSounds() async throws {
        let fixture = Fixture()
        let editor = ComposerTextView()
        AudioEvents.log = []
        try await fixture.start(into: editor)
        try await Task.sleep(for: .milliseconds(20))
        expect(AudioEvents.log.isEmpty, "The start cue waits for the microphone's first samples")
        fixture.capture.onLevels?([])
        try await wait { AudioEvents.log.contains("start cue") }
        expect(
            AudioEvents.log == ["start cue"],
            "The start cue plays on the first samples")
        fixture.coordinator.toggle(into: editor)
        expect(
            AudioEvents.log == ["start cue", "stop cue"],
            "The stop cue plays after the start cue")
        expect(fixture.capture.isRecording, "The microphone is still open when the stop cue plays")
        try await wait { fixture.models.pending != nil }
        fixture.models.finish("Spoken words")
        try await wait { fixture.coordinator.field == nil }
        expect(editor.string == "Spoken words", "Sounds leave the transcript untouched")
    }

    private static func testCancelSilently() async throws {
        let fixture = Fixture()
        let editor = ComposerTextView()
        AudioEvents.log = []
        try await fixture.start(into: editor)
        fixture.capture.onLevels?([])
        try await wait { AudioEvents.log.contains("start cue") }
        fixture.coordinator.cancel(in: editor)
        try await wait { !fixture.capture.isRecording }
        try await Task.sleep(for: .milliseconds(50))
        expect(!AudioEvents.log.contains("stop cue"), "Cancelling plays no stop cue")
    }

    private static func testCancelDuringStartCue() async throws {
        let fixture = Fixture()
        let editor = ComposerTextView()
        AudioEvents.log = []
        try await fixture.start(into: editor)
        fixture.capture.isBluetooth = true
        fixture.capture.onLevels?([])
        fixture.coordinator.cancel(in: editor)
        try await Task.sleep(for: .milliseconds(600))
        expect(
            AudioEvents.log.isEmpty,
            "A session cancelled before its start cue plays no sound")
    }

    private static func testBluetoothStartCue() async throws {
        let fixture = Fixture()
        let editor = ComposerTextView()
        AudioEvents.log = []
        try await fixture.start(into: editor)
        fixture.capture.isBluetooth = true
        let samples = ContinuousClock.now
        fixture.capture.onLevels?([])
        try await wait { AudioEvents.log.contains("start cue") }
        expect(
            ContinuousClock.now - samples >= .milliseconds(500),
            "A Bluetooth microphone delays the start cue until its headset has switched output")
        fixture.coordinator.cancel(in: editor)
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        print("PASS  \(message)")
    }

    @MainActor
    private final class Fixture {
        let settings = AppSettings()
        let models = DictationModelStore()
        let queue = DeliveryQueue()
        var messages: [String] = []
        var transcripts: [String] = []
        var pasteAppIDs: [pid_t?] = []
        var focusedTarget: InjectionTarget?
        lazy var coordinator = DictationCoordinator(
            settings: settings, hotKeys: HotKeyManager(), models: models,
            corrections: DictationCorrectionStore(fileURL: FileManager.default.temporaryDirectory
                .appending(path: "dictation-corrections-\(UUID()).json")),
            injector: TextInjector(
                clipboardManager: ClipboardManager(), settings: settings, deliveryQueue: queue),
            focusedTarget: { [weak self] in self?.focusedTarget },
            confirmEnable: { false },
            showMessage: { [weak self] message, _ in self?.messages.append(message) },
            recordTranscript: { [weak self] text, _, app in
                self?.transcripts.append(text)
                self?.pasteAppIDs.append(app?.processIdentifier)
            })

        var capture: DictationCapture { DictationCapture.latest! }
        var panel: DictationPanelController { DictationPanelController.latest! }

        func start(into editor: ComposerTextView) async throws {
            coordinator.toggle(into: editor)
            try await wait { capture.isRecording }
            expect(coordinator.field?.editor == ObjectIdentifier(editor), "The session belongs to its editor")
        }
    }

    @MainActor
    @Observable
    fileprivate final class Draft {
        let id = UUID()
        var text: String
        init(_ text: String) { self.text = text }
    }

    @MainActor
    @Observable
    fileprivate final class SurfaceState {
        var chat = Draft("First draft")
    }

    private struct Root: View {
        let state: SurfaceState
        let dictation: DictationCoordinator

        var body: some View { Composer(chat: state.chat, dictation: dictation) }
    }

    private struct Composer: View {
        let chat: Draft
        let dictation: DictationCoordinator
        @State private var handle = ComposerTextViewHandle()
        @State private var targeted = false

        var body: some View {
            @Bindable var chat = chat
            ChatComposerTextView(
                text: $chat.text, focusKey: chat.id, maximumTextHeight: 180, handle: handle,
                isFileDragTargeted: $targeted, onDropFiles: { _ in },
                onInvalidate: { dictation.cancel(in: $0) }, onSubmit: {})
        }
    }

    @MainActor
    private final class Surface {
        private var window: NSWindow?

        init(state: SurfaceState, dictation: DictationCoordinator) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Root(state: state, dictation: dictation))
            window.contentView?.layoutSubtreeIfNeeded()
            self.window = window
        }

        var editor: ComposerTextView? { window?.contentView.flatMap(Self.findEditor) }

        func close() {
            window?.close()
            window = nil
        }

        private static func findEditor(_ view: NSView) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
    }
}

@MainActor
final class AppSettings {
    var snippetsEnabled = false
    var dictationEnabled = true
    var dictationModel = DictationModel.redux
    var dictationUsesApple = false
    var dictationMicrophone: String?
    var dictationLanguage: String?
    var dictationAdaptsCapitalization = true
    var dictationRemovesFillerWords = false
    var dictationCleanupMode: DictationCleanupMode = .off
    var dictationAutoLearnsWords = false
    var dictationPlaysSounds = true
    var dictationIndicatorStyle = DictationIndicatorStyle.compact
    var dictationLivePreview = false
    var dictationTwoLinePreview = false
    var dictationAnimateTranscript = true
    var dictationIdleIndicator = false
}

enum HotKeyAction { case dictationHold }

@MainActor
final class HotKeyManager {
    struct Binding { var supportsHold: Bool }
    func binding(for action: HotKeyAction) -> Binding? { nil }
    func conflictOwner(of binding: Binding, excluding action: HotKeyAction) -> String? { nil }
}

@MainActor
final class DictationCapture {
    func recentSamples(seconds: Int) async -> [Float] { [] }
    static weak var latest: DictationCapture?
    var onLevels: (([Float]) -> Void)?
    var onLimit: (() -> Void)?
    var isRecording = false
    var isBluetooth = false
    var stopCount = 0

    init() { Self.latest = self }
    func start(microphoneID: String?, stream: AsyncStream<[Float]>.Continuation? = nil) async throws {
        try Task.checkCancellation()
        isRecording = true
    }
    func stop() async -> [Float] {
        isRecording = false
        stopCount += 1
        return [Float](repeating: 0, count: 1_600)
    }
}

@MainActor
final class DictationModelStore {
    var pending: CheckedContinuation<String, any Error>?
    var finished = false

    func isInstalled(_ model: DictationModel) -> Bool { true }
    func beginRecording(_ model: DictationModel) {}
    func endRecording() {}
    func download(_ model: DictationModel) async throws {}
    func delete(_ model: DictationModel) async throws {}
    func stop() async {}
    func prepareForTermination() {}

    func transcribe(_ samples: [Float], model: DictationModel, language: String?) async throws -> String {
        defer { finished = true }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func finish(_ text: String) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: text)
    }
}

@MainActor
final class DictationPanelController {
    @MainActor
    final class State {
        var animatesTranscript = true
        var twoLinePreview = false
        var levels: [Float] = []
        var transcript = ""
    }
    static weak var latest: DictationPanelController?
    let state = State()
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStart: (() -> Void)?
    var isVisible = false
    init() { Self.latest = self }
    func showStarting(style: DictationIndicatorStyle) { isVisible = true }
    func showListening() {}
    func showPreview(_ text: String, twoLines: Bool, cumulative: Bool) { state.transcript = text }
    func hidePreview() {}
    func showIdle(style: DictationIndicatorStyle) { isVisible = true }
    func showTranscribing() {}
    func close() { isVisible = false }
}

@MainActor
enum AudioEvents {
    static var log: [String] = []
}

@MainActor
final class DictationCueRunner {
    enum Cue { case start, stop }

    func play(_ cue: Cue) { AudioEvents.log.append(cue == .start ? "start cue" : "stop cue") }
}

@MainActor
final class ClipboardManager {
    static let internalType = NSPasteboard.PasteboardType("com.tinycast.internal")
    func prepareForTinycastPasteboardMutation() {}
    func synchronizeAfterTinycastPasteboardMutation(changeCount: Int) {}
    func pauseCapture() {}
    func resumeCapture() {}
}

enum Permissions {
    @discardableResult
    static func ensureAccessibility() -> Bool { false }
    static func isAccessibilityTrusted() -> Bool { false }
}

@MainActor
enum Paster {
    static let tinycastEventTag: Int64 = 0x54494E59
    static var copies: [String] = []
    static func copyPlainText(_ text: String) { copies.append(text) }
    static func postCommandV(toPid pid: pid_t? = nil) {}
    static func postCommandC(toPid pid: pid_t? = nil) {}
}

enum DialogTone { case danger }
