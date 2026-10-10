import Foundation
import SQLite3

// MARK: - Transcription Database (SQLite + FTS5)
/// Backend de persistencia para el historial de transcripciones (#6).
///
/// Tabla única con payload JSON completo (evita drift de espejo cuando el modelo
/// evoluciona) + espejo FTS5 contentless para búsqueda a nivel de texto.
/// Conexión con WAL, FULLMUTEX y busy_timeout; acceso serial vía `queue`.
final class TranscriptionDatabase {

    static let shared = TranscriptionDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "transcriptor.sqlite")   // acceso serial
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("TranscriptorNative", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appFolder.path) {
            try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        return appFolder
    }

    private var dbURL: URL {
        storageDirectory.appendingPathComponent("transcriptions.sqlite")
    }

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        openAndMigrate()
    }

    // MARK: - Connection

    private func openAndMigrate() {
        let url = dbURL
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            AppLogger.shared.log("SQLite open failed: \(message)", level: .error, category: .app)
            return
        }
        db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA busy_timeout=3000;")
        exec("""
        CREATE TABLE IF NOT EXISTS transcriptions (
            id TEXT PRIMARY KEY, payload TEXT NOT NULL, title TEXT NOT NULL,
            created_at REAL NOT NULL, duration REAL NOT NULL,
            is_favorite INTEGER NOT NULL, language TEXT NOT NULL, deleted_at REAL);
        CREATE INDEX IF NOT EXISTS idx_trans_created ON transcriptions(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_trans_deleted ON transcriptions(deleted_at);
        CREATE VIRTUAL TABLE IF NOT EXISTS transcriptions_fts USING fts5(title, text, content='');
        """)
        importLegacyJSONIfNeeded()
    }

    /// Ejecuta SQL sin resultados (PRAGMA, DDL, multi-statement).
    private func exec(_ sql: String) {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            AppLogger.shared.log("SQLite exec error: \(message)", level: .error, category: .app)
            sqlite3_free(errMsg)
        }
    }

    /// Prepara una sentencia dentro de `queue.sync`.
    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            AppLogger.shared.log("SQLite prepare error: \(String(cString: sqlite3_errmsg(db)))",
                                 level: .error, category: .app)
            return nil
        }
        return stmt
    }

    // MARK: - Bind helpers

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    private func bindNull(_ stmt: OpaquePointer?, _ index: Int32) {
        sqlite3_bind_null(stmt, index)
    }

    /// SQLITE_TRANSIENT: SQLite copia el texto (Swift puede liberarlo tras el bind).
    private var SQLITE_TRANSIENT: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    // MARK: - CRUD

    /// Inserta o reemplaza una transcripción y sincroniza el espejo FTS.
    func upsert(_ t: Transcription, isDeleted: Bool = false) {
        queue.sync {
            guard let db else { return }

            // 1. Espejo FTS: retirar la entrada antigua (INSERT OR REPLACE cambia rowid)
            var oldRow: Int64?
            if let stmt = prepare("SELECT rowid FROM transcriptions WHERE id = ?;") {
                bind(stmt, 1, t.id.uuidString)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    oldRow = sqlite3_column_int64(stmt, 0)
                }
                sqlite3_finalize(stmt)
            }
            if let oldRow {
                exec("DELETE FROM transcriptions_fts WHERE rowid = \(oldRow);")
            }

            // 2. Upsert de la fila
            guard let stmt = prepare("""
                INSERT OR REPLACE INTO transcriptions
                    (id, payload, title, created_at, duration, is_favorite, language, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """) else { return }
            defer { sqlite3_finalize(stmt) }
            guard let payload = try? String(data: encoder.encode(t), encoding: .utf8) else {
                AppLogger.shared.log("SQLite upsert: encode failed for \(t.id)",
                                     level: .error, category: .app)
                return
            }
            bind(stmt, 1, t.id.uuidString)
            bind(stmt, 2, payload)
            bind(stmt, 3, t.title)
            bind(stmt, 4, t.createdAt.timeIntervalSince1970)
            bind(stmt, 5, t.duration)
            bind(stmt, 6, t.isFavorite ? 1 : 0)
            bind(stmt, 7, t.language)
            if isDeleted {
                bind(stmt, 8, Date().timeIntervalSince1970)
            } else {
                bindNull(stmt, 8)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                AppLogger.shared.log("SQLite upsert error: \(String(cString: sqlite3_errmsg(db)))",
                                     level: .error, category: .app)
                return
            }

            // 3. Espejo FTS con el rowid nuevo
            guard let row = rowid(of: t.id) else { return }
            guard let fts = prepare("INSERT INTO transcriptions_fts(rowid, title, text) VALUES (?, ?, ?);") else { return }
            defer { sqlite3_finalize(fts) }
            sqlite3_bind_int64(fts, 1, row)
            bind(fts, 2, t.title)
            bind(fts, 3, t.text)
            if sqlite3_step(fts) != SQLITE_DONE {
                AppLogger.shared.log("SQLite FTS sync error: \(String(cString: sqlite3_errmsg(db)))",
                                     level: .error, category: .app)
            }
        }
    }

    private func rowid(of id: UUID) -> Int64? {
        guard let stmt = prepare("SELECT rowid FROM transcriptions WHERE id = ?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Transcripciones activas (no papelera), ordenadas por fecha descendente.
    func loadAll() -> [Transcription] {
        queue.sync {
            guard let stmt = prepare(
                "SELECT payload FROM transcriptions WHERE deleted_at IS NULL ORDER BY created_at DESC;"
            ) else { return [] }
            defer { sqlite3_finalize(stmt) }
            return decodeRows(stmt)
        }
    }

    /// Transcripciones en la papelera, ordenadas por fecha de borrado descendente.
    func loadTrash() -> [Transcription] {
        queue.sync {
            guard let stmt = prepare(
                "SELECT payload FROM transcriptions WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC;"
            ) else { return [] }
            defer { sqlite3_finalize(stmt) }
            return decodeRows(stmt)
        }
    }

    /// Busca una transcripción por id.
    func find(id: UUID) -> Transcription? {
        queue.sync {
            guard let stmt = prepare("SELECT payload FROM transcriptions WHERE id = ?;") else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodePayload(at: stmt, column: 0)
        }
    }

    /// Soft-delete / restaura (`date == nil` → activo).
    func setDeleted(id: UUID, at date: Date?) {
        queue.sync {
            guard let db else { return }
            guard let stmt = prepare("UPDATE transcriptions SET deleted_at = ? WHERE id = ?;") else { return }
            defer { sqlite3_finalize(stmt) }
            if let date {
                bind(stmt, 1, date.timeIntervalSince1970)
            } else {
                bindNull(stmt, 1)
            }
            bind(stmt, 2, id.uuidString)
            if sqlite3_step(stmt) != SQLITE_DONE {
                AppLogger.shared.log("SQLite setDeleted error: \(String(cString: sqlite3_errmsg(db)))",
                                     level: .error, category: .app)
            }
        }
    }

    /// Borrado definitivo (fila + espejo FTS).
    func removeForever(id: UUID) {
        queue.sync {
            guard let row = rowid(of: id) else { return }
            exec("DELETE FROM transcriptions_fts WHERE rowid = \(row);")
            guard let stmt = prepare("DELETE FROM transcriptions WHERE id = ?;") else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            sqlite3_step(stmt)
        }
    }

    /// Borra todo el historial (activos + papelera) y su espejo FTS.
    func clearAll() {
        queue.sync {
            exec("DELETE FROM transcriptions_fts;")
            exec("DELETE FROM transcriptions;")
        }
    }

    /// Búsqueda FTS5 (frase literal escapada). Si MATCH falla por input
    /// degenerado → fallback LIKE sobre título + payload en memoria.
    func search(matching query: String) -> [Transcription] {
        queue.sync {
            let phrase = ftsPhrase(query)
            if let results = ftsSearch(matchPhrase: phrase) {
                return results
            }
            return likeSearch(query)
        }
    }

    private func ftsSearch(matchPhrase phrase: String) -> [Transcription]? {
        guard let stmt = prepare("""
            SELECT t.payload FROM transcriptions_fts, transcriptions t
            WHERE transcriptions_fts MATCH ? AND t.rowid = transcriptions_fts.rowid
              AND t.deleted_at IS NULL
            ORDER BY t.created_at DESC;
        """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, phrase)
        var rows: [Transcription] = []
        var degenerate = false
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                if let t = decodePayload(at: stmt, column: 0) {
                    rows.append(t)
                }
            } else if step == SQLITE_DONE {
                break
            } else {
                // Input degenerado para FTS → fallback
                degenerate = true
                break
            }
        }
        if degenerate {
            AppLogger.shared.log("SQLite FTS MATCH failed, falling back to LIKE",
                                 level: .warning, category: .app)
            return nil
        }
        return rows
    }

    private func likeSearch(_ query: String) -> [Transcription] {
        guard let stmt = prepare("SELECT payload FROM transcriptions WHERE deleted_at IS NULL;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        let needle = query.lowercased()
        return decodeRows(stmt).filter {
            $0.title.lowercased().contains(needle) || $0.text.lowercased().contains(needle)
        }
    }

    /// Escapa una consulta como frase FTS5 literal (comillas duplicadas).
    private func ftsPhrase(_ query: String) -> String {
        "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Elimina de la papelera los registros con más de `days` días.
    /// Devuelve los ids purgados (para que el llamador limpie su audio).
    func purgeTrash(olderThanDays days: Int) -> [UUID] {
        queue.sync {
            guard days > 0 else { return [] }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
            guard let stmt = prepare(
                "SELECT id FROM transcriptions WHERE deleted_at IS NOT NULL AND deleted_at < ?;"
            ) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, cutoff)
            var ids: [UUID] = []
            while sqlite3_step(stmt) == SQLITE_ROW,
                  let cString = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: cString)) {
                ids.append(id)
            }
            for id in ids {
                if let row = rowid(of: id) {
                    exec("DELETE FROM transcriptions_fts WHERE rowid = \(row);")
                }
                guard let del = prepare("DELETE FROM transcriptions WHERE id = ?;") else { continue }
                bind(del, 1, id.uuidString)
                sqlite3_step(del)
                sqlite3_finalize(del)
            }
            return ids
        }
    }

    // MARK: - Row decoding

    private func decodeRows(_ stmt: OpaquePointer?) -> [Transcription] {
        var rows: [Transcription] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let t = decodePayload(at: stmt, column: 0) {
                rows.append(t)
            }
        }
        return rows
    }

    private func decodePayload(at stmt: OpaquePointer?, column: Int32) -> Transcription? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        let payload = String(cString: cString)
        guard let data = payload.data(using: .utf8),
              let t = try? decoder.decode(Transcription.self, from: data) else {
            AppLogger.shared.log("SQLite: skipped undecodable row", level: .error, category: .app)
            return nil
        }
        return t
    }

    private func countRows() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM transcriptions;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Legacy JSON migration (one-shot)

    /// Migra `transcriptions.json` → SQLite. El JSON nunca se borra: se renombora
    /// a `.bak` (red de seguridad).
    private func importLegacyJSONIfNeeded() {
        let json = storageDirectory.appendingPathComponent("transcriptions.json")
        guard FileManager.default.fileExists(atPath: json.path) else { return }

        // ¿Ya migrado? Si la tabla tiene filas, el JSON es redundante → .bak.
        if countRows() > 0 {
            moveToBackup(json)
            AppLogger.shared.log("Legacy JSON redundant (rows exist) — moved to .bak", category: .app)
            return
        }

        guard let data = try? Data(contentsOf: json),
              let items = try? decoder.decode([Transcription].self, from: data) else {
            AppLogger.shared.log("Legacy JSON present but unreadable — keeping file",
                                 level: .error, category: .app)
            return
        }
        items.forEach { upsert($0) }
        moveToBackup(json)
        AppLogger.shared.log("Migrated \(items.count) transcriptions to SQLite", category: .app)
    }

    private func moveToBackup(_ json: URL) {
        let backup = json.deletingLastPathComponent().appendingPathComponent("transcriptions.json.bak")
        let fm = FileManager.default
        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: backup)
        }
        try? fm.moveItem(at: json, to: backup)
    }
}
