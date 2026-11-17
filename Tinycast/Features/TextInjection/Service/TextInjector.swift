import AppKit
import Carbon.HIToolbox

/// Its own shape, not a caller's result type, so the injector stays owned by no one feature.
struct InjectedText: Equatable, Sendable {
    let text: String
    /// Leaves the caret this many characters back from the end; nil leaves it after the text.
    let cursorOffsetFromEnd: Int?

    init(_ text: String, cursorOffsetFromEnd: Int? = nil) {
        self.text = text
        self.cursorOffsetFromEnd = cursorOffsetFromEnd
    }

    /// UTF-16 distance from the start of the inserted text to where the caret should land.
    var caretPrefixLength: Int {
        let offset = min(max(cursorOffsetFromEnd ?? 0, 0), text.count)
        return text[..<text.index(text.endIndex, offsetBy: -offset)].utf16.count
    }
}

enum DeliveryFailure: Equatable, Sendable {
    case notDelivered
    /// No focused element takes text, so the caller should offer the text another way.
    case noTextTarget
}

@MainActor
final class DeliveryCompletion {
    private let onDelivered: @MainActor () -> Void
    private let onFailed: @MainActor (DeliveryFailure) -> Void
    private(set) var isConfirmed = false
    private var isSettled = false

    init(
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (DeliveryFailure) -> Void = { _ in }
    ) {
        self.onDelivered = onDelivered
        self.onFailed = onFailed
    }

    func confirm() {
        guard !isSettled else { return }
        isSettled = true
        isConfirmed = true
        onDelivered()
    }

    /// Driven from a `defer`, so a delivery that returned early still says so instead of vanishing.
    func settle(_ failure: DeliveryFailure = .notDelivered) {
        guard !isSettled else { return }
        isSettled = true
        onFailed(failure)
    }
}

@MainActor
final class TextInjector {
    typealias AutomaticGeneration = UInt

    private let clipboardManager: ClipboardManager
    private let settings: AppSettings
    private let deliveryQueue: DeliveryQueue
    private var automaticGeneration: AutomaticGeneration = 0
    private var activePasteboardLease: TemporaryPasteboardLease?

    init(
        clipboardManager: ClipboardManager, settings: AppSettings,
        deliveryQueue: DeliveryQueue = DeliveryQueue()
    ) {
        self.clipboardManager = clipboardManager
        self.settings = settings
        self.deliveryQueue = deliveryQueue
    }

    /// A paste is still in flight, or we still hold the pasteboard it borrowed.
    var isDelivering: Bool { !deliveryQueue.isIdle || activePasteboardLease != nil }

    func drain() async { await deliveryQueue.drain() }

    func prepareInteractiveExpansion(target: InjectionTarget?, restoreFocusOnFailure: Bool = true) -> Bool {
        if let editor = target?.ownEditor { return editor.isEditable }
        guard targetAcceptsInjection(target?.externalApp), Permissions.ensureAccessibility() else {
            if restoreFocusOnFailure { target?.restoreFocus() }
            return false
        }
        return true
    }

    func beginAutomaticExpansion(target: InjectionTarget?) -> AutomaticGeneration? {
        cancelAutomaticExpansion()
        guard expansionIsAllowed(generation: automaticGeneration, target: target) else { return nil }
        return automaticGeneration
    }

    func cancelAutomaticExpansion(target: InjectionTarget? = nil) {
        automaticGeneration &+= 1
        deliveryQueue.cancelAutomatic()
        target?.restoreFocus()
    }

    func prepareForTermination() {
        automaticGeneration &+= 1
        deliveryQueue.cancelAll()
        finishPendingPasteboardOwnership()
    }

    func cancelArgumentPrompt(
        automaticGeneration: AutomaticGeneration?,
        target: InjectionTarget?
    ) {
        if automaticGeneration != nil {
            cancelAutomaticExpansion(target: target)
        } else {
            target?.restoreFocus()
        }
    }

    /// A hotkey's target comes from `frontmostApplication`, which can be Tinycast itself.
    private func targetAcceptsInjection(_ targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp,
            !targetApp.isTerminated,
            targetApp.bundleIdentifier != Bundle.main.bundleIdentifier,
            !IsSecureEventInputEnabled()
        else { return false }
        return true
    }

    private func automaticExpansionIsAllowed(
        generation: AutomaticGeneration,
        targetApp: NSRunningApplication?
    ) -> Bool {
        guard generation == automaticGeneration,
            settings.snippetsEnabled,
            Permissions.isAccessibilityTrusted(),
            targetAcceptsInjection(targetApp)
        else { return false }
        return true
    }

    /// In process there is nothing to grant, activate or post: our own view is the whole contract.
    private func expansionIsAllowed(
        generation: AutomaticGeneration,
        target: InjectionTarget?
    ) -> Bool {
        switch target {
        case .ownEditor(let editor):
            return generation == automaticGeneration && settings.snippetsEnabled && editor.isEditable
        case .external(let app):
            return automaticExpansionIsAllowed(generation: generation, targetApp: app)
        case nil:
            return false
        }
    }

    func captureExpansionContext(
        target: InjectionTarget?,
        clipboardHistory: [String]
    ) -> SnippetTemplateEngine.ExpansionContext {
        SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: clipboardHistory,
            selection: selection(in: target),
            now: Date(),
            calendar: Calendar.current,
            locale: Locale.current,
            timeZone: .current)
    }

    /// The caller must know there *is* a selection: a zero-length one inserts at the caret instead.
    func replaceSelection(
        with text: String,
        in targetApp: NSRunningApplication?,
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (DeliveryFailure) -> Void = { _ in }
    ) {
        deliver(
            InjectedText(text), target: targetApp.map(InjectionTarget.external),
            expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil, onDelivered: onDelivered, onFailed: onFailed)
    }

    /// A `changeCount` that never moves means nothing was selected, not that the old clipboard won.
    func copySelection(from targetApp: NSRunningApplication?) async -> String? {
        await deliveryQueue.drain()
        guard finishPendingPasteboardOwnership(),
            await activateAndWaitForTarget(targetApp, automaticGeneration: nil),
            deliveryIsAllowed(
                automaticGeneration: nil, targetApp: targetApp,
                promptForInteractiveAccessibility: true)
        else { return nil }
        return await copySelection(from: targetApp, pasteboard: NSPasteboard.general)
    }

    /// Split for the harness, which drives a stub pasteboard rather than another app.
    func copySelection(
        from targetApp: NSRunningApplication?, pasteboard: any PasteboardAccess
    ) async -> String? {
        // A second borrow would snapshot the first's copy and read its restore as a selection.
        guard !isBorrowingCopy, let original = PasteboardSnapshot(pasteboard: pasteboard) else {
            return nil
        }
        isBorrowingCopy = true
        clipboardManager.pauseCapture()
        defer {
            restore(original, to: pasteboard)
            clipboardManager.resumeCapture()
            isBorrowingCopy = false
        }

        Paster.postCommandC(toPid: targetApp?.processIdentifier)
        for _ in 0..<Self.copyPollAttempts {
            guard await wait(for: Self.copyPollInterval) else { return nil }
            guard pasteboard.changeCount != original.changeCount else { continue }
            guard let copied = PasteboardSnapshot(pasteboard: pasteboard),
                let data = copied.firstStringData
            else { return nil }
            return String(bytes: data, encoding: .utf8)
        }
        return nil
    }

    private func restore(_ snapshot: PasteboardSnapshot, to pasteboard: any PasteboardAccess) {
        guard let items = snapshot.pasteboardItems() else { return }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return }
        clipboardManager.synchronizeAfterTinycastPasteboardMutation(
            changeCount: pasteboard.changeCount)
    }

    private var isBorrowingCopy = false

    /// A copy lands well inside a second; past that the app was never going to answer.
    private static let copyPollAttempts = 40
    private static let copyPollInterval = Duration.milliseconds(25)

    func deliver(
        _ injected: InjectedText,
        target: InjectionTarget?,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?,
        activateTarget: Bool = true,
        isValid: @escaping @MainActor () -> Bool = { true },
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (DeliveryFailure) -> Void = { _ in }
    ) {
        let targetApp = target?.externalApp
        if activateTarget { activate(targetApp) }
        if let automaticGeneration {
            guard expansionIsAllowed(generation: automaticGeneration, target: target) else { return }
        } else {
            guard prepareInteractiveExpansion(target: target, restoreFocusOnFailure: activateTarget) else {
                onFailed(.notDelivered)
                return
            }
        }

        deliveryQueue.enqueue(isAutomatic: automaticGeneration != nil) { [weak self] in
            guard let self else { return }
            let completion = DeliveryCompletion(onDelivered: onDelivered, onFailed: onFailed)
            guard isValid() else { completion.settle(); return }
            if let editor = target?.ownEditor {
                await self.deliverInProcess(
                    injected,
                    into: editor,
                    expectedKeyword: expectedKeyword,
                    keywordLength: keywordLength,
                    automaticGeneration: automaticGeneration,
                    isValid: isValid,
                    completion: completion)
                return
            }
            await self.performDelivery(
                injected,
                targetApp: targetApp,
                expectedKeyword: expectedKeyword,
                keywordLength: keywordLength,
                automaticGeneration: automaticGeneration,
                activateTarget: activateTarget,
                completion: completion)
        }
    }

    /// Needs no grant, activation or pasteboard, but the keyword still converges on Rule 2.
    private func deliverInProcess(
        _ injected: InjectedText,
        into editor: any InjectableTextView,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?,
        isValid: @MainActor () -> Bool,
        completion: DeliveryCompletion
    ) async {
        defer { completion.settle() }
        for _ in 0..<Self.convergenceAttempts {
            // The tap runs ahead of AppKit, so looking before the wait reads a stale view as a miss.
            if keywordLength > 0 {
                guard await wait(for: Self.convergenceInterval) else { return }
            }
            guard isValid(),
                inProcessDeliveryIsAllowed(automaticGeneration: automaticGeneration, editor: editor)
            else { return }
            switch editor.keywordReplacementState(
                expectedKeyword: expectedKeyword, keywordLength: keywordLength)
            {
            case .matched(let range):
                editor.inject(injected, over: range)
                completion.confirm()
                return
            case .rejected:
                return
            case .pending:
                continue
            }
        }
    }

    private func inProcessDeliveryIsAllowed(
        automaticGeneration: AutomaticGeneration?,
        editor: any InjectableTextView
    ) -> Bool {
        guard let automaticGeneration else { return editor.isEditable }
        return expansionIsAllowed(generation: automaticGeneration, target: .ownEditor(editor))
    }

    private func performDelivery(
        _ injected: InjectedText,
        targetApp: NSRunningApplication?,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?,
        activateTarget: Bool,
        completion: DeliveryCompletion
    ) async {
        defer { completion.settle() }
        guard finishPendingPasteboardOwnership() else { return }
        if activateTarget {
            guard await activateAndWaitForTarget(targetApp, automaticGeneration: automaticGeneration)
            else { return }
        }
        guard deliveryIsAllowed(
            automaticGeneration: automaticGeneration,
            targetApp: targetApp,
            promptForInteractiveAccessibility: true)
        else { return }

        let accessibilityReplacement = await replaceUsingAccessibility(
            injected,
            targetApp: targetApp,
            expectedKeyword: expectedKeyword,
            keywordLength: keywordLength,
            automaticGeneration: automaticGeneration)
        switch accessibilityReplacement {
        case .delivered:
            completion.confirm()
            return
        case .noTextTarget:
            completion.settle(.noTextTarget)
            return
        case .unavailable, .renderer, .rejected:
            guard accessibilityReplacement.fallsBackToEvents else { return }
        }

        guard
            await deliverUsingEvents(
                injected.text,
                keywordLength: keywordLength,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration,
                targetAlreadyActive: !activateTarget,
                canReadPasteState: accessibilityReplacement != .renderer)
        else { return }

        guard let offset = injected.cursorOffsetFromEnd, offset > 0 else {
            completion.confirm()
            return
        }
        for index in 0..<offset {
            guard
                deliveryIsAllowed(
                    automaticGeneration: automaticGeneration,
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false),
                KeyEventSynthesizer.postKey(code: CGKeyCode(kVK_LeftArrow), targetApp: targetApp)
            else { return }
            if index < offset - 1,
                !(await wait(for: .milliseconds(8)))
            {
                return
            }
        }
        completion.confirm()
    }

    private func deliverUsingEvents(
        _ text: String,
        keywordLength: Int,
        targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?,
        targetAlreadyActive: Bool,
        canReadPasteState: Bool
    ) async -> Bool {
        let isShortSingleLine =
            text.count <= 100
            && !text.contains("\n")
            && !text.contains("\r")
        if isShortSingleLine {
            return await deliverUsingUnicodeEvents(
                text,
                keywordLength: keywordLength,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration)
        }

        guard let lease = beginTemporaryPasteboardLease(text) else {
            return await deliverUsingUnicodeEvents(
                text,
                keywordLength: keywordLength,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration)
        }
        activePasteboardLease = lease
        defer { finish(lease) }

        guard let deletionEvents = KeyEventSynthesizer.deletionEvents(count: keywordLength),
            await wait(for: .milliseconds(targetAlreadyActive ? 50 : 80)),
            lease.isOwned,
            deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: targetApp,
                promptForInteractiveAccessibility: false),
            await postEventGroups(
                deletionEvents,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration),
            await waitAfterKeywordDeletion(keywordLength),
            lease.isOwned,
            deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: targetApp,
                promptForInteractiveAccessibility: false)
        else { return false }

        let stateBeforePaste = canReadPasteState ? AccessibilityTextReplacer.textState(in: targetApp) : nil
        Paster.postCommandV(toPid: targetApp?.processIdentifier)
        return await waitForPasteConfirmation(
            previousState: stateBeforePaste,
            pasteboardLease: lease,
            targetApp: targetApp,
            automaticGeneration: automaticGeneration)
    }

    private func deliverUsingUnicodeEvents(
        _ text: String,
        keywordLength: Int,
        targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        guard let insertionEvents = KeyEventSynthesizer.unicodeEvents(text),
            let deletionEvents = KeyEventSynthesizer.deletionEvents(count: keywordLength),
            deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: targetApp,
                promptForInteractiveAccessibility: false),
            await postEventGroups(
                deletionEvents,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration),
            await waitAfterKeywordDeletion(keywordLength),
            await postEventGroups(
                insertionEvents,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration)
        else { return false }

        return await wait(for: .milliseconds(100))
    }

    /// Each group is one keystroke, spaced so a target that stops accepting them halts the rest.
    private func postEventGroups(
        _ events: [[CGEvent]],
        targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        for index in events.indices {
            guard
                deliveryIsAllowed(
                    automaticGeneration: automaticGeneration,
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false)
            else { return false }
            KeyEventSynthesizer.post(events[index], targetApp: targetApp)
            if index < events.count - 1,
                !(await wait(for: .milliseconds(8)))
            {
                return false
            }
        }
        return true
    }

    private func waitAfterKeywordDeletion(_ keywordLength: Int) async -> Bool {
        if keywordLength == 0 { return true }
        return await wait(for: .milliseconds(40))
    }

    private func beginTemporaryPasteboardLease(_ text: String) -> TemporaryPasteboardLease? {
        clipboardManager.prepareForTinycastPasteboardMutation()
        return TemporaryPasteboardLease.begin(
            text: text,
            pasteboard: NSPasteboard.general
        ) { [clipboardManager] changeCount in
            clipboardManager.synchronizeAfterTinycastPasteboardMutation(
                changeCount: changeCount)
        }
    }

    @discardableResult
    private func finishPendingPasteboardOwnership() -> Bool {
        guard let lease = activePasteboardLease else { return true }
        for _ in 0..<3 where lease.isOwned { finish(lease) }
        return !lease.isOwned
    }

    private func finish(_ lease: TemporaryPasteboardLease) {
        switch lease.restoreIfOwned() {
        case .restored(let changeCount):
            // Keeps the poller from recording the restored original as a second copy.
            clipboardManager.synchronizeAfterTinycastPasteboardMutation(changeCount: changeCount)
        case .superseded:
            break
        case .failed:
            // Still ours, so leave `activePasteboardLease` in place for the retry below.
            if lease.isOwned { return }
        }
        if activePasteboardLease === lease { activePasteboardLease = nil }
    }

    private func deliveryIsAllowed(
        automaticGeneration: AutomaticGeneration?,
        targetApp: NSRunningApplication?,
        promptForInteractiveAccessibility: Bool
    ) -> Bool {
        if let automaticGeneration {
            guard
                automaticExpansionIsAllowed(
                    generation: automaticGeneration,
                    targetApp: targetApp),
                let targetApp,
                targetApp.isActive,
                NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == targetApp.processIdentifier
            else { return false }
            return true
        }
        // Re-checked before every post, so a target that went away or went secure stops delivery.
        guard targetAcceptsInjection(targetApp), let targetApp,
            targetApp.isActive,
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == targetApp.processIdentifier
        else { return false }
        return promptForInteractiveAccessibility
            ? Permissions.ensureAccessibility()
            : Permissions.isAccessibilityTrusted()
    }

    private func activateAndWaitForTarget(
        _ targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        guard let targetApp else {
            return deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: nil,
                promptForInteractiveAccessibility: false)
        }
        activate(targetApp)
        for _ in 0..<50 {
            if targetApp.isActive,
                NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == targetApp.processIdentifier
            {
                return true
            }
            if let automaticGeneration,
                !automaticExpansionIsAllowed(
                    generation: automaticGeneration,
                    targetApp: targetApp)
            {
                return false
            }
            guard await wait(for: .milliseconds(20)) else { return false }
        }
        return false
    }

    private func replaceUsingAccessibility(
        _ injected: InjectedText,
        targetApp: NSRunningApplication?,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?
    ) async -> AccessibilityReplacement {
        guard let targetApp else { return .unavailable }
        return await AccessibilityTextReplacer.replace(
            injected,
            in: targetApp,
            expectedKeyword: expectedKeyword,
            keywordLength: keywordLength,
            attempts: Self.convergenceAttempts
        ) { [weak self] in
            guard let self, automaticGeneration != nil,
                self.deliveryIsAllowed(
                    automaticGeneration: automaticGeneration,
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false)
            else { return false }
            return await self.wait(for: Self.convergenceInterval)
        }
    }

    /// A renderer, or AppKit handing us our own keystroke, converges in single-digit milliseconds.
    private static let convergenceAttempts = 8
    private static let convergenceInterval = Duration.milliseconds(5)

    private func waitForPasteConfirmation(
        previousState: AccessibilityTextReplacer.TextState?,
        pasteboardLease: TemporaryPasteboardLease,
        targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        var readStateAfterPaste = false
        for attempt in 0..<80 {
            guard pasteboardLease.isOwned,
                deliveryIsAllowed(
                    automaticGeneration: automaticGeneration,
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false)
            else { return false }

            if let previousState,
                let currentState = AccessibilityTextReplacer.textState(in: targetApp)
            {
                readStateAfterPaste = true
                if currentState != previousState { return true }
            }
            if PasteConfirmationPolicy.acceptsUnconfirmedDelivery(
                attempt: attempt,
                hadPreviousState: previousState != nil,
                readStateAfterPaste: readStateAfterPaste)
            {
                return true
            }
            guard await wait(for: .milliseconds(25)) else { return false }
        }
        return false
    }

    private func activate(_ targetApp: NSRunningApplication?) {
        guard targetApp?.isTerminated == false else { return }
        targetApp?.activate()
    }

    private func selection(in target: InjectionTarget?) -> String {
        switch target {
        case .ownEditor(let editor): return editor.injectableSelection
        case .external(let app): return selectedText(in: app) ?? ""
        case nil: return ""
        }
    }

    private func selectedText(in targetApp: NSRunningApplication?) -> String? {
        guard Permissions.isAccessibilityTrusted(), let targetApp else { return nil }
        return AccessibilityText.selection(in: targetApp)
    }

    private func wait(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

enum PasteConfirmationPolicy {
    static func acceptsUnconfirmedDelivery(
        attempt: Int,
        hadPreviousState: Bool,
        readStateAfterPaste: Bool
    ) -> Bool {
        attempt >= 15 && (!hadPreviousState || !readStateAfterPaste)
    }
}
