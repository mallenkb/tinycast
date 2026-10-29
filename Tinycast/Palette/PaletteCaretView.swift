import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class PaletteCaretView: NSView {
    private(set) weak var editor: NSTextView?
    private var observations: [NotificationToken] = []
    private var menuHidden = false

    init(editor: NSTextView) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        let center = NotificationCenter.default
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
            observations.append(
                NotificationToken(
                    center.addObserver(forName: name, object: editor, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.refresh(restart: true) }
                    }, center: center))
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observations.append(
            NotificationToken(
                workspaceCenter.addObserver(
                    forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh(restart: true) }
                }, center: workspaceCenter))
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(restart: false)
    }

    func setMenuHidden(_ hidden: Bool) {
        guard menuHidden != hidden else { return }
        menuHidden = hidden
        refresh(restart: true)
    }

    func refresh(restart: Bool) {
        guard let editor, let window = editor.window, window.isKeyWindow, window.isVisible,
            window.firstResponder === editor, !menuHidden, editor.isEditable,
            editor.selectedRange().length == 0, !editor.hasMarkedText()
        else {
            isHidden = true
            layer?.removeAnimation(forKey: "blink")
            return
        }
        let range = NSRange(location: editor.selectedRange().location, length: 0)
        let screenRect = editor.firstRect(forCharacterRange: range, actualRange: nil)
        guard screenRect.height > 0, screenRect.origin.x.isFinite, screenRect.origin.y.isFinite else {
            isHidden = true
            layer?.removeAnimation(forKey: "blink")
            return
        }
        var rect = editor.convert(window.convertFromScreen(screenRect), from: nil)
        rect.size.width = Theme.Size.caretWidth
        let wasHidden = isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = rect
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(Theme.Colors.textPrimary).cgColor
        }
        layer?.opacity = 1
        isHidden = false
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer?.removeAnimation(forKey: "blink")
            return
        }
        guard restart || wasHidden || layer?.animation(forKey: "blink") == nil else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0, 1]
        blink.keyTimes = [0, 0.35, 0.5, 0.85, 1]
        blink.timingFunctions = [
            CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        blink.duration = Theme.Duration.caretBlink
        blink.repeatCount = .infinity
        layer?.add(blink, forKey: "blink")
    }
}
