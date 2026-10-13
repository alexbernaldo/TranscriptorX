import Foundation
import SQLite3

/// Migraciones idempotentes del esquema de `transcriptions`.
/// v2 (modelos): `model_id` y `engine` (NULL = registro anterior → «Desconocido»).
enum TranscriptionSchema {
    static let currentVersion = 2

    static func columns(of table: String, in db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        var names = Set<String>()
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return names }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names
    }

    static func userVersion(in db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Seguro de llamar en cada arranque: solo añade lo que falta.
    @discardableResult
    static func migrate(_ db: OpaquePointer) -> Bool {
        let existing = columns(of: "transcriptions", in: db)
        guard !existing.isEmpty else { return false }   // la tabla aún no existe
        var ok = true
        for column in ["model_id", "engine"] where !existing.contains(column) {
            ok = sqlite3_exec(db, "ALTER TABLE transcriptions ADD COLUMN \(column) TEXT;", nil, nil, nil) == SQLITE_OK && ok
        }
        if ok, userVersion(in: db) < currentVersion {
            sqlite3_exec(db, "PRAGMA user_version = \(currentVersion);", nil, nil, nil)
        }
        return ok
    }
}
