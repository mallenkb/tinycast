import Foundation

extension AppCore {
    /// What a settings change re-projects onto the running app, outside any view.
    struct FeatureSwitch: Sendable {
        let reads: @Sendable @MainActor (AppSettings) -> Void
        let apply: @Sendable @MainActor (AppCore) -> Void

        init(
            _ reads: @escaping @Sendable @MainActor (AppSettings) -> Void,
            apply: @escaping @Sendable @MainActor (AppCore) -> Void
        ) {
            self.reads = reads
            self.apply = apply
        }
    }

    func observeFeatureSwitches() {
        for featureSwitch in Self.featureSwitches {
            track(featureSwitch.reads, reproject: featureSwitch.apply)
        }
        track(aiSettings, { _ = $0.retention }, reproject: { $0.aiChatCoordinator.applyRetention() })
        track(aiSettings, { _ = $0.launchRevisions }, reproject: { $0.applyInstalledLaunches() })
        trackChatRoute()
    }

    private static let featureSwitches: [FeatureSwitch] = [
        FeatureSwitch(
            { _ = $0.automaticallyCheckForUpdates },
            apply: { $0.updateCoordinator.applyAutomaticChecking() }),
        FeatureSwitch(
            {
                _ = $0.windowManagementEnabled
                _ = $0.windowManagementShowInLauncher
            },
            apply: {
                $0.applyWindowCommandsPresence()
                $0.customWindowSizeCoordinator.applyCustomWindowSizesPresence()
            }),
        FeatureSwitch(
            {
                _ = $0.windowManagementEnabled
                _ = $0.windowLayoutsShowInLauncher
            }, apply: { $0.windowLayoutCoordinator.applyWindowLayoutsPresence() }),
        FeatureSwitch(
            {
                _ = $0.windowManagementEnabled
                _ = $0.windowRoomsShowInLauncher
            }, apply: { $0.roomCoordinator.applyEnabled() }),
        FeatureSwitch(
            {
                _ = $0.customCommandsEnabled
                _ = $0.customCommandsShowInLauncher
            }, apply: { $0.customCommandCoordinator.applyCustomCommandsPresence() }),
        FeatureSwitch(
            {
                _ = $0.quicklinksEnabled
                _ = $0.quicklinksShowInLauncher
            }, apply: { $0.quicklinkCoordinator.applyQuicklinksPresence() }),
        FeatureSwitch(
            { _ = $0.appleShortcutsEnabled }, apply: { $0.appleShortcutCoordinator.applyPresence() }),
        FeatureSwitch({ _ = $0.clipboardEnabled }, apply: { $0.clipboardCoordinator.applyEnabled() }),
        FeatureSwitch({ _ = $0.clipboardTextSearchEnabled }, apply: { $0.applyClipboardTextSearch() }),
        FeatureSwitch({ _ = $0.fileSearchEnabled }, apply: { $0.fileSearchCoordinator.applyEnabled() }),
        FeatureSwitch(
            { _ = $0.fileSearchImageContentEnabled },
            apply: { $0.fileSearchCoordinator.applyImageContent() }),
        FeatureSwitch(
            { _ = $0.fileSearchDocumentContentEnabled },
            apply: { $0.fileSearchCoordinator.applyDocumentContent() }),
        FeatureSwitch(
            { _ = $0.fileSearchShowInLauncher },
            apply: { $0.fileSearchCoordinator.applyLauncherFiles() }),
        // Two features, one switch: each coordinator gates only its own command and mode.
        FeatureSwitch(
            { _ = $0.navigationEnabled },
            apply: {
                $0.windowSwitchCoordinator.applyEnabled()
                $0.menuSearchCoordinator.applyEnabled()
            }),
        FeatureSwitch({ _ = $0.notesEnabled }, apply: { $0.notesCoordinator.applyEnabled() }),
        FeatureSwitch(
            { _ = $0.notesShowsInMenuBar }, apply: { $0.notesCoordinator.applyMenuBarItem() }),
        FeatureSwitch({ _ = $0.aiEnabled }, apply: { $0.aiChatCoordinator.applyEnabled() }),
        FeatureSwitch(
            { _ = $0.dictationIdleRelease },
            apply: { $0.dictationModels.setIdleRelease($0.settings.dictationIdleRelease) }),
        FeatureSwitch(
            {
                _ = $0.dictationEnabled
                _ = $0.dictationIdleIndicator
                _ = $0.dictationIndicatorStyle
                _ = $0.dictationHideIndicatorText
            },
            apply: {
                $0.hotKeys.dictationEnabled = $0.settings.dictationEnabled
                $0.dictationCoordinator.applyIndicatorSettings()
            }),
        FeatureSwitch(
            {
                _ = $0.aiEnabled
                _ = $0.mcpEnabled
            }, apply: { $0.mcpCoordinator.applyEnabled() }),
        FeatureSwitch(
            { _ = $0.quickActionsEnabled }, apply: { $0.quickActionCoordinator.applyEnabled() }),
        FeatureSwitch({ _ = $0.calendarEnabled }, apply: { $0.calendarCoordinator.applyEnabled() }),
        FeatureSwitch(
            {
                _ = $0.calendarShowInLauncher
                _ = $0.calendarLauncherLimit
            }, apply: { $0.calendarCoordinator.publishEntries() }),
        FeatureSwitch({ _ = $0.calendarSpan }, apply: { $0.calendarCoordinator.applySpan() }),
        FeatureSwitch(
            {
                _ = $0.autoJoinMeetings
                _ = $0.menuBarEvents
                _ = $0.calendarMenuBarDisplay
                _ = $0.menuBarLinkedEventsOnly
                _ = $0.hideCurrentEvent
            }, apply: { $0.calendarCoordinator.applyClock() }),
        FeatureSwitch(
            {
                _ = $0.fileSearchScopes
                _ = $0.fileSearchIgnorePatterns
                _ = $0.fileSearchRemovedDefaultPatterns
            }, apply: { $0.fileSearchCoordinator.applyPolicy() }),
        FeatureSwitch(
            { _ = $0.snippetsEnabled }, apply: { $0.snippetCoordinator.applySnippetsEnabled() }),
        // Not a feature switch, but the same re-projection: a combo has the chord's ⇧ bit baked in.
        FeatureSwitch({ _ = $0.hyperKeyIncludesShift }, apply: { $0.applyHyperChord() }),
        FeatureSwitch(
            { _ = $0.snippetsShowInLauncher },
            apply: { $0.snippetCoordinator.applySnippetsLauncherPresence() }),
        FeatureSwitch({ _ = $0.appearance }, apply: { $0.applyAppearance() }),
        FeatureSwitch({ _ = $0.animationsEnabled }, apply: { $0.applyMotion() }),
        FeatureSwitch({ _ = $0.language }, apply: { $0.offerLanguageRelaunch() }),
        FeatureSwitch({ _ = $0.interfaceSize }, apply: { $0.windowController.applyInterfaceSize() }),
        // Settings panes did these on change; settings.json can change them with no pane open.
        FeatureSwitch(
            { _ = $0.clipboardRetention },
            apply: { $0.clipboardCoordinator.applyRetention($0.settings.clipboardRetention) }),
        FeatureSwitch(
            {
                _ = $0.dictationEnabled
                _ = $0.dictationCleanupEngine
            },
            apply: {
                if !$0.settings.dictationEnabled { $0.dictationWriting.cancel() }
                if $0.settings.dictationEnabled {
                    $0.dictationCleanup.stopIfModelChanged(to: $0.dictationWriting.selectedLocalModel)
                } else {
                    $0.dictationCleanup.stop()
                }
            }),
        FeatureSwitch(
            { _ = $0.dictationHistoryRetention },
            apply: { $0.dictationHistory.setRetention($0.settings.dictationHistoryRetention) }),
        FeatureSwitch(
            { _ = $0.extensionsShowInLauncher },
            apply: { $0.extensionCoordinator.applyExtensionsLauncherPresence() }),
        FeatureSwitch({ _ = $0.snippetsFolder }, apply: { $0.applySnippetsFolder() }),
        FeatureSwitch({ _ = $0.notesFolder }, apply: { $0.applyNotesFolder() })
    ]
}
