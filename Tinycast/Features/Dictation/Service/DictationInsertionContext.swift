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
        let readField: (() -> String?)?

        var context: DictationTextFormatter.Context? {
            guard let selected = Range(range, in: text) else { return nil }
            return .init(before: text[..<selected.lowerBound], after: text[selected.upperBound...])
        }

        func correctionProbe(inserted: String) -> CorrectionProbe? {
            guard let readField else { return nil }
            return CorrectionProbe(text: text, range: range, inserted: inserted, readField: readField)
        }
    }

    @MainActor
    struct CorrectionProbe {
        private static let maximumFieldLength = 8_192
        let inserted: String
        private let prefix: Substring
        private let suffix: Substring
        private let replaced: Substring
        private let readField: () -> String?

        fileprivate init?(text: String, range: NSRange, inserted: String, readField: @escaping () -> String?) {
            guard text.utf16.count + inserted.utf16.count <= Self.maximumFieldLength,
                let selection = Range(range, in: text)
            else { return nil }
            self.inserted = inserted
            prefix = text[..<selection.lowerBound]
            suffix = text[selection.upperBound...]
            replaced = text[selection]
            self.readField = readField
        }

        func restoresSelection(_ text: String) -> Bool {
            text != inserted && text == replaced
        }

        func readInsertion() -> String? {
            guard let text = readField(), text.utf16.count <= Self.maximumFieldLength,
                text.hasPrefix(prefix), text.hasSuffix(suffix),
                text.count >= prefix.count + suffix.count
            else { return nil }
            return String(text.dropFirst(prefix.count).dropLast(suffix.count))
        }
    }

    static func read(in target: InjectionTarget?, learnsCorrections: Bool) -> Snapshot? {
        if let editor = target?.ownEditor {
            let readField: (() -> String?)? = if learnsCorrections, editor.isEditable, !editor.hasMarkedText() {
                { [weak editor] in
                    guard let editor, editor.isEditable, !editor.hasMarkedText(),
                        let window = editor.window, window.isKeyWindow, window.firstResponder === editor
                    else { return nil }
                    return editor.string
                }
            } else { nil }
            return Snapshot(text: editor.string, range: editor.selectedRange(), readField: readField)
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
        let readField: (() -> String?)? = if learnsCorrections, let role = values[2] as? String,
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
            (values[3] as? String) != kAXSecureTextFieldSubrole {
            {
                guard canObserve(app),
                    let focused = AccessibilityText.focusedElement(in: app, timeout: messagingTimeout),
                    CFEqual(element, focused)
                else { return nil }
                return value(in: element)
            }
        } else { nil }
        return Snapshot(text: text, range: range, readField: readField)
    }

    private static func canObserve(_ app: NSRunningApplication) -> Bool {
        app.isActive && !IsSecureEventInputEnabled() && Permissions.isAccessibilityTrusted()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func value(in element: AXUIElement) -> String? {
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
