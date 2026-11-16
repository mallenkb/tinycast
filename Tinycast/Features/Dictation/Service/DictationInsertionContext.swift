import AppKit
import Carbon.HIToolbox
@preconcurrency import ApplicationServices

@MainActor
enum DictationInsertionContext {
    private static let messagingTimeout: Float = 0.15

    @MainActor
    struct Snapshot {
        let text: String
        let range: NSRange
        let field: Field?
        let element: AXUIElement?

        var context: DictationTextFormatter.Context? {
            guard let selected = Range(range, in: text) else { return nil }
            return .init(before: text[..<selected.lowerBound], after: text[selected.upperBound...])
        }

        func correctionProbe(inserted: String) -> CorrectionProbe? {
            guard let field, text.utf16.count + inserted.utf16.count <= CorrectionProbe.maximumFieldLength,
                let selection = Range(range, in: text)
            else { return nil }
            let anchor = DictationInsertionAnchor(
                prefix: text[..<selection.lowerBound], suffix: text[selection.upperBound...],
                replaced: text[selection], inserted: inserted)
            return CorrectionProbe(anchor: anchor, field: field)
        }
    }

    @MainActor
    struct Field {
        let read: () -> String?
        let observe: (@escaping @MainActor () -> Void) -> CorrectionObservation?
    }

    @MainActor
    struct CorrectionProbe {
        static let maximumFieldLength = 8_192
        let anchor: DictationInsertionAnchor
        let field: Field

        var inserted: String { anchor.inserted }

        func restoresSelection(_ text: String) -> Bool {
            text != anchor.inserted && text == anchor.replaced
        }

        func readInsertion() -> String? {
            guard let text = field.read(), text.utf16.count <= Self.maximumFieldLength,
                let insertion = anchor.locate(in: text)
            else { return nil }
            return String(insertion)
        }

        func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> CorrectionObservation? {
            field.observe(onChange)
        }
    }

    /// Wakes the watcher on edits and focus moves, so the field is read only after something changed.
    @MainActor
    final class CorrectionObservation {
        fileprivate let onChange: @MainActor () -> Void
        private var observer: AXObserver?
        private var token: NotificationToken?

        fileprivate init(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }

        fileprivate static func editor(_ editor: NSTextView, onChange: @escaping @MainActor () -> Void) -> CorrectionObservation {
            let observation = CorrectionObservation(onChange: onChange)
            let center = NotificationCenter.default
            observation.token = NotificationToken(
                center.addObserver(forName: NSText.didChangeNotification, object: editor, queue: .main) { _ in
                    MainActor.assumeIsolated { onChange() }
                }, center: center)
            return observation
        }

        fileprivate static func element(
            _ element: AXUIElement, in app: NSRunningApplication, onChange: @escaping @MainActor () -> Void
        ) -> CorrectionObservation? {
            var created: AXObserver?
            guard AXObserverCreate(app.processIdentifier, axCallback, &created) == .success, let created
            else { return nil }
            let observation = CorrectionObservation(onChange: onChange)
            let refcon = Unmanaged.passUnretained(observation).toOpaque()
            guard AXObserverAddNotification(created, element, kAXValueChangedNotification as CFString, refcon)
                == .success
            else { return nil }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXObserverAddNotification(
                created, application, kAXFocusedUIElementChangedNotification as CFString, refcon)
            AXObserverAddNotification(created, element, kAXUIElementDestroyedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            observation.observer = created
            return observation
        }

        func invalidate() {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            observer = nil
            token = nil
        }

        isolated deinit {
            invalidate()
        }
    }

    static func read(in target: InjectionTarget?, learnsCorrections: Bool) -> Snapshot? {
        if let editor = target?.ownEditor {
            let field: Field? = if learnsCorrections, editor.isEditable, !editor.hasMarkedText() {
                Field(
                    read: { [weak editor] in
                        guard let editor, editor.isEditable, !editor.hasMarkedText(),
                            let window = editor.window, window.isKeyWindow, window.firstResponder === editor
                        else { return nil }
                        return editor.string
                    },
                    observe: { [weak editor] onChange in
                        editor.map { CorrectionObservation.editor($0, onChange: onChange) }
                    })
            } else { nil }
            return Snapshot(text: editor.string, range: editor.selectedRange(), field: field, element: nil)
        }
        guard let app = target?.externalApp, canObserve(app),
            let element = AccessibilityText.focusedElement(in: app, timeout: messagingTimeout)
        else { return nil }
        let selectionAttributes = [kAXValueAttribute, kAXSelectedTextRangeAttribute]
        let attributes = learnsCorrections
            ? selectionAttributes + [kAXRoleAttribute, kAXSubroleAttribute] : selectionAttributes
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &rawValues) == .success,
            let values = rawValues as? [Any], values.count == attributes.count,
            let text = values[0] as? String, let range = selection(values[1] as CFTypeRef)
        else { return nil }
        let field: Field? = if learnsCorrections, let role = values[2] as? String,
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
            (values[3] as? String) != kAXSecureTextFieldSubrole {
            Field(
                read: {
                    guard canObserve(app),
                        let focused = AccessibilityText.focusedElement(in: app, timeout: messagingTimeout),
                        CFEqual(element, focused)
                    else { return nil }
                    return value(in: element)
                },
                observe: { onChange in CorrectionObservation.element(element, in: app, onChange: onChange) })
        } else { nil }
        return Snapshot(text: text, range: range, field: field, element: element)
    }

    private static func canObserve(_ app: NSRunningApplication) -> Bool {
        app.isActive && !IsSecureEventInputEnabled() && Permissions.isAccessibilityTrusted()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func value(in element: AXUIElement) -> String? {
        var length: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &length) == .success,
            let count = length as? Int, count > CorrectionProbe.maximumFieldLength
        { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &result) == .success
        else { return nil }
        return result as? String
    }

    private static func selection(_ selected: CFTypeRef) -> NSRange? {
        guard CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(selected, to: AXValue.self), .cfRange, &range)
        else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

private func axCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observation = Unmanaged<DictationInsertionContext.CorrectionObservation>.fromOpaque(refcon)
        .takeUnretainedValue()
    MainActor.assumeIsolated { observation.onChange() }
}
