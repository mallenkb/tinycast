import SwiftUI

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults = AppPaths.preferences
    private typealias Key = AppSettingsKey

    /// What `AppIndex` scans, in scan order; editing it re-indexes, being observed.
    var searchScopes: [String] {
        didSet { Stored.searchScopes.store(searchScopes, in: defaults) }
    }

    var launcherShowsSuggestions: Bool {
        didSet { Stored.launcherShowsSuggestions.store(launcherShowsSuggestions, in: defaults) }
    }

    /// How loose a fuzzy root-search hit may be and still show.
    var rootSearchSensitivity: SearchSensitivity {
        didSet { Stored.rootSearchSensitivity.store(rootSearchSensitivity, in: defaults) }
    }

    /// Ships on, unlike every other feature switch: a launcher is expected to keep history.
    var clipboardEnabled: Bool {
        didSet { Stored.clipboardEnabled.store(clipboardEnabled, in: defaults) }
    }

    var clipboardTextSearchEnabled: Bool {
        didSet { Stored.clipboardTextSearchEnabled.store(clipboardTextSearchEnabled, in: defaults) }
    }

    var clipboardRetention: ClipboardRetention {
        didSet { Stored.clipboardRetention.store(clipboardRetention, in: defaults) }
    }

    /// Bundle IDs never recorded from; ordered, so the Settings list stays stable.
    var clipboardDisabledApps: [String] {
        didSet { Stored.clipboardDisabledApps.store(clipboardDisabledApps, in: defaults) }
    }

    /// What ↵ does on a clipboard entry; Paste takes the chord the chosen action leaves free.
    var clipboardDefaultAction: ClipboardDefaultAction {
        didSet { Stored.clipboardDefaultAction.store(clipboardDefaultAction, in: defaults) }
    }

    var launchAtLogin: Bool {
        didSet {
            Stored.launchAtLogin.store(launchAtLogin, in: defaults)
            applyLaunchAtLogin()
        }
    }

    private var launchAtLoginStatus = LaunchAtLogin.status

    enum LaunchAtLoginIssue {
        case approvalRequired
        case changeFailed

        var message: LocalizedStringResource {
            switch self {
            case .approvalRequired: "Allow Tinycast in Login Items to start it when you log in."
            case .changeFailed: "macOS couldn't change Launch at login."
            }
        }

        var actionTitle: LocalizedStringResource {
            switch self {
            case .approvalRequired: "Open System Settings"
            case .changeFailed: "Try Again"
            }
        }
    }

    var launchAtLoginIssue: LaunchAtLoginIssue? {
        switch (launchAtLogin, launchAtLoginStatus) {
        case (true, .requiresApproval): .approvalRequired
        case (true, .enabled), (false, .notRegistered), (false, .notFound): nil
        default: .changeFailed
        }
    }

    func applyLaunchAtLogin() {
        launchAtLoginStatus = LaunchAtLogin.set(launchAtLogin)
    }

    func refreshLaunchAtLoginStatus() {
        let status = LaunchAtLogin.status
        if status != launchAtLoginStatus { launchAtLoginStatus = status }
    }

    func resolveLaunchAtLoginIssue() {
        switch launchAtLoginIssue {
        case .approvalRequired: LaunchAtLogin.openSystemSettings()
        case .changeFailed: applyLaunchAtLogin()
        case nil: break
        }
    }

    /// The launcher icon's visibility; dragging the icon out of the menu bar turns it off.
    var showInMenuBar: Bool {
        didSet { Stored.showInMenuBar.store(showInMenuBar, in: defaults) }
    }

    var automaticallyCheckForUpdates: Bool {
        didSet { Stored.automaticallyCheckForUpdates.store(automaticallyCheckForUpdates, in: defaults) }
    }

    /// The physical key remapped to the Hyper chord; `HyperKeyManager` reacts via its observer.
    var hyperKey: HyperKeyPhysicalKey {
        didSet { Stored.hyperKey.store(hyperKey, in: defaults) }
    }

    var hyperKeyIncludesShift: Bool {
        didSet { Stored.hyperKeyIncludesShift.store(hyperKeyIncludesShift, in: defaults) }
    }

    var hyperKeyQuickPress: HyperKeyQuickPress {
        didSet { Stored.hyperKeyQuickPress.store(hyperKeyQuickPress, in: defaults) }
    }

    var hyperKeySecureInputCompatibility: Bool {
        didSet { Stored.hyperKeySecureInputCompatibility.store(hyperKeySecureInputCompatibility, in: defaults) }
    }

    /// Preferred skin tone applied to modifier-capable emoji at render and copy time.
    var emojiSkinTone: EmojiSkinTone {
        didSet { Stored.emojiSkinTone.store(emojiSkinTone, in: defaults) }
    }

    /// Grid density used when the emoji picker opens; in-session zoom remains temporary.
    var emojiGridColumns: EmojiGridColumns {
        didSet { Stored.emojiGridColumns.store(emojiGridColumns, in: defaults) }
    }

    /// How long a closed palette keeps its state before popping back to the root launcher.
    var popToRootTimeout: PopToRootTimeout {
        didSet { Stored.popToRootTimeout.store(popToRootTimeout, in: defaults) }
    }

    var escapeKeyBehavior: EscapeKeyBehavior {
        didSet { Stored.escapeKeyBehavior.store(escapeKeyBehavior, in: defaults) }
    }

    /// Follow macOS, or pin Tinycast to one appearance. Applied by `AppCore.applyAppearance()`.
    var appearance: AppAppearance {
        didSet { Stored.appearance.store(appearance, in: defaults) }
    }

    /// The per-app key System Settings writes too, so the two never disagree.
    var language: AppLanguage {
        didSet { defaults.set([language.rawValue], forKey: Key.language.rawValue) }
    }

    /// Which separators the calculator reads and writes; `.system` follows Language & Region.
    var calcNumberStyle: CalcNumberStyle {
        didSet { Stored.calcNumberStyle.store(calcNumberStyle, in: defaults) }
    }

    var typography: AppTypography {
        didSet { Stored.typography.store(typography, in: defaults) }
    }

    var interfaceMetrics: InterfaceMetrics {
        InterfaceMetrics(scale: interfaceSize.scale, typographyStyle: typography)
    }

    var interfaceSize: InterfaceSize {
        didSet {
            Stored.interfaceSize.store(interfaceSize, in: defaults)
            let shift = Double(
                (oldValue.metrics.size.panelWidth - interfaceSize.metrics.size.panelWidth) / 2)
            if shift != 0 {
                palettePositions = palettePositions.mapValues { offset in
                    offset.count == 2 ? [offset[0] + shift, offset[1]] : offset
                }
            }
        }
    }

    /// Summon the launcher as a slim search bar that expands into the full list on typing.
    var compactMode: Bool {
        didSet { Stored.compactMode.store(compactMode, in: defaults) }
    }

    var compactBarCommands: [CommandID] {
        didSet { Stored.compactBarCommands.store(compactBarCommands, in: defaults) }
    }

    /// Summon the palette on the display under the pointer instead of the one holding the menu bar.
    var openOnCursorScreen: Bool {
        didSet { Stored.openOnCursorScreen.store(openOnCursorScreen, in: defaults) }
    }

    var dictionaryRecentSources: [String] {
        didSet { Stored.dictionaryRecentSources.store(dictionaryRecentSources, in: defaults) }
    }

    var dictionaryPreferredSource: String {
        didSet { Stored.dictionaryPreferredSource.store(dictionaryPreferredSource, in: defaults) }
    }

    var dictionaryPronunciationSource: String {
        didSet { Stored.dictionaryPronunciationSource.store(dictionaryPronunciationSource, in: defaults) }
    }

    var dictionaryPronunciationSlow: Bool {
        didSet { Stored.dictionaryPronunciationSlow.store(dictionaryPronunciationSlow, in: defaults) }
    }

    var dictionaryPronunciationVoice: String {
        didSet { Stored.dictionaryPronunciationVoice.store(dictionaryPronunciationVoice, in: defaults) }
    }

    var dictionaryPronunciationAccent: String {
        didSet { Stored.dictionaryPronunciationAccent.store(dictionaryPronunciationAccent, in: defaults) }
    }

    var autoSwitchInputSourceID: String? {
        didSet { Stored.autoSwitchInputSourceID.store(autoSwitchInputSourceID, in: defaults) }
    }

    /// Lets the panel be dragged by its top edge; off by default, so most launches never grab it.
    var paletteDraggable: Bool {
        didSet { Stored.paletteDraggable.store(paletteDraggable, in: defaults) }
    }

    /// Off, every surface changes at once; on, Reduce Motion still trims movement where it did.
    var animationsEnabled: Bool {
        didSet { Stored.animationsEnabled.store(animationsEnabled, in: defaults) }
    }

    /// Where a drag left the panel's top-left, per display and relative to it.
    var palettePositions: [String: [Double]] {
        didSet { Stored.palettePositions.store(palettePositions, in: defaults) }
    }

    var paletteExpandedCenterDisplays: Set<String> {
        didSet { Stored.paletteExpandedCenterDisplays.store(paletteExpandedCenterDisplays, in: defaults) }
    }

    func palettePosition(on display: String) -> CGPoint? {
        palettePositions[display].flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    func setPalettePosition(_ offset: CGPoint?, on display: String, expandedCenter: Bool) {
        if offset != nil && expandedCenter {
            paletteExpandedCenterDisplays.insert(display)
        } else {
            paletteExpandedCenterDisplays.remove(display)
        }
        guard let offset else {
            palettePositions.removeValue(forKey: display)
            return
        }
        palettePositions[display] = [offset.x, offset.y]
    }

    // Feature switches, off out of the box, and off means fully off.
    var fileSearchEnabled: Bool {
        didSet { Stored.fileSearchEnabled.store(fileSearchEnabled, in: defaults) }
    }

    /// Tilde-abbreviated, so a backup taken on one machine still points somewhere on another.
    var fileSearchScopes: [String] {
        didSet { Stored.fileSearchScopes.store(fileSearchScopes, in: defaults) }
    }

    /// Only what the user added; the shipped rules are compiled into `FileSearchIgnoreList`.
    var fileSearchIgnorePatterns: [String] {
        didSet { Stored.fileSearchIgnorePatterns.store(fileSearchIgnorePatterns, in: defaults) }
    }

    var fileSearchRemovedDefaultPatterns: [String] {
        didSet { Stored.fileSearchRemovedDefaultPatterns.store(fileSearchRemovedDefaultPatterns, in: defaults) }
    }

    var fileSearchEffectiveIgnorePatterns: [String] {
        FileSearchIgnoreList.patterns(
            added: fileSearchIgnorePatterns, removedDefaults: fileSearchRemovedDefaultPatterns)
    }

    var fileSearchDocumentContentEnabled: Bool {
        didSet { Stored.fileSearchDocumentContentEnabled.store(fileSearchDocumentContentEnabled, in: defaults) }
    }

    var fileSearchImageContentEnabled: Bool {
        didSet { Stored.fileSearchImageContentEnabled.store(fileSearchImageContentEnabled, in: defaults) }
    }
    var fileSearchShowInLauncher: Bool {
        didSet { Stored.fileSearchShowInLauncher.store(fileSearchShowInLauncher, in: defaults) }
    }

    var notesEnabled: Bool {
        didSet { Stored.notesEnabled.store(notesEnabled, in: defaults) }
    }

    var dictationEnabled: Bool {
        didSet { Stored.dictationEnabled.store(dictationEnabled, in: defaults) }
    }

    var dictationModel: DictationModel {
        didSet { Stored.dictationModel.store(dictationModel, in: defaults) }
    }

    var dictationUsesApple: Bool {
        didSet { Stored.dictationUsesApple.store(dictationUsesApple, in: defaults) }
    }

    var dictationRemovesFillerWords: Bool {
        didSet { Stored.dictationRemovesFillerWords.store(dictationRemovesFillerWords, in: defaults) }
    }

    var dictationCleanupEngine: String {
        didSet { Stored.dictationCleanupEngine.store(dictationCleanupEngine, in: defaults) }
    }

    var dictationSmartCleanup: Bool {
        didSet { Stored.dictationSmartCleanup.store(dictationSmartCleanup, in: defaults) }
    }

    var dictationAdvancedCleanup: Bool {
        didSet { Stored.dictationAdvancedCleanup.store(dictationAdvancedCleanup, in: defaults) }
    }

    var dictationCleanupMode: DictationCleanupMode {
        get {
            if dictationSmartCleanup { return .smart }
            if dictationAdvancedCleanup { return .advanced }
            return dictationRemovesFillerWords ? .basic : .off
        }
        set {
            dictationSmartCleanup = newValue == .smart
            dictationAdvancedCleanup = newValue == .advanced
            dictationRemovesFillerWords = newValue != .off
        }
    }

    var dictationAutoTransform: Bool {
        didSet { Stored.dictationAutoTransform.store(dictationAutoTransform, in: defaults) }
    }

    var dictationTransformID: String {
        didSet { Stored.dictationTransformID.store(dictationTransformID, in: defaults) }
    }

    var dictationAppOverrides: [String: [String: String]] {
        didSet { Stored.dictationAppOverrides.store(dictationAppOverrides, in: defaults) }
    }

    /// Nil lets macOS follow the system input device as it changes.
    var dictationMicrophone: String? {
        didSet { Stored.dictationMicrophone.store(dictationMicrophone, in: defaults) }
    }

    var dictationAdaptsCapitalization: Bool {
        didSet { Stored.dictationAdaptsCapitalization.store(dictationAdaptsCapitalization, in: defaults) }
    }

    var dictationHistoryRetention: ClipboardRetention {
        didSet { Stored.dictationHistoryRetention.store(dictationHistoryRetention, in: defaults) }
    }

    var dictationPlaysSounds: Bool {
        didSet { Stored.dictationPlaysSounds.store(dictationPlaysSounds, in: defaults) }
    }

    var dictationIndicatorStyle: DictationIndicatorStyle {
        didSet { Stored.dictationIndicatorStyle.store(dictationIndicatorStyle, in: defaults) }
    }

    var dictationIndicatorPositions: [String: [Double]] {
        didSet { Stored.dictationIndicatorPositions.store(dictationIndicatorPositions, in: defaults) }
    }

    var dictationLivePreview: Bool {
        didSet { Stored.dictationLivePreview.store(dictationLivePreview, in: defaults) }
    }

    var dictationTwoLinePreview: Bool {
        didSet { Stored.dictationTwoLinePreview.store(dictationTwoLinePreview, in: defaults) }
    }

    var dictationAnimateTranscript: Bool {
        didSet { Stored.dictationAnimateTranscript.store(dictationAnimateTranscript, in: defaults) }
    }

    var dictationIdleIndicator: Bool {
        didSet { Stored.dictationIdleIndicator.store(dictationIdleIndicator, in: defaults) }
    }

    var dictationIdleRelease: DictationIdleRelease {
        didSet { Stored.dictationIdleRelease.store(dictationIdleRelease, in: defaults) }
    }

    var dictationLanguage: String? {
        didSet { Stored.dictationLanguage.store(dictationLanguage, in: defaults) }
    }

    var notesRendersMarkdown: Bool {
        didSet { Stored.notesRendersMarkdown.store(notesRendersMarkdown, in: defaults) }
    }

    var notesShowsFormattingBar: Bool {
        didSet { Stored.notesShowsFormattingBar.store(notesShowsFormattingBar, in: defaults) }
    }

    var notesShowsInMenuBar: Bool {
        didSet { Stored.notesShowsInMenuBar.store(notesShowsInMenuBar, in: defaults) }
    }

    /// The notes folder as the user wrote it, `~` allowed; nil keeps it in Application Support.
    var notesFolder: String? {
        didSet { Stored.notesFolder.store(notesFolder, in: defaults) }
    }

    /// Off by default: connecting a server is consent to run code Tinycast did not write.
    var mcpEnabled: Bool {
        didSet { Stored.mcpEnabled.store(mcpEnabled, in: defaults) }
    }
    var aiEnabled: Bool {
        didSet { Stored.aiEnabled.store(aiEnabled, in: defaults) }
    }

    var customCommandsEnabled: Bool {
        didSet { Stored.customCommandsEnabled.store(customCommandsEnabled, in: defaults) }
    }

    /// With the feature on, controls only whether its launcher section appears.
    var customCommandsShowInLauncher: Bool {
        didSet { Stored.customCommandsShowInLauncher.store(customCommandsShowInLauncher, in: defaults) }
    }

    /// Also keyword-expansion consent, so it confirms first and never rides a backup.
    var snippetsEnabled: Bool {
        didSet { Stored.snippetsEnabled.store(snippetsEnabled, in: defaults) }
    }

    /// Off out of the box: on means Tinycast may read a selection anywhere and type over it.
    var quickActionsEnabled: Bool {
        didSet { Stored.quickActionsEnabled.store(quickActionsEnabled, in: defaults) }
    }

    var snippetsShowInLauncher: Bool {
        didSet { Stored.snippetsShowInLauncher.store(snippetsShowInLauncher, in: defaults) }
    }

    /// The snippets folder as the user wrote it, `~` allowed; nil keeps it in Application Support.
    var snippetsFolder: String? {
        didSet { Stored.snippetsFolder.store(snippetsFolder, in: defaults) }
    }

    var navigationEnabled: Bool {
        didSet { Stored.navigationEnabled.store(navigationEnabled, in: defaults) }
    }

    var menuSearchDisabledApps: [String] {
        didSet { Stored.menuSearchDisabledApps.store(menuSearchDisabledApps, in: defaults) }
    }

    /// Off: the Apple menu is the same on every app, so it would only pad every snapshot.
    var menuSearchShowsAppleMenu: Bool {
        didSet { Stored.menuSearchShowsAppleMenu.store(menuSearchShowsAppleMenu, in: defaults) }
    }

    /// Consent to run third-party JavaScript: it confirms, defaults off, rides no backup.
    var extensionsEnabled: Bool {
        didSet { Stored.extensionsEnabled.store(extensionsEnabled, in: defaults) }
    }

    var extensionsShowInLauncher: Bool {
        didSet { Stored.extensionsShowInLauncher.store(extensionsShowInLauncher, in: defaults) }
    }

    /// Only an install from GitHub needs one — the store serves extensions already built.
    var extensionPackageManager: ExtensionPackageManager {
        didSet { Stored.extensionPackageManager.store(extensionPackageManager, in: defaults) }
    }

    /// For a toolchain Tinycast doesn't know — mise or Nix shims are the common case.
    var extensionCustomSearchPaths: [String] {
        didSet { Stored.extensionCustomSearchPaths.store(extensionCustomSearchPaths, in: defaults) }
    }

    /// Doubles as calendar-access consent, so only `CalendarCoordinator` may write it.
    var calendarEnabled: Bool {
        didSet { Stored.calendarEnabled.store(calendarEnabled, in: defaults) }
    }

    var calendarShowInLauncher: Bool {
        didSet { Stored.calendarShowInLauncher.store(calendarShowInLauncher, in: defaults) }
    }

    var calendarLauncherLimit: CalendarLauncherLimit {
        didSet { Stored.calendarLauncherLimit.store(calendarLauncherLimit, in: defaults) }
    }

    /// Narrows the fetch itself rather than what is shown, so every surface reads the same days.
    var calendarSpan: MeetingSpan {
        didSet { Stored.calendarSpan.store(calendarSpan, in: defaults) }
    }

    var joinWindowMinutes: JoinWindow {
        didSet { Stored.joinWindowMinutes.store(joinWindowMinutes, in: defaults) }
    }

    /// Arms the app to open meeting links unattended, so only the Calendar pane's switch writes it.
    var autoJoinMeetings: Bool {
        didSet { Stored.autoJoinMeetings.store(autoJoinMeetings, in: defaults) }
    }

    var autoJoinConfirms: Bool {
        didSet { Stored.autoJoinConfirms.store(autoJoinConfirms, in: defaults) }
    }

    var autoJoinNamedProvidersOnly: Bool {
        didSet { Stored.autoJoinNamedProvidersOnly.store(autoJoinNamedProvidersOnly, in: defaults) }
    }

    /// Doubles as camera consent, so only the Calendar pane's switch writes it.
    var cameraPreview: Bool {
        didSet { Stored.cameraPreview.store(cameraPreview, in: defaults) }
    }

    /// Nil opens meeting links in the default browser.
    var meetingBrowserBundleID: String? {
        didSet { Stored.meetingBrowserBundleID.store(meetingBrowserBundleID, in: defaults) }
    }

    var menuBarEvents: MenuBarEvents {
        didSet { Stored.menuBarEvents.store(menuBarEvents, in: defaults) }
    }

    var calendarMenuBarDisplay: CalendarMenuBarDisplay {
        didSet { Stored.calendarMenuBarDisplay.store(calendarMenuBarDisplay, in: defaults) }
    }

    var menuBarLinkedEventsOnly: Bool {
        didSet { Stored.menuBarLinkedEventsOnly.store(menuBarLinkedEventsOnly, in: defaults) }
    }

    var calendarMenuBarHidesWhenEmpty: Bool {
        didSet { Stored.calendarMenuBarHidesWhenEmpty.store(calendarMenuBarHidesWhenEmpty, in: defaults) }
    }

    var hideCurrentEvent: HideCurrentEvent {
        didSet { Stored.hideCurrentEvent.store(hideCurrentEvent, in: defaults) }
    }

    /// Off means fully off: no launcher entries, and a still-registered shortcut moves nothing.
    var windowManagementEnabled: Bool {
        didSet { Stored.windowManagementEnabled.store(windowManagementEnabled, in: defaults) }
    }

    var windowManagementShowInLauncher: Bool {
        didSet { Stored.windowManagementShowInLauncher.store(windowManagementShowInLauncher, in: defaults) }
    }

    /// Points between tiled windows and the screen edge; `WindowPlacementEngine` caps it.
    var windowGap: Int {
        didSet { Stored.windowGap.store(windowGap, in: defaults) }
    }

    /// Its own flag: hiding 34 command rows must not also hide the layouts you wrote.
    var windowLayoutsShowInLauncher: Bool {
        didSet { Stored.windowLayoutsShowInLauncher.store(windowLayoutsShowInLauncher, in: defaults) }
    }

    var windowRoomsShowInLauncher: Bool {
        didSet { Stored.windowRoomsShowInLauncher.store(windowRoomsShowInLauncher, in: defaults) }
    }

    /// What re-triggering a half does: nothing, step its size, or walk it across the displays.
    var windowCycle: WindowCycle {
        didSet { Stored.windowCycle.store(windowCycle, in: defaults) }
    }

    var windowWrapsDisplays: Bool {
        didSet { Stored.windowWrapsDisplays.store(windowWrapsDisplays, in: defaults) }
    }

    var windowKeepsProportions: Bool {
        didSet { Stored.windowKeepsProportions.store(windowKeepsProportions, in: defaults) }
    }

    /// Off means fully off, down to a still-registered shortcut opening nothing.
    var quicklinksEnabled: Bool {
        didSet { Stored.quicklinksEnabled.store(quicklinksEnabled, in: defaults) }
    }

    var quicklinksShowInLauncher: Bool {
        didSet { Stored.quicklinksShowInLauncher.store(quicklinksShowInLauncher, in: defaults) }
    }

    /// Off means the Shortcuts tool is never run, down to a bound shortcut running nothing.
    var appleShortcutsEnabled: Bool {
        didSet { Stored.appleShortcutsEnabled.store(appleShortcutsEnabled, in: defaults) }
    }

    /// Ask for a new window rather than a tab; off is the macOS default.
    var quicklinkOpensNewWindow: Bool {
        didSet { Stored.quicklinkOpensNewWindow.store(quicklinkOpensNewWindow, in: defaults) }
    }

    var quicklinkPassesSelectedText: Bool {
        didSet { Stored.quicklinkPassesSelectedText.store(quicklinkPassesSelectedText, in: defaults) }
    }

    var quicklinkConfirmsBeforeDelete: Bool {
        didSet { Stored.quicklinkConfirmsBeforeDelete.store(quicklinkConfirmsBeforeDelete, in: defaults) }
    }

    /// Whether the support window may reopen itself; off means never ask again.
    var supportRemindersEnabled: Bool {
        didSet { Stored.supportRemindersEnabled.store(supportRemindersEnabled, in: defaults) }
    }

    /// Whether settings.json mirrors these settings; `AppCore` starts and stops the mirror.
    var settingsFileEnabled: Bool {
        didSet { Stored.settingsFileEnabled.store(settingsFileEnabled, in: defaults) }
    }

    /// Rows a link from outside may run without asking; only `DeepLinkCoordinator` adds to it.
    var allowedDeepLinks: [String] {
        didSet { Stored.allowedDeepLinks.store(allowedDeepLinks, in: defaults) }
    }

    /// With no per-app list the bundle follows macOS's languages, so this runs before any lookup.
    static func pinLanguage() {
        UserDefaults.standard.set([storedLanguage.rawValue], forKey: Key.language.rawValue)
    }

    /// The app's own domain only: a plain read falls through to the global list.
    private static var storedLanguage: AppLanguage {
        AppLanguage(
            storedPreferences: AppPaths.preferences.persistentDomain(forName: AppPaths.storageIdentifier)?[Key.language.rawValue]
                as? [String], systemPreferences: SystemLanguages.preferred)
    }

    init() {
        searchScopes = Stored.searchScopes.load(from: defaults)
        launcherShowsSuggestions = Stored.launcherShowsSuggestions.load(from: defaults)
        rootSearchSensitivity = Stored.rootSearchSensitivity.load(from: defaults)
        clipboardEnabled = Stored.clipboardEnabled.load(from: defaults)
        clipboardTextSearchEnabled = Stored.clipboardTextSearchEnabled.load(from: defaults)
        clipboardRetention = Stored.clipboardRetention.load(from: defaults)
        clipboardDisabledApps = Stored.clipboardDisabledApps.load(from: defaults)
        clipboardDefaultAction = Stored.clipboardDefaultAction.load(from: defaults)
        launchAtLogin = Stored.launchAtLogin.load(from: defaults)
        showInMenuBar = Stored.showInMenuBar.load(from: defaults)
        automaticallyCheckForUpdates = Stored.automaticallyCheckForUpdates.load(from: defaults)
        hyperKey = Stored.hyperKey.load(from: defaults)
        hyperKeyIncludesShift = Stored.hyperKeyIncludesShift.load(from: defaults)
        hyperKeyQuickPress = Stored.hyperKeyQuickPress.load(from: defaults)
        hyperKeySecureInputCompatibility = Stored.hyperKeySecureInputCompatibility.load(from: defaults)
        emojiSkinTone = Stored.emojiSkinTone.load(from: defaults)
        emojiGridColumns = Stored.emojiGridColumns.load(from: defaults)
        popToRootTimeout = Stored.popToRootTimeout.load(from: defaults)
        escapeKeyBehavior = Stored.escapeKeyBehavior.load(from: defaults)
        appearance = Stored.appearance.load(from: defaults)
        language = Self.storedLanguage
        calcNumberStyle = Stored.calcNumberStyle.load(from: defaults)
        typography = Stored.typography.load(from: defaults)
        interfaceSize = Stored.interfaceSize.load(from: defaults)
        compactMode = Stored.compactMode.load(from: defaults)
        compactBarCommands = Stored.compactBarCommands.load(from: defaults)
        openOnCursorScreen = Stored.openOnCursorScreen.load(from: defaults)
        dictionaryRecentSources = Stored.dictionaryRecentSources.load(from: defaults)
        dictionaryPreferredSource = Stored.dictionaryPreferredSource.load(from: defaults)
        dictionaryPronunciationSource = Stored.dictionaryPronunciationSource.load(from: defaults)
        dictionaryPronunciationSlow = Stored.dictionaryPronunciationSlow.load(from: defaults)
        dictionaryPronunciationVoice = Stored.dictionaryPronunciationVoice.load(from: defaults)
        dictionaryPronunciationAccent = Stored.dictionaryPronunciationAccent.load(from: defaults)
        autoSwitchInputSourceID = Stored.autoSwitchInputSourceID.load(from: defaults)
        paletteDraggable = Stored.paletteDraggable.load(from: defaults)
        animationsEnabled = Stored.animationsEnabled.load(from: defaults)
        palettePositions = Stored.palettePositions.load(from: defaults)
        paletteExpandedCenterDisplays = Stored.paletteExpandedCenterDisplays.load(from: defaults)
        fileSearchEnabled = Stored.fileSearchEnabled.load(from: defaults)
        fileSearchScopes = Stored.fileSearchScopes.load(from: defaults)
        fileSearchIgnorePatterns = Stored.fileSearchIgnorePatterns.load(from: defaults)
        fileSearchRemovedDefaultPatterns = Stored.fileSearchRemovedDefaultPatterns.load(from: defaults)
        fileSearchDocumentContentEnabled = Stored.fileSearchDocumentContentEnabled.load(from: defaults)
        fileSearchImageContentEnabled = Stored.fileSearchImageContentEnabled.load(from: defaults)
        fileSearchShowInLauncher = Stored.fileSearchShowInLauncher.load(from: defaults)
        notesEnabled = Stored.notesEnabled.load(from: defaults)
        dictationEnabled = Stored.dictationEnabled.load(from: defaults)
        dictationModel = Stored.dictationModel.load(from: defaults)
        dictationUsesApple = Stored.dictationUsesApple.load(from: defaults)
        dictationRemovesFillerWords = Stored.dictationRemovesFillerWords.load(from: defaults)
        dictationCleanupEngine = Stored.dictationCleanupEngine.load(from: defaults)
        dictationSmartCleanup = Stored.dictationSmartCleanup.load(from: defaults)
        dictationAdvancedCleanup = Stored.dictationAdvancedCleanup.load(from: defaults)
        dictationAutoTransform = Stored.dictationAutoTransform.load(from: defaults)
        dictationTransformID = Stored.dictationTransformID.load(from: defaults)
        dictationAppOverrides = Stored.dictationAppOverrides.load(from: defaults)
        dictationMicrophone = Stored.dictationMicrophone.load(from: defaults)
        dictationAdaptsCapitalization = Stored.dictationAdaptsCapitalization.load(from: defaults)
        dictationHistoryRetention = Stored.dictationHistoryRetention.load(from: defaults)
        dictationPlaysSounds = Stored.dictationPlaysSounds.load(from: defaults)
        dictationIndicatorStyle = Stored.dictationIndicatorStyle.load(from: defaults)
        dictationIndicatorPositions = Stored.dictationIndicatorPositions.load(from: defaults)
        dictationLivePreview = Stored.dictationLivePreview.load(from: defaults)
        dictationTwoLinePreview = Stored.dictationTwoLinePreview.load(from: defaults)
        dictationAnimateTranscript = Stored.dictationAnimateTranscript.load(from: defaults)
        dictationIdleIndicator = Stored.dictationIdleIndicator.load(from: defaults)
        dictationIdleRelease = Stored.dictationIdleRelease.load(from: defaults)
        dictationLanguage = Stored.dictationLanguage.load(from: defaults)
        notesRendersMarkdown = Stored.notesRendersMarkdown.load(from: defaults)
        notesShowsFormattingBar = Stored.notesShowsFormattingBar.load(from: defaults)
        notesShowsInMenuBar = Stored.notesShowsInMenuBar.load(from: defaults)
        notesFolder = Stored.notesFolder.load(from: defaults)
        mcpEnabled = Stored.mcpEnabled.load(from: defaults)
        aiEnabled = Stored.aiEnabled.load(from: defaults)
        customCommandsEnabled = Stored.customCommandsEnabled.load(from: defaults)
        customCommandsShowInLauncher = Stored.customCommandsShowInLauncher.load(from: defaults)
        snippetsEnabled = Stored.snippetsEnabled.load(from: defaults)
        quickActionsEnabled = Stored.quickActionsEnabled.load(from: defaults)
        snippetsShowInLauncher = Stored.snippetsShowInLauncher.load(from: defaults)
        snippetsFolder = Stored.snippetsFolder.load(from: defaults)
        navigationEnabled = Stored.navigationEnabled.load(from: defaults)
        menuSearchDisabledApps = Stored.menuSearchDisabledApps.load(from: defaults)
        menuSearchShowsAppleMenu = Stored.menuSearchShowsAppleMenu.load(from: defaults)
        extensionsEnabled = Stored.extensionsEnabled.load(from: defaults)
        extensionsShowInLauncher = Stored.extensionsShowInLauncher.load(from: defaults)
        extensionPackageManager = Stored.extensionPackageManager.load(from: defaults)
        extensionCustomSearchPaths = Stored.extensionCustomSearchPaths.load(from: defaults)
        calendarEnabled = Stored.calendarEnabled.load(from: defaults)
        calendarShowInLauncher = Stored.calendarShowInLauncher.load(from: defaults)
        calendarLauncherLimit = Stored.calendarLauncherLimit.load(from: defaults)
        calendarSpan = Stored.calendarSpan.load(from: defaults)
        joinWindowMinutes = Stored.joinWindowMinutes.load(from: defaults)
        autoJoinMeetings = Stored.autoJoinMeetings.load(from: defaults)
        autoJoinConfirms = Stored.autoJoinConfirms.load(from: defaults)
        autoJoinNamedProvidersOnly = Stored.autoJoinNamedProvidersOnly.load(from: defaults)
        cameraPreview = Stored.cameraPreview.load(from: defaults)
        meetingBrowserBundleID = Stored.meetingBrowserBundleID.load(from: defaults)
        menuBarEvents = Stored.menuBarEvents.load(from: defaults)
        calendarMenuBarDisplay = Stored.calendarMenuBarDisplay.load(from: defaults)
        menuBarLinkedEventsOnly = Stored.menuBarLinkedEventsOnly.load(from: defaults)
        calendarMenuBarHidesWhenEmpty = Stored.calendarMenuBarHidesWhenEmpty.load(from: defaults)
        hideCurrentEvent = Stored.hideCurrentEvent.load(from: defaults)
        windowManagementEnabled = Stored.windowManagementEnabled.load(from: defaults)
        windowManagementShowInLauncher = Stored.windowManagementShowInLauncher.load(from: defaults)
        windowGap = Stored.windowGap.load(from: defaults)
        windowLayoutsShowInLauncher = Stored.windowLayoutsShowInLauncher.load(from: defaults)
        windowRoomsShowInLauncher = Stored.windowRoomsShowInLauncher.load(from: defaults)
        windowCycle = Stored.windowCycle.load(from: defaults)
        windowWrapsDisplays = Stored.windowWrapsDisplays.load(from: defaults)
        windowKeepsProportions = Stored.windowKeepsProportions.load(from: defaults)
        quicklinksEnabled = Stored.quicklinksEnabled.load(from: defaults)
        quicklinksShowInLauncher = Stored.quicklinksShowInLauncher.load(from: defaults)
        appleShortcutsEnabled = Stored.appleShortcutsEnabled.load(from: defaults)
        quicklinkOpensNewWindow = Stored.quicklinkOpensNewWindow.load(from: defaults)
        quicklinkPassesSelectedText = Stored.quicklinkPassesSelectedText.load(from: defaults)
        quicklinkConfirmsBeforeDelete = Stored.quicklinkConfirmsBeforeDelete.load(from: defaults)
        supportRemindersEnabled = Stored.supportRemindersEnabled.load(from: defaults)
        settingsFileEnabled = Stored.settingsFileEnabled.load(from: defaults)
        allowedDeepLinks = Stored.allowedDeepLinks.load(from: defaults)
    }
}

/// Every persisted preference: its key, its default and how it is stored.
@MainActor
private enum Stored {
    typealias Key = AppSettingsKey

    static let searchScopes = Preference<[String]>(Key.searchScopes.rawValue, default: SearchScopes.defaults)
    static let launcherShowsSuggestions = Preference<Bool>(
        Key.launcherShowsSuggestions.rawValue, default: true)
    static let rootSearchSensitivity = Preference<SearchSensitivity>(
        Key.rootSearchSensitivity.rawValue, default: .default)
    static let clipboardEnabled = Preference<Bool>(Key.clipboardEnabled.rawValue, default: true)
    static let clipboardTextSearchEnabled = Preference<Bool>(
        Key.clipboardTextSearchEnabled.rawValue, default: false)
    static let clipboardRetention = Preference<ClipboardRetention>(
        Key.clipboardRetention.rawValue, default: .threeMonths)
    /// Password managers ship excluded, until the user first edits the list.
    static let clipboardDisabledApps = Preference<[String]>(
        Key.clipboardDisabledApps.rawValue, default: ["com.apple.keychainaccess", "com.apple.Passwords"])
    static let clipboardDefaultAction = Preference<ClipboardDefaultAction>(
        Key.clipboardDefaultAction.rawValue, default: .paste)
    static let launchAtLogin = Preference<Bool>(Key.launchAtLogin.rawValue, default: true)
    static let showInMenuBar = Preference<Bool>(Key.showInMenuBar.rawValue, default: true)
    static let automaticallyCheckForUpdates = Preference<Bool>(
        Key.automaticallyCheckForUpdates.rawValue, default: true)
    static let hyperKey = Preference<HyperKeyPhysicalKey>(Key.hyperKey.rawValue, default: .none)
    static let hyperKeyIncludesShift = Preference<Bool>(Key.hyperKeyIncludesShift.rawValue, default: true)
    static let hyperKeyQuickPress = Preference<HyperKeyQuickPress>(
        Key.hyperKeyQuickPress.rawValue, default: .none)
    static let hyperKeySecureInputCompatibility = Preference<Bool>(
        Key.hyperKeySecureInputCompatibility.rawValue, default: false)
    static let emojiSkinTone = Preference<EmojiSkinTone>(Key.emojiSkinTone.rawValue, default: .none)
    static let emojiGridColumns = Preference<EmojiGridColumns>(
        Key.emojiGridColumns.rawValue, default: .default)
    static let popToRootTimeout = Preference<PopToRootTimeout>(
        Key.popToRootTimeout.rawValue, default: .afterNinety)
    static let escapeKeyBehavior = Preference<EscapeKeyBehavior>(
        Key.escapeKeyBehavior.rawValue, default: .navigateBackOrClose)
    static let appearance = Preference<AppAppearance>(Key.appearance.rawValue, default: .system)
    static let calcNumberStyle = Preference<CalcNumberStyle>(Key.calcNumberStyle.rawValue, default: .system)
    static let typography = Preference<AppTypography>(Key.typography.rawValue, default: .system)
    static let interfaceSize = Preference<InterfaceSize>(Key.interfaceSize.rawValue, default: .standard)
    static let compactMode = Preference<Bool>(Key.compactMode.rawValue, default: false)
    static let compactBarCommands = Preference<[CommandID]>(
        Key.compactBarCommands.rawValue, default: CommandID.defaultCompactBarCommands,
        read: { $0.stringArray(forKey: $1).flatMap(CommandID.compactBarCommands(from:)) },
        write: { $0.set($2.map(\.rawValue), forKey: $1) })
    static let openOnCursorScreen = Preference<Bool>(Key.openOnCursorScreen.rawValue, default: true)
    static let dictionaryRecentSources = Preference<[String]>(
        Key.dictionaryRecentSources.rawValue, default: [],
        read: { $0.stringArray(forKey: $1).map { Array($0.prefix(12)) } },
        write: { $0.set($2, forKey: $1) })
    static let dictionaryPreferredSource = Preference<String>(
        Key.dictionaryPreferredSource.rawValue, default: "")
    static let dictionaryPronunciationSource = Preference<String>(
        Key.dictionaryPronunciationSource.rawValue, default: "nativeSpeech")
    static let dictionaryPronunciationSlow = Preference<Bool>(
        Key.dictionaryPronunciationSlow.rawValue, default: false)
    static let dictionaryPronunciationVoice = Preference<String>(
        Key.dictionaryPronunciationVoice.rawValue, default: "")
    static let dictionaryPronunciationAccent = Preference<String>(
        Key.dictionaryPronunciationAccent.rawValue, default: "")
    static let autoSwitchInputSourceID = Preference<String?>(Key.autoSwitchInputSource.rawValue)
    static let paletteDraggable = Preference<Bool>(Key.paletteDraggable.rawValue, default: false)
    static let animationsEnabled = Preference<Bool>(Key.animationsEnabled.rawValue, default: true)
    static let palettePositions = Preference<[String: [Double]]>(Key.palettePosition.rawValue, default: [:])
    static let paletteExpandedCenterDisplays = Preference<Set<String>>(
        Key.paletteExpandedCenterDisplays.rawValue, default: [],
        read: { $0.stringArray(forKey: $1).map(Set.init) }, write: { $0.set(Array($2), forKey: $1) })
    static let fileSearchEnabled = Preference<Bool>(Key.fileSearchEnabled.rawValue, default: false)
    /// Unset seeds home; a stored empty array is a cleared list that searches nothing.
    static let fileSearchScopes = Preference<[String]>(
        Key.fileSearchScopes.rawValue, default: FileSearchScope.defaultScopes)
    static let fileSearchIgnorePatterns = Preference<[String]>(
        Key.fileSearchIgnorePatterns.rawValue, default: [])
    static let fileSearchRemovedDefaultPatterns = Preference<[String]>(
        Key.fileSearchRemovedDefaultPatterns.rawValue, default: [])
    static let fileSearchDocumentContentEnabled = Preference<Bool>(
        Key.fileSearchDocumentContentEnabled.rawValue, default: false)
    static let fileSearchImageContentEnabled = Preference<Bool>(
        Key.fileSearchImageContentEnabled.rawValue, default: false)
    static let fileSearchShowInLauncher = Preference<Bool>(
        Key.fileSearchShowInLauncher.rawValue, default: true)
    static let notesEnabled = Preference<Bool>(Key.notesEnabled.rawValue, default: false)
    static let dictationEnabled = Preference<Bool>(Key.dictationEnabled.rawValue, default: false)
    static let dictationModel = Preference<DictationModel>(
        Key.dictationModel.rawValue, default: DictationModel.Family.parakeet.defaultModel)
    static let dictationUsesApple = Preference<Bool>(Key.dictationUsesApple.rawValue, default: false)
    static let dictationRemovesFillerWords = Preference<Bool>(
        Key.dictationRemovesFillerWords.rawValue, default: true)
    static let dictationCleanupEngine = Preference<String>(
        Key.dictationCleanupEngine.rawValue, default: DictationCleanupModel.Variant.defaultSmart.rawValue)
    static let dictationSmartCleanup = Preference<Bool>(Key.dictationSmartCleanup.rawValue, default: false)
    static let dictationAdvancedCleanup = Preference<Bool>(
        Key.dictationAdvancedCleanup.rawValue, default: false)
    static let dictationAutoTransform = Preference<Bool>(Key.dictationAutoTransform.rawValue, default: false)
    static let dictationAppOverrides = Preference<[String: [String: String]]>(
        Key.dictationAppOverrides.rawValue, default: [:])
    static let dictationTransformID = Preference<String>(
        Key.dictationTransformID.rawValue, default: "D1C70000-0000-4000-8000-000000000001")
    static let dictationMicrophone = Preference<String?>(Key.dictationMicrophone.rawValue)
    static let dictationAdaptsCapitalization = Preference<Bool>(
        Key.dictationAdaptsCapitalization.rawValue, default: true)
    static let dictationHistoryRetention = Preference<ClipboardRetention>(
        Key.dictationHistoryRetention.rawValue, default: .threeMonths)
    static let dictationPlaysSounds = Preference<Bool>(Key.dictationPlaysSounds.rawValue, default: true)
    static let dictationIndicatorStyle = Preference<DictationIndicatorStyle>(
        Key.dictationIndicatorStyle.rawValue, default: .compact)
    static let dictationIndicatorPositions = Preference<[String: [Double]]>(
        Key.dictationIndicatorPositions.rawValue, default: [:])
    static let dictationLivePreview = Preference<Bool>(Key.dictationLivePreview.rawValue, default: false)
    static let dictationTwoLinePreview = Preference<Bool>(
        Key.dictationTwoLinePreview.rawValue, default: false)
    static let dictationAnimateTranscript = Preference<Bool>(
        Key.dictationAnimateTranscript.rawValue, default: true)
    static let dictationIdleIndicator = Preference<Bool>(Key.dictationIdleIndicator.rawValue, default: false)
    static let dictationIdleRelease = Preference<DictationIdleRelease>(
        Key.dictationIdleRelease.rawValue, default: .oneMinute)
    /// A language Tinycast no longer offers reads as nil, so the system language applies.
    static let dictationLanguage = Preference<String?>(
        Key.dictationLanguage.rawValue, default: nil,
        read: { $0.string(forKey: $1).map { DictationLanguage(rawValue: $0)?.rawValue } },
        write: { $0.set($2, forKey: $1) })
    static let notesRendersMarkdown = Preference<Bool>(Key.notesRendersMarkdown.rawValue, default: true)
    static let notesShowsFormattingBar = Preference<Bool>(Key.notesShowsFormattingBar.rawValue, default: true)
    static let notesShowsInMenuBar = Preference<Bool>(Key.notesShowsInMenuBar.rawValue, default: false)
    static let notesFolder = Preference<String?>(Key.notesFolder.rawValue)
    static let mcpEnabled = Preference<Bool>(Key.mcpEnabled.rawValue, default: false)
    static let aiEnabled = Preference<Bool>(Key.aiEnabled.rawValue, default: false)
    static let customCommandsEnabled = Preference<Bool>(Key.customCommandsEnabled.rawValue, default: false)
    static let customCommandsShowInLauncher = Preference<Bool>(
        Key.customCommandsShowInLauncher.rawValue, default: true)
    static let snippetsEnabled = Preference<Bool>(Key.snippetsEnabled.rawValue, default: false)
    static let quickActionsEnabled = Preference<Bool>(Key.quickActionsEnabled.rawValue, default: false)
    static let snippetsShowInLauncher = Preference<Bool>(Key.snippetsShowInLauncher.rawValue, default: true)
    static let snippetsFolder = Preference<String?>(Key.snippetsFolder.rawValue)
    static let navigationEnabled = Preference<Bool>(Key.navigationEnabled.rawValue, default: false)
    static let menuSearchDisabledApps = Preference<[String]>(Key.menuSearchDisabledApps.rawValue, default: [])
    static let menuSearchShowsAppleMenu = Preference<Bool>(
        Key.menuSearchShowsAppleMenu.rawValue, default: false)
    /// Opt-in, unlike its siblings: until it is asked for, nothing about extensions is loaded.
    static let extensionsEnabled = Preference<Bool>(Key.extensionsEnabled.rawValue, default: false)
    static let extensionsShowInLauncher = Preference<Bool>(
        Key.extensionsShowInLauncher.rawValue, default: true)
    static let extensionPackageManager = Preference<ExtensionPackageManager>(
        Key.extensionPackageManager.rawValue, default: .automatic)
    static let extensionCustomSearchPaths = Preference<[String]>(
        Key.extensionCustomSearchPaths.rawValue, default: [])
    /// Opt-in, like extensions: until it is asked for, EventKit is never loaded.
    static let calendarEnabled = Preference<Bool>(Key.calendarEnabled.rawValue, default: false)
    static let calendarShowInLauncher = Preference<Bool>(Key.calendarShowInLauncher.rawValue, default: true)
    static let calendarLauncherLimit = Preference<CalendarLauncherLimit>(
        Key.calendarLauncherLimit.rawValue, default: .five)
    static let calendarSpan = Preference<MeetingSpan>(Key.calendarSpan.rawValue, default: .todayAndTomorrow)
    static let joinWindowMinutes = Preference<JoinWindow>(Key.joinWindowMinutes.rawValue, default: .five)
    static let autoJoinMeetings = Preference<Bool>(Key.autoJoinMeetings.rawValue, default: false)
    static let autoJoinConfirms = Preference<Bool>(Key.autoJoinConfirms.rawValue, default: true)
    static let autoJoinNamedProvidersOnly = Preference<Bool>(
        Key.autoJoinNamedProvidersOnly.rawValue, default: false)
    static let cameraPreview = Preference<Bool>(Key.cameraPreview.rawValue, default: false)
    static let meetingBrowserBundleID = Preference<String?>(Key.meetingBrowser.rawValue)
    static let menuBarEvents = Preference<MenuBarEvents>(Key.menuBarEvents.rawValue, default: .today)
    static let calendarMenuBarDisplay = Preference<CalendarMenuBarDisplay>(
        Key.calendarMenuBarDisplay.rawValue, default: .disabled)
    static let menuBarLinkedEventsOnly = Preference<Bool>(Key.menuBarLinkedEventsOnly.rawValue, default: true)
    static let calendarMenuBarHidesWhenEmpty = Preference<Bool>(
        Key.calendarMenuBarHidesWhenEmpty.rawValue, default: false)
    static let hideCurrentEvent = Preference<HideCurrentEvent>(
        Key.hideCurrentEvent.rawValue, default: .dontHide)
    static let windowManagementEnabled = Preference<Bool>(
        Key.windowManagementEnabled.rawValue, default: false)
    static let windowManagementShowInLauncher = Preference<Bool>(
        Key.windowManagementShowInLauncher.rawValue, default: true)
    static let windowGap = Preference<Int>(Key.windowGap.rawValue, default: 0)
    static let windowLayoutsShowInLauncher = Preference<Bool>(
        Key.windowLayoutsShowInLauncher.rawValue, default: true)
    static let windowRoomsShowInLauncher = Preference<Bool>(
        Key.windowRoomsShowInLauncher.rawValue, default: true)
    static let windowCycle = Preference<WindowCycle>(Key.windowCycle.rawValue, default: .off)
    static let windowWrapsDisplays = Preference<Bool>(Key.windowWrapsDisplays.rawValue, default: true)
    static let windowKeepsProportions = Preference<Bool>(Key.windowKeepsProportions.rawValue, default: true)
    static let quicklinksEnabled = Preference<Bool>(Key.quicklinksEnabled.rawValue, default: false)
    static let quicklinksShowInLauncher = Preference<Bool>(
        Key.quicklinksShowInLauncher.rawValue, default: true)
    static let appleShortcutsEnabled = Preference<Bool>(Key.appleShortcutsEnabled.rawValue, default: false)
    static let quicklinkOpensNewWindow = Preference<Bool>(
        Key.quicklinkOpensNewWindow.rawValue, default: false)
    static let quicklinkPassesSelectedText = Preference<Bool>(
        Key.quicklinkPassesSelectedText.rawValue, default: false)
    static let quicklinkConfirmsBeforeDelete = Preference<Bool>(
        Key.quicklinkConfirmsBeforeDelete.rawValue, default: true)
    static let supportRemindersEnabled = Preference<Bool>(Key.supportReminders.rawValue, default: true)
    static let settingsFileEnabled = Preference<Bool>(Key.settingsFileEnabled.rawValue, default: false)
    static let allowedDeepLinks = Preference<[String]>(Key.allowedDeepLinks.rawValue, default: [])
}
