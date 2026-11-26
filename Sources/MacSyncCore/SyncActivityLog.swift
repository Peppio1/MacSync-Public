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
    private let databasePath: String
    // Owned by the serial synchronization worker; never shared across queues.
    public var cycleID: String?
    public var currentJob: QueuedChange?

    public init(path: String, readOnly: Bool = false) throws {
        self.databasePath = path
        var dbHandle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &dbHandle, flags, nil) == SQLITE_OK else {
            if dbHandle != nil { sqlite3_close(dbHandle) }
            throw JournalError.database("Cannot open activity database")
        }
        db = dbHandle
        do {
            if readOnly {
                try execute("PRAGMA busy_timeout=1000; PRAGMA query_only=ON;")
                return
            }
            try SQLiteConnectionSetup.configureWriter(db)
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
            // Additive metadata side table: older log rows and rollback readers
            // retain their original schema. No changes to the queue or inventory.
            try execute("""
                CREATE TABLE IF NOT EXISTS sync_activity_context_v2(
                    activity_id INTEGER PRIMARY KEY, cycle_id TEXT NOT NULL, job_id INTEGER
                );
                CREATE INDEX IF NOT EXISTS idx_activity_context_cycle ON sync_activity_context_v2(cycle_id,activity_id DESC);
                CREATE INDEX IF NOT EXISTS idx_sync_activity_level ON sync_activity(level,id DESC);
                CREATE TRIGGER IF NOT EXISTS prune_activity_context_v2 AFTER DELETE ON sync_activity
                BEGIN DELETE FROM sync_activity_context_v2 WHERE activity_id=OLD.id; END;
                """)
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
        do {
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
        if let cycleID {
            do {
            let rowID=sqlite3_last_insert_rowid(db)
            let context=try prepare("INSERT INTO sync_activity_context_v2(activity_id,cycle_id,job_id) VALUES(?,?,?);")
            defer { sqlite3_finalize(context) }
            guard sqlite3_bind_int64(context,1,rowID)==SQLITE_OK else { throw failure() }
            try bind(cycleID,2,context)
            if let job=currentJob, job.rootID==rootID, job.relativePath==relativePath {
                guard sqlite3_bind_int64(context,3,job.id)==SQLITE_OK else { throw failure() }
            } else { guard sqlite3_bind_null(context,3)==SQLITE_OK else { throw failure() } }
            guard sqlite3_step(context)==SQLITE_DONE else { throw failure() }
            } catch {
                // Optional correlation must never turn a logged operation into a transfer failure.
                TechnicalFallbackLog.record(databasePath:databasePath,cycleID:cycleID,action:"activity_context_failed",message:SyncDiagnostic.describe(error))
            }
        }
        } catch {
            // Diagnostics cannot rely on a database which just failed.
            TechnicalFallbackLog.record(databasePath:databasePath,cycleID:cycleID,action:"activity_write_failed",
                message:SyncDiagnostic.describe(error))
            throw error
        }
    }

    public func technicalPage(limit:Int = 100, level:SyncLogLevel? = nil, search:String = "",
                              beforeID:Int64? = nil, afterID:Int64? = nil,
                              since: Date? = nil) throws -> [TechnicalLogRow] {
        let check=try prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_activity_context_v2';")
        let rc=sqlite3_step(check)
        sqlite3_finalize(check)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw failure() }
        let hasContext = rc==SQLITE_ROW
        var sql = "SELECT a.id,a.event_time,a.level,a.root_id,a.action,a.relative_path,a.bytes,a.duration_seconds,a.message,"
        sql += hasContext ? "c.cycle_id,c.job_id FROM sync_activity a LEFT JOIN sync_activity_context_v2 c ON c.activity_id=a.id" : "NULL,NULL FROM sync_activity a"
        sql += " WHERE a.id<? AND a.id>?"
        if since != nil { sql += " AND a.event_time>=?" }
        if level != nil { sql += " AND a.level=?" }
        if !search.isEmpty {
            sql += " AND (instr(lower(a.relative_path),lower(?))>0 OR instr(lower(a.message),lower(?))>0 OR instr(lower(a.action),lower(?))>0 OR instr(lower(a.root_id),lower(?))>0"
            if hasContext { sql += " OR instr(lower(c.cycle_id),lower(?))>0 OR CAST(c.job_id AS TEXT)=?" }
            sql += ")"
        }
        sql += " ORDER BY a.id DESC LIMIT ?;"
        let query=try prepare(sql)
        defer { sqlite3_finalize(query) }
        guard sqlite3_bind_int64(query,1,beforeID ?? Int64.max)==SQLITE_OK,
              sqlite3_bind_int64(query,2,afterID ?? 0)==SQLITE_OK else { throw failure() }
        var index:Int32=3
        if let since {
            guard sqlite3_bind_double(query,index,since.timeIntervalSince1970)==SQLITE_OK else { throw failure() }
            index += 1
        }
        if let level { try bind(level.rawValue,index,query); index += 1 }
        if !search.isEmpty {
            for _ in 0..<(hasContext ? 6 : 4) { try bind(search,index,query); index += 1 }
        }
        guard sqlite3_bind_int(query,index,Int32(max(1,min(limit,5000))))==SQLITE_OK else { throw failure() }
        var result:[TechnicalLogRow]=[]
        while true {
            let step=sqlite3_step(query)
            if step==SQLITE_DONE { return result }
            guard step==SQLITE_ROW else { throw failure() }
            let entry=SyncLogEntry(id:sqlite3_column_int64(query,0),timestamp:Date(timeIntervalSince1970:sqlite3_column_double(query,1)),
                level:textColumn(query,2),rootID:textColumn(query,3),action:textColumn(query,4),relativePath:textColumn(query,5),
                bytes:sqlite3_column_int64(query,6),durationSeconds:sqlite3_column_double(query,7),message:textColumn(query,8))
            result.append(TechnicalLogRow(entry:entry,
                cycleID:sqlite3_column_type(query,9)==SQLITE_NULL ? nil : textColumn(query,9),
                jobID:sqlite3_column_type(query,10)==SQLITE_NULL ? nil : sqlite3_column_int64(query,10)))
        }
    }

    public func recent(limit: Int = 200, level: SyncLogLevel? = nil, search: String = "") throws -> [SyncLogEntry] {
        let query = try prepare("""
            SELECT id,event_time,level,root_id,action,relative_path,bytes,duration_seconds,message
            FROM sync_activity
            WHERE (? = '' OR level = ?)
              AND (? = '' OR instr(lower(relative_path), lower(?)) > 0
                          OR instr(lower(message), lower(?)) > 0)
            ORDER BY id DESC LIMIT ?;
            """)
        defer { sqlite3_finalize(query) }
        let selected = level?.rawValue ?? ""
        try bind(selected, 1, query)
        try bind(selected, 2, query)
        try bind(search, 3, query)
        try bind(search, 4, query)
        try bind(search, 5, query)
        guard sqlite3_bind_int(query, 6, Int32(max(1, min(limit, 5000)))) == SQLITE_OK else { throw failure() }
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

    public func exportText(limit: Int = 5000, level: SyncLogLevel? = nil, search: String = "") throws -> String {
        let iso = ISO8601DateFormatter()
        var rows = ["timestamp\tlevel\troot\taction\trelative_path\tbytes\tseconds\tmessage"]
        for entry in try recent(limit: limit, level: level, search: search).reversed() {
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

    /// Keep logs bounded without touching any other SQLite table or photo.
    /// The most recent records are kept, subject also to a maximum age.
    /// Invoke on a background worker (never in the SwiftUI render loop).
    @discardableResult
    public func prune(retainNewest: Int = 20_000, maxAgeDays: Int = 90) throws -> Int {
        guard (100...100_000).contains(retainNewest),
              (7...3650).contains(maxAgeDays) else {
            throw JournalError.database("Invalid activity-log retention policy")
        }
        let stmt = try prepare("""
            DELETE FROM sync_activity
             WHERE action NOT GLOB 'timing_distribution_*'
               AND action NOT IN ('metric_resource_interval','metric_resource_samples_dropped')
               AND (event_time < ? OR id NOT IN (
                    SELECT id FROM sync_activity
                    WHERE action NOT GLOB 'timing_distribution_*'
                      AND action NOT IN ('metric_resource_interval','metric_resource_samples_dropped')
                    ORDER BY id DESC LIMIT ?
                ));
            """)
        defer { sqlite3_finalize(stmt) }
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        guard sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int(stmt, 2, Int32(retainNewest)) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        return Int(sqlite3_changes(db))
    }

    /// Separate diagnostic budget without changing the queue or existing tables.
    /// Older versions can still read the same log and apply their old retention.
    public func pruneDiagnostics(retainNewest:Int=DiagnosticCollectionLevel.maxRetainedSamples,maxAgeDays:Int)throws->Int {
        guard (100...100_000).contains(retainNewest),(1...90).contains(maxAgeDays) else {
            throw JournalError.database("Invalid diagnostic retention policy")
        }
        let stmt=try prepare("""
            DELETE FROM sync_activity
            WHERE (action GLOB 'timing_distribution_*' OR action IN ('metric_resource_interval','metric_resource_samples_dropped'))
              AND (event_time < ? OR id NOT IN (
                SELECT id FROM sync_activity
                WHERE action GLOB 'timing_distribution_*' OR action IN ('metric_resource_interval','metric_resource_samples_dropped')
                ORDER BY id DESC LIMIT ?
              ));
            """)
        defer { sqlite3_finalize(stmt) }
        let cutoff=Date().addingTimeInterval(-Double(maxAgeDays)*86400)
        guard sqlite3_bind_double(stmt,1,cutoff.timeIntervalSince1970)==SQLITE_OK,
              sqlite3_bind_int(stmt,2,Int32(retainNewest))==SQLITE_OK,
              sqlite3_step(stmt)==SQLITE_DONE else { throw failure() }
        return Int(sqlite3_changes(db))
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
