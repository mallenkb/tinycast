import Foundation

// A stand-in with the real property names: the shipped mapping compiles against it unchanged.
@MainActor
final class AppSettings {
    var animationsEnabled = false
    var appearance = AppAppearance.allCases[0]
    var appleShortcutsEnabled = false
    var autoJoinConfirms = false
    var autoJoinNamedProvidersOnly = false
    var automaticallyCheckForUpdates = false
    var calcNumberStyle = CalcNumberStyle.allCases[0]
    var calendarLauncherLimit = CalendarLauncherLimit.allCases[0]
    var calendarMenuBarDisplay = CalendarMenuBarDisplay.allCases[0]
    var calendarMenuBarHidesWhenEmpty = false
    var calendarShowInLauncher = false
    var calendarSpan = MeetingSpan.allCases[0]
    var clipboardDefaultAction = ClipboardDefaultAction.allCases[0]
    var clipboardDisabledApps: [String] = []
    var clipboardEnabled = false
    var clipboardRetention = ClipboardRetention.allCases[0]
    var compactBarCommands = CommandID.defaultCompactBarCommands
    var compactMode = false
    var customCommandsEnabled = false
    var customCommandsShowInLauncher = false
    var dictionaryPreferredSource = ""
    var dictionaryPronunciationAccent = ""
    var dictionaryPronunciationSlow = false
    var dictionaryPronunciationSource = "nativeSpeech"
    var dictionaryPronunciationVoice = ""
    var dictionaryRecentSources: [String] = []
    var emojiGridColumns = EmojiGridColumns.allCases[0]
    var emojiSkinTone = EmojiSkinTone.allCases[0]
    var escapeKeyBehavior = EscapeKeyBehavior.allCases[0]
    var extensionsShowInLauncher = false
    var fileSearchDocumentContentEnabled = false
    var fileSearchEnabled = false
    var fileSearchIgnorePatterns: [String] = []
    var fileSearchRemovedDefaultPatterns: [String] = []
    var fileSearchScopes: [String] = []
    var fileSearchShowInLauncher = false
    var hideCurrentEvent = HideCurrentEvent.allCases[0]
    var hyperKey = HyperKeyPhysicalKey.allCases[0]
    var hyperKeyIncludesShift = false
    var hyperKeyQuickPress = HyperKeyQuickPress.allCases[0]
    var hyperKeySecureInputCompatibility = false
    var interfaceSize = InterfaceSize.allCases[0]
    var joinWindowMinutes = JoinWindow.allCases[0]
    var language = AppLanguage.allCases[0]
    var launchAtLogin = false
    var launcherShowsSuggestions = false
    var menuBarEvents = MenuBarEvents.allCases[0]
    var menuBarLinkedEventsOnly = false
    var menuSearchDisabledApps: [String] = []
    var menuSearchShowsAppleMenu = false
    var navigationEnabled = false
    var notesEnabled = false
    var notesRendersMarkdown = false
    var notesShowsFormattingBar = false
    var notesShowsInMenuBar = false
    var openOnCursorScreen = false
    var paletteDraggable = false
    var popToRootTimeout = PopToRootTimeout.allCases[0]
    var quicklinkConfirmsBeforeDelete = false
    var quicklinkOpensNewWindow = false
    var quicklinkPassesSelectedText = false
    var quicklinksEnabled = false
    var quicklinksShowInLauncher = false
    var rootSearchSensitivity = SearchSensitivity.allCases[0]
    var searchScopes = SearchScopes.defaults
    var showInMenuBar = false
    var snippetsShowInLauncher = false
    var supportRemindersEnabled = false
    var typography = AppTypography.allCases[0]
    var windowCycle = WindowCycle.allCases[0]
    var windowGap = 0
    var windowKeepsProportions = false
    var windowLayoutsShowInLauncher = false
    var windowManagementEnabled = false
    var windowManagementShowInLauncher = false
    var windowRoomsShowInLauncher = false
    var windowWrapsDisplays = false
    var snippetsEnabled = false
    var extensionsEnabled = false
    var calendarEnabled = false
    var autoJoinMeetings = false
    var cameraPreview = false
    var quickActionsEnabled = false
    var settingsFileEnabled = false
    var mcpEnabled = false
    var aiEnabled = false
    var dictationEnabled = false
}

// Stand-ins for types whose real files pull in a store or the app; only their shape matters here.
enum ClipboardRetention: Int, CaseIterable {
    case threeMonths = 90
    case forever = -1
}

enum ClipboardDefaultAction: String, CaseIterable {
    case paste
    case copy
}

enum HyperKeyPhysicalKey: String, CaseIterable {
    case none
    case capsLock
}

enum HyperKeyQuickPress: String, CaseIterable {
    case none
    case escape
}

enum CalcNumberStyle: String, CaseIterable {
    case system
    case periodDecimal
}

enum SearchSensitivity: String, CaseIterable {
    case standard
    case strict
}

enum InterfaceSize: String, CaseIterable {
    case standard
    case large
}

enum CommandID: String {
    case clipboardHistory = "command:clipboard-history"
    case searchEmoji = "command:search-emoji"

    static let defaultCompactBarCommands: [CommandID] = [.clipboardHistory, .searchEmoji]

    static func compactBarCommands(from identifiers: [String]) -> [CommandID]? {
        let commands = identifiers.compactMap(CommandID.init(rawValue:))
        return commands.count == identifiers.count ? commands : nil
    }
}

struct HotKeyBinding: Codable {}
struct CustomCommand: Codable {}
struct Quicklink: Codable {}
struct WindowLayout: Codable {}
struct Room: Codable {}
struct CustomWindowSize: Codable {}

private func other<T: CaseIterable & Equatable>(_ value: T) -> T {
    T.allCases.first { $0 != value } ?? value
}

/// Moves every carried field off its fresh value, so a field the mapping drops cannot pass.
@MainActor
private func perturb(_ s: AppSettings) {
    s.animationsEnabled.toggle()
    s.appearance = other(s.appearance)
    s.appleShortcutsEnabled.toggle()
    s.autoJoinConfirms.toggle()
    s.autoJoinNamedProvidersOnly.toggle()
    s.automaticallyCheckForUpdates.toggle()
    s.calcNumberStyle = other(s.calcNumberStyle)
    s.calendarLauncherLimit = other(s.calendarLauncherLimit)
    s.calendarMenuBarDisplay = other(s.calendarMenuBarDisplay)
    s.calendarMenuBarHidesWhenEmpty.toggle()
    s.calendarShowInLauncher.toggle()
    s.calendarSpan = other(s.calendarSpan)
    s.clipboardDefaultAction = other(s.clipboardDefaultAction)
    s.clipboardDisabledApps = ["probe-clipboardDisabledApps"]
    s.clipboardEnabled.toggle()
    s.clipboardRetention = other(s.clipboardRetention)
    s.compactBarCommands = Array(s.compactBarCommands.prefix(1))
    s.compactMode.toggle()
    s.customCommandsEnabled.toggle()
    s.customCommandsShowInLauncher.toggle()
    s.dictionaryPreferredSource = "probe-dictionaryPreferredSource"
    s.dictionaryPronunciationAccent = "probe-dictionaryPronunciationAccent"
    s.dictionaryPronunciationSlow.toggle()
    s.dictionaryPronunciationSource = "recordedAudio"
    s.dictionaryPronunciationVoice = "probe-dictionaryPronunciationVoice"
    s.dictionaryRecentSources = ["probe-dictionaryRecentSources"]
    s.emojiGridColumns = other(s.emojiGridColumns)
    s.emojiSkinTone = other(s.emojiSkinTone)
    s.escapeKeyBehavior = other(s.escapeKeyBehavior)
    s.extensionsShowInLauncher.toggle()
    s.fileSearchDocumentContentEnabled.toggle()
    s.fileSearchEnabled.toggle()
    s.fileSearchIgnorePatterns = ["probe-fileSearchIgnorePatterns"]
    s.fileSearchRemovedDefaultPatterns = ["probe-fileSearchRemovedDefaultPatterns"]
    s.fileSearchScopes = ["probe-fileSearchScopes"]
    s.fileSearchShowInLauncher.toggle()
    s.hideCurrentEvent = other(s.hideCurrentEvent)
    s.hyperKey = other(s.hyperKey)
    s.hyperKeyIncludesShift.toggle()
    s.hyperKeyQuickPress = other(s.hyperKeyQuickPress)
    s.hyperKeySecureInputCompatibility.toggle()
    s.interfaceSize = other(s.interfaceSize)
    s.joinWindowMinutes = other(s.joinWindowMinutes)
    s.language = other(s.language)
    s.launchAtLogin.toggle()
    s.launcherShowsSuggestions.toggle()
    s.menuBarEvents = other(s.menuBarEvents)
    s.menuBarLinkedEventsOnly.toggle()
    s.menuSearchDisabledApps = ["probe-menuSearchDisabledApps"]
    s.menuSearchShowsAppleMenu.toggle()
    s.navigationEnabled.toggle()
    s.notesEnabled.toggle()
    s.notesRendersMarkdown.toggle()
    s.notesShowsFormattingBar.toggle()
    s.notesShowsInMenuBar.toggle()
    s.openOnCursorScreen.toggle()
    s.paletteDraggable.toggle()
    s.popToRootTimeout = other(s.popToRootTimeout)
    s.quicklinkConfirmsBeforeDelete.toggle()
    s.quicklinkOpensNewWindow.toggle()
    s.quicklinkPassesSelectedText.toggle()
    s.quicklinksEnabled.toggle()
    s.quicklinksShowInLauncher.toggle()
    s.rootSearchSensitivity = other(s.rootSearchSensitivity)
    s.searchScopes = Array(SearchScopes.defaults.prefix(1))
    s.showInMenuBar.toggle()
    s.snippetsShowInLauncher.toggle()
    s.supportRemindersEnabled.toggle()
    s.typography = other(s.typography)
    s.windowCycle = other(s.windowCycle)
    s.windowGap = 12
    s.windowKeepsProportions.toggle()
    s.windowLayoutsShowInLauncher.toggle()
    s.windowManagementEnabled.toggle()
    s.windowManagementShowInLauncher.toggle()
    s.windowRoomsShowInLauncher.toggle()
    s.windowWrapsDisplays.toggle()
}

private let capabilityFlags = [
    "snippetsEnabled", "extensionsEnabled", "calendarEnabled", "autoJoinMeetings", "cameraPreview",
    "quickActionsEnabled", "settingsFileEnabled", "mcpEnabled", "aiEnabled", "dictationEnabled",
]

@MainActor
private func capabilities(_ s: AppSettings) -> [Bool] {
    [
        s.snippetsEnabled, s.extensionsEnabled, s.calendarEnabled, s.autoJoinMeetings,
        s.cameraPreview, s.quickActionsEnabled, s.settingsFileEnabled, s.mcpEnabled, s.aiEnabled,
        s.dictationEnabled,
    ]
}

@MainActor
private func grantCapabilities(_ s: AppSettings) {
    s.snippetsEnabled = true
    s.extensionsEnabled = true
    s.calendarEnabled = true
    s.autoJoinMeetings = true
    s.cameraPreview = true
    s.quickActionsEnabled = true
    s.settingsFileEnabled = true
    s.mcpEnabled = true
    s.aiEnabled = true
    s.dictationEnabled = true
}

@main
struct SettingsBackupRoundTripTest {
    @MainActor
    static func main() throws {
        var failures = 0
        func check(_ description: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL")  \(description)")
            if !condition { failures += 1 }
        }
        func fields(_ data: SettingsBackup.SettingsData) throws -> [String: String] {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any]
            return (json ?? [:]).mapValues { "\($0)" }
        }

        let source = AppSettings()
        perturb(source)
        grantCapabilities(source)
        var backup = SettingsBackup()
        backup.settings = SettingsBackup.SettingsData(source)
        let encoded = try backup.encoded()
        let decoded = try SettingsBackup(json: encoded)

        let target = AppSettings()
        let fresh = try fields(SettingsBackup.SettingsData(target))
        let gathered = try fields(SettingsBackup.SettingsData(source))
        let unchanged = fresh.keys.filter { fresh[$0] == gathered[$0] }.sorted()
        check("every carried field moved off its fresh value \(unchanged)", unchanged.isEmpty)

        let applied = decoded.settings?.apply(to: target) ?? 0
        check("every field applied (\(applied) of \(gathered.count))", applied == gathered.count)
        check(
            "the target gathers what the source gathered",
            SettingsBackup.SettingsData(target) == SettingsBackup.SettingsData(source))

        let text = String(bytes: encoded, encoding: .utf8) ?? ""
        let leaked = capabilityFlags.filter { text.contains("\"\($0)\"") }
        check("no capability flag is written \(leaked)", leaked.isEmpty)
        check("no capability flag is granted by an import", !capabilities(target).contains(true))

        // A hand-edited file naming the flags must still grant nothing.
        let hostile = Data(
            (#"{"settings": {"snippetsEnabled": true, "extensionsEnabled": true, "calendarEnabled": true, "#
                + #""autoJoinMeetings": true, "cameraPreview": true, "quickActionsEnabled": true}}"#).utf8)
        let fromHostile = AppSettings()
        _ = try SettingsBackup(json: hostile).settings?.apply(to: fromHostile)
        check("a file naming capability flags grants none", !capabilities(fromHostile).contains(true))

        print(failures == 0 ? "\nAll passed." : "\n\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
