import Darwin
import Foundation
import SQLite3

nonisolated struct ImageContentStore: Sendable {
    struct Fingerprint: Equatable, Sendable {
        let modified: TimeInterval
        let size: Int

        init?(url: URL) {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ path in path.map { lstat($0, &info) == 0 } ?? false }),
                info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_flags & UInt32(SF_DATALESS) == 0
            else { return nil }
            modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            size = Int(info.st_size)
        }
    }

    let url: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func purge() -> Bool {
        var removed = true
        for suffix in ["", "-wal", "-shm"] {
            do {
                try FileManager.default.removeItem(atPath: url.path + suffix)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                removed = false
            }
        }
        return removed
    }

    func prepare() -> Bool {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return false }
        guard let db = open(writing: true) else { return false }
        defer { sqlite3_close_v2(db) }
        return sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS images(
                path TEXT NOT NULL UNIQUE, scope TEXT NOT NULL, modified REAL NOT NULL, size INTEGER NOT NULL,
                text TEXT NOT NULL, version INTEGER NOT NULL, attempts INTEGER NOT NULL, retry_at REAL NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS image_terms USING fts5(
                text, content='images', content_rowid='rowid', tokenize='porter unicode61'
            );
            CREATE TRIGGER IF NOT EXISTS images_ai AFTER INSERT ON images BEGIN
                INSERT INTO image_terms(rowid, text) VALUES(new.rowid, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS images_ad AFTER DELETE ON images BEGIN
                INSERT INTO image_terms(image_terms, rowid, text) VALUES('delete', old.rowid, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS images_au AFTER UPDATE ON images BEGIN
                INSERT INTO image_terms(image_terms, rowid, text) VALUES('delete', old.rowid, old.text);
                INSERT INTO image_terms(rowid, text) VALUES(new.rowid, new.text);
            END;
            UPDATE images SET attempts=0, retry_at=0 WHERE attempts > 0;
            """, nil, nil, nil) == SQLITE_OK
    }

    func needsExtraction(path: String, scope: String, fingerprint: Fingerprint, version: Int, now: Date) -> Bool {
        guard let db = open(writing: false) else { return true }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT modified, size, version, attempts, retry_at, scope FROM images WHERE path = ?1",
            -1, &statement, nil) == SQLITE_OK
        else { return true }
        defer { sqlite3_finalize(statement) }
        bind(path, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
            sqlite3_column_double(statement, 0) == fingerprint.modified,
            sqlite3_column_int64(statement, 1) == fingerprint.size,
            string(statement, 5) == scope
        else { return true }
        return sqlite3_column_int(statement, 2) < version && sqlite3_column_int(statement, 3) < 3
            && sqlite3_column_double(statement, 4) <= now.timeIntervalSince1970
    }

    @discardableResult
    func save(
        _ content: ImageContent?, path: String, scope: String, fingerprint: Fingerprint, version: Int, now: Date
    ) -> Bool {
        guard !Task.isCancelled, let db = open(writing: true) else { return false }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO images(path, scope, modified, size, text, version, attempts, retry_at)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(path) DO UPDATE SET scope=excluded.scope, modified=excluded.modified, size=excluded.size,
                text=CASE WHEN excluded.version=0 AND images.modified=excluded.modified AND images.size=excluded.size
                    THEN images.text ELSE excluded.text END,
                version=CASE WHEN excluded.version=0 AND images.modified=excluded.modified AND images.size=excluded.size
                    THEN images.version ELSE excluded.version END,
                attempts=CASE WHEN images.modified=excluded.modified AND images.size=excluded.size
                    AND images.scope=excluded.scope THEN images.attempts + excluded.attempts ELSE excluded.attempts END,
                retry_at=excluded.retry_at
            """, -1, &statement, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(path, to: 1, in: statement)
        bind(scope, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, fingerprint.modified)
        sqlite3_bind_int64(statement, 4, Int64(fingerprint.size))
        bind(content?.searchText ?? "", to: 5, in: statement)
        sqlite3_bind_int(statement, 6, Int32(content?.version ?? 0))
        let failed = (content?.version ?? 0) < version
        sqlite3_bind_int(statement, 7, failed ? 1 : 0)
        sqlite3_bind_double(statement, 8, failed ? now.addingTimeInterval(60).timeIntervalSince1970 : 0)
        return !Task.isCancelled && sqlite3_step(statement) == SQLITE_DONE
    }

    @discardableResult
    func prune(scope: String, accepts: (String) -> Bool) -> Bool {
        guard !Task.isCancelled, let db = open(writing: true) else { return false }
        defer { sqlite3_close_v2(db) }
        var rows: OpaquePointer?
        var remove: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT rowid, path, scope, modified, size FROM images WHERE rowid > ?1 ORDER BY rowid LIMIT 128
            """, -1, &rows, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(rows) }
        guard sqlite3_prepare_v2(db, "DELETE FROM images WHERE rowid = ?1", -1, &remove, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(remove) }
        var cursor: Int64 = 0
        var changed = false
        while !Task.isCancelled {
            let start = cursor
            var stale: [Int64] = []
            sqlite3_bind_int64(rows, 1, cursor)
            while !Task.isCancelled, sqlite3_step(rows) == SQLITE_ROW {
                cursor = sqlite3_column_int64(rows, 0)
                let path = string(rows, 1)
                if string(rows, 2) == scope, accepts(path),
                    let current = Fingerprint(url: URL(fileURLWithPath: path)),
                    current.modified == sqlite3_column_double(rows, 3), current.size == sqlite3_column_int64(rows, 4)
                { continue }
                stale.append(cursor)
            }
            sqlite3_reset(rows)
            guard cursor != start, !Task.isCancelled else { break }
            guard !stale.isEmpty else { continue }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { break }
            var succeeded = true
            for row in stale {
                sqlite3_bind_int64(remove, 1, row)
                succeeded = !Task.isCancelled && sqlite3_step(remove) == SQLITE_DONE
                sqlite3_reset(remove)
                if !succeeded { break }
            }
            guard succeeded, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                break
            }
            changed = true
        }
        return changed
    }

    func search(
        text: String, scope: String, dates: DateInterval?, limit: Int,
        accepts: (String, Fingerprint) -> Bool, isCancelled: @Sendable () -> Bool
    ) -> [String] {
        let terms = ImageContent.terms(in: text)
        guard !terms.isEmpty, !isCancelled(), let db = open(writing: false) else { return [] }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT i.path, i.modified, i.size FROM image_terms f JOIN images i ON i.rowid = f.rowid
            WHERE image_terms MATCH ?1 AND i.scope = ?2 AND i.modified >= ?3 AND i.modified < ?4
            ORDER BY bm25(image_terms), i.modified DESC
            """, -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        let phrases = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        bind(phrases.joined(separator: " AND "), to: 1, in: statement)
        bind(scope, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, dates?.start.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
        sqlite3_bind_double(statement, 4, dates?.end.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude)
        var paths: [String] = []
        while !isCancelled(), sqlite3_step(statement) == SQLITE_ROW {
            let path = string(statement, 0)
            guard let current = Fingerprint(url: URL(fileURLWithPath: path)),
                current.modified == sqlite3_column_double(statement, 1),
                current.size == sqlite3_column_int64(statement, 2), accepts(path, current)
            else { continue }
            paths.append(path)
            if paths.count >= limit { break }
        }
        return isCancelled() ? [] : paths
    }

    private func open(writing: Bool) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = writing ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        sqlite3_busy_timeout(db, 500)
        sqlite3_exec(db, "PRAGMA cache_size=-2048", nil, nil, nil)
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        return db
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
