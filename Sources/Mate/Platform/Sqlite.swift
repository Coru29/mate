import Foundation
import SQLite3

/// Read-only lookups in another app's SQLite database (Cursor's `state.vscdb`). Opened per call with
/// `immutable=1`, so SQLite takes no locks and never touches the owner's WAL or shared-memory files; the trade-off
/// is that writes still sitting in the WAL (not yet checkpointed) are not seen. Never logs values.
enum Sqlite {
    /// The `value` column of the row whose `key` column equals `key`, as UTF-8 text; nil when the file, the table or
    /// the row is missing, the read fails, or the value is not text. `table` must be a plain identifier.
    static func readValue(db: URL, table: String, key: String) -> String? {
        readValues(db: db, table: table, keys: [key])?[key]
    }

    /// Several keys in one open/close: the rows found (missing keys are absent), or nil when the database could not
    /// be read at all (missing file, open or query failure), so a caller can tell "no such row" from "unreadable".
    static func readValues(db: URL, table: String, keys: [String]) -> [String: String]? {
        guard !keys.isEmpty, table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              FileManager.default.fileExists(atPath: db.path),
              let path = db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_open_v2("file:\(path)?mode=ro&immutable=1", &handle, flags, nil) == SQLITE_OK else {
            Log.error("sqlite: could not open \(db.lastPathComponent)")
            return nil
        }
        sqlite3_busy_timeout(handle, 200)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM \(table) WHERE key = ?1 LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            Log.error("sqlite: could not query \(table) in \(db.lastPathComponent)")
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var out: [String: String] = [:]
        for key in keys {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            guard sqlite3_bind_text(stmt, 1, key, -1, transient) == SQLITE_OK else { return nil }
            let step = sqlite3_step(stmt)
            // Only DONE means "no such row"; BUSY, CORRUPT, IOERR… mean the database could not be read.
            if step == SQLITE_DONE { continue }
            guard step == SQLITE_ROW else {
                Log.error("sqlite: read of \(db.lastPathComponent) failed (\(step))")
                return nil
            }
            let n = Int(sqlite3_column_bytes(stmt, 0))
            guard n > 0, let bytes = sqlite3_column_blob(stmt, 0),
                  let s = String(data: Data(bytes: bytes, count: n), encoding: .utf8) else { continue }
            out[key] = s
        }
        return out
    }
}
