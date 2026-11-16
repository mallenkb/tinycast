import Foundation

/// Stores → staged bundle: `plan` reads on the main actor, `write` does every byte of IO off it.
@MainActor
enum BackupComposer {
    /// Everything the writer needs, in `Sendable` form, so the heavy half can leave the actor.
    struct Plan: Sendable {
        var categories: Set<BackupCategory>
        var appVersion: String
        var settings: Data?
        var clipboardDatabase: URL?
        var snippetsDirectory: URL?
        var notesDirectory: URL?
        var learning: [BackupBundle.LearningPart: Data] = [:]
        var learningRecords = 0
    }

    struct Result: Sendable {
        var manifest: BackupManifest
        /// Clips whose image file had already gone; reported rather than silently dropped.
        var missingImages: Int
    }

    static func plan(_ categories: Set<BackupCategory>, from core: AppCore) -> Plan {
        var plan = Plan(
            categories: categories,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "unknown")
        if categories.contains(.configuration) {
            plan.settings = try? settingsBackup(from: core).encoded()
        }
        if categories.contains(.clipboard) { plan.clipboardDatabase = core.clipboardStore.dbURL }
        if categories.contains(.snippets) {
            plan.snippetsDirectory = core.snippetsStore.snippetsDirectory
        }
        if categories.contains(.notes) { plan.notesDirectory = core.notesStore.notesDirectory }
        if categories.contains(.learning) {
            // From memory, not the files: the ranking store persists asynchronously.
            let encoder = BackupBundle.encoder
            plan.learning[.ranking] = try? encoder.encode(core.launcherRanking.visits)
            plan.learning[.emoji] = try? encoder.encode(core.frequentEmoji.records)
            plan.learning[.calculator] = try? encoder.encode(core.calcHistory.entries)
            plan.learningRecords =
                core.launcherRanking.visits.count + core.frequentEmoji.records.count
                + core.calcHistory.entries.count
        }
        return plan
    }

    static func settingsBackup(from core: AppCore) -> SettingsBackup {
        var backup = SettingsBackup()
        backup.settings = SettingsBackup.SettingsData(core.settings)
        let hk = core.hotKeys
        var hotkeys = SettingsBackup.HotkeyBackup()
        hotkeys.togglePalette = hk.binding(for: .togglePalette)
        hotkeys.commands = Dictionary(
            uniqueKeysWithValues: CommandID.allCases.compactMap { id in
                id.hotKeyAction.flatMap(hk.binding(for:)).map { (id.rawValue, $0) }
            })
        hotkeys.apps = Dictionary(
            uniqueKeysWithValues: hk.boundBundleIDs.compactMap { id in
                hk.binding(for: .app(bundleID: id)).map { (id, $0) }
            })
        hotkeys.panes = Dictionary(
            uniqueKeysWithValues: hk.boundPaneBundleIDs.compactMap { id in
                hk.binding(for: .settingsPane(bundleID: id)).map { (id, $0) }
            })
        hotkeys.customCommands = Dictionary(
            uniqueKeysWithValues: hk.boundCustomCommandIDs.compactMap { id in
                hk.binding(for: .customCommand(id: id)).map { (id.uuidString.lowercased(), $0) }
            })
        hotkeys.systemActions = Dictionary(
            uniqueKeysWithValues: SystemAction.ID.allCases.compactMap { id in
                hk.binding(for: .systemAction(id: id)).map { (id.rawValue, $0) }
            })
        hotkeys.windowCommands = Dictionary(
            uniqueKeysWithValues: WindowCommand.ID.allCases.compactMap { id in
                hk.binding(for: .windowCommand(id: id)).map { (id.rawValue, $0) }
            })
        hotkeys.quicklinks = Dictionary(
            uniqueKeysWithValues: hk.boundQuicklinkIDs.compactMap { id in
                hk.binding(for: .quicklink(id: id)).map { (id.uuidString.lowercased(), $0) }
            })
        hotkeys.windowLayouts = Dictionary(
            uniqueKeysWithValues: hk.boundWindowLayoutIDs.compactMap { id in
                hk.binding(for: .windowLayout(id: id)).map { (id.uuidString.lowercased(), $0) }
            })
        hotkeys.windowRooms = Dictionary(
            uniqueKeysWithValues: hk.boundWindowRoomIDs.compactMap { id in
                hk.binding(for: .windowRoom(id: id)).map { (id.uuidString.lowercased(), $0) }
            })
        hotkeys.customWindowSizes = Dictionary(
            uniqueKeysWithValues: hk.boundCustomWindowSizeIDs.compactMap { id in
                hk.binding(for: .customWindowSize(id: id)).map { (id.uuidString.lowercased(), $0) }
            })
        backup.hotkeys = hotkeys

        backup.customCommands = core.customCommands.commands
        backup.quicklinks = core.quicklinks.quicklinks
        backup.windowLayouts = core.windowLayouts.layouts
        backup.windowRooms = core.rooms.rooms
        backup.customWindowSizes = core.customWindowSizes.sizes
        backup.favoriteApps = core.favorites.keys
        backup.hiddenLauncherItems = Array(core.visibility.hiddenItemKeys)
        backup.hiddenLauncherKinds = Array(core.visibility.disabledKinds)
        backup.launcherAliases = core.aliases.aliases
        backup.pinnedEmoji = core.pinnedEmoji.glyphs
        return backup
    }

    nonisolated static func write(_ plan: Plan, into bundle: BackupBundle) throws -> Result {
        try bundle.prepare(plan.categories)
        var counts: [String: Int] = [:]
        var missingImages = 0

        if let settings = plan.settings {
            try bundle.write(settings, to: bundle.settingsURL)
            counts[BackupCategory.configuration.rawValue] = 1
        }
        if let database = plan.clipboardDatabase {
            let outcome = try writeClipboard(from: database, into: bundle)
            counts[BackupCategory.clipboard.rawValue] = outcome.written
            missingImages = outcome.missing
        }
        if let directory = plan.snippetsDirectory {
            counts[BackupCategory.snippets.rawValue] = try copyDocuments(
                from: directory, to: bundle.snippetsDirectory)
        }
        if let directory = plan.notesDirectory {
            counts[BackupCategory.notes.rawValue] = try copyDocuments(
                from: directory, to: bundle.notesDirectory)
        }
        if !plan.learning.isEmpty {
            for (part, data) in plan.learning { try bundle.write(data, to: bundle.learningURL(part)) }
            counts[BackupCategory.learning.rawValue] = plan.learningRecords
        }

        let manifest = BackupManifest(
            appVersion: plan.appVersion, createdAt: Date(), counts: counts)
        try bundle.writeManifest(manifest)
        return Result(manifest: manifest, missingImages: missingImages)
    }

    // MARK: - Parts

    private nonisolated static func writeClipboard(
        from database: URL, into bundle: BackupBundle
    )
        throws -> (written: Int, missing: Int)
    {
        let writer = try bundle.clipboardWriter()
        var written = 0
        var missing = 0
        var failure: Error?
        ClipboardStore.forEachStoredItem(inDatabaseAt: database) { item in
            guard failure == nil else { return }
            do {
                guard let portable = try portableItem(item, into: bundle) else {
                    missing += 1
                    return
                }
                try writer.write(portable)
                written += 1
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return (written, missing)
    }

    /// nil when the image has gone; hardlinked where the volume allows, so PNGs cost inodes.
    private nonisolated static func portableItem(
        _ item: ClipboardItem, into bundle: BackupBundle
    )
        throws -> BackupClipboardItem?
    {
        var imageName: String?
        if item.kind == .image {
            guard let path = item.imagePath,
                FileManager.default.fileExists(atPath: path)
            else { return nil }
            let source = URL(fileURLWithPath: path)
            // The stored blob's own name, so exporting twice names the same clip the same way.
            var name = source.lastPathComponent
            var destination = bundle.clipboardImagesDirectory.appendingPathComponent(name)
            if !BackupBundle.isSafeName(name)
                || FileManager.default.fileExists(atPath: destination.path)
            {
                name = UUID().uuidString + ".png"
                destination = bundle.clipboardImagesDirectory.appendingPathComponent(name)
            }
            if (try? FileManager.default.linkItem(at: source, to: destination)) == nil {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            imageName = name
        }
        // A referenced file is exported as its path; a backup never carries bytes it never held.
        if item.kind == .file, item.filePath.map(FileManager.default.fileExists) != true {
            return nil
        }
        let kind: BackupClipboardItem.Kind
        switch item.kind {
        case .text: kind = .text
        case .image: kind = .image
        case .file: kind = .file
        }
        return BackupClipboardItem(
            kind: kind, text: item.text, imageName: imageName,
            createdAt: item.createdAt, sourceBundleID: item.sourceBundleID,
            pinnedAt: item.pinnedAt)
    }

    /// Markdown copied verbatim: both repositories read `.md` back, so a round trip loses nothing.
    private nonisolated static func copyDocuments(
        from source: URL, to destination: URL
    ) throws
        -> Int
    {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        var copied = 0
        for name in names.sorted() where (name as NSString).pathExtension == "md" {
            guard BackupBundle.isSafeName(name) else { continue }
            // Resolved: a symlinked note must travel as a file, since the reader refuses links.
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(name).resolvingSymlinksInPath(),
                to: destination.appendingPathComponent(name))
            copied += 1
        }
        return copied
    }
}
