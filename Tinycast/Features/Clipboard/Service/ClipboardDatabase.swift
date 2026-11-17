import Foundation
import SQLite3

// Spelled as the C macro in sqlite3.h, which isn't imported into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The history's `clipboard.sqlite3` and its `images/` blobs; `ClipboardStore` holds the policy.
@MainActor
final class ClipboardDatabase {
    nonisolated static let memoryWindow = 1000
    /// The most unpinned rows any one query answers with, ordinary and OCR-only alike.
    nonisolated static let searchLimit = 200

    nonisolated private static let insertSQL = """
        INSERT INTO items(id, kind, text, image_path, created_at, source_app, pinned_at)
        VALUES(?,?,?,?,?,?,?)
        """

    private static let schema = """
        CREATE TABLE IF NOT EXISTS items(
          id TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,
          text TEXT,
          image_path TEXT,
          created_at REAL NOT NULL,
          source_app TEXT,
          pinned_at REAL
        );
        CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at);
        CREATE INDEX IF NOT EXISTS items_pinned_at ON items(pinned_at) WHERE pinned_at IS NOT NULL;
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
          text, content='items', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(rowid, text) VALUES(new.rowid, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, text) VALUES('delete', old.rowid, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF rowid, text ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, text) VALUES('delete', old.rowid, old.text);
          INSERT INTO items_fts(rowid, text) VALUES(new.rowid, new.text);
        END;
        """

    private static let extractionSchema = """
        CREATE TABLE IF NOT EXISTS item_text(
          item_id TEXT NOT NULL UNIQUE, text TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS item_text_fts USING fts5(
          text, content='item_text', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS item_text_ai AFTER INSERT ON item_text BEGIN
          INSERT INTO item_text_fts(rowid, text) VALUES(new.rowid, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS item_text_ad AFTER DELETE ON item_text BEGIN
          INSERT INTO item_text_fts(item_text_fts, rowid, text)
            VALUES('delete', old.rowid, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_extract_ad AFTER DELETE ON items BEGIN
          DELETE FROM item_text WHERE item_id = old.id;
        END;
        CREATE TABLE IF NOT EXISTS item_text_failures(
          item_id TEXT NOT NULL UNIQUE, attempts INTEGER NOT NULL, retry_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS item_text_versions(item_id TEXT NOT NULL UNIQUE, version INTEGER NOT NULL);
        CREATE TRIGGER IF NOT EXISTS items_extract_version_ad AFTER DELETE ON items BEGIN
          DELETE FROM item_text_versions WHERE item_id = old.id;
        END;
        CREATE TRIGGER IF NOT EXISTS items_extract_failure_ad AFTER DELETE ON items BEGIN
          DELETE FROM item_text_failures WHERE item_id = old.id;
        END;
        CREATE INDEX IF NOT EXISTS items_extract_candidates ON items(kind)
          WHERE kind IN ('image', 'file');
        """

    let imagesDir: URL
    let url: URL
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var loadStmt: OpaquePointer?
    private var windowFloorStmt: OpaquePointer?
    private var searchStmt: OpaquePointer?
    private var deleteByIDStmt: OpaquePointer?
    private var pinStmt: OpaquePointer?
    private var staleImagesStmt: OpaquePointer?
    private var deleteStaleStmt: OpaquePointer?

    init(directory: URL) {
        imagesDir = directory.appendingPathComponent("images", isDirectory: true)
        url = directory.appendingPathComponent("clipboard.sqlite3")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        open()
    }

    // Isolated so teardown may touch the main-actor pointers; the release is already on main.
    isolated deinit {
        close()
    }

    var isOpen: Bool { db != nil }

    /// Idempotent, so the coordinator can re-open the file when the feature is switched back on.
    func open() {
        guard db == nil else { return }
        if openDatabase() { return }
        // Captured, not authored: discard a corrupt or outdated database and start over.
        close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        if !openDatabase() { close() }
    }

    func close() {
        [
            insertStmt, loadStmt, windowFloorStmt, searchStmt, deleteByIDStmt, pinStmt,
            staleImagesStmt, deleteStaleStmt
        ].forEach { sqlite3_finalize($0) }
        insertStmt = nil
        loadStmt = nil
        windowFloorStmt = nil
        searchStmt = nil
        deleteByIDStmt = nil
        pinStmt = nil
        staleImagesStmt = nil
        deleteStaleStmt = nil
        sqlite3_close_v2(db)
        db = nil
    }

    /// The resident window plus every pin, newest first; nil while the file is closed.
    func loadWindow() -> [ClipboardItem]? {
        guard let stmt = loadStmt else { return nil }
        sqlite3_bind_int64(stmt, 1, windowFloor())
        var loaded: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = Self.row(stmt) { loaded.append(item) }
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return loaded
    }

    func removeOrphanedCopies() {
        ImageDerivative.removeOrphans(in: imagesDir)
    }

    /// The floor rowid `loadStmt` reads from; 0 means no floor, so load everything.
    private func windowFloor() -> sqlite3_int64 {
        guard let stmt = windowFloorStmt else { return 0 }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_bind_int(stmt, 1, Int32(Self.memoryWindow - 1))
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    func insert(_ item: ClipboardItem) {
        if let stmt = insertStmt { Self.bindAndInsert(stmt, item) }
    }

    /// Whether a row changed; throws when the write itself could not run.
    func updateText(_ text: String, id: UUID) throws(ClipboardStore.UpdateError) -> Bool {
        guard let stmt = prepare("UPDATE items SET text = ?1 WHERE id = ?2") else {
            throw .writeFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw .writeFailed }
        return sqlite3_changes(db) > 0
    }

    func delete(_ item: ClipboardItem) {
        guard let stmt = deleteByIDStmt else { return }
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func deleteUnpinned() {
        // RETURNING hands back the deleted blobs in the same pass, so no separate SELECT is needed.
        guard db != nil,
            let stmt = prepare("DELETE FROM items WHERE pinned_at IS NULL RETURNING image_path")
        else { return }
        var orphaned: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let path = Self.columnString(stmt, 0), owns(path) { orphaned.append(path) }
        }
        sqlite3_finalize(stmt)
        removeBlobsInBackground(orphaned)
    }

    /// Whether any row went; owned blobs of the deleted rows are removed off the main actor.
    func deleteUnpinned(olderThan cutoff: Date) -> Bool {
        guard let imagesStmt = staleImagesStmt, let deleteStmt = deleteStaleStmt else { return false }
        sqlite3_bind_double(imagesStmt, 1, cutoff.timeIntervalSince1970)
        var staleOwnedPaths: [String] = []
        while sqlite3_step(imagesStmt) == SQLITE_ROW {
            // Only delete files we own; an external reference just loses its row.
            if let path = Self.columnString(imagesStmt, 0), owns(path) {
                staleOwnedPaths.append(path)
            }
        }
        sqlite3_reset(imagesStmt)
        sqlite3_clear_bindings(imagesStmt)
        sqlite3_bind_double(deleteStmt, 1, cutoff.timeIntervalSince1970)
        sqlite3_step(deleteStmt)
        let changed = sqlite3_changes(db) > 0
        sqlite3_reset(deleteStmt)
        sqlite3_clear_bindings(deleteStmt)
        removeBlobsInBackground(staleOwnedPaths)
        return changed
    }

    func pin(_ item: ClipboardItem, at stamp: Date) {
        guard let stmt = pinStmt else { return }
        sqlite3_bind_double(stmt, 1, stamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    /// Rewrites the row under the same id so it leads; a delete would take its derived text too.
    func moveToFront(_ updated: ClipboardItem) {
        guard
            let stmt = prepare(
                """
                UPDATE items SET rowid = (SELECT COALESCE(MAX(rowid), 0) + 1 FROM items),
                  created_at = ?1, pinned_at = ?2 WHERE id = ?3
                """)
        else { return }
        sqlite3_bind_double(stmt, 1, updated.createdAt.timeIntervalSince1970)
        if let stamp = updated.pinnedAt {
            sqlite3_bind_double(stmt, 2, stamp.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, updated.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// Ordinary-text FTS hits, newest first; nil when the query cannot run, so the caller falls back.
    func search(_ q: String) -> [ClipboardItem]? {
        // Trigram FTS needs ≥3 characters; shorter queries filter the in-memory window.
        guard let stmt = searchStmt, q.count >= 3 else { return nil }
        let match = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
        var results: [ClipboardItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let item = Self.row(stmt) { results.append(item) }
            status = sqlite3_step(stmt)
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return status == SQLITE_DONE ? results : nil
    }

    // MARK: - Recognized text

    func createExtractionSchema() -> Bool {
        guard let db, sqlite3_exec(db, Self.extractionSchema, nil, nil, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_exec(db, "DELETE FROM item_text_failures", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM item_text WHERE text = ''", nil, nil, nil)
        return true
    }

    func nextExtractionItem(now: Date, version: Int, scope: ClipboardStore.ExtractionScope) -> ClipboardItem? {
        guard
            let stmt = prepare(
                """
                SELECT id, kind, text, image_path, created_at, source_app, pinned_at
                FROM items i WHERE \(scope.predicate)
                  AND id NOT IN (SELECT t.item_id FROM item_text t JOIN item_text_versions v ON v.item_id = t.item_id
                    WHERE v.version >= ?2)
                  AND id NOT IN (SELECT item_id FROM item_text_failures
                    WHERE attempts >= 3 OR retry_at > ?1)
                ORDER BY rowid DESC LIMIT 1
                """)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(version))
        return sqlite3_step(stmt) == SQLITE_ROW ? Self.row(stmt) : nil
    }

    func nextExtractionRetry(version: Int, scope: ClipboardStore.ExtractionScope) -> Date? {
        guard
            let stmt = prepare(
                """
                SELECT MIN(f.retry_at) FROM item_text_failures f
                JOIN items i ON i.id = f.item_id
                LEFT JOIN item_text_versions v ON v.item_id = f.item_id
                WHERE f.attempts < 3 AND COALESCE(v.version, 0) < ?1 AND \(scope.predicate)
                """)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(version))
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    func recordExtractionFailure(for item: ClipboardItem, retryAt: Date) {
        guard
            let stmt = prepare(
                """
                INSERT INTO item_text_failures(item_id, attempts, retry_at)
                SELECT id, 1, ?2 FROM items WHERE id = ?1
                ON CONFLICT(item_id) DO UPDATE SET attempts = attempts + 1, retry_at = excluded.retry_at
                """)
        else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, retryAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    /// Selects the row rather than naming it, so an item deleted mid-recognition stays deleted.
    func setExtractedText(_ text: String, for item: ClipboardItem, version: Int, completed: Bool) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        if let remove = prepare("""
            DELETE FROM item_text WHERE item_id = ?1 AND
                COALESCE((SELECT version FROM item_text_versions WHERE item_id = ?1), 0) < ?2
            """) {
            sqlite3_bind_text(remove, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(remove, 2, Int32(version))
            sqlite3_step(remove)
            sqlite3_finalize(remove)
        }
        guard
            let stmt = prepare(
                """
                INSERT OR IGNORE INTO item_text(item_id, text)
                SELECT id, ?2 FROM items WHERE id = ?1 AND kind IN ('image', 'file')
                """)
        else { return false }
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
        let stored = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        sqlite3_finalize(stmt)
        guard stored else { return false }
        if let stmt = prepare("INSERT OR REPLACE INTO item_text_versions(item_id, version) VALUES(?1, ?2)") {
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(version))
            let updated = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard updated else { return false }
        } else { return false }
        if completed, let stmt = prepare("DELETE FROM item_text_failures WHERE item_id = ?1") {
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { return false }
        committed = true
        return true
    }

    // MARK: - Blobs

    /// Whether a path is inside our images directory; only those are ours to delete.
    func owns(_ path: String) -> Bool {
        path.hasPrefix(imagesDir.path + "/")
    }

    func newBlobURL() -> URL {
        imagesDir.appendingPathComponent(UUID().uuidString + ".png")
    }

    nonisolated static func writeBlob(_ data: Data, to url: URL) -> Bool {
        (try? data.write(to: url, options: .atomic)) != nil
    }

    func deleteBlob(_ item: ClipboardItem) {
        guard let path = item.imagePath, owns(path) else { return }
        Self.removeBlob(atPath: path)
    }

    /// A retention cut can strand hundreds of files, so delete them off the main actor.
    private func removeBlobsInBackground(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        Task.detached(priority: .utility) {
            for path in paths { Self.removeBlob(atPath: path) }
        }
    }

    nonisolated private static func removeBlob(atPath path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        ImageDerivative.removeCopies(of: url)
    }

    // MARK: - Connection

    private func openDatabase() -> Bool {
        guard
            sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK,
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
                == SQLITE_OK,
            sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK
        else { return false }
        insertStmt = prepare(Self.insertSQL)
        // Two indexed branches, deliberately not one OR. See docs/features/clipboard.md#store.
        loadStmt = prepare(
            """
            SELECT id, kind, text, image_path, created_at, source_app, pinned_at FROM (
              SELECT rowid AS rid, * FROM items WHERE rowid >= ?1
              UNION ALL
              SELECT rowid AS rid, * FROM items WHERE pinned_at IS NOT NULL AND rowid < ?1
            ) ORDER BY rid DESC
            """)
        windowFloorStmt = prepare(
            "SELECT rowid FROM items WHERE pinned_at IS NULL ORDER BY rowid DESC LIMIT 1 OFFSET ?")
        searchStmt = prepare(
            """
            SELECT i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app, i.pinned_at
            FROM (
              SELECT rowid FROM items_fts WHERE items_fts MATCH ?
              ORDER BY rowid DESC LIMIT \(Self.searchLimit)
            ) f JOIN items i ON i.rowid = f.rowid ORDER BY f.rowid DESC
            """)
        deleteByIDStmt = prepare("DELETE FROM items WHERE id = ?")
        // Only ever sets a stamp: unpinning rewrites the whole row so it leads the history again.
        pinStmt = prepare("UPDATE items SET pinned_at = ? WHERE id = ?")
        staleImagesStmt = prepare(
            """
            SELECT image_path FROM items
            WHERE created_at < ? AND pinned_at IS NULL AND image_path IS NOT NULL
            """)
        deleteStaleStmt = prepare("DELETE FROM items WHERE created_at < ? AND pinned_at IS NULL")
        return insertStmt != nil && loadStmt != nil && windowFloorStmt != nil && searchStmt != nil
            && deleteByIDStmt != nil && pinStmt != nil && staleImagesStmt != nil
            && deleteStaleStmt != nil
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    // MARK: - Whole-file passes

    /// A staged blob moves into `imagesDirectory`, making `owns` true so retention reclaims it.
    nonisolated static func importStoredItems(
        inDatabaseAt url: URL, adoptingImagesInto imagesDirectory: URL? = nil,
        _ items: some Sequence<ClipboardItem>
    ) -> Int {
        var keys: Set<Int> = []
        forEachStoredItem(inDatabaseAt: url) { keys.insert(importKey($0)) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return 0
        }
        defer { sqlite3_close_v2(db) }
        // A capture from the poller can hold the write lock; without this the import truncates.
        sqlite3_busy_timeout(db, 5_000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        var inserted = 0
        // One transaction for the batch: ~1 WAL commit rather than one per row.
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for staged in items {
            let item = adoptionTarget(staged, in: imagesDirectory)
            guard keys.insert(importKey(item)).inserted else { continue }
            if item.imagePath != staged.imagePath,
                !moveBlob(from: staged.imagePath, to: item.imagePath)
            {
                continue
            }
            bindAndInsert(stmt, item)
            inserted += 1
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return inserted
    }

    /// Hashed, never held: a whole history's text must not sit in memory to dedupe an import.
    nonisolated private static func importKey(_ item: ClipboardItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.kind)
        // Keyed off `text` for everything but an image, or every file entry hashes alike.
        hasher.combine(item.kind == .image ? item.imagePath : item.text)
        return hasher.finalize()
    }

    /// Keeps the staged name, so a backup imported twice dedupes rather than copying every image.
    nonisolated private static func adoptionTarget(
        _ item: ClipboardItem, in directory: URL?
    ) -> ClipboardItem {
        guard let directory, item.kind == .image, let path = item.imagePath else { return item }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return ClipboardItem(
            id: item.id, kind: .image, text: nil,
            imagePath: directory.appendingPathComponent(name).path, createdAt: item.createdAt,
            sourceBundleID: item.sourceBundleID, pinnedAt: item.pinnedAt)
    }

    /// false leaves the row out, so none ever points into a staging tree about to be discarded.
    nonisolated private static func moveBlob(from source: String?, to destination: String?) -> Bool {
        guard let source, let destination else { return false }
        let from = URL(fileURLWithPath: source)
        let to = URL(fileURLWithPath: destination)
        return (try? FileManager.default.moveItem(at: from, to: to)) != nil
            || (try? FileManager.default.copyItem(at: from, to: to)) != nil
    }

    /// Past the memory window, off-main. `READWRITE` because a WAL reader still writes `-shm`.
    nonisolated static func forEachStoredItem(
        inDatabaseAt url: URL, _ body: (ClipboardItem) -> Void
    ) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return
        }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, kind, text, image_path, created_at, source_app, pinned_at
            FROM items ORDER BY rowid
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = row(stmt) { body(item) }
        }
    }

    // MARK: - Rows

    nonisolated private static func bindAndInsert(_ stmt: OpaquePointer, _ item: ClipboardItem) {
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, SQLITE_TRANSIENT)
        if let text = item.text {
            sqlite3_bind_text(stmt, 3, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let path = item.imagePath {
            sqlite3_bind_text(stmt, 4, path, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_double(stmt, 5, item.createdAt.timeIntervalSince1970)
        if let source = item.sourceBundleID {
            sqlite3_bind_text(stmt, 6, source, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let pinnedAt = item.pinnedAt {
            sqlite3_bind_double(stmt, 7, pinnedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    nonisolated static func row(_ stmt: OpaquePointer?) -> ClipboardItem? {
        guard let idString = columnString(stmt, 0), let id = UUID(uuidString: idString),
            let kindString = columnString(stmt, 1),
            let kind = ClipboardItem.Kind(rawValue: kindString)
        else { return nil }
        return ClipboardItem(
            id: id, kind: kind, text: columnString(stmt, 2), imagePath: columnString(stmt, 3),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
            sourceBundleID: columnString(stmt, 5), pinnedAt: columnDate(stmt, 6))
    }

    nonisolated private static func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    nonisolated static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }
}

extension ClipboardStore.ExtractionScope {
    fileprivate var predicate: String {
        let kind = switch filter {
        case .all: "i.kind IN ('image', 'file')"
        case .image: "i.kind = 'image'"
        case .file: "i.kind = 'file'"
        case .text, .color, .link, .email: "0"
        }
        guard residentOnly else { return kind }
        return """
            \(kind) AND (i.pinned_at IS NOT NULL OR i.rowid >= COALESCE(
                (SELECT rowid FROM items WHERE pinned_at IS NULL ORDER BY rowid DESC
                 LIMIT 1 OFFSET \(ClipboardDatabase.memoryWindow - 1)), 0))
            """
    }
}
