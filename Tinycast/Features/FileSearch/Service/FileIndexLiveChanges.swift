import Foundation
import Synchronization

/// Folder events applied as an overlay on the snapshot, so a change never waits for a rebuild.
extension FileIndex {
    /// Idempotent, so a replayed or duplicate event is harmless; true asks for a rebuild.
    @discardableResult
    func apply(folder path: String, recursive: Bool = false) -> Bool {
        guard let (snapshot, changes) = diff(folder: path, recursive: recursive) else { return false }
        return state.withLock { state in
            // A rebuild landed meanwhile; it replays this event from its own start.
            guard state.snapshot === snapshot else { return false }
            for index in changes.kills { state.kill(index, in: snapshot) }
            for removal in changes.removals { state.remove(removal.path, isDirectory: removal.isDirectory) }
            for (childPath, child) in changes.additions { state.add(childPath, child) }
            return state.changeCount > Self.rebuildThreshold || state.added.count > Self.addedRebuildThreshold
        }
    }

    /// Its copy of the state dies on return, so `apply` writes the overlay without copying it.
    private func diff(
        folder path: String, recursive: Bool
    ) -> (FileIndexSnapshot, FolderDiff.Changes)? {
        let current = state.withLock { $0 }
        guard let snapshot = current.snapshot, let policy = current.policy else { return nil }
        let overlay = current.added[path]
        let base =
            overlay == nil
            ? snapshot.lookup(path).flatMap { index in
                snapshot.isDirectory(index) && !current.isDead(index) ? index : nil
            } : nil
        guard
            let prior = overlay?.isDirectory == true ? overlay?.prior : base.map({ snapshot.prior[$0] })
        else { return nil }

        var diff = FolderDiff(folder: path, state: current, snapshot: snapshot, policy: policy)
        let listed = lister.withLock { lister in
            recursive
                ? diff.rescan(base: base, prior: prior, using: lister)
                : diff.compare(base: base, prior: prior, using: lister)
        }
        guard listed, !diff.changes.isEmpty else { return nil }
        return (snapshot, diff.changes)
    }

    /// One folder's changes. A row that did not change costs a `memcmp` and allocates nothing.
    private struct FolderDiff {
        struct Changes {
            var kills: [Int] = []
            var removals: [(path: String, isDirectory: Bool)] = []
            var additions: [(String, FileIndexCrawler.Child)] = []

            var isEmpty: Bool { kills.isEmpty && removals.isEmpty && additions.isEmpty }
        }

        let folder: String
        let state: State
        let snapshot: FileIndexSnapshot
        let policy: FileSearchPolicy
        private(set) var changes = Changes()
        /// Walked once the listing is released, since walking reuses the same lister.
        private var newFolders: [(path: String, prior: Int8)] = []

        init(folder: String, state: State, snapshot: FileIndexSnapshot, policy: FileSearchPolicy) {
            self.folder = folder
            self.state = state
            self.snapshot = snapshot
            self.policy = policy
        }

        /// Both sides are sorted by name bytes, so one merge pass finds every difference.
        mutating func compare(base: Int?, prior: Int8, using lister: FileIndexCrawler.Lister) -> Bool {
            let overlayNames = state.addedChildren[folder] ?? []
            let listed: Void? = lister.list(folder, prior: prior, policy: policy) { entries, order, name in
                let rows = base.map(snapshot.children(of:)) ?? 0..<0
                var row = rows.lowerBound
                var overlaySeen = 0
                for position in order {
                    let entry = entries[position]
                    let entryName = name(entry)
                    while row < rows.upperBound, FileIndexCrawler.compare(snapshot.name(row), entryName) < 0 {
                        killIfAlive(row)
                        row += 1
                    }
                    if row < rows.upperBound, FileIndexCrawler.compare(snapshot.name(row), entryName) == 0 {
                        let matched = row
                        row += 1
                        if !state.isDead(matched) {
                            if hasChanged(matched, to: entry) {
                                kill(matched)
                                add(entry, named: String(decoding: entryName, as: UTF8.self))
                            }
                            continue
                        }
                    }
                    let text = String(decoding: entryName, as: UTF8.self)
                    guard overlayNames.contains(text) else {
                        add(entry, named: text)
                        continue
                    }
                    overlaySeen += 1
                    update(text, to: entry)
                }
                while row < rows.upperBound {
                    killIfAlive(row)
                    row += 1
                }
                guard overlaySeen < overlayNames.count else { return }
                let onDisk = Set(order.map { String(decoding: name(entries[$0]), as: UTF8.self) })
                for gone in overlayNames where !onDisk.contains(gone) { removeAdded(gone) }
            }
            guard listed != nil else { return false }
            walkNewFolders(using: lister)
            return true
        }

        /// For an event that lost its detail: everything beneath the folder is listed afresh.
        mutating func rescan(base: Int?, prior: Int8, using lister: FileIndexCrawler.Lister) -> Bool {
            if let base {
                for row in snapshot.children(of: base) { killIfAlive(row) }
            }
            for name in state.addedChildren[folder] ?? [] { removeAdded(name) }
            let listed: Void? = lister.list(folder, prior: prior, policy: policy) { entries, _, name in
                for entry in entries { add(entry, named: String(decoding: name(entry), as: UTF8.self)) }
            }
            guard listed != nil else { return false }
            walkNewFolders(using: lister)
            return true
        }

        private func hasChanged(_ row: Int, to entry: FileIndexCrawler.Entry) -> Bool {
            if snapshot.isDirectory(row) != entry.isDirectory { return true }
            return snapshot.mtime[row] != entry.mtime
        }

        private mutating func update(_ name: String, to entry: FileIndexCrawler.Entry) {
            let path = FileIndexCrawler.path(folder, name)
            guard let added = state.added[path] else {
                add(entry, named: name)
                return
            }
            if added.isDirectory != entry.isDirectory {
                changes.removals.append((path, added.isDirectory))
                add(entry, named: name)
            } else if added.mtime != entry.mtime {
                add(entry, named: name)
            }
        }

        private mutating func killIfAlive(_ row: Int) {
            if !state.isDead(row) { kill(row) }
        }

        /// A vanished folder also takes whatever the overlay added beneath it.
        private mutating func kill(_ row: Int) {
            changes.kills.append(row)
            guard snapshot.isDirectory(row) else { return }
            changes.removals.append((FileIndexCrawler.path(folder, snapshot.nameString(row)), true))
        }

        private mutating func removeAdded(_ name: String) {
            let path = FileIndexCrawler.path(folder, name)
            if let index = state.added.index(forKey: path) {
                let existing = state.added[index]
                changes.removals.append((existing.key, existing.value.isDirectory))
            } else {
                changes.removals.append((path, false))
            }
        }

        private mutating func add(_ entry: FileIndexCrawler.Entry, named name: String) {
            let child = FileIndexCrawler.Child(entry, name: name, parent: folder, policy: policy)
            let path = FileIndexCrawler.path(folder, name)
            changes.additions.append((path, child))
            if child.isDirectory { newFolders.append((path, child.prior)) }
        }

        private mutating func walkNewFolders(using lister: FileIndexCrawler.Lister) {
            for (path, prior) in newFolders {
                changes.additions += lister.walk(path, prior: prior, policy: policy)
            }
            newFolders = []
        }
    }
}
