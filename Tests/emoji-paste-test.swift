import AppKit

@main
@MainActor
struct EmojiPasteTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    static func main() async {
        let settings = AppSettings()
        let history = FrequentEmojiStore()
        let window = PaletteWindowController()
        let palette = PaletteCoordinator()
        let coordinator = EmojiCoordinator(
            frequentEmoji: history, settings: settings, windowController: window,
            paletteCoordinator: palette)
        let emoji = EmojiEntry(
            glyph: "😂", name: "face with tears of joy", category: .smileysAndPeople,
            supportsSkinTone: false, keywords: "")
        coordinator.pasteEmoji(emoji)
        await settle()
        expect(NSPasteboard.general.string(forType: .string) == "😂", "selected emoji reaches the pasteboard")
        expect(palette.hides == [false], "paste dismisses without a competing focus restoration")
        expect(CGEvent.deliveries == [4242, 4242], "key down and up target the captured app")
        expect(CGEvent.broadcasts == 0, "paste never broadcasts to an unrelated foreground app")
        expect(CGEvent.commands.allSatisfy { $0 }, "both events carry Command")
        expect(history.glyphs == ["😂"], "history records the selected base glyph")
        expect(window.previousApp?.activations == 1, "paste requests target activation")

        CGEvent.reset()
        let hand = EmojiEntry(
            glyph: "👋", name: "waving hand", category: .smileysAndPeople,
            supportsSkinTone: true, keywords: "")
        settings.emojiSkinTone = .medium
        coordinator.copyEmoji(hand)
        await settle()
        expect(NSPasteboard.general.string(forType: .string) == "👋🏽", "copy applies the configured skin tone")
        expect(CGEvent.deliveries.isEmpty && CGEvent.broadcasts == 0, "copy emits no paste events")
        expect(history.glyphs.last == "👋", "skin tone does not change the history key")

        CGEvent.reset()
        let hides = palette.hides.count
        coordinator.pasteEmojiKeepingWindowOpen(hand)
        await settle()
        expect(palette.hides.count == hides, "keep-open paste leaves the palette open")
        expect(CGEvent.deliveries == [4242, 4242], "keep-open paste targets the captured app")
        expect(window.previousApp?.activations == 1, "keep-open paste does not activate another app")

        CGEvent.reset()
        coordinator.pasteEmoji(emoji)
        window.previousApp?.isTerminated = true
        await settle()
        expect(CGEvent.deliveries.isEmpty && CGEvent.broadcasts == 0, "a target that quits gets no delayed events")
        print(failures == 0 ? "Emoji delivery checks passed" : "\(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}

@MainActor
final class NSRunningApplication {
    let processIdentifier: pid_t = 4242
    var isTerminated = false
    var activations = 0
    func activate() { activations += 1 }
}

@MainActor
final class AppSettings { var emojiSkinTone = EmojiSkinTone.none }

@MainActor
final class FrequentEmojiStore {
    var glyphs: [String] = []
    func record(_ glyph: String) { glyphs.append(glyph) }
}

@MainActor
final class PaletteCoordinator {
    var hides: [Bool] = []
    func hidePalette(restoreFocus: Bool) { hides.append(restoreFocus) }
}

@MainActor
final class PaletteWindowController {
    var previousApp: NSRunningApplication? = NSRunningApplication()
    func pasteStringKeepingWindowOpen(_ text: String) {
        Paster.pasteStringInPlace(text, into: previousApp)
    }
}

@MainActor
final class CGEvent {
    static var deliveries: [pid_t] = []
    static var broadcasts = 0
    static var commands: [Bool] = []
    var flags: CGEventFlags = []
    init?(keyboardEventSource: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool) {}
    func setIntegerValueField(_ field: CGEventField, value: Int64) {}
    func postToPid(_ pid: pid_t) {
        Self.deliveries.append(pid)
        Self.commands.append(flags.contains(.maskCommand))
    }
    func post(tap: CGEventTapLocation) { Self.broadcasts += 1 }
    static func reset() { deliveries = []; broadcasts = 0; commands = [] }
}

@MainActor
final class NSPasteboard {
    static let general = NSPasteboard()
    private let board = AppKit.NSPasteboard.withUniqueName()
    func clearContents() { board.clearContents() }
    func declareTypes(_ types: [AppKit.NSPasteboard.PasteboardType], owner: Any?) {
        board.declareTypes(types, owner: owner)
    }
    @discardableResult
    func setString(_ value: String, forType type: AppKit.NSPasteboard.PasteboardType) -> Bool {
        board.setString(value, forType: type)
    }
    @discardableResult
    func setData(_ data: Data, forType type: AppKit.NSPasteboard.PasteboardType) -> Bool {
        board.setData(data, forType: type)
    }
    func string(forType type: AppKit.NSPasteboard.PasteboardType) -> String? {
        board.string(forType: type)
    }
}

@MainActor
enum Permissions { static func ensureAccessibility() -> Bool { true } }

@MainActor
enum ClipboardManager {
    static let internalType = AppKit.NSPasteboard.PasteboardType("test.tinycast.internal")
}

struct ClipboardItem {
    enum Kind { case text, image, file }
    let kind: Kind
    let text: String?
    var plainText: String? { text }
}

@MainActor
final class ClipboardStore {
    func promote(_ item: ClipboardItem) {}
    func imageURL(for item: ClipboardItem) -> URL? { nil }
    func fileURL(for item: ClipboardItem) -> URL? { nil }
}

enum PasteboardFiles {
    static func write(_ url: URL, to board: NSPasteboard) {}
}
