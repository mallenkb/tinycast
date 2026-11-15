import Foundation

/// Where each fired binding goes. `AppCore.start()` builds one and hands it to `HotKeyManager`.
struct HotKeyRoutes {
    var togglePalette: () -> Void = {}
    var dictationHoldPressed: () -> Void = {}
    var dictationTogglePressed: () -> Void = {}
    var dictationHoldReleased: () -> Void = {}
    var dictationHoldCancelled: () -> Void = {}
    var dictationCancelled: () -> Void = {}
    /// The launcher's own command funnel, so a shortcut and a palette row run the same thing.
    var runCommand: (CommandID) -> Void = { _ in }
    var runCustomCommand: (UUID) -> Void = { _ in }
    var runSystemAction: (SystemAction.ID) -> Void = { _ in }
    var runWindowCommand: (WindowCommand.ID) -> Void = { _ in }
    var runWindowLayout: (UUID) -> Void = { _ in }
    var enterRoom: (UUID) -> Void = { _ in }
    var runCustomWindowSize: (UUID) -> Void = { _ in }
    var openQuicklink: (UUID) -> Void = { _ in }
    var runDictationTransform: (UUID) -> Void = { _ in }
    var runQuickAction: (UUID) -> Void = { _ in }
    var runAppleShortcut: (UUID) -> Void = { _ in }
    var expandSnippet: (StoredSnippet.ID) -> Void = { _ in }
    var runExtensionCommand: (String) -> Void = { _ in }
}
