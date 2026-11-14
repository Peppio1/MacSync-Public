import Foundation
import SQLite3

public enum ChangeKind: String, Codable, Sendable {
    case upsert
    case delete
}

public struct QueuedChange: Equatable, Sendable {
    public let id: Int64
    public let rootID: String
    public let relativePath: String
    public let kind: ChangeKind
    public let recordedAt: Date
}

public enum JournalError: Error, LocalizedError {
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .database(let description): return description
        }
    }
}

/// Persistent local event queue. The first prototype stores events but never
/// executes file transfers or deletions.
public final class ChangeJournal {
    private var connection: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let description = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if handle != nil { sqlite3_close(handle) }
            throw JournalError.database("Unable to open SQLite: " + description)
        }
        connection = handle

        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA busy_timeout=5000;")
            try execute("""
                CREATE TABLE IF NOT EXISTS change_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    root_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('upsert','delete')),
                    recorded_at REAL NOT NULL,
                    completed INTEGER NOT NULL DEFAULT 0
                );
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_queue_pending ON change_queue(completed, id);")
            try execute("CREATE INDEX IF NOT EXISTS idx_queue_uploads ON change_queue(completed, kind, id);")
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    @discardableResult
    public func enqueue(rootID: String, relativePath: String, kind: ChangeKind) throws -> Int64 {
        guard !rootID.isEmpty, !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              !relativePath.contains("\0") else {
            throw JournalError.database("Unsafe or empty relative path")
        }

        let statement = try prepare("""
            INSERT INTO change_queue(root_id, relative_path, kind, recorded_at)
            VALUES (?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }

        try bind(rootID, at: 1, in: statement)
        try bind(relativePath, at: 2, in: statement)
        try bind(kind.rawValue, at: 3, in: statement)
        guard sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw databaseFailure()
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseFailure()
        }
        return sqlite3_last_insert_rowid(connection)
    }

    public func pending(limit: Int = 1000) throws -> [QueuedChange] {
        let statement = try prepare("""
            SELECT id, root_id, relative_path, kind, recorded_at
            FROM change_queue WHERE completed = 0 ORDER BY id LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 100_000)))) == SQLITE_OK else {
            throw databaseFailure()
        }

        var result: [QueuedChange] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseFailure() }

            let rawKind = columnText(statement, at: 3)
            guard let kind = ChangeKind(rawValue: rawKind) else {
                throw JournalError.database("Invalid change kind stored in database")
            }
            result.append(QueuedChange(
                id: sqlite3_column_int64(statement, 0),
                rootID: columnText(statement, at: 1),
                relativePath: columnText(statement, at: 2),
                kind: kind,
                recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return result
    }


    /// Inventory reconciliation can replace a queued job while the copy
    /// is staging. Never publish a job which is no longer current.
    public func uploadIsCurrent(_ job: QueuedChange) throws -> Bool {
        let stmt = try prepare("""
            SELECT COUNT(*) FROM change_queue q
            WHERE q.id=? AND q.root_id=? AND q.relative_path=?
              AND q.kind='upsert' AND q.completed=0
              AND NOT EXISTS (
                  SELECT 1 FROM change_queue n
                   WHERE n.root_id=q.root_id AND n.relative_path=q.relative_path
                     AND n.completed=0 AND n.id>q.id
              );
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, job.id) == SQLITE_OK else {
            throw databaseFailure()
        }
        try bind(job.rootID, at: 2, in: stmt)
        try bind(job.relativePath, at: 3, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        return sqlite3_column_int64(stmt, 0) == 1
    }

    /// Fetch only pending upserts. Pending deletes must never starve uploads;
    /// deletes remain queued for a future, separately gated mirror phase.
    public func pendingUploads(limit: Int = 100, afterID: Int64 = 0) throws -> [QueuedChange] {
        let statement = try prepare("""
            SELECT id, root_id, relative_path, kind, recorded_at
              FROM change_queue
             WHERE completed = 0 AND kind = 'upsert' AND id > ?
             ORDER BY id LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, max(0, afterID)) == SQLITE_OK,
              sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 1000)))) == SQLITE_OK else {
            throw databaseFailure()
        }
        var result: [QueuedChange] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseFailure() }
            result.append(QueuedChange(
                id: sqlite3_column_int64(statement, 0),
                rootID: columnText(statement, at: 1),
                relativePath: columnText(statement, at: 2),
                kind: .upsert,
                recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return result
    }

    /// Atomic, conditional baseline acknowledgement. A verified hash is only
    /// accepted when the SAME job is still pending, its source inventory
    /// still records that exact file size and modification timestamp, the
    /// source root has not been rebound and no concurrent newer operation for
    /// the same path is pending. No DELETE job can ever be completed here.
    ///
    /// All eligible jobs are acknowledged in one transaction. A cancelled
    /// verification never calls this method.
    public func acknowledgeVerifiedFiles(
        _ entries: [SeedVerifiedMatch],
        sourceRoots: [String: String]
    ) throws -> Int {
        guard !entries.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let sql = """
                UPDATE change_queue SET completed=1
                 WHERE id=? AND root_id=? AND relative_path=?
                   AND kind='upsert' AND completed=0
                   AND EXISTS (
                       SELECT 1 FROM file_inventory f
                        WHERE f.root_id=change_queue.root_id
                          AND f.relative_path=change_queue.relative_path
                          AND f.kind='file'
                          AND f.file_size=?
                          AND ABS(f.modified_at - ?) < 0.002
                   )
                   AND EXISTS (
                       SELECT 1 FROM watched_roots w
                        WHERE w.root_id=change_queue.root_id
                          AND w.absolute_path=?
                   )
                   AND NOT EXISTS (
                       SELECT 1 FROM change_queue q
                        WHERE q.root_id=change_queue.root_id
                          AND q.relative_path=change_queue.relative_path
                          AND q.completed=0 AND q.id<>change_queue.id
                   );
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var changed = 0
            for entry in entries {
                guard let root = sourceRoots[entry.rootID] else { continue }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                guard sqlite3_bind_int64(statement, 1, entry.jobID) == SQLITE_OK
                else { throw databaseFailure() }
                try bind(entry.rootID, at: 2, in: statement)
                try bind(entry.relativePath, at: 3, in: statement)
                guard sqlite3_bind_int64(statement, 4, entry.source.size) == SQLITE_OK,
                      sqlite3_bind_double(statement, 5, entry.source.modifiedAt) == SQLITE_OK
                else { throw databaseFailure() }
                try bind(root, at: 6, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseFailure() }
                changed += Int(sqlite3_changes(connection))
            }
            try execute("COMMIT;")
            return changed
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func watchedRootPath(rootID: String) throws -> String? {
        let stmt = try prepare("""
            SELECT absolute_path FROM watched_roots WHERE root_id=?;
            """)
        defer { sqlite3_finalize(stmt) }
        try bind(rootID, at: 1, in: stmt)
        switch sqlite3_step(stmt) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: return columnText(stmt, at: 0)
        default: throw databaseFailure()
        }
    }

    /// Pending DELETE events created AFTER the operator armed this session.
    /// Prior delete events are intentionally never executed retroactively.
    public func pendingDeletes(
        after: Date, limit: Int = 500, afterID: Int64 = 0
    ) throws -> [QueuedChange] {
        let statement = try prepare("""
            SELECT id,root_id,relative_path,kind,recorded_at
              FROM change_queue
             WHERE completed=0 AND kind='delete'
               AND recorded_at > ? AND id > ?
             ORDER BY id LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, after.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, afterID) == SQLITE_OK,
              sqlite3_bind_int(statement, 3, Int32(max(1, min(1000, limit)))) == SQLITE_OK
        else { throw databaseFailure() }
        var rows: [QueuedChange] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseFailure() }
            rows.append(QueuedChange(
                id: sqlite3_column_int64(statement, 0),
                rootID: columnText(statement, at: 1),
                relativePath: columnText(statement, at: 2),
                kind: .delete,
                recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return rows
    }

    public func pendingDeleteCount(after: Date) throws -> Int {
        let stmt = try prepare("""
            SELECT COUNT(*) FROM change_queue
            WHERE completed=0 AND kind='delete' AND recorded_at > ?;
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_double(stmt, 1, after.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Any new upload or inventory entry makes an old delete unsafe.
    /// Check both before the move/remove and again when acknowledging it.
    public func deletionIsCurrent(id: Int64, rootID: String, relativePath: String) throws -> Bool {
        let stmt = try prepare("""
            SELECT COUNT(*) FROM change_queue q
            WHERE q.id=? AND q.root_id=? AND q.relative_path=?
              AND q.kind='delete' AND q.completed=0
              AND NOT EXISTS (
                 SELECT 1 FROM file_inventory f
                  WHERE f.root_id=q.root_id AND f.relative_path=q.relative_path
              )
              AND NOT EXISTS (
                 SELECT 1 FROM change_queue other
                  WHERE other.root_id=q.root_id AND other.relative_path=q.relative_path
                    AND other.completed=0 AND other.id<>q.id
              );
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK else { throw databaseFailure() }
        try bind(rootID, at: 2, in: stmt)
        try bind(relativePath, at: 3, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        return sqlite3_column_int64(stmt, 0) == 1
    }

    @discardableResult
    public func acknowledgeDeletion(id: Int64, rootID: String, relativePath: String) throws -> Bool {
        let stmt = try prepare("""
            UPDATE change_queue SET completed=1
            WHERE id=? AND root_id=? AND relative_path=? AND kind='delete' AND completed=0
            AND NOT EXISTS (
                SELECT 1 FROM file_inventory f
                WHERE f.root_id=change_queue.root_id AND f.relative_path=change_queue.relative_path
            )
            AND NOT EXISTS (
                SELECT 1 FROM change_queue q
                WHERE q.root_id=change_queue.root_id AND q.relative_path=change_queue.relative_path
                  AND q.completed=0 AND q.id<>change_queue.id
            );
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK else { throw databaseFailure() }
        try bind(rootID, at: 2, in: stmt)
        try bind(relativePath, at: 3, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
        return sqlite3_changes(connection) == 1
    }

    public func markCompleted(id: Int64) throws {
        let statement = try prepare("UPDATE change_queue SET completed = 1 WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, id) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseFailure()
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseFailure()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseFailure()
        }
        return statement
    }

    private func bind(_ text: String, at index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else { throw databaseFailure() }
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
    }

    private func databaseFailure() -> JournalError {
        JournalError.database(
            connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable"
        )
    }
}
