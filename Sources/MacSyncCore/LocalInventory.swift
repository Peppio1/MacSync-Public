import Foundation
import SQLite3

public struct TrackedItem: Equatable, Sendable {
    public let relativePath: String
    public let kind: String
    public let size: Int64
    public let modifiedAt: Double

    public init(relativePath: String, kind: String, size: Int64, modifiedAt: Double) {
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct ReconciliationResult: Sendable {
    public let inspected: Int
    public let queuedUpserts: Int
    public let queuedDeletes: Int
}

/// Local-only scanner: never follows symbolic links or reads the SMB destination.
/// Errors abort the whole scan, so an unavailable root never becomes a mass deletion.
public enum LocalScanner {
    public static func scan(root: URL, subtree: URL? = nil) throws -> [TrackedItem] {
        let root = root.standardizedFileURL
        let target = (subtree ?? root).standardizedFileURL
        guard root.isFileURL, target.isFileURL,
              target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw JournalError.database("Scan path is outside the source root")
        }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw JournalError.database("Source root is not a regular accessible directory")
        }

        // Missing leaf is valid (deleted file); a missing ancestor is not a missing root.
        guard FileManager.default.fileExists(atPath: target.path) else {
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        var found: [TrackedItem] = []

        func record(_ file: URL) throws -> Bool {
            let metadata = try file.resourceValues(forKeys: keys)
            let kind: String
            if metadata.isSymbolicLink == true {
                kind = "symlink"
            } else if metadata.isDirectory == true {
                kind = "directory"
            } else if metadata.isRegularFile == true {
                kind = "file"
            } else {
                throw JournalError.database("Unsupported filesystem object: " + file.path)
            }
            let prefix = root.path + "/"
            guard file.path.hasPrefix(prefix) else {
                throw JournalError.database("Unexpected path outside root")
            }
            let relative = String(file.path.dropFirst(prefix.count))
            found.append(TrackedItem(
                relativePath: relative,
                kind: kind,
                size: Int64(metadata.fileSize ?? 0),
                modifiedAt: metadata.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
            return kind == "directory"
        }

        if target != root {
            let isDirectory = try record(target)
            if !isDirectory { return found }
        }

        var enumerationError: Error?
        let enumerator = FileManager.default.enumerator(
            at: target, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        )
        guard let enumerator else {
            throw JournalError.database("Cannot enumerate source directory")
        }
        for case let file as URL in enumerator {
            if enumerationError != nil { break }
            do {
                let directory = try record(file)
                if !directory { enumerator.skipDescendants() }
            } catch {
                enumerationError = error
                break
            }
        }
        if let enumerationError { throw enumerationError }
        return found
    }
}

/// An independent local SQLite connection sharing the ChangeJournal schema.
/// Access serially from one monitor worker queue. All inventory and pending-queue
/// mutations are in a single atomic transaction.
public final class LocalInventory {
    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let error = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if handle != nil { sqlite3_close(handle) }
            throw JournalError.database(error)
        }
        db = handle
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA busy_timeout=5000;")
            try execute("""
                CREATE TABLE IF NOT EXISTS file_inventory(
                    root_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    file_size INTEGER NOT NULL,
                    modified_at REAL NOT NULL,
                    PRIMARY KEY(root_id, relative_path)
                );
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS watched_roots(
                    root_id TEXT PRIMARY KEY,
                    absolute_path TEXT NOT NULL,
                    last_event_id TEXT,
                    last_scan_at REAL NOT NULL
                );
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS change_queue(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    root_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('upsert','delete')),
                    recorded_at REAL NOT NULL,
                    completed INTEGER NOT NULL DEFAULT 0
                );
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_inventory_pending_path ON change_queue(root_id, relative_path, completed);")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public func lastEventID(rootID: String) throws -> UInt64? {
        let statement = try prepare("SELECT last_event_id FROM watched_roots WHERE root_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let ptr = sqlite3_column_text(statement, 0) else { return nil }
            return UInt64(String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self)))
        default: throw failure()
        }
    }

    public func rootPath(rootID: String) throws -> String? {
        let statement = try prepare("SELECT absolute_path FROM watched_roots WHERE root_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let ptr = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        default: throw failure()
        }
    }

    public func pendingCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM change_queue WHERE completed=0;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func itemCount(rootID: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM file_inventory WHERE root_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Scan occurs BEFORE the transaction. Errors do not mutate the DB.
    /// A subtree scan affects only its own path and descendants.
    @discardableResult
    public func reconcile(
        rootID: String,
        root: URL,
        subtree: URL? = nil,
        eventID: UInt64? = nil
    ) throws -> ReconciliationResult {
        guard !rootID.isEmpty else { throw JournalError.database("Missing root identifier") }
        let root = root.standardizedFileURL
        let target = (subtree ?? root).standardizedFileURL
        let rows = try LocalScanner.scan(root: root, subtree: subtree)
        let fullScan = target.path == root.path
        let scope = fullScan ? "" : String(target.path.dropFirst(root.path.count + 1))

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if let knownPath = try rootPath(rootID: rootID), knownPath != root.path {
                throw JournalError.database("Source root moved; refusing to reconcile against a different path")
            }

            let before = try readEntries(rootID: rootID)
            let affected = before.filter { fullScan || $0.key == scope || $0.key.hasPrefix(scope + "/") }
            let seen = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0) })
            var upserts = 0
            var deletes = 0
            for row in rows {
                if before[row.relativePath] != row {
                    try store(rootID: rootID, item: row)
                    try enqueue(rootID: rootID, relativePath: row.relativePath, kind: .upsert)
                    upserts += 1
                }
            }

            for (path, _) in affected where seen[path] == nil {
                try remove(rootID: rootID, relativePath: path)
                try enqueue(rootID: rootID, relativePath: path, kind: .delete)
                deletes += 1
            }

            // Keep existing event ID if caller is doing a scan independent of FSEvents.
            let prior = try lastEventID(rootID: rootID)
            let checkpoint: UInt64?
            if let eventID { checkpoint = max(prior ?? 0, eventID) }
            else { checkpoint = prior }
            try saveRoot(rootID: rootID, rootPath: root.path, eventID: checkpoint)
            try execute("COMMIT;")
            return ReconciliationResult(inspected: rows.count, queuedUpserts: upserts, queuedDeletes: deletes)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func readEntries(rootID: String) throws -> [String: TrackedItem] {
        let statement = try prepare("""
            SELECT relative_path, kind, file_size, modified_at
            FROM file_inventory WHERE root_id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        var items: [String: TrackedItem] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            let path = column(statement, 0)
            items[path] = TrackedItem(
                relativePath: path, kind: column(statement, 1),
                size: sqlite3_column_int64(statement, 2),
                modifiedAt: sqlite3_column_double(statement, 3)
            )
        }
        return items
    }

    private func store(rootID: String, item: TrackedItem) throws {
        let statement = try prepare("""
            INSERT INTO file_inventory(root_id,relative_path,kind,file_size,modified_at)
            VALUES(?,?,?,?,?)
            ON CONFLICT(root_id,relative_path) DO UPDATE SET
              kind=excluded.kind,file_size=excluded.file_size,modified_at=excluded.modified_at;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        try bind(item.relativePath, at: 2, statement: statement)
        try bind(item.kind, at: 3, statement: statement)
        guard sqlite3_bind_int64(statement, 4, item.size) == SQLITE_OK,
              sqlite3_bind_double(statement, 5, item.modifiedAt) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func remove(rootID: String, relativePath: String) throws {
        let statement = try prepare("DELETE FROM file_inventory WHERE root_id=? AND relative_path=?;")
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        try bind(relativePath, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func enqueue(rootID: String, relativePath: String, kind: ChangeKind) throws {
        // Coalesce multiple pending changes for the same path. Do not lose
        // successful operations (completed=1) from the audit table.
        let delete = try prepare("""
            DELETE FROM change_queue WHERE root_id=? AND relative_path=? AND completed=0;
            """)
        defer { sqlite3_finalize(delete) }
        try bind(rootID, at: 1, statement: delete)
        try bind(relativePath, at: 2, statement: delete)
        guard sqlite3_step(delete) == SQLITE_DONE else { throw failure() }

        let insert = try prepare("""
            INSERT INTO change_queue(root_id,relative_path,kind,recorded_at) VALUES(?,?,?,?);
            """)
        defer { sqlite3_finalize(insert) }
        try bind(rootID, at: 1, statement: insert)
        try bind(relativePath, at: 2, statement: insert)
        try bind(kind.rawValue, at: 3, statement: insert)
        guard sqlite3_bind_double(insert, 4, Date().timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
    }

    private func saveRoot(rootID: String, rootPath: String, eventID: UInt64?) throws {
        let statement = try prepare("""
            INSERT INTO watched_roots(root_id,absolute_path,last_event_id,last_scan_at)
            VALUES(?,?,?,?)
            ON CONFLICT(root_id) DO UPDATE SET
                absolute_path=excluded.absolute_path,
                last_event_id=excluded.last_event_id,
                last_scan_at=excluded.last_scan_at;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        try bind(rootPath, at: 2, statement: statement)
        if let eventID {
            try bind(String(eventID), at: 3, statement: statement)
        } else {
            guard sqlite3_bind_null(statement, 3) == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        return statement
    }

    private func bind(_ text: String, at index: Int32, statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard code == SQLITE_OK else { throw failure() }
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
    }

    private func failure() -> JournalError {
        JournalError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite closed")
    }
}
