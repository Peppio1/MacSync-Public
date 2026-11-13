import Foundation
import SQLite3

public enum SyncLogLevel: String, Sendable {
    case info, success, warning, error
}

public struct SyncLogEntry: Equatable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let level: String
    public let rootID: String
    public let action: String
    public let relativePath: String
    public let bytes: Int64
    public let durationSeconds: Double
    public let message: String
}

/// Persistent SQLite activity history. No passwords, IP addresses or full
/// local/network paths are accepted by the API; only a relative file path.
public final class SyncActivityLog {
    private var db: OpaquePointer?

    public init(path: String) throws {
        var dbHandle: OpaquePointer?
        guard sqlite3_open(path, &dbHandle) == SQLITE_OK else {
            if dbHandle != nil { sqlite3_close(dbHandle) }
            throw JournalError.database("Cannot open activity database")
        }
        db = dbHandle
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA busy_timeout=5000;")
            try execute("""
                CREATE TABLE IF NOT EXISTS sync_activity (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_time REAL NOT NULL,
                    level TEXT NOT NULL,
                    root_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    bytes INTEGER NOT NULL,
                    duration_seconds REAL NOT NULL,
                    message TEXT NOT NULL
                );
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_sync_activity_recent ON sync_activity(id DESC);")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func record(
        level: SyncLogLevel, rootID: String, action: String,
        relativePath: String = "", bytes: Int64 = 0,
        durationSeconds: Double = 0, message: String
    ) throws {
        guard valid(rootID), valid(action), valid(message),
              valid(relativePath), !relativePath.hasPrefix("/"),
              bytes >= 0, durationSeconds >= 0, durationSeconds.isFinite else {
            throw JournalError.database("Invalid log entry")
        }
        let statement = try prepare("""
            INSERT INTO sync_activity(event_time,level,root_id,action,relative_path,bytes,duration_seconds,message)
            VALUES(?,?,?,?,?,?,?,?);
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970) == SQLITE_OK else { throw failure() }
        try bind(level.rawValue, 2, statement)
        try bind(rootID, 3, statement)
        try bind(action, 4, statement)
        try bind(relativePath, 5, statement)
        guard sqlite3_bind_int64(statement, 6, bytes) == SQLITE_OK,
              sqlite3_bind_double(statement, 7, durationSeconds) == SQLITE_OK else { throw failure() }
        try bind(message, 8, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    public func recent(limit: Int = 200) throws -> [SyncLogEntry] {
        let query = try prepare("""
            SELECT id,event_time,level,root_id,action,relative_path,bytes,duration_seconds,message
            FROM sync_activity ORDER BY id DESC LIMIT ?;
            """)
        defer { sqlite3_finalize(query) }
        guard sqlite3_bind_int(query, 1, Int32(max(1, min(limit, 5000)))) == SQLITE_OK else { throw failure() }
        var entries: [SyncLogEntry] = []
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            entries.append(SyncLogEntry(
                id: sqlite3_column_int64(query, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(query, 1)),
                level: textColumn(query, 2),
                rootID: textColumn(query, 3),
                action: textColumn(query, 4),
                relativePath: textColumn(query, 5),
                bytes: sqlite3_column_int64(query, 6),
                durationSeconds: sqlite3_column_double(query, 7),
                message: textColumn(query, 8)
            ))
        }
        return entries
    }

    public func exportText(limit: Int = 5000) throws -> String {
        let iso = ISO8601DateFormatter()
        var rows = ["timestamp\tlevel\troot\taction\trelative_path\tbytes\tseconds\tmessage"]
        for entry in try recent(limit: limit).reversed() {
            let values: [String] = [
                iso.string(from: entry.timestamp), entry.level, entry.rootID,
                entry.action, entry.relativePath, String(entry.bytes),
                String(format: "%.3f", entry.durationSeconds), entry.message
            ]
            rows.append(values.map { $0.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func valid(_ s: String) -> Bool {
        s.count <= 4096 && !s.contains("\0") && !s.contains("\n") && !s.contains("\r")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { throw failure() }
        return stmt
    }

    private func bind(_ value: String, _ i: Int32, _ stmt: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { sqlite3_bind_text(stmt, i, $0, -1, transient) }
        guard result == SQLITE_OK else { throw failure() }
    }

    private func textColumn(_ stmt: OpaquePointer, _ i: Int32) -> String {
        guard let pointer = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
    }

    private func failure() -> JournalError {
        JournalError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite closed")
    }
}
