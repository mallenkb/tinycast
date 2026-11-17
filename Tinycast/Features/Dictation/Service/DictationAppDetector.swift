import AppKit

/// Reads which kind of app the text lands in, looking past a browser or terminal when allowed.
enum DictationAppDetector {
    /// Short, because it runs between the end of recording and the paste.
    private static let timeout: Float = 0.25

    static func kind(of app: NSRunningApplication?, webApps: Bool, terminalAgents: Bool) -> DictationAppKind {
        guard let app, let bundle = app.bundleIdentifier else { return .document }
        let kind = DictationAppKind(bundleIdentifier: bundle)
        if webApps, DictationAppKind.browsers.contains(bundle),
           let element = AccessibilityText.focusedElement(in: app, timeout: timeout),
           let host = AccessibilityText.pageURL(containing: element, timeout: timeout)?.host() {
            return DictationAppKind(webHost: host) ?? kind
        }
        if terminalAgents, DictationAppKind.terminals.contains(bundle),
           let title = AccessibilityText.focusedWindowTitle(in: app, timeout: timeout) {
            return DictationAppKind(terminalTitle: title) ?? kind
        }
        return kind
    }
}
