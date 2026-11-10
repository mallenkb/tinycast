import AppKit
import Carbon.HIToolbox
@preconcurrency import ApplicationServices

@MainActor
enum DictationInsertionContext {
    @MainActor
    struct CorrectionProbe {
        private static let maximumFieldLength = 8_192
        let inserted: String
        private let prefix: Substring
        private let suffix: Substring
        private let readField: () -> String?

        fileprivate init?(text: String, range: NSRange, inserted: String, readField: @escaping () -> String?) {
            guard text.utf16.count + inserted.utf16.count <= Self.maximumFieldLength,
                let selection = Range(range, in: text)
            else { return nil }
            self.inserted = inserted
            prefix = text[..<selection.lowerBound]
            suffix = text[selection.upperBound...]
            self.readField = readField
        }

        func readInsertion() -> String? {
            guard let text = readField(), text.utf16.count <= Self.maximumFieldLength,
                text.hasPrefix(prefix), text.hasSuffix(suffix),
                text.count >= prefix.count + suffix.count
            else { return nil }
            return String(text.dropFirst(prefix.count).dropLast(suffix.count))
        }
    }

    static func read(in target: InjectionTarget?) -> DictationTextFormatter.Context? {
        if let editor = target?.ownEditor {
            return context(editor.string, range: editor.selectedRange())
        }
        guard let app = target?.externalApp else { return nil }
        guard let element = AccessibilityText.focusedElement(in: app),
            let text = value(in: element), let range = selection(in: element)
        else { return nil }
        return context(text, range: range)
    }

    static func correctionProbe(in target: InjectionTarget?, inserted: String) -> CorrectionProbe? {
        if let editor = target?.ownEditor {
            guard editor.isEditable, !editor.hasMarkedText() else { return nil }
            return CorrectionProbe(
                text: editor.string, range: editor.selectedRange(), inserted: inserted
            ) { [weak editor] in
                guard let editor, editor.isEditable, !editor.hasMarkedText(),
                    let window = editor.window, window.isKeyWindow, window.firstResponder === editor
                else { return nil }
                return editor.string
            }
        }
        guard let app = target?.externalApp, canObserve(app),
            let element = AccessibilityText.focusedElement(in: app),
            isReadableEditor(element),
            let text = value(in: element), let range = selection(in: element)
        else { return nil }
        return CorrectionProbe(text: text, range: range, inserted: inserted) {
            guard canObserve(app), let focused = AccessibilityText.focusedElement(in: app),
                CFEqual(element, focused)
            else { return nil }
            return value(in: element)
        }
    }

    private static func canObserve(_ app: NSRunningApplication) -> Bool {
        app.isActive && !IsSecureEventInputEnabled() && Permissions.isAccessibilityTrusted()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func isReadableEditor(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
            let role = role as? String,
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        else { return false }
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) != kAXSecureTextFieldSubrole
    }

    private static func value(in element: AXUIElement) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &result) == .success
        else { return nil }
        return result as? String
    }

    private static func selection(in element: AXUIElement) -> NSRange? {
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
            let selected, CFGetTypeID(selected) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(selected, to: AXValue.self), .cfRange, &range)
        else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func context(_ text: String, range: NSRange) -> DictationTextFormatter.Context? {
        guard let selected = Range(range, in: text) else { return nil }
        return .init(
            before: text[..<selected.lowerBound],
            after: text[selected.upperBound...])
    }
}
