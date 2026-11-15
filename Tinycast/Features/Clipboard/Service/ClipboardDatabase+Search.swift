import Foundation
import SQLite3

// Spelled as the C macro in sqlite3.h, which isn't imported into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Off-main reads on a private connection, so a slow description query never blocks capture.
extension ClipboardDatabase {
    nonisolated static func describedMatches(
        in url: URL, description: ClipboardStore.DescriptionQuery, filter: ClipboardFilter, includeRecognizedText: Bool
    ) -> [ClipboardItem] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return []
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "PRAGMA cache_size=-2048", nil, nil, nil)
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        let text = description.text
        let kind = description.kind?.rawValue
        let terms = ([text] + description.alternativeTexts).filter { !$0.isEmpty }
        let usesFTS = !terms.isEmpty && terms.allSatisfy { $0.count >= 3 }
        let imageTerms = description.kind == .image || (description.kind == nil && !description.linksOnly)
            ? ImageContent.terms(in: text) : []
        let imageParameter = 6 + terms.count
        let imageUsesFTS = !imageTerms.isEmpty && imageTerms.allSatisfy { $0.count >= 3 }
        func contains(_ column: String) -> String {
            terms.indices.map { "instr(lower(\(column)), lower(?\(6 + $0))) > 0" }.joined(separator: " OR ")
        }
        let ordinary = usesFTS
            ? "i.rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?1)"
            : "(\(contains("i.text")))"
        let recognizedPhrase = usesFTS
            ? "i.id IN (SELECT t.item_id FROM item_text t JOIN item_text_fts f ON f.rowid = t.rowid WHERE item_text_fts MATCH ?1)"
            : "i.id IN (SELECT item_id FROM item_text WHERE \(contains("text")))"
        let imagePredicates = imageTerms.indices.map {
            "instr(lower(text), lower(?\(imageParameter + $0))) > 0"
        }.joined(separator: " AND ")
        let recognizedImage = imageUsesFTS
            ? "i.id IN (SELECT t.item_id FROM item_text t JOIN item_text_fts f ON f.rowid=t.rowid WHERE item_text_fts MATCH ?\(imageParameter))"
            : "i.id IN (SELECT item_id FROM item_text WHERE \(imagePredicates))"
        let recognized = imageTerms.isEmpty ? recognizedPhrase
            : "(\(recognizedPhrase) OR \(recognizedImage))"
        let match = terms.isEmpty ? "1" : includeRecognizedText ? "(\(ordinary) OR \(recognized))" : ordinary
        let sql = """
            SELECT i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app, i.pinned_at
            FROM items i WHERE (?2 IS NULL OR i.kind = ?2) AND i.created_at >= ?3 AND i.created_at < ?4 AND \(match)
              AND (?5 IS NULL OR instr(lower(i.text), ?5) > 0)
            ORDER BY i.pinned_at IS NULL, i.pinned_at, i.rowid DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let term = usesFTS
            ? terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
            : text
        sqlite3_bind_text(statement, 1, term, -1, SQLITE_TRANSIENT)
        if let kind { sqlite3_bind_text(statement, 2, kind, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_double(statement, 3, description.dates?.start.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
        sqlite3_bind_double(statement, 4, description.dates?.end.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude)
        if let website = description.website {
            sqlite3_bind_text(statement, 5, website, -1, SQLITE_TRANSIENT)
        }
        if !usesFTS {
            for (offset, term) in terms.enumerated() {
                sqlite3_bind_text(statement, Int32(6 + offset), term, -1, SQLITE_TRANSIENT)
            }
        }
        if imageUsesFTS {
            let match = imageTerms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: " AND ")
            sqlite3_bind_text(statement, Int32(imageParameter), match, -1, SQLITE_TRANSIENT)
        } else {
            for (offset, term) in imageTerms.enumerated() {
                sqlite3_bind_text(statement, Int32(imageParameter + offset), term, -1, SQLITE_TRANSIENT)
            }
        }
        var results: [ClipboardItem] = []
        var unpinned = 0
        while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
            guard let item = row(statement), filter.matches(item), description.matches(item) else { continue }
            results.append(item)
            if !item.isPinned { unpinned += 1 }
            if unpinned >= searchLimit { break }
        }
        return Task.isCancelled ? [] : results
    }

    nonisolated static func extractedMatches(
        in url: URL, query: String, filter: ClipboardFilter, residentIDs: Set<UUID>?
    ) -> [ClipboardItem] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return []
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "PRAGMA cache_size=-2048", nil, nil, nil)
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        let isShort = query.count < 3
        let kind = filter == .image ? "i.kind = 'image'" : filter == .file ? "i.kind = 'file'" : "1"
        let columns = "i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app, i.pinned_at"
        let sql =
            isShort
            ? """
            SELECT \(columns), t.text FROM item_text t JOIN items i ON i.id = t.item_id
            WHERE \(kind) AND (i.pinned_at IS NOT NULL OR i.rowid >= COALESCE(
              (SELECT rowid FROM items WHERE pinned_at IS NULL ORDER BY rowid DESC LIMIT 1 OFFSET \(memoryWindow - 1)), 0))
            ORDER BY i.pinned_at IS NULL, i.pinned_at, i.rowid DESC
            """
            : """
            SELECT * FROM (
              SELECT \(columns), NULL AS recognized, i.rowid AS rid FROM items i
                WHERE i.pinned_at IS NULL AND i.rowid IN (
                SELECT i.rowid FROM item_text_fts f
                  JOIN item_text t ON t.rowid = f.rowid JOIN items i ON i.id = t.item_id
                WHERE item_text_fts MATCH ?1 AND \(kind)
                ORDER BY i.rowid DESC
                LIMIT \(searchLimit) + (SELECT COUNT(*) FROM items WHERE pinned_at IS NOT NULL)
              )
              UNION ALL
              SELECT \(columns), t.text AS recognized, i.rowid AS rid
                FROM items i JOIN item_text t ON t.item_id = i.id
                WHERE i.pinned_at IS NOT NULL AND \(kind)
            ) ORDER BY pinned_at IS NULL, pinned_at, rid DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if !isShort {
            let match = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
        }
        var matches: [ClipboardItem] = []
        var unpinned = 0
        while !Task.isCancelled, sqlite3_step(stmt) == SQLITE_ROW {
            guard let item = row(stmt) else { continue }
            if let residentIDs, !residentIDs.contains(item.id) { continue }
            if isShort || item.isPinned,
                columnString(stmt, 7)?.localizedCaseInsensitiveContains(query) != true
            {
                continue
            }
            matches.append(item)
            if !item.isPinned { unpinned += 1 }
            if unpinned == searchLimit { break }
        }
        return Task.isCancelled ? [] : matches
    }
}
