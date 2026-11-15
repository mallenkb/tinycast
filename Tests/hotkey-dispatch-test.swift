import AppKit
import Carbon.HIToolbox

@main
@MainActor
struct HotKeyDispatchTest {
    static var failures = 0
    static var checks = 0

    static func check(_ name: String, _ value: Bool) {
        checks += 1
        if !value { failures += 1; print("FAIL \(name)") }
    }

    static func main() {
        for includesShift in [false, true] { dispatch(includesShift: includesShift) }
        routing()
        print("\(checks) dispatch checks; \(failures) failures")
        if failures > 0 { exit(1) }
    }

    static func dispatch(includesShift: Bool) {
        let domain = "tinycast.hotkey-dispatch-test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = HotKeyManager(defaults: defaults)
        let center = HotKeyCenter.current!
        var presses = 0
        var releases = 0
        var cancellations = 0
        var palette = 0
        manager.routes = HotKeyRoutes(
            togglePalette: { palette += 1 }, dictationHoldPressed: { presses += 1 },
            dictationHoldReleased: { releases += 1 }, dictationHoldCancelled: { cancellations += 1 })
        manager.dictationEnabled = true
        let chord = KeyShortcut.hyperChord(includesShift: includesShift)
        let hyper = KeyShortcut(
            carbonKeyCode: kVK_ANSI_G, carbonModifiers: KeyShortcut.carbonModifiers(from: chord))
        let control = KeyShortcut(carbonKeyCode: kVK_ANSI_G, carbonModifiers: controlKey)
        manager.setBinding(.combo(hyper), for: .dictationHold)
        let normal = center.entries[HotKeyAction.dictationHold.defaultsKey]!
        normal.onKeyDown(0)
        normal.onKeyUp?()
        check("normal dictation has both callbacks", presses == 1 && releases == 1)
        var toggles = 0
        manager.routes.dictationTogglePressed = { toggles += 1 }
        let toggle = KeyShortcut(carbonKeyCode: kVK_ANSI_T, carbonModifiers: controlKey)
        manager.setBinding(.combo(toggle), for: .dictationToggle)
        let toggleEntry = center.entries[HotKeyAction.dictationToggle.defaultsKey]!
        toggleEntry.onKeyDown(0)
        toggleEntry.onKeyUp?()
        check("toggle works alongside hold and has no release callback", toggles == 1 && releases == 1)
        check(
            "the hold chord cannot also bind toggle",
            manager.conflictOwner(of: .combo(hyper), excluding: .dictationToggle) != nil)

        manager.setSecureInputEquivalents(includesShift: includesShift)
        let id = "secureInputEquivalent." + HotKeyAction.dictationHold.defaultsKey
        let secure = center.entries[id]!
        secure.onKeyDown(CGEventFlags.maskControl.rawValue | 1)
        secure.onKeyUp?()
        check("Left Control cannot invoke Hyper", presses == 1 && releases == 1)
        secure.onKeyDown(CGEventFlags.maskControl.rawValue)
        secure.onKeyUp?()
        check("missing side identity cannot invoke Hyper", presses == 1)
        secure.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        secure.onKeyUp?()
        check("Right Control dispatches Hyper and release", presses == 2 && releases == 2)
        secure.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2001)
        secure.onKeyUp?()
        check("both Controls keep the reserved Right Control route", presses == 3 && releases == 3)
        manager.setBinding(.combo(control), for: .togglePalette)
        check(
            "shared Control combination has one registration",
            center.entries.values.filter { $0.shortcut == control }.count == 1)
        let shared = center.entries[id]!
        shared.onKeyDown(CGEventFlags.maskControl.rawValue | 1)
        shared.onKeyUp?()
        check(
            "Left Control retains its ordinary Tinycast binding",
            palette == 1 && presses == 3 && releases == 3)
        shared.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        shared.onKeyUp?()
        check(
            "Right Control selects Hyper rather than ordinary binding",
            palette == 1 && presses == 4 && releases == 4)
        shared.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        manager.recordingAction = .togglePalette
        manager.recordingAction = nil
        let resumed = center.entries[id]!
        let beforeResume = presses
        resumed.onKeyDown(CGEventFlags.maskControl.rawValue | 1)
        resumed.onKeyUp?()
        check("recording clears the previous Hyper press route", presses == beforeResume && palette == 2)
        let beforeCancellation = cancellations
        resumed.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        manager.setSecureInputEquivalents(includesShift: nil)
        check("leaving Secure Input cancels an active hold", cancellations == beforeCancellation + 1)
        check("leaving Secure Input removes equivalent", center.entries[id] == nil)
        check(
            "leaving Secure Input restores ordinary registration",
            center.entries[HotKeyAction.togglePalette.defaultsKey]?.shortcut == control)
        manager.setSecureInputEquivalents(includesShift: includesShift)
        manager.setBinding(nil, for: .dictationHold)
        check("unbinding removes equivalent", center.entries[id] == nil)
        check(
            "unbinding preserves ordinary Control registration",
            center.entries[HotKeyAction.togglePalette.defaultsKey]?.shortcut == control)
        manager.setBinding(.combo(hyper), for: .dictationHold)
        manager.setBinding(nil, for: .togglePalette)
        check(
            "deleting ordinary binding preserves Hyper equivalent",
            center.entries[id]?.shortcut == control
                && center.entries[HotKeyAction.togglePalette.defaultsKey] == nil)
        manager.setSecureInputEquivalents(includesShift: nil)
        manager.setBinding(.combo(control), for: .dictationHold)
        manager.setBinding(.combo(hyper), for: .togglePalette)
        manager.setSecureInputEquivalents(includesShift: includesShift)
        let swappedID = "secureInputEquivalent." + HotKeyAction.togglePalette.defaultsKey
        let swapped = center.entries[swappedID]!
        let beforePress = presses
        let beforeRelease = releases
        swapped.onKeyDown(CGEventFlags.maskControl.rawValue | 1)
        swapped.onKeyUp?()
        check(
            "ordinary Control dictation still releases through a shared registration",
            presses == beforePress + 1 && releases == beforeRelease + 1)
        swapped.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        swapped.onKeyUp?()
        check(
            "Hyper selects the other action in a shared registration",
            palette == 3 && presses == beforePress + 1)
    }

    static func routing() {
        let domain = "tinycast.hotkey-dispatch-test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = HotKeyManager(defaults: defaults)
        let quicklink = UUID()
        var routed: [String] = []
        manager.routes = HotKeyRoutes(
            dictationTogglePressed: { routed.append("toggle") },
            dictationCancelled: { routed.append("cancelled") },
            runCommand: { routed.append("command \($0.rawValue)") },
            openQuicklink: { routed.append("quicklink \($0 == quicklink)") },
            expandSnippet: { routed.append("snippet \($0)") })
        manager.perform(.command(.sample))
        manager.perform(.quicklink(id: quicklink))
        manager.perform(.snippet(id: "s"))
        manager.perform(.dictationToggle)
        check(
            "each action reaches its own route",
            routed == ["command sample", "quicklink true", "snippet s"])
        manager.dictationEnabled = true
        manager.perform(.dictationToggle)
        manager.dictationEnabled = false
        check("dictation routes follow the switch", routed.suffix(2) == ["toggle", "cancelled"])
        manager.allowsAction = { $0 != .command(.sample) }
        manager.perform(.command(.sample))
        check("a switched-off category never reaches its route", routed.count == 5)
    }
}
