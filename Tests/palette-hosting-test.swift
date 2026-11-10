import AppKit
import SwiftUI

@MainActor
final class PaletteState {
    var menuOpen = false { didSet { onMenuOpenChanged?(menuOpen) } }
    var onMenuOpenChanged: ((Bool) -> Void)?
    var isComposing = false
    var searchFieldFrame = CGRect.zero
    var mode = PaletteMode.launcher

    func notePointerMoved(to: CGPoint) {}
    func disarmHoverHighlight(pointerAt: CGPoint) {}
    func noteCommandHeld(_ held: Bool) {}
}

enum PaletteMode {
    case launcher
    var isNativeEditor: Bool { false }
}

@MainActor
enum ASCIIKeyboardLayout {
    static func character(for event: NSEvent) -> String? { nil }
}

@main
@MainActor
struct PaletteHostingTests {
    static func main() {
        _ = NSApplication.shared
        let panel = PalettePanel(rootView: Color.clear)
        panel.releaseContent()

        for query in ["invoice", "all HTML files from last week Thursday", "files containing quarterly report"] {
            weak var hosting: NSView?
            autoreleasepool {
                panel.mount(Text(verbatim: query))
                hosting = panel.contentView
                precondition(hosting != nil)
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.releaseContent()
            }
            precondition(panel.contentView == nil && hosting == nil, "The hidden panel retained its search view")
        }
        precondition(!panel.isVisible)
        print("Palette releases each hosted view and mounts a fresh one while hidden.")
    }
}
