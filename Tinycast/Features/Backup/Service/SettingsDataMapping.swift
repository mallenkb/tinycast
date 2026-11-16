import Foundation

/// `AppSettings` and the backup's settings fields; a consent flag has no field, so none moves.
@MainActor
extension SettingsBackup.SettingsData {
    init(_ s: AppSettings) {
        self.init(
            clipboardEnabled: s.clipboardEnabled,
            clipboardRetentionDays: s.clipboardRetention.rawValue,
            clipboardDefaultAction: s.clipboardDefaultAction.rawValue,
            clipboardDisabledApps: s.clipboardDisabledApps,
            launchAtLogin: s.launchAtLogin,
            hyperKey: s.hyperKey.rawValue,
            hyperKeyIncludesShift: s.hyperKeyIncludesShift,
            hyperKeyQuickPress: s.hyperKeyQuickPress.rawValue,
            hyperKeySecureInputCompatibility: s.hyperKeySecureInputCompatibility,
            emojiSkinTone: s.emojiSkinTone.rawValue,
            emojiGridColumns: s.emojiGridColumns.rawValue,
            showInMenuBar: s.showInMenuBar,
            automaticallyCheckForUpdates: s.automaticallyCheckForUpdates,
            popToRootSeconds: s.popToRootTimeout.rawValue,
            escapeKeyBehavior: s.escapeKeyBehavior.rawValue,
            appearance: s.appearance.rawValue,
            language: s.language.rawValue,
            dictionaryRecentSources: s.dictionaryRecentSources,
            dictionaryPreferredSource: s.dictionaryPreferredSource,
            dictionaryPronunciationSource: s.dictionaryPronunciationSource,
            dictionaryPronunciationSlow: s.dictionaryPronunciationSlow,
            dictionaryPronunciationVoice: s.dictionaryPronunciationVoice,
            dictionaryPronunciationAccent: s.dictionaryPronunciationAccent,
            calcNumberStyle: s.calcNumberStyle.rawValue,
            typography: s.typography.rawValue,
            interfaceSize: s.interfaceSize.rawValue,
            compactMode: s.compactMode,
            compactBarCommands: s.compactBarCommands.map(\.rawValue),
            searchScopes: s.searchScopes,
            launcherShowsSuggestions: s.launcherShowsSuggestions,
            rootSearchSensitivity: s.rootSearchSensitivity.rawValue,
            openOnCursorScreen: s.openOnCursorScreen,
            paletteDraggable: s.paletteDraggable,
            animationsEnabled: s.animationsEnabled,
            fileSearchEnabled: s.fileSearchEnabled,
            fileSearchScopes: s.fileSearchScopes,
            fileSearchIgnorePatterns: s.fileSearchIgnorePatterns,
            fileSearchRemovedDefaultPatterns: s.fileSearchRemovedDefaultPatterns,
            fileSearchShowInLauncher: s.fileSearchShowInLauncher,
            fileSearchDocumentContentEnabled: s.fileSearchDocumentContentEnabled,
            notesEnabled: s.notesEnabled,
            notesRendersMarkdown: s.notesRendersMarkdown,
            notesShowsFormattingBar: s.notesShowsFormattingBar,
            notesShowsInMenuBar: s.notesShowsInMenuBar,
            customCommandsEnabled: s.customCommandsEnabled,
            customCommandsShowInLauncher: s.customCommandsShowInLauncher,
            snippetsShowInLauncher: s.snippetsShowInLauncher,
            navigationEnabled: s.navigationEnabled,
            menuSearchDisabledApps: s.menuSearchDisabledApps,
            menuSearchShowsAppleMenu: s.menuSearchShowsAppleMenu,
            windowManagementEnabled: s.windowManagementEnabled,
            windowManagementShowInLauncher: s.windowManagementShowInLauncher,
            windowGap: s.windowGap,
            windowCycle: s.windowCycle.rawValue,
            windowWrapsDisplays: s.windowWrapsDisplays,
            windowKeepsProportions: s.windowKeepsProportions,
            windowLayoutsShowInLauncher: s.windowLayoutsShowInLauncher,
            windowRoomsShowInLauncher: s.windowRoomsShowInLauncher,
            quicklinksEnabled: s.quicklinksEnabled,
            quicklinksShowInLauncher: s.quicklinksShowInLauncher,
            extensionsShowInLauncher: s.extensionsShowInLauncher,
            quicklinkOpensNewWindow: s.quicklinkOpensNewWindow,
            quicklinkPassesSelectedText: s.quicklinkPassesSelectedText,
            quicklinkConfirmsBeforeDelete: s.quicklinkConfirmsBeforeDelete,
            appleShortcutsEnabled: s.appleShortcutsEnabled,
            calendarShowInLauncher: s.calendarShowInLauncher,
            calendarLauncherLimit: s.calendarLauncherLimit.rawValue,
            calendarSpan: s.calendarSpan.rawValue,
            joinWindowMinutes: s.joinWindowMinutes.rawValue,
            autoJoinConfirms: s.autoJoinConfirms,
            autoJoinNamedProvidersOnly: s.autoJoinNamedProvidersOnly,
            menuBarEvents: s.menuBarEvents.rawValue,
            calendarMenuBarDisplay: s.calendarMenuBarDisplay.rawValue,
            menuBarLinkedEventsOnly: s.menuBarLinkedEventsOnly,
            calendarMenuBarHidesWhenEmpty: s.calendarMenuBarHidesWhenEmpty,
            hideCurrentEvent: s.hideCurrentEvent.rawValue,
            supportReminders: s.supportRemindersEnabled)
    }

    /// The number of fields applied; a raw value this build doesn't know is skipped.
    func apply(to settings: AppSettings) -> Int {
        let s = self
        var count = 0
        if let flag = s.clipboardEnabled {
            settings.clipboardEnabled = flag
            count += 1
        }
        if let days = s.clipboardRetentionDays, let retention = ClipboardRetention(rawValue: days) {
            settings.clipboardRetention = retention
            count += 1
        }
        if let apps = s.clipboardDisabledApps {
            settings.clipboardDisabledApps = apps
            count += 1
        }
        if let raw = s.clipboardDefaultAction, let action = ClipboardDefaultAction(rawValue: raw) {
            settings.clipboardDefaultAction = action
            count += 1
        }
        if let launch = s.launchAtLogin {
            settings.launchAtLogin = launch
            count += 1
        }
        if let raw = s.hyperKey, let key = HyperKeyPhysicalKey(rawValue: raw) {
            settings.hyperKey = key
            count += 1
        }
        if let flag = s.hyperKeyIncludesShift {
            settings.hyperKeyIncludesShift = flag
            count += 1
        }
        if let raw = s.hyperKeyQuickPress, let quick = HyperKeyQuickPress(rawValue: raw) {
            settings.hyperKeyQuickPress = quick
            count += 1
        }
        if let flag = s.hyperKeySecureInputCompatibility {
            settings.hyperKeySecureInputCompatibility = flag
            count += 1
        }
        if let raw = s.emojiSkinTone, let tone = EmojiSkinTone(rawValue: raw) {
            settings.emojiSkinTone = tone
            count += 1
        }
        if let raw = s.emojiGridColumns, let columns = EmojiGridColumns(rawValue: raw) {
            settings.emojiGridColumns = columns
            count += 1
        }
        if let show = s.showInMenuBar {
            settings.showInMenuBar = show
            count += 1
        }
        if let automaticallyCheck = s.automaticallyCheckForUpdates {
            settings.automaticallyCheckForUpdates = automaticallyCheck
            count += 1
        }
        if let secs = s.popToRootSeconds, let timeout = PopToRootTimeout(rawValue: secs) {
            settings.popToRootTimeout = timeout
            count += 1
        }
        if let raw = s.escapeKeyBehavior, let behavior = EscapeKeyBehavior(rawValue: raw) {
            settings.escapeKeyBehavior = behavior
            count += 1
        }
        if let raw = s.typography, let typography = AppTypography(rawValue: raw) {
            settings.typography = typography
            count += 1
        }
        if let raw = s.interfaceSize, let size = InterfaceSize(rawValue: raw) {
            settings.interfaceSize = size
            count += 1
        }
        if let raw = s.appearance, let appearance = AppAppearance(rawValue: raw) {
            settings.appearance = appearance
            count += 1
        }
        if let raw = s.language, let language = AppLanguage(rawValue: raw) {
            settings.language = language
            count += 1
        }
        if let recent = s.dictionaryRecentSources {
            settings.dictionaryRecentSources = Array(recent.prefix(12))
            count += 1
        }
        if let source = s.dictionaryPreferredSource {
            settings.dictionaryPreferredSource = source
            count += 1
        }
        if let source = s.dictionaryPronunciationSource, ["nativeSpeech", "recordedAudio"].contains(source) {
            settings.dictionaryPronunciationSource = source
            count += 1
        }
        if let slow = s.dictionaryPronunciationSlow {
            settings.dictionaryPronunciationSlow = slow
            count += 1
        }
        if let voice = s.dictionaryPronunciationVoice {
            settings.dictionaryPronunciationVoice = voice
            count += 1
        }
        if let accent = s.dictionaryPronunciationAccent {
            settings.dictionaryPronunciationAccent = accent
            count += 1
        }
        if let raw = s.calcNumberStyle, let style = CalcNumberStyle(rawValue: raw) {
            settings.calcNumberStyle = style
            count += 1
        }
        if let flag = s.compactMode {
            settings.compactMode = flag
            count += 1
        }
        if let identifiers = s.compactBarCommands,
            let commands = CommandID.compactBarCommands(from: identifiers)
        {
            settings.compactBarCommands = commands
            count += 1
        }
        if let scopes = s.searchScopes {
            settings.searchScopes = SearchScopes.normalize(scopes)
            count += 1
        }
        if let flag = s.launcherShowsSuggestions {
            settings.launcherShowsSuggestions = flag
            count += 1
        }
        if let raw = s.rootSearchSensitivity, let sensitivity = SearchSensitivity(rawValue: raw) {
            settings.rootSearchSensitivity = sensitivity
            count += 1
        }
        if let flag = s.openOnCursorScreen {
            settings.openOnCursorScreen = flag
            count += 1
        }
        if let flag = s.paletteDraggable {
            settings.paletteDraggable = flag
            count += 1
        }
        if let flag = s.animationsEnabled {
            settings.animationsEnabled = flag
            count += 1
        }
        // Writing through AppSettings is enough; AppCore's sinks re-project the rest.
        if let flag = s.fileSearchEnabled {
            settings.fileSearchEnabled = flag
            count += 1
        }
        if let scopes = s.fileSearchScopes {
            settings.fileSearchScopes = scopes
            count += 1
        }
        if let patterns = s.fileSearchIgnorePatterns {
            settings.fileSearchIgnorePatterns = patterns
            count += 1
        }
        if let patterns = s.fileSearchRemovedDefaultPatterns {
            settings.fileSearchRemovedDefaultPatterns = patterns
            count += 1
        }
        if let flag = s.fileSearchShowInLauncher {
            settings.fileSearchShowInLauncher = flag
            count += 1
        }
        if let flag = s.fileSearchDocumentContentEnabled {
            settings.fileSearchDocumentContentEnabled = flag
            count += 1
        }
        if let flag = s.notesEnabled {
            settings.notesEnabled = flag
            count += 1
        }
        if let flag = s.notesRendersMarkdown {
            settings.notesRendersMarkdown = flag
            count += 1
        }
        if let flag = s.notesShowsFormattingBar {
            settings.notesShowsFormattingBar = flag
            count += 1
        }
        if let flag = s.notesShowsInMenuBar {
            settings.notesShowsInMenuBar = flag
            count += 1
        }
        if let flag = s.customCommandsEnabled {
            settings.customCommandsEnabled = flag
            count += 1
        }
        if let flag = s.customCommandsShowInLauncher {
            settings.customCommandsShowInLauncher = flag
            count += 1
        }
        if let flag = s.snippetsShowInLauncher {
            settings.snippetsShowInLauncher = flag
            count += 1
        }
        if let flag = s.navigationEnabled {
            settings.navigationEnabled = flag
            count += 1
        }
        if let apps = s.menuSearchDisabledApps {
            settings.menuSearchDisabledApps = apps
            count += 1
        }
        if let flag = s.menuSearchShowsAppleMenu {
            settings.menuSearchShowsAppleMenu = flag
            count += 1
        }
        if let flag = s.windowManagementEnabled {
            settings.windowManagementEnabled = flag
            count += 1
        }
        if let flag = s.windowManagementShowInLauncher {
            settings.windowManagementShowInLauncher = flag
            count += 1
        }
        if let gap = s.windowGap {
            settings.windowGap = gap
            count += 1
        }
        if let raw = s.windowCycle, let cycle = WindowCycle(rawValue: raw) {
            settings.windowCycle = cycle
            count += 1
        }
        if let flag = s.windowWrapsDisplays {
            settings.windowWrapsDisplays = flag
            count += 1
        }
        if let flag = s.windowKeepsProportions {
            settings.windowKeepsProportions = flag
            count += 1
        }
        if let flag = s.windowLayoutsShowInLauncher {
            settings.windowLayoutsShowInLauncher = flag
            count += 1
        }
        if let flag = s.windowRoomsShowInLauncher {
            settings.windowRoomsShowInLauncher = flag
            count += 1
        }
        if let flag = s.quicklinksEnabled {
            settings.quicklinksEnabled = flag
            count += 1
        }
        if let flag = s.extensionsShowInLauncher {
            settings.extensionsShowInLauncher = flag
            count += 1
        }
        if let flag = s.quicklinksShowInLauncher {
            settings.quicklinksShowInLauncher = flag
            count += 1
        }
        if let flag = s.appleShortcutsEnabled {
            settings.appleShortcutsEnabled = flag
            count += 1
        }
        if let flag = s.quicklinkOpensNewWindow {
            settings.quicklinkOpensNewWindow = flag
            count += 1
        }
        if let flag = s.quicklinkPassesSelectedText {
            settings.quicklinkPassesSelectedText = flag
            count += 1
        }
        if let flag = s.quicklinkConfirmsBeforeDelete {
            settings.quicklinkConfirmsBeforeDelete = flag
            count += 1
        }
        if let flag = s.calendarShowInLauncher {
            settings.calendarShowInLauncher = flag
            count += 1
        }
        if let raw = s.calendarLauncherLimit, let limit = CalendarLauncherLimit(rawValue: raw) {
            settings.calendarLauncherLimit = limit
            count += 1
        }
        if let raw = s.calendarSpan, let span = MeetingSpan(rawValue: raw) {
            settings.calendarSpan = span
            count += 1
        }
        if let raw = s.joinWindowMinutes, let window = JoinWindow(rawValue: raw) {
            settings.joinWindowMinutes = window
            count += 1
        }
        if let flag = s.autoJoinConfirms {
            settings.autoJoinConfirms = flag
            count += 1
        }
        if let flag = s.autoJoinNamedProvidersOnly {
            settings.autoJoinNamedProvidersOnly = flag
            count += 1
        }
        if let raw = s.menuBarEvents, let lead = MenuBarEvents(rawValue: raw) {
            settings.menuBarEvents = lead
            count += 1
        }
        if let raw = s.calendarMenuBarDisplay,
            let display = CalendarMenuBarDisplay(rawValue: raw)
        {
            settings.calendarMenuBarDisplay = display
            count += 1
        }
        if let flag = s.menuBarLinkedEventsOnly {
            settings.menuBarLinkedEventsOnly = flag
            count += 1
        }
        if let flag = s.calendarMenuBarHidesWhenEmpty {
            settings.calendarMenuBarHidesWhenEmpty = flag
            count += 1
        }
        if let raw = s.hideCurrentEvent, let hide = HideCurrentEvent(rawValue: raw) {
            settings.hideCurrentEvent = hide
            count += 1
        }
        if let flag = s.supportReminders {
            settings.supportRemindersEnabled = flag
            count += 1
        }
        return count
    }
}
