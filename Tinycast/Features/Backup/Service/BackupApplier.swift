import Foundation

/// Staged bundle → live stores. Everything merges except Launcher Learning, which replaces.
@MainActor
enum BackupApplier {
    struct Summary: Sendable {
        var settings: SettingsBackup.ApplySummary?
        var clipboard = 0
        var snippets = 0
        var snippetsNeedEnabling = false
        var notes = 0
        var learning = 0
        /// Reported rather than thrown: a failure here must not abort the categories after it.
        var problems: [String] = []
    }

    static func apply(
        _ categories: Set<BackupCategory>, from bundle: BackupBundle, settings: SettingsBackup?, to core: AppCore
    ) async -> Summary {
        var summary = Summary()
        if let settings {
            summary.settings = apply(settings, to: core)
        } else if categories.contains(.configuration) {
            summary.problems.append(
                String(localized: "Couldn't read \(BackupCategory.configuration.descriptor.label)."))
        }
        if categories.contains(.clipboard) {
            summary.clipboard = await importClipboard(bundle, into: core.clipboardStore)
            if summary.clipboard > 0 { core.clipboardStore.load() }
        }
        if categories.contains(.snippets) {
            do {
                try await applySnippets(bundle, to: core, summary: &summary)
                summary.snippetsNeedEnabling =
                    summary.snippets > 0 && !core.settings.snippetsEnabled
            } catch {
                summary.problems.append(
                    String(localized: "Couldn't import snippets: \(error.localizedDescription)"))
            }
        }
        if categories.contains(.notes) {
            summary.notes = await applyNotes(bundle, to: core)
        }
        if categories.contains(.learning) {
            summary.learning = applyLearning(bundle, to: core)
        }
        return summary
    }

    /// Content first, so a restored binding has its quicklink, layout, room or size to attach to.
    @discardableResult
    static func apply(_ backup: SettingsBackup, to core: AppCore) -> SettingsBackup.ApplySummary {
        var summary = SettingsBackup.ApplySummary()
        if let settings = backup.settings { summary.settingsFields = settings.apply(to: core.settings) }
        if let customCommands = backup.customCommands {
            summary.customCommands = core.customCommandCoordinator.replaceCustomCommands(customCommands)
        }
        if let quicklinks = backup.quicklinks {
            summary.quicklinks = core.quicklinkCoordinator.replaceQuicklinks(quicklinks)
        }
        if let windowLayouts = backup.windowLayouts {
            summary.windowLayouts = core.windowLayoutCoordinator.replaceWindowLayouts(windowLayouts)
        }
        if let windowRooms = backup.windowRooms {
            summary.windowRooms = core.roomCoordinator.replaceRooms(windowRooms)
        }
        if let customWindowSizes = backup.customWindowSizes {
            summary.customWindowSizes =
                core.customWindowSizeCoordinator.replaceCustomWindowSizes(customWindowSizes)
        }
        if let hotkeys = backup.hotkeys { summary.hotkeys = applyHotkeys(hotkeys, to: core) }
        if let favoriteApps = backup.favoriteApps {
            core.favorites.replace(keys: favoriteApps)
            summary.favorites = favoriteApps.count
        }
        if backup.hiddenLauncherItems != nil || backup.hiddenLauncherKinds != nil {
            let items = backup.hiddenLauncherItems ?? Array(core.visibility.hiddenItemKeys)
            let kinds = backup.hiddenLauncherKinds ?? Array(core.visibility.disabledKinds)
            core.visibility.replace(hiddenItems: items, disabledKinds: kinds)
            summary.hiddenItems = items.count
        }
        if let launcherAliases = backup.launcherAliases {
            core.aliases.replace(launcherAliases)
            // Counted after the store, which drops blanks the file may carry.
            summary.aliases = core.aliases.aliases.count
        }
        if let pinnedEmoji = backup.pinnedEmoji {
            core.pinnedEmoji.replace(pinnedEmoji)
            summary.pinnedEmoji = core.pinnedEmoji.glyphs.count
        }
        return summary
    }

    private static func applyHotkeys(
        _ hotkeys: SettingsBackup.HotkeyBackup, to core: AppCore
    ) -> Int {
        let hk = core.hotKeys
        var count = 0
        // Skip an already-claimed binding: the second registration would silently fail.
        func apply(_ binding: HotKeyBinding, _ action: HotKeyAction) {
            guard hk.conflictOwner(of: binding, excluding: action) == nil else { return }
            hk.setBinding(binding, for: action)
            count += 1
        }
        if let b = hotkeys.togglePalette { apply(b, .togglePalette) }
        for (rawID, b) in hotkeys.commands ?? [:] {
            guard let action = CommandID(rawValue: rawID)?.hotKeyAction else { continue }
            apply(b, action)
        }
        for (id, b) in hotkeys.apps ?? [:] { apply(b, .app(bundleID: id)) }
        for (id, b) in hotkeys.panes ?? [:] { apply(b, .settingsPane(bundleID: id)) }
        for (rawID, b) in hotkeys.customCommands ?? [:] {
            guard let id = UUID(uuidString: rawID), core.customCommands.command(id: id) != nil else {
                continue
            }
            apply(b, .customCommand(id: id))
        }
        for (rawID, b) in hotkeys.systemActions ?? [:] {
            guard let id = SystemAction.ID(rawValue: rawID) else { continue }
            apply(b, .systemAction(id: id))
        }
        for (rawID, b) in hotkeys.windowCommands ?? [:] {
            guard let id = WindowCommand.ID(rawValue: rawID) else { continue }
            apply(b, .windowCommand(id: id))
        }
        for (rawID, b) in hotkeys.windowLayouts ?? [:] {
            guard let id = UUID(uuidString: rawID), core.windowLayouts.layout(id: id) != nil
            else { continue }
            apply(b, .windowLayout(id: id))
        }
        for (rawID, b) in hotkeys.windowRooms ?? [:] {
            guard let id = UUID(uuidString: rawID), core.rooms.room(id: id) != nil else { continue }
            apply(b, .windowRoom(id: id))
        }
        for (rawID, b) in hotkeys.customWindowSizes ?? [:] {
            guard let id = UUID(uuidString: rawID), core.customWindowSizes.size(id: id) != nil
            else { continue }
            apply(b, .customWindowSize(id: id))
        }
        for (rawID, b) in hotkeys.quicklinks ?? [:] {
            guard let id = UUID(uuidString: rawID), core.quicklinks.quicklink(id: id) != nil else {
                continue
            }
            apply(b, .quicklink(id: id))
        }
        return count
    }

    // MARK: - Parts

    /// Off-main and streamed: a restored history runs to hundreds of thousands of clips.
    private nonisolated static func importClipboard(
        _ bundle: BackupBundle, into store: ClipboardStore
    ) async -> Int {
        ClipboardDatabase.importStoredItems(
            inDatabaseAt: store.dbURL, adoptingImagesInto: store.imagesDir,
            bundle.clipboardItems().lazy.compactMap { staged($0, in: bundle) })
    }

    /// The row still points into staging; the store adopts the blob once it accepts the clip.
    private nonisolated static func staged(
        _ item: BackupClipboardItem, in bundle: BackupBundle
    ) -> ClipboardItem? {
        switch item.kind {
        case .text:
            guard let text = item.text else { return nil }
            return ClipboardItem(
                id: UUID(), kind: .text, text: text, imagePath: nil, createdAt: item.createdAt,
                sourceBundleID: item.sourceBundleID, pinnedAt: item.pinnedAt)
        case .image:
            guard let name = item.imageName, let url = bundle.clipboardImageURL(named: name) else {
                return nil
            }
            return ClipboardItem(
                id: UUID(), kind: .image, text: nil, imagePath: url.path,
                createdAt: item.createdAt, sourceBundleID: item.sourceBundleID,
                pinnedAt: item.pinnedAt)
        case .file:
            // A path from another Mac names nothing here, so the row is dropped rather than dead.
            guard let path = item.text, FileManager.default.fileExists(atPath: path) else {
                return nil
            }
            return ClipboardItem(
                id: UUID(), kind: .file, text: path, imagePath: nil, createdAt: item.createdAt,
                sourceBundleID: item.sourceBundleID, pinnedAt: item.pinnedAt)
        }
    }

    private static func applySnippets(
        _ bundle: BackupBundle, to core: AppCore, summary: inout Summary
    ) async throws {
        if core.settings.snippetsEnabled { await core.snippetsStore.start() }
        let existing = Set(core.snippetsStore.snippets.lazy.map { Pair($0.snippet.name, $0.snippet.text) })
        let (fresh, skipped) = try await readSnippets(bundle, excluding: existing)
        if skipped > 0 {
            summary.problems.append(String(localized: "\(skipped) snippet files couldn’t be loaded"))
        }
        summary.snippets = try await core.snippetsStore.importSnippets(fresh).count
    }

    @concurrent private static func readSnippets(
        _ bundle: BackupBundle, excluding existing: Set<Pair>
    ) async throws -> ([Snippet], Int) {
        var fresh: [Snippet] = []
        var skipped = 0
        for url in try bundle.documentURLs(in: bundle.snippetsDirectory, extension: "md") {
            do {
                let snippet = try autoreleasepool {
                    let source = try String(contentsOf: url, encoding: .utf8)
                    return try SnippetMarkdownSerializer.parse(content: source, fileURL: url)
                }
                if !existing.contains(Pair(snippet.name, snippet.text)) { fresh.append(snippet) }
            } catch {
                skipped += 1
            }
        }
        return (fresh, skipped)
    }

    private static func applyNotes(_ bundle: BackupBundle, to core: AppCore) async -> Int {
        let documents = bundle.documents(in: bundle.notesDirectory, extension: "md")
        guard !documents.isEmpty else { return 0 }
        return await core.notesStore.importNotes(
            documents.map {
                NotesRepository.Incoming(
                    title: ($0.name as NSString).deletingPathExtension, source: $0.contents)
            })
    }

    private static func applyLearning(_ bundle: BackupBundle, to core: AppCore) -> Int {
        var applied = 0
        if let visits = bundle.decodeLearning(.ranking, as: [String: LauncherVisit].self) {
            core.launcherRanking.replace(visits)
            applied += visits.count
        }
        if let records = bundle.decodeLearning(.emoji, as: [FrequentEmoji].self) {
            core.frequentEmoji.replace(records)
            applied += records.count
        }
        if let entries = bundle.decodeLearning(.calculator, as: [CalcHistoryEntry].self) {
            core.calcHistory.replace(entries)
            applied += entries.count
        }
        return applied
    }

    /// Name and body together, so two snippets sharing one name still both survive an import.
    private struct Pair: Hashable {
        let name: String
        let text: String

        init(_ name: String, _ text: String) {
            self.name = name
            self.text = text
        }
    }
}
