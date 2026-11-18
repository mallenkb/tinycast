import AppKit
import Carbon.HIToolbox

enum AccessibilityReplacement: Equatable {
    case delivered
    case unavailable
    case renderer
    case rejected
    /// Nothing focused holds a caret, so typed keys would land on shortcuts or type-select.
    case noTextTarget

    /// `.rejected` means the document is not the one we measured, so events would edit the wrong text.
    var fallsBackToEvents: Bool { self == .unavailable || self == .renderer }
}

/// The two judgements a replacement makes, kept pure so the harness can drive both tiers.
enum TextReplacementPolicy {
    enum KeywordState: Equatable {
        case matched(NSRange)
        case pending
        case rejected
    }

    /// Too little text yet is a renderer still catching up; enough text but wrong is a real mismatch.
    static func keywordState(
        value: String, selectedRange: NSRange, keyword: String
    ) -> KeywordState {
        guard selectedRange.length == 0,
            let selectedStringRange = Range(selectedRange, in: value)
        else { return .rejected }
        let beforeCursor = value[..<selectedStringRange.lowerBound]
        guard beforeCursor.count >= keyword.count else { return .pending }
        let start = beforeCursor.index(beforeCursor.endIndex, offsetBy: -keyword.count)
        guard beforeCursor[start...].lowercased() == keyword.lowercased() else { return .rejected }
        return .matched(NSRange(start..<beforeCursor.endIndex, in: value))
    }

    /// Chromium and Electron often show no caret over AX, so only a known non-text focus refuses.
    static func refusesInsertion(focusedRole: String?) -> Bool {
        guard let focusedRole else { return false }
        return nonTextRoles.contains(focusedRole)
    }

    private static let nonTextRoles: Set<String> = [
        "AXBrowser", "AXButton", "AXCell", "AXCheckBox", "AXDisclosureTriangle", "AXImage", "AXList",
        "AXMenuButton", "AXOutline", "AXPopUpButton", "AXRadioButton", "AXRow", "AXSlider", "AXTable",
    ]

    /// Chromium answers `.success` and applies nothing, so the value has to read back as we wrote it.
    static func confirmsReplacement(
        originalValue: String,
        replacementRange: NSRange,
        insertedText: String,
        observedValue: String?
    ) -> Bool {
        guard let observedValue,
            let stringRange = Range(replacementRange, in: originalValue)
        else { return false }
        var expected = originalValue
        expected.replaceSubrange(stringRange, with: insertedText)
        return observedValue == expected
    }
}

/// Writes through the focused element's AX text attributes and reads the state a paste changes.
@MainActor
enum AccessibilityTextReplacer {
    struct TextState: Equatable {
        let value: String
        let selectedRange: NSRange
    }

    private struct Target {
        let element: AXUIElement
        let value: String
        let originalRange: NSRange
        let replacementRange: NSRange
    }

    private enum TargetState {
        case ready(Target)
        case pending
        case unavailable
        case renderer
        case rejected
        case noTextTarget
    }

    /// Rule 1: a renderer surface answers about its own model, so it is never written to over AX.
    static func replace(
        _ injected: InjectedText,
        in targetApp: NSRunningApplication,
        expectedKeyword: String?,
        keywordLength: Int,
        attempts: Int,
        waitForConvergence: @MainActor () async -> Bool
    ) async -> AccessibilityReplacement {
        let state = await target(
            in: targetApp,
            expectedKeyword: expectedKeyword,
            keywordLength: keywordLength,
            attempts: attempts,
            waitForConvergence: waitForConvergence)
        let target: Target
        switch state {
        case .ready(let ready): target = ready
        case .rejected: return .rejected
        case .renderer: return .renderer
        case .noTextTarget: return .noTextTarget
        case .pending, .unavailable: return .unavailable
        }

        guard setSelectedRange(target.replacementRange, in: target.element) else {
            return .unavailable
        }
        guard
            AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextAttribute as CFString,
                injected.text as CFString) == .success
        else {
            _ = setSelectedRange(target.originalRange, in: target.element)
            return .unavailable
        }

        let observed = stringValue(in: target.element)
        guard
            TextReplacementPolicy.confirmsReplacement(
                originalValue: target.value,
                replacementRange: target.replacementRange,
                insertedText: injected.text,
                observedValue: observed)
        else {
            _ = setSelectedRange(target.originalRange, in: target.element)
            // An untouched value is a tier that did nothing; anything else moved text we cannot name.
            return observed == target.value ? .unavailable : .rejected
        }

        _ = setSelectedRange(
            NSRange(
                location: target.replacementRange.location + injected.caretPrefixLength, length: 0),
            in: target.element)
        return .delivered
    }

    /// Rule 2: a renderer applies the keystroke before it says so, so a short lag is not a mismatch.
    private static func target(
        in targetApp: NSRunningApplication,
        expectedKeyword: String?,
        keywordLength: Int,
        attempts: Int,
        waitForConvergence: @MainActor () async -> Bool
    ) async -> TargetState {
        for attempt in 0..<attempts {
            let state = inspect(
                in: targetApp,
                expectedKeyword: expectedKeyword,
                keywordLength: keywordLength)
            guard case .pending = state else { return state }
            guard attempt < attempts - 1, await waitForConvergence() else { return .unavailable }
        }
        return .unavailable
    }

    static func restoreInsertion(
        in app: NSRunningApplication, element: AXUIElement, expected: String,
        insertedRange: NSRange, replaced: String
    ) -> Bool {
        guard !app.isTerminated, Permissions.isAccessibilityTrusted(), !IsSecureEventInputEnabled(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
            case .ready(let target) = inspect(in: app, expectedKeyword: nil, keywordLength: 0),
            CFEqual(target.element, element), target.value.utf16.elementsEqual(expected.utf16),
            target.originalRange == NSRange(location: NSMaxRange(insertedRange), length: 0),
            Range(insertedRange, in: expected) != nil,
            setSelectedRange(insertedRange, in: target.element)
        else { return false }

        guard selectedRange(in: target.element) == insertedRange,
            stringValue(in: target.element)?.utf16.elementsEqual(expected.utf16) == true,
            AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, replaced as CFString)
                == .success,
            TextReplacementPolicy.confirmsReplacement(
                originalValue: expected, replacementRange: insertedRange, insertedText: replaced,
                observedValue: stringValue(in: target.element))
        else {
            if stringValue(in: target.element)?.utf16.elementsEqual(expected.utf16) == true {
                _ = setSelectedRange(target.originalRange, in: target.element)
            }
            return false
        }
        _ = setSelectedRange(
            NSRange(location: insertedRange.location, length: replaced.utf16.count), in: target.element)
        return true
    }

    private static func inspect(
        in targetApp: NSRunningApplication,
        expectedKeyword: String?,
        keywordLength: Int
    ) -> TargetState {
        guard let element = AccessibilityText.focusedElement(in: targetApp) else { return .unavailable }
        if usesTextMarkerSelection(element) { return .renderer }
        guard let originalRange = selectedRange(in: element) else {
            // A typed keyword proves a caret even where AX cannot see one, so only insertion is refused.
            let role = AccessibilityText.attribute(element, kAXRoleAttribute) as? String
            return keywordLength == 0 && TextReplacementPolicy.refusesInsertion(focusedRole: role)
                ? .noTextTarget : .unavailable
        }
        guard isAttributeSettable(kAXSelectedTextRangeAttribute, in: element),
            isAttributeSettable(kAXSelectedTextAttribute, in: element),
            let value = stringValue(in: element)
        else { return .unavailable }

        guard keywordLength > 0 else {
            // Offsets its own value cannot address are a broken tier, not proof the document moved.
            guard Range(originalRange, in: value) != nil else { return .unavailable }
            return .ready(
                Target(
                    element: element, value: value, originalRange: originalRange,
                    replacementRange: originalRange))
        }
        guard let expectedKeyword, expectedKeyword.count == keywordLength else { return .rejected }
        switch TextReplacementPolicy.keywordState(
            value: value, selectedRange: originalRange, keyword: expectedKeyword)
        {
        case .matched(let replacementRange):
            return .ready(
                Target(
                    element: element, value: value, originalRange: originalRange,
                    replacementRange: replacementRange))
        case .pending: return .pending
        case .rejected: return .rejected
        }
    }

    static func textState(in targetApp: NSRunningApplication?) -> TextState? {
        guard let targetApp,
            let element = AccessibilityText.focusedElement(in: targetApp),
            !usesTextMarkerSelection(element),
            let value = stringValue(in: element),
            let selectedRange = selectedRange(in: element)
        else { return nil }
        return TextState(value: value, selectedRange: selectedRange)
    }

    /// Web content and Monaco expose selection only as markers; their `AXValue` trails or is empty.
    private static func usesTextMarkerSelection(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextMarkerRangeAttribute as CFString,
                &value) == .success,
            let value
        else { return false }
        return CFGetTypeID(value) == AXTextMarkerRangeGetTypeID()
    }

    private static func stringValue(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &value) == .success
        else { return nil }
        return value as? String
    }

    private static func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func setSelectedRange(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value) == .success
    }

    private static func isAttributeSettable(_ attribute: String, in element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                element,
                attribute as CFString,
                &settable) == .success
        else { return false }
        return settable.boolValue
    }
}
