import Foundation
import SQLite3
import Darwin

public enum ChangeKind: String, Codable, Sendable {
    case upsert
    case delete
}

/// Persistent origin of a queue operation. Older databases remain explicitly
/// unknown; never guess that an old job was an initial inventory job.
public enum QueuedChangeOrigin: String, Sendable {
    case initialInventory = "initial_inventory"
    case sourceMonitor = "source_monitor"
    case archiveAudit = "archive_audit"
    case destinationRebind = "destination_rebind"
    case legacyUnknown = "legacy_unknown"
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
struct NameRectificationProgressRecord: Codable, Equatable {
    let rootID: String
    let relativePath: String
    var sourceRequired: Bool
    var destinationRequired: Bool
    var sourceCompleted: Bool
    var destinationCompleted: Bool
}

public final class ChangeJournal {
    private var connection: OpaquePointer?
    private let databasePath: String
    // Test-only shadow evidence. Never grants a deletion or changes a queue decision.
    var experimentalSourceNameLineage = false

    /// UI readers use a strict read-only connection without schema DDL or
    /// journal-mode changes. Existing operational writers retain the original
    /// constructor behavior and all transactional safety checks.
    public init(path: String, readOnly: Bool = false) throws {
        self.databasePath = path
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let description = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if handle != nil { sqlite3_close(handle) }
            throw JournalError.database("Unable to open SQLite: " + description)
        }
        connection = handle

        do {
            if readOnly {
                try execute("PRAGMA busy_timeout=1000; PRAGMA query_only=ON;")
                return
            }
            try SQLiteConnectionSetup.configureWriter(connection)
            try execute("PRAGMA synchronous=FULL;")
            try execute("""
                CREATE TABLE IF NOT EXISTS change_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    root_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('upsert','delete')),
                    recorded_at REAL NOT NULL,
                    completed INTEGER NOT NULL DEFAULT 0,
                    origin TEXT NOT NULL DEFAULT 'legacy_unknown'
                );
                """)
            // Additive, local-only migration. Old pending rows retain their
            // original IDs and remain unclassified, never retroactively marked
            // as initial/verified by an audit.
            try SQLiteConnectionSetup.addColumnIfMissing(connection,table:"change_queue",column:"origin",
                sql:"ALTER TABLE change_queue ADD COLUMN origin TEXT NOT NULL DEFAULT 'legacy_unknown';")
            try execute("CREATE TABLE IF NOT EXISTS name_rectification_batch(singleton INTEGER PRIMARY KEY CHECK(singleton=1), plan TEXT NOT NULL, next_move INTEGER NOT NULL DEFAULT 0, progress TEXT NOT NULL DEFAULT '[]');")
            // Child completion index, not another rename plan: identities and
            // old/new names remain exclusively in name_rectification_batch.
            // Constant-time upserts avoid re-encoding thousands of statuses
            // after every successful rename.
            try execute("CREATE TABLE IF NOT EXISTS name_rectification_completed(root_id TEXT NOT NULL, relative_path TEXT NOT NULL, side TEXT NOT NULL CHECK(side IN ('source','destination')), PRIMARY KEY(root_id,relative_path,side));")
            // New coordinated operations have independent durable records.
            // Never rewrite an older batch or lose its recorded protection.
            try execute("CREATE TABLE IF NOT EXISTS name_rectification_groups(root_id TEXT NOT NULL, relative_path TEXT NOT NULL, plan TEXT NOT NULL, PRIMARY KEY(root_id,relative_path));")
            // Additive history: old releases ignore it, pending plans keep
            // their schema. No receipt is an authorization for remote mutation.
            try execute(NameRectificationReceipt.schemaSQL)
            try execute(QueueCompletionLedger.schemaSQL)
            // Existing profiles retain their approved plan, next_move and
            // exact fingerprints. Adding a column never rewrites the plan.
            try SQLiteConnectionSetup.addColumnIfMissing(connection,table:"name_rectification_batch",column:"progress",
                sql:"ALTER TABLE name_rectification_batch ADD COLUMN progress TEXT NOT NULL DEFAULT '[]';")
            try execute("CREATE TABLE IF NOT EXISTS name_rectification_scopes(root_id TEXT NOT NULL, path TEXT NOT NULL, expires REAL NOT NULL, PRIMARY KEY(root_id,path));")
            try execute("CREATE TABLE IF NOT EXISTS name_scan_cache(root_id TEXT NOT NULL, side TEXT NOT NULL, snapshot TEXT NOT NULL, PRIMARY KEY(root_id, side));")
            try execute("CREATE TABLE IF NOT EXISTS publication_intents(job_id INTEGER PRIMARY KEY, root_id TEXT NOT NULL, relative_path TEXT NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS upload_retry(scope TEXT NOT NULL, root_id TEXT NOT NULL, job_id INTEGER NOT NULL, attempts INTEGER NOT NULL, next_at REAL NOT NULL, reason TEXT NOT NULL, PRIMARY KEY(scope,root_id,job_id));")
            try execute("CREATE TABLE IF NOT EXISTS transfer_recovery(job_id INTEGER PRIMARY KEY, root_id TEXT NOT NULL, relative_path TEXT NOT NULL, record TEXT NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS queue_rebuild_hold(singleton INTEGER PRIMARY KEY CHECK(singleton=1), token TEXT NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS retired_delete_evidence(job_id INTEGER PRIMARY KEY);")
            try execute("CREATE TABLE IF NOT EXISTS blocked_name_jobs(job_id INTEGER PRIMARY KEY);")
            try execute("CREATE TABLE IF NOT EXISTS retired_publication_evidence(job_id INTEGER PRIMARY KEY);")
            try execute("CREATE TABLE IF NOT EXISTS verified_content_cache(root_id TEXT NOT NULL, relative_path TEXT NOT NULL, binding TEXT NOT NULL, source_stamp TEXT NOT NULL, target_stamp TEXT NOT NULL, PRIMARY KEY(root_id,relative_path));")
            try execute("CREATE TABLE IF NOT EXISTS directory_bindings(root_id TEXT NOT NULL, role TEXT NOT NULL, stamp TEXT NOT NULL, PRIMARY KEY(root_id,role));")
            try execute("CREATE INDEX IF NOT EXISTS idx_queue_pending ON change_queue(completed, id);")
            try execute("CREATE INDEX IF NOT EXISTS idx_queue_origin ON change_queue(origin, completed, kind);")
            try execute("CREATE INDEX IF NOT EXISTS idx_queue_uploads ON change_queue(completed, kind, id);")
            try execute("CREATE INDEX IF NOT EXISTS idx_queue_current_path ON change_queue(root_id, relative_path, completed, id);")
            try execute("CREATE INDEX IF NOT EXISTS idx_queue_delete_pages ON change_queue(completed, kind, length(relative_path) DESC, id);")
            try execute("""
                CREATE TABLE IF NOT EXISTS mirror_attempts(
                    job_id INTEGER PRIMARY KEY, root_id TEXT NOT NULL, attempted_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_mirror_attempts_time ON mirror_attempts(root_id, attempted_at);
                CREATE TABLE IF NOT EXISTS mirror_safety_lock(
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1), reason TEXT NOT NULL
                );
                """)
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    /// A cached equality is only reused for the same pair of root bindings
    /// and both complete POSIX fingerprints. Never used by deep audits.
    private func cacheStamp(_ value:SeedFileFingerprint) throws -> String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        return String(decoding:try encoder.encode(value),as:UTF8.self)
    }

    public func cachedContentMatches(rootID:String,path:String,binding:String,source:SeedFileFingerprint,target:SeedFileFingerprint) throws -> Bool {
        let stmt=try prepare("SELECT 1 FROM verified_content_cache WHERE root_id=? AND relative_path=? AND binding=? AND source_stamp=? AND target_stamp=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt); try bind(path,at:2,in:stmt); try bind(binding,at:3,in:stmt)
        try bind(cacheStamp(source),at:4,in:stmt); try bind(cacheStamp(target),at:5,in:stmt)
        let rc=sqlite3_step(stmt)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw databaseFailure() }
        return rc==SQLITE_ROW
    }

    public func storeContentMatch(rootID:String,path:String,binding:String,source:SeedFileFingerprint,target:SeedFileFingerprint) throws {
        let stmt=try prepare("INSERT OR REPLACE INTO verified_content_cache(root_id,relative_path,binding,source_stamp,target_stamp) VALUES(?,?,?,?,?);")
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt); try bind(path,at:2,in:stmt); try bind(binding,at:3,in:stmt)
        try bind(cacheStamp(source),at:4,in:stmt); try bind(cacheStamp(target),at:5,in:stmt)
        guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
    }

    public func clearVerifiedContentCache() throws {
        try execute("DELETE FROM verified_content_cache;")
    }

    /// Persisted across application restart. No transfer or delete is
    /// permitted until an explicit complete archive audit rebuilds the queue.
    public func queueRebuildToken() throws -> String? {
        let stmt = try prepare("SELECT token FROM queue_rebuild_hold WHERE singleton=1;")
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw databaseFailure() }
        return columnText(stmt,at:0)
    }

    /// Used when the exclusion policy changes, before updating preferences.
    /// A crash between the two operations remains safely held.
    public func requireQueueRebuild() throws {
        try clearVerifiedContentCache()
        let stmt=try prepare("INSERT OR REPLACE INTO queue_rebuild_hold(singleton,token) VALUES(1,?);")
        defer { sqlite3_finalize(stmt) }
        try bind(UUID().uuidString,at:1,in:stmt)
        guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
    }

    /// A durable maintenance barrier, separate from any queue row.
    public func requireUnilateralNameAudit() throws {
        let stmt=try prepare("INSERT OR REPLACE INTO queue_rebuild_hold(singleton,token) VALUES(1,?);")
        defer { sqlite3_finalize(stmt) }
        try bind("unilateral-name:"+UUID().uuidString,at:1,in:stmt)
        guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
    }

    public func unilateralNameAuditRequired() throws -> Bool {
        // Old inventories may predate the hold table. Do not run DDL on a
        // read-only connection just to check whether maintenance is pending.
        let stmt=try prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='queue_rebuild_hold';")
        let rc=sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc == SQLITE_DONE { return false }
        guard rc == SQLITE_ROW else { throw databaseFailure() }
        return try queueRebuildToken()?.hasPrefix("unilateral-name:") == true
    }

    @discardableResult public func retireExcludedJobs() throws -> Int {
        guard FileExclusionPolicy.ignoreDSStore else { return 0 }
        try execute("UPDATE change_queue SET completed=1 WHERE completed=0 AND instr('/'||relative_path||'/','/.DS_Store/')>0;")
        return Int(sqlite3_changes(connection))
    }

    /// Requires the caller to have drained BOTH sync and inventory workers.
    /// Keep historical IDs, deletion evidence and all publication intents.
    /// No filesystem work on the source or destination.
    @discardableResult
    public func resetPendingQueue(backup: URL) throws -> Int {
        try ArchiveDatabaseSafety.backup(URL(fileURLWithPath:databasePath),to:backup)
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("INSERT OR IGNORE INTO retired_delete_evidence(job_id) SELECT id FROM change_queue WHERE completed=0 AND kind='delete';")
            try execute("INSERT OR IGNORE INTO retired_publication_evidence(job_id) SELECT q.id FROM change_queue q JOIN publication_intents p ON p.job_id=q.id WHERE q.completed=0 AND q.kind='upsert';")
            try clearVerifiedContentCache()
            try clearUploadRetries()
            try execute("UPDATE change_queue SET completed=1 WHERE completed=0;")
            let count = Int(sqlite3_changes(connection))
            let stmt = try prepare("INSERT OR REPLACE INTO queue_rebuild_hold(singleton,token) VALUES(1,?);")
            defer { sqlite3_finalize(stmt) }
            try bind(UUID().uuidString,at:1,in:stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
            try execute("COMMIT;")
            return count
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Only revalidate old deletion evidence from the same authorization.
    /// Do not generate DELETEs from arbitrary server-only findings.
    /// Original IDs and timestamps preserve the original authorization cutoff.
    @discardableResult
    public func completeQueueRebuild(token:String, verifiedExtraIDs:Set<String> = [],
                                     authorizationCutoff:Int64 = Int64.max,
                                     shouldContinue:() -> Bool = { true }) throws -> Int {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard try queueRebuildToken() == token, shouldContinue() else { throw SeedVerificationError.cancelled }
            if token.hasPrefix("unilateral-name:"), try hasPendingNameRectification() {
                throw JournalError.database("Rettifica pendente: risolvere prima i nomi dall'esito incerto")
            }
            let query = try prepare("""
                SELECT q.id,q.root_id,q.relative_path FROM retired_delete_evidence e
                JOIN change_queue q ON q.id=e.job_id
                WHERE q.completed=1 AND q.kind='delete' AND q.id>?;
                """)
            defer { sqlite3_finalize(query) }
            guard sqlite3_bind_int64(query,1,authorizationCutoff) == SQLITE_OK else { throw databaseFailure() }
            var eligible:[Int64] = []
            var rc = sqlite3_step(query)
            while rc == SQLITE_ROW {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                let root = columnText(query,at:1), path = columnText(query,at:2)
                if verifiedExtraIDs.contains(root + "\0" + path) && WindowsPathSafety.validRelativePath(path) {
                    eligible.append(sqlite3_column_int64(query,0))
                }
                rc = sqlite3_step(query)
            }
            guard rc == SQLITE_DONE else { throw databaseFailure() }
            let update = try prepare("""
                UPDATE change_queue SET completed=0
                WHERE id=? AND completed=1 AND kind='delete'
                  AND NOT EXISTS(SELECT 1 FROM file_inventory f WHERE f.root_id=change_queue.root_id AND f.relative_path=change_queue.relative_path)
                  AND NOT EXISTS(SELECT 1 FROM change_queue newer WHERE newer.root_id=change_queue.root_id AND newer.relative_path=change_queue.relative_path AND (newer.completed=0 OR newer.id>change_queue.id));
                """)
            defer { sqlite3_finalize(update) }
            var restored=0
            for id in eligible {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                guard sqlite3_bind_int64(update,1,id) == SQLITE_OK,
                      sqlite3_step(update) == SQLITE_DONE else { throw databaseFailure() }
                restored += Int(sqlite3_changes(connection))
            }
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            // A retired deletion is evidence for THIS rebuild, not a
            // permanent right to delete a future, unrelated destination.
            // Its original queue row and the verified backup retain history.
            try execute("DELETE FROM retired_delete_evidence;")
            // Even a metadata match cannot prove that an interrupted
            // publication actually succeeded. Requeue unresolved retired
            // publication paths for live SHA-256 reconciliation; existing
            // audit/monitor jobs win. No physical files are touched here.
            try execute("""
                INSERT INTO change_queue(root_id,relative_path,kind,recorded_at,origin)
                SELECT DISTINCT q.root_id,q.relative_path,'upsert',strftime('%s','now'),'legacy_unknown'
                FROM retired_publication_evidence e
                JOIN change_queue q ON q.id=e.job_id
                JOIN publication_intents p ON p.job_id=q.id
                JOIN file_inventory f ON f.root_id=q.root_id AND f.relative_path=q.relative_path AND f.kind='file'
                WHERE NOT EXISTS(SELECT 1 FROM change_queue newer WHERE newer.root_id=q.root_id AND newer.relative_path=q.relative_path AND newer.completed=0);
                """)
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("DELETE FROM queue_rebuild_hold WHERE singleton=1;")
            try execute("COMMIT;")
            return restored
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    public func enqueue(rootID: String, relativePath: String, kind: ChangeKind,
                        origin: QueuedChangeOrigin = .sourceMonitor) throws -> Int64 {
        guard !rootID.isEmpty, !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              !relativePath.contains("\0") else {
            throw JournalError.database("Unsafe or empty relative path")
        }

        let statement = try prepare("""
            INSERT INTO change_queue(root_id, relative_path, kind, recorded_at, origin)
            VALUES (?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }

        try bind(rootID, at: 1, in: statement)
        try bind(relativePath, at: 2, in: statement)
        try bind(kind.rawValue, at: 3, in: statement)
        guard sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw databaseFailure()
        }
        try bind(origin.rawValue, at: 5, in: statement)
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
    /// Capture a bounded snapshot of pending work. Newly queued events
    /// receive larger AUTOINCREMENT IDs and wait until the next cycle.
    /// First opt-in after migration establishes the target baseline. Never
    /// replace an existing binding automatically, even on reconnection.
    /// Job IDs change when a new monitor event supersedes an operation.
    /// Root-level holds are reserved for incompatible publication facilities.
    // Invalid names stay pending until a separate source event replaces them.
    @discardableResult func noteBlockedName(_ job:QueuedChange) throws -> Bool {
        let stmt=try prepare("INSERT OR IGNORE INTO blocked_name_jobs(job_id) VALUES(?);")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt,1,job.id)==SQLITE_OK,sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
        return sqlite3_changes(connection)==1
    }

    func retryBlocked(_ job:QueuedChange, now:Date) throws -> Bool {
        let stmt=try prepare("SELECT 1 FROM upload_retry WHERE root_id=? AND (job_id=? OR scope='root') AND next_at>? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        try bind(job.rootID,at:1,in:stmt)
        guard sqlite3_bind_int64(stmt,2,job.id)==SQLITE_OK,sqlite3_bind_double(stmt,3,now.timeIntervalSince1970)==SQLITE_OK else { throw databaseFailure() }
        let rc=sqlite3_step(stmt)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw databaseFailure() }
        return rc==SQLITE_ROW
    }

    func recordRetry(_ job:QueuedChange, rootWide:Bool, reason:String, now:Date, initial:Double) throws {
        let stmt=try prepare("""
            INSERT INTO upload_retry(scope,root_id,job_id,attempts,next_at,reason)
            VALUES(?,?,?,1,?,?)
            ON CONFLICT(scope,root_id,job_id) DO UPDATE SET
              attempts=MIN(upload_retry.attempts+1,8),
              next_at=?+MIN(3600,?*(1 << MIN(upload_retry.attempts,7))),
              reason=excluded.reason;
            """)
        defer { sqlite3_finalize(stmt) }
        try bind(rootWide ? "root" : "job",at:1,in:stmt); try bind(job.rootID,at:2,in:stmt)
        let epoch=now.timeIntervalSince1970
        guard sqlite3_bind_int64(stmt,3,rootWide ? 0 : job.id)==SQLITE_OK,
              sqlite3_bind_double(stmt,4,epoch+min(3600,initial))==SQLITE_OK else { throw databaseFailure() }
        try bind(reason,at:5,in:stmt)
        guard sqlite3_bind_double(stmt,6,epoch)==SQLITE_OK,
              sqlite3_bind_double(stmt,7,initial)==SQLITE_OK,sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
    }

    func clearRetry(_ job:QueuedChange) throws {
        let stmt=try prepare("DELETE FROM upload_retry WHERE root_id=? AND scope='job' AND job_id=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(job.rootID,at:1,in:stmt)
        guard sqlite3_bind_int64(stmt,2,job.id)==SQLITE_OK,sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
    }

    public func clearUploadRetries() throws { try execute("DELETE FROM upload_retry;") }

    // Root-wide upload retries are reserved for the former exclusive publication probe.
    public func clearLegacyPublicationRetries() throws { try execute("DELETE FROM upload_retry WHERE scope='root';") }

    func saveTransferRecovery(_ job:QueuedChange, record:String) throws {
        guard try uploadIsCurrent(job) else { throw MountedCopyError.sourceChanging }
        let stmt=try prepare("INSERT OR REPLACE INTO transfer_recovery(job_id,root_id,relative_path,record) VALUES(?,?,?,?);")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt,1,job.id)==SQLITE_OK else { throw databaseFailure() }
        try bind(job.rootID,at:2,in:stmt); try bind(job.relativePath,at:3,in:stmt); try bind(record,at:4,in:stmt)
        guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
    }

    func transferRecovery(_ job:QueuedChange) throws -> String? {
        let stmt=try prepare("SELECT record FROM transfer_recovery WHERE job_id=? AND root_id=? AND relative_path=?;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt,1,job.id)==SQLITE_OK else { throw databaseFailure() }
        try bind(job.rootID,at:2,in:stmt); try bind(job.relativePath,at:3,in:stmt)
        let rc=sqlite3_step(stmt)
        if rc==SQLITE_DONE { return nil }
        guard rc==SQLITE_ROW else { throw databaseFailure() }
        return columnText(stmt,at:0)
    }

    func clearTransferRecovery(_ job:QueuedChange) throws {
        let stmt=try prepare("DELETE FROM transfer_recovery WHERE job_id=? AND root_id=? AND relative_path=?;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt,1,job.id)==SQLITE_OK else { throw databaseFailure() }
        try bind(job.rootID,at:2,in:stmt); try bind(job.relativePath,at:3,in:stmt)
        guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
    }

    /// Carry an unresolved publication across a queue reset. The recovery
    /// record still contains the original target/source/volume fingerprints.
    /// Ambiguous multiple intents are left untouched and the job is deferred.
    func adoptRetiredPublication(_ job:QueuedChange) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard try uploadIsCurrent(job) else { throw MountedCopyError.sourceChanging }
            let query=try prepare("""
                SELECT p.job_id FROM retired_publication_evidence e
                JOIN publication_intents p ON p.job_id=e.job_id
                WHERE p.root_id=? AND p.relative_path=? AND p.job_id<>?;
                """)
            defer { sqlite3_finalize(query) }
            try bind(job.rootID,at:1,in:query); try bind(job.relativePath,at:2,in:query)
            guard sqlite3_bind_int64(query,3,job.id)==SQLITE_OK else { throw databaseFailure() }
            var ids:[Int64]=[]
            var rc=sqlite3_step(query)
            while rc==SQLITE_ROW { ids.append(sqlite3_column_int64(query,0)); rc=sqlite3_step(query) }
            guard rc==SQLITE_DONE else { throw databaseFailure() }
            if let old=ids.first {
                guard ids.count==1, try !hasPublicationIntent(job), try transferRecovery(job)==nil else {
                    throw MountedCopyError.destinationChanging
                }
                for table in ["publication_intents","transfer_recovery"] {
                    let move=try prepare("UPDATE \(table) SET job_id=? WHERE job_id=? AND root_id=? AND relative_path=?;")
                    defer { sqlite3_finalize(move) }
                    guard sqlite3_bind_int64(move,1,job.id)==SQLITE_OK,
                          sqlite3_bind_int64(move,2,old)==SQLITE_OK else { throw databaseFailure() }
                    try bind(job.rootID,at:3,in:move); try bind(job.relativePath,at:4,in:move)
                    guard sqlite3_step(move)==SQLITE_DONE else { throw databaseFailure() }
                }
                let remove=try prepare("DELETE FROM retired_publication_evidence WHERE job_id=?;")
                defer { sqlite3_finalize(remove) }
                guard sqlite3_bind_int64(remove,1,old)==SQLITE_OK,sqlite3_step(remove)==SQLITE_DONE else { throw databaseFailure() }
            }
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    public func recordPublicationIntent(_ job: QueuedChange) throws {
        let stmt = try prepare("INSERT OR IGNORE INTO publication_intents(job_id,root_id,relative_path) VALUES(?,?,?);")
        defer { sqlite3_finalize(stmt) }
        guard try uploadIsCurrent(job), sqlite3_bind_int64(stmt,1,job.id) == SQLITE_OK else { throw MountedCopyError.sourceChanging }
        try bind(job.rootID,at:2,in:stmt); try bind(job.relativePath,at:3,in:stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
    }
    public func hasPublicationIntent(_ job: QueuedChange) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM publication_intents WHERE job_id=? AND root_id=? AND relative_path=?;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt,1,job.id) == SQLITE_OK else { throw databaseFailure() }
        try bind(job.rootID,at:2,in:stmt); try bind(job.relativePath,at:3,in:stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw databaseFailure() }
        return rc == SQLITE_ROW
    }
    public func clearPublicationIntent(_ job: QueuedChange) throws {
        let stmt = try prepare("DELETE FROM publication_intents WHERE job_id=? AND root_id=? AND relative_path=?;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt,1,job.id) == SQLITE_OK else { throw databaseFailure() }
        try bind(job.rootID,at:2,in:stmt); try bind(job.relativePath,at:3,in:stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
    }

    func pendingNameRectification() throws -> (data: Data, offset: Int, progress: Data)? {
        let statement = try prepare("SELECT plan,next_move,progress FROM name_rectification_batch WHERE singleton=1;")
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return (Data(columnText(statement, at: 0).utf8), Int(sqlite3_column_int64(statement, 1)), Data(columnText(statement, at: 2).utf8))
        case SQLITE_DONE: return nil
        default: throw databaseFailure()
        }
    }

    public func hasPendingNameRectification() throws -> Bool {
        if try pendingNameRectification() != nil { return true }
        let stmt = try prepare("SELECT 1 FROM name_rectification_groups LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw databaseFailure() }
        return rc == SQLITE_ROW
    }

    func coordinatedNameGroups() throws -> [(rootID:String,path:String,data:Data)] {
        let stmt = try prepare("SELECT root_id,relative_path,plan FROM name_rectification_groups ORDER BY length(relative_path) DESC,root_id,relative_path;")
        defer { sqlite3_finalize(stmt) }
        var rows: [(String,String,Data)] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw databaseFailure() }
            rows.append((columnText(stmt,at:0),columnText(stmt,at:1),Data(columnText(stmt,at:2).utf8)))
        }
    }

    func saveCoordinatedNameGroup(rootID:String,path:String,data:Data) throws {
        let stmt = try prepare("""
            INSERT INTO name_rectification_groups(root_id,relative_path,plan) VALUES(?,?,?)
            ON CONFLICT(root_id,relative_path) DO UPDATE SET plan=excluded.plan;
            """)
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt); try bind(path,at:2,in:stmt)
        try bind(String(decoding:data,as:UTF8.self),at:3,in:stmt)
        guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
    }

    /// Finish one verified group and patch only the cached rows affected by
    /// its successful rename. Failed/rolled-back rows stay in the list.
    func finishCoordinatedNameGroup(rootID:String,path:String,
                                    completed:[(item:IncompatibleName,newName:String)],
                                    restoredSource:(item:IncompatibleName,newName:String,volume:VolumeFingerprint)? = nil,
                                    recordReconciliationScope:Bool = true,
                                    receipt:NameRectificationReceipt? = nil) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for entry in completed {
                let item = entry.item
                guard item.rootID==rootID, item.relativePath==path else {
                    throw JournalError.database("Gruppo rettifica incoerente")
                }
                let parent = path.split(separator:"/").dropLast().joined(separator:"/")
                let renamed = parent.isEmpty ? entry.newName : parent+"/"+entry.newName
                if item.side == .destination && recordReconciliationScope {
                    let scope = try prepare("""
                        INSERT OR REPLACE INTO name_rectification_scopes(root_id,path,expires)
                        VALUES(?,?,strftime('%s','now')+604800);
                        """)
                    defer { sqlite3_finalize(scope) }
                    try bind(rootID,at:1,in:scope); try bind(renamed,at:2,in:scope)
                    guard sqlite3_step(scope)==SQLITE_DONE else { throw databaseFailure() }
                }
                if let cached = try nameScan(rootID:rootID,side:item.side), cached.rootPath==item.rootPath {
                    let rows = cached.rows.compactMap { row -> IncompatibleName? in
                        if row.relativePath==path { return nil }
                        guard item.isDirectory, row.relativePath.hasPrefix(path+"/") else { return row }
                        return IncompatibleName(rootID:row.rootID,rootPath:row.rootPath,
                            relativePath:renamed+String(row.relativePath.dropFirst(path.count)),
                            objectKind:row.objectKind,side:row.side,reason:row.reason,
                            affectedDescendants:row.affectedDescendants)
                    }
                    try saveNameScan(NameScanSnapshot(rootID:cached.rootID,side:cached.side,
                        rootPath:cached.rootPath,volume:cached.volume,date:cached.date,rows:rows))
                }
            }
            // An audit may have refreshed the cache while the source had its
            // temporary corrected spelling. Restore the original cached row
            // only after the engine has verified the compensating rename.
            if let restored = restoredSource {
                let item = restored.item
                guard item.side == .source, item.rootID == rootID, item.relativePath == path else {
                    throw JournalError.database("Ripristino rettifica incoerente")
                }
                if let cached = try nameScan(rootID:rootID,side:.source),
                   cached.rootPath == item.rootPath, cached.volume == restored.volume {
                    let parent = path.split(separator:"/").dropLast().joined(separator:"/")
                    let renamed = parent.isEmpty ? restored.newName : parent+"/"+restored.newName
                    var seen = Set<String>()
                    var rows = cached.rows.compactMap { row -> IncompatibleName? in
                        let updated: IncompatibleName
                        if item.isDirectory, row.relativePath.hasPrefix(renamed+"/") {
                            updated = IncompatibleName(rootID:row.rootID,rootPath:row.rootPath,
                                relativePath:path+String(row.relativePath.dropFirst(renamed.count)),
                                objectKind:row.objectKind,side:row.side,reason:row.reason,
                                affectedDescendants:row.affectedDescendants)
                        } else { updated = row }
                        return seen.insert(updated.relativePath).inserted ? updated : nil
                    }
                    if seen.insert(path).inserted { rows.append(item) }
                    try saveNameScan(NameScanSnapshot(rootID:cached.rootID,side:cached.side,
                        rootPath:cached.rootPath,volume:cached.volume,date:cached.date,rows:rows))
                }
            }
            if let receipt {
                guard completed.count==1,completed[0].item.side == .source,
                      receipt.rootID==rootID,receipt.oldPath.utf8.elementsEqual(path.utf8),
                      receipt.sourceRoot==completed[0].item.rootPath,
                      receipt.isDirectory==completed[0].item.isDirectory,
                      receipt.newPath.split(separator:"/").last.map(String.init)==completed[0].newName,
                      restoredSource==nil else { throw JournalError.database("Ricevuta rettifica incoerente") }
                let insert=try prepare("INSERT INTO name_rectification_receipts(root_id,old_path,new_path,receipt) VALUES(?,?,?,?);")
                defer { sqlite3_finalize(insert) }
                try bind(rootID,at:1,in:insert);try bind(receipt.oldPath,at:2,in:insert)
                try bind(receipt.newPath,at:3,in:insert)
                try bind(String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self),at:4,in:insert)
                guard sqlite3_step(insert)==SQLITE_DONE else { throw databaseFailure() }
            }
            let stmt = try prepare("DELETE FROM name_rectification_groups WHERE root_id=? AND relative_path=?;")
            defer { sqlite3_finalize(stmt) }
            try bind(rootID,at:1,in:stmt); try bind(path,at:2,in:stmt)
            guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    /// Capture a *stored* binding and queue watermark without touching SMB.
    func nameRectificationContext(rootID:String)throws->NameRectificationContext {
        let stmt=try prepare("SELECT stamp FROM directory_bindings WHERE root_id=? AND role='target';")
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt)
        let rc=sqlite3_step(stmt)
        let target:DirectoryBinding?
        if rc==SQLITE_ROW {
            target=try JSONDecoder().decode(DirectoryBinding.self,from:Data(columnText(stmt,at:0).utf8))
        } else if rc==SQLITE_DONE { target=nil }
        else { throw databaseFailure() }
        return NameRectificationContext(plannedAt:Date(),queueSequence:try queueSequence(),targetBinding:target)
    }

    /// Bounded history reader; callers must independently revalidate identity,
    /// mapping, current job and destination before relying on a receipt.
    func nameRectificationReceipts(rootID:String,limit:Int=1000,beforeID:Int64=Int64.max)throws->[(id:Int64,receipt:NameRectificationReceipt)] {
        let stmt=try prepare("SELECT id,old_path,new_path,receipt FROM name_rectification_receipts WHERE root_id=? AND id<? ORDER BY id DESC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt)
        guard sqlite3_bind_int64(stmt,2,beforeID)==SQLITE_OK,
              sqlite3_bind_int(stmt,3,Int32(max(1,min(1000,limit))))==SQLITE_OK else { throw databaseFailure() }
        var rows:[(Int64,NameRectificationReceipt)]=[]
        while true {
            let rc=sqlite3_step(stmt)
            if rc==SQLITE_DONE { return rows }
            guard rc==SQLITE_ROW else { throw databaseFailure() }
            let receipt=try JSONDecoder().decode(NameRectificationReceipt.self,from:Data(columnText(stmt,at:3).utf8))
            guard receipt.rootID==rootID,receipt.oldPath.utf8.elementsEqual(columnText(stmt,at:1).utf8),
                  receipt.newPath.utf8.elementsEqual(columnText(stmt,at:2).utf8) else {
                throw JournalError.database("Ricevuta rettifica non valida")
            }
            rows.append((sqlite3_column_int64(stmt,0),receipt))
        }
    }

    /// Diagnostic association only, never authority for remote absence.
    func rectificationMonitorLink(jobID:Int64)throws->Int64? {
        let stmt=try prepare("SELECT receipt_id FROM name_rectification_monitor_links WHERE job_id=?;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt,1,jobID)==SQLITE_OK else { throw databaseFailure() }
        let rc=sqlite3_step(stmt)
        if rc==SQLITE_DONE { return nil }
        guard rc==SQLITE_ROW else { throw databaseFailure() }
        return sqlite3_column_int64(stmt,0)
    }

    func nameRectificationCompleted() throws -> Set<String> {
        let statement = try prepare("SELECT root_id,relative_path,side FROM name_rectification_completed;")
        defer { sqlite3_finalize(statement) }
        var completed = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return completed
            case SQLITE_ROW:
                completed.insert(columnText(statement, at: 0) + "\0" +
                                 columnText(statement, at: 1) + "\0" +
                                 columnText(statement, at: 2))
            default: throw databaseFailure()
            }
        }
    }

    func saveNameRectification(_ data: Data?, progress: [NameRectificationProgressRecord]? = nil) throws {
        guard let data else {
            try execute("DELETE FROM name_rectification_batch WHERE singleton=1;")
            try execute("DELETE FROM name_rectification_completed;")
            return
        }
        // The first save must atomically reset the previous batch's side
        // statuses. Rewrites of the remaining plan run inside the existing
        // advanceNameRectification transaction and preserve those statuses.
        let write: () throws -> Void = {
            let statement = try self.prepare("""
                INSERT OR REPLACE INTO name_rectification_batch(singleton,plan,progress)
                VALUES(1,?,?);
                """)
            defer { sqlite3_finalize(statement) }
            try self.bind(String(decoding: data, as: UTF8.self), at: 1, in: statement)
            let existing = try self.pendingNameRectification()
            let statusBytes = try progress.map { try JSONEncoder().encode($0) } ??
                existing?.progress ?? Data("[]".utf8)
            try self.bind(String(decoding: statusBytes, as: UTF8.self), at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw self.databaseFailure() }
        }
        if progress != nil {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try write()
                try execute("DELETE FROM name_rectification_completed;")
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        } else {
            try write()
        }
    }

    func advanceNameRectification(to offset: Int, finished: Bool, rootID: String?, path: String?,
                                  remainingPlan: Data?, completed: (rootID: String, path: String, side: String)? = nil) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if let completed {
                guard completed.side == "source" || completed.side == "destination",
                      try pendingNameRectification() != nil else {
                    throw JournalError.database("Lato o registro rettifica non valido")
                }
                let record = try prepare("""
                    INSERT OR IGNORE INTO name_rectification_completed(root_id,relative_path,side)
                    VALUES(?,?,?);
                    """)
                defer { sqlite3_finalize(record) }
                try bind(completed.rootID, at: 1, in: record)
                try bind(completed.path, at: 2, in: record)
                try bind(completed.side, at: 3, in: record)
                guard sqlite3_step(record) == SQLITE_DONE else { throw databaseFailure() }
            }
            if let rootID, let path {
                try execute("DELETE FROM name_rectification_scopes WHERE expires<=CAST(strftime('%s','now') AS INTEGER);")
                let add = try prepare("""
                    INSERT OR REPLACE INTO name_rectification_scopes(root_id,path,expires)
                    VALUES(?,?,strftime('%s','now')+604800);
                    """)
                defer { sqlite3_finalize(add) }
                try bind(rootID, at: 1, in: add)
                try bind(path, at: 2, in: add)
                guard sqlite3_step(add) == SQLITE_DONE else { throw databaseFailure() }
            }
            if finished {
                try saveNameRectification(nil)
            } else if let remainingPlan {
                try saveNameRectification(remainingPlan)
            } else {
                let update = try prepare("UPDATE name_rectification_batch SET next_move=? WHERE singleton=1;")
                defer { sqlite3_finalize(update) }
                guard sqlite3_bind_int64(update, 1, Int64(offset)) == SQLITE_OK,
                      sqlite3_step(update) == SQLITE_DONE else { throw databaseFailure() }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func nameRectificationScopes() throws -> [String: [String]] {
        let query = try prepare("""
            SELECT root_id,path FROM name_rectification_scopes
            WHERE expires>CAST(strftime('%s','now') AS INTEGER);
            """)
        defer { sqlite3_finalize(query) }
        var scopes: [String: [String]] = [:]
        while true {
            switch sqlite3_step(query) {
            case SQLITE_DONE: return scopes
            case SQLITE_ROW: scopes[columnText(query, at: 0), default: []].append(columnText(query, at: 1))
            default: throw databaseFailure()
            }
        }
    }

    public func nameScan(rootID: String, side: IncompatibleName.Side) throws -> NameScanSnapshot? {
        let statement = try prepare("SELECT snapshot FROM name_scan_cache WHERE root_id=? AND side=?;")
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, in: statement)
        try bind(side.rawValue, at: 2, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            return try JSONDecoder().decode(NameScanSnapshot.self, from: Data(columnText(statement, at: 0).utf8))
        default: throw databaseFailure()
        }
    }

    public func invalidateNameScan(rootID: String, side: IncompatibleName.Side) throws {
        let statement = try prepare("DELETE FROM name_scan_cache WHERE root_id=? AND side=?;")
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, in: statement)
        try bind(side.rawValue, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseFailure() }
    }

    public func saveNameScan(_ snapshot: NameScanSnapshot) throws {
        let value = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        let statement = try prepare("INSERT OR REPLACE INTO name_scan_cache(root_id,side,snapshot) VALUES(?,?,?);")
        defer { sqlite3_finalize(statement) }
        try bind(snapshot.rootID, at: 1, in: statement)
        try bind(snapshot.side.rawValue, at: 2, in: statement)
        try bind(value, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseFailure() }
    }

    /// Read-only verification for local name maintenance. No destination
    /// probing, no enrollment of a replaced source.
    public func verifyLocalSourceBinding(rootID:String,root:URL) throws -> DirectoryBinding {
        guard try watchedRootPath(rootID:rootID)==root.path else { throw MountedCopyError.invalidMapping }
        let stamp = try verifiedNameBinding(rootID: rootID, root: root, side: .source)
        guard !stamp.volume.isNetworkVolume else { throw MountedCopyError.unsafeFile }
        return stamp
    }

    func verifiedNameBinding(rootID: String, root: URL, side: IncompatibleName.Side) throws -> DirectoryBinding {
        let stamp = try DirectoryBinding.read(root)
        let stmt = try prepare("SELECT stamp FROM directory_bindings WHERE root_id=? AND role=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt)
        try bind(side == .source ? "source" : "target", at: 2, in: stmt)
        guard sqlite3_step(stmt)==SQLITE_ROW,
              let data=columnText(stmt,at:0).data(using:.utf8),
              try JSONDecoder().decode(DirectoryBinding.self,from:data)==stamp else {
            throw side == .source ? MountedCopyError.sourceRootChanged : MountedCopyError.volumeChanged
        }
        return stamp
    }

    public func verifyDirectoryBindings(_ maps: [MountedFolderMapping], allowNewTarget: Bool = false) throws {
        _ = try verifiedDirectoryBindingSnapshot(maps, allowNewTarget: allowNewTarget)
    }

    /// Return the exact stamps already checked by the existing preflight;
    /// shadow evidence must never obtain a new SMB fingerprint per item.
    private func verifiedDirectoryBindingSnapshot(_ maps: [MountedFolderMapping], allowNewTarget: Bool = false) throws -> [(String,String,String)] {
        let bindings = try maps.flatMap { map -> [(String,String,String)] in
            try map.verify()
            return try [("source",map.source),("target",map.target)].map { (map.rootID,$0.0,try DirectoryBinding.encoded($0.1)) }
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for (rootID,role,stamp) in bindings {
                    let query = try prepare("SELECT stamp FROM directory_bindings WHERE root_id=? AND role=?;")
                    defer { sqlite3_finalize(query) }
                    try bind(rootID,at:1,in:query); try bind(role,at:2,in:query)
                    let state = sqlite3_step(query)
                    if state == SQLITE_ROW {
                        guard columnText(query,at:0) == stamp else {
                            throw role == "source" ? MountedCopyError.sourceRootChanged : MountedCopyError.volumeChanged
                        }
                    } else {
                        guard state == SQLITE_DONE, role == "target", allowNewTarget else {
                            throw MountedCopyError.invalidMapping
                        }
                        let insert = try prepare("INSERT INTO directory_bindings(root_id,role,stamp) VALUES(?,?,?);")
                        defer { sqlite3_finalize(insert) }
                        try bind(rootID,at:1,in:insert); try bind(role,at:2,in:insert); try bind(stamp,at:3,in:insert)
                        guard sqlite3_step(insert) == SQLITE_DONE else { throw databaseFailure() }
                    }
            }
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
        return bindings
    }

    /// Startup-only recovery of an already Finder-mounted SMB share whose
    /// mount path changed. Requires the exact same remote mount source and
    /// stable directory inode/birth identity for EVERY target. No queue item,
    /// consent, source binding or file content is modified by this operation.
    /// A missing/changed binding is ambiguous and must fail closed.
    public func rebindVerifiedSMBMount(_ maps: [MountedFolderMapping],
                                       oldVolume: VolumeFingerprint) throws {
        guard !maps.isEmpty, oldVolume.fileSystem.lowercased() == "smbfs",
              oldVolume.isStrongIdentity,
              !(try hasPendingNameRectification()),
              Set(maps.map { $0.rootID }).count == maps.count else {
            throw MountedCopyError.volumeChanged
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for map in maps {
                try map.verify()
                guard try watchedRootPath(rootID:map.rootID) == map.source.path else {
                    throw MountedCopyError.sourceRootChanged
                }
                _ = try verifyLocalSourceBinding(rootID: map.rootID, root: map.source)
                let current = try DirectoryBinding.read(map.target)
                guard current.volume.fileSystem.lowercased() == "smbfs",
                      current.volume.mountSource == oldVolume.mountSource,
                      current.volume.mountPath != oldVolume.mountPath,
                      current.volume.isStrongIdentity else { throw MountedCopyError.volumeChanged }

                let query = try prepare("SELECT stamp FROM directory_bindings WHERE root_id=? AND role='target';")
                defer { sqlite3_finalize(query) }
                try bind(map.rootID,at:1,in:query)
                guard sqlite3_step(query) == SQLITE_ROW,
                      let data = columnText(query,at:0).data(using:.utf8),
                      let saved = try? JSONDecoder().decode(DirectoryBinding.self,from:data) else {
                    throw MountedCopyError.volumeChanged
                }
                guard saved == current ||
                      (saved.volume == oldVolume && current.isSameObjectAfterSMBRemount(as:saved)) else {
                    throw MountedCopyError.volumeChanged
                }
                try map.verify()
                guard try DirectoryBinding.read(map.target) == current else {
                    throw MountedCopyError.volumeChanged
                }
                if saved != current {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let encoded = String(decoding:try encoder.encode(current),as:UTF8.self)
                    let update = try prepare("UPDATE directory_bindings SET stamp=? WHERE root_id=? AND role='target' AND stamp=?;")
                    defer { sqlite3_finalize(update) }
                    try bind(encoded,at:1,in:update)
                    try bind(map.rootID,at:2,in:update)
                    try bind(String(decoding:data,as:UTF8.self),at:3,in:update)
                    guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(connection) == 1 else {
                        throw MountedCopyError.volumeChanged
                    }
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Read-only indexed local proposal check. Exclude the original itself.
    public func classifyLocalNameProposals(_ rows:[IncompatibleName]) throws -> [IncompatibleName] {
        guard !rows.isEmpty else { return rows }
        let schema=try prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('source_name_members','source_name_index_ready');")
        defer { sqlite3_finalize(schema) }
        guard sqlite3_step(schema)==SQLITE_ROW else { throw databaseFailure() }
        let available=sqlite3_column_int(schema,0)==2
        guard sqlite3_step(schema)==SQLITE_DONE else { throw databaseFailure() }
        guard available else { return rows }
        let stmt=try prepare("""
            SELECT EXISTS(SELECT 1 FROM source_name_index_ready WHERE root_id=?1),
                   EXISTS(SELECT 1 FROM source_name_members WHERE root_id=?1
                     AND parent_path=?2 AND folded_leaf=?3 AND relative_path<>?4 COLLATE BINARY);
            """)
        defer { sqlite3_finalize(stmt) }
        var proposals:[String:Int]=[:]
        func proposalKey(_ row:IncompatibleName,_ proposed:String)->String {
            let parent=row.relativePath.split(separator:"/").dropLast().joined(separator:"/")
            return row.rootID+"\0"+parent+"\0"+WindowsPathSafety.comparisonFold(proposed)
        }
        for row in rows where row.side == .source {
            if let proposed=NameRectification.proposedName(row.name) {
                proposals[proposalKey(row,proposed),default:0] += 1
            }
        }
        var result:[IncompatibleName]=[]
        result.reserveCapacity(rows.count)
        for var row in rows {
            guard row.side == .source,let proposed=NameRectification.proposedName(row.name) else {
                result.append(row);continue
            }
            let parent=row.relativePath.split(separator:"/").dropLast().joined(separator:"/")
            try bind(row.rootID,at:1,in:stmt)
            try bind(parent,at:2,in:stmt)
            try bind(WindowsPathSafety.comparisonFold(proposed),at:3,in:stmt)
            try bind(row.relativePath,at:4,in:stmt)
            guard sqlite3_step(stmt)==SQLITE_ROW else { throw databaseFailure() }
            let ready=sqlite3_column_int(stmt,0)==1
            let occupied=sqlite3_column_int(stmt,1)==1
            guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
            sqlite3_reset(stmt);sqlite3_clear_bindings(stmt)
            row.proposedNameAvailable=ready ? (!occupied && proposals[proposalKey(row,proposed),default:0]==1) : nil
            result.append(row)
        }
        return result
    }

    /// Persistent, derived name-maintenance queue. Only incompatible local
    /// leaves with an outstanding upload (including an invalid ancestor of
    /// a pending child) belong here. Do not duplicate jobs or consult SMB.
    public func pendingLocalNameRectifications() throws -> [IncompatibleName] {
        let schema = try prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_name_members';")
        let available = sqlite3_step(schema)
        sqlite3_finalize(schema)
        guard available == SQLITE_ROW || available == SQLITE_DONE else { throw databaseFailure() }
        // Older test/maintenance databases may have a journal but no monitor
        // inventory. The worker still applies its independent path validation.
        guard available == SQLITE_ROW else { return [] }
        let stmt = try prepare("""
            SELECT m.root_id,w.absolute_path,m.relative_path,m.kind,
              CASE WHEN m.reason<>'' THEN m.reason ELSE 'Conflitto fra nomi equivalenti in Windows' END,
              CASE WHEN m.kind='directory' THEN
                (SELECT COUNT(*) FROM file_inventory f
                 WHERE f.root_id=m.root_id AND f.relative_path>=m.relative_path||'/'
                   AND f.relative_path<m.relative_path||'0')
              ELSE 0 END
            FROM source_name_members m JOIN watched_roots w ON w.root_id=m.root_id
            JOIN source_name_index_ready r ON r.root_id=m.root_id
            WHERE (m.reason<>'' OR m.conflicting=1)
              AND (EXISTS(SELECT 1 FROM change_queue q
                    WHERE q.root_id=m.root_id AND q.relative_path=m.relative_path
                      AND q.completed=0 AND q.kind='upsert')
                OR (m.kind='directory' AND EXISTS(SELECT 1 FROM change_queue q
                    WHERE q.root_id=m.root_id AND q.relative_path>=m.relative_path||'/'
                      AND q.relative_path<m.relative_path||'0'
                      AND q.completed=0 AND q.kind='upsert')))
            ORDER BY m.root_id,m.relative_path;
            """)
        defer { sqlite3_finalize(stmt) }
        var result:[IncompatibleName]=[]
        var code=sqlite3_step(stmt)
        while code==SQLITE_ROW {
            result.append(.init(rootID:columnText(stmt,at:0),rootPath:columnText(stmt,at:1),
                relativePath:columnText(stmt,at:2),objectKind:columnText(stmt,at:3),
                side:.source,reason:columnText(stmt,at:4),
                affectedDescendants:Int(sqlite3_column_int64(stmt,5))))
            code=sqlite3_step(stmt)
        }
        guard code==SQLITE_DONE else { throw databaseFailure() }
        return try classifyLocalNameProposals(result)
    }

    public func pendingUploadUpperBound() throws -> Int64? {
        let stmt = try prepare("""
            SELECT MAX(id) FROM change_queue WHERE completed=0 AND kind='upsert';
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        return sqlite3_column_type(stmt, 0) == SQLITE_NULL
            ? nil : sqlite3_column_int64(stmt, 0)
    }

    /// A bounded, read-only projection of worker priority and known local gates.
    /// No SMB reads, no queue acknowledgement, no change to actual worker order.
    public func queuePreview(cursor:QueueExecutionCursor? = nil, mirrorCutoff:Int64? = nil,
                             paused:Bool=false, search:String="", kind:String="all",
                             statusFilter:String="all", offset:Int=0, limit:Int=200,
                             now:Date=Date()) throws -> QueuePreviewPage {
        let cutoff=cursor == nil ? mirrorCutoff : cursor?.mirrorCutoff
        let phase=cursor?.phase.rawValue ?? "idle"
        let rebuilding=try queueRebuildToken() != nil
        let mirrorBlocked=try mirrorBlockReason() != nil
        let held=paused || rebuilding || mirrorBlocked
        let sql="""
            WITH classified AS (
              SELECT id,root_id,relative_path,kind,recorded_at,origin,
                CASE
                  WHEN id=?5 THEN 'current'
                  WHEN ?8=1 THEN 'hold'
                  WHEN kind='delete' AND ?7<0 THEN 'mirrorOff'
                  WHEN kind='delete' AND id<=?7 THEN 'beforeConsent'
                  WHEN id>?1 OR ?6='finished' THEN 'laterCycle'
                  WHEN kind='upsert' AND (?6='deletes' OR id<=?2) THEN 'laterCycle'
                  WHEN kind='delete' AND ?6='deletes' AND
                    (length(relative_path)>?3 OR (length(relative_path)=?3 AND id<=?4)) THEN 'laterCycle'
                  WHEN kind='upsert' AND EXISTS(SELECT 1 FROM upload_retry r
                    WHERE r.root_id=q.root_id AND (r.job_id=q.id OR r.scope='root') AND r.next_at>?9) THEN 'retry'
                  WHEN kind='upsert' AND EXISTS(SELECT 1 FROM blocked_name_jobs b WHERE b.job_id=q.id) THEN 'nameBlocked'
                  WHEN kind='delete' AND EXISTS(SELECT 1 FROM change_queue u
                    WHERE u.completed=0 AND u.kind='upsert') THEN 'waitingCopies'
                  ELSE 'planned'
                END AS state
              FROM change_queue q WHERE completed=0 AND (?10='all' OR kind=?10)
                AND (?11='' OR instr(lower(relative_path),lower(?11))>0 OR instr(lower(root_id),lower(?11))>0)
            ), selected AS (
              SELECT *, CASE WHEN state='current' THEN 0
                  WHEN state IN ('planned','waitingCopies') AND kind='upsert' THEN 1
                  WHEN state IN ('planned','waitingCopies') AND kind='delete' THEN 2
                  WHEN kind='upsert' THEN 3 ELSE 4 END AS sort_rank
              FROM classified WHERE ?12='all'
                OR (?12='planned' AND state IN ('current','planned','waitingCopies'))
                OR (?12='blocked' AND state NOT IN ('current','planned','waitingCopies'))
              ORDER BY sort_rank,
                CASE WHEN kind='delete' THEN \(QueueExecutionOrder.deleteLengthSQL) ELSE 0 END DESC,
                \(QueueExecutionOrder.idSQL) LIMIT ?13 OFFSET ?14
            )
            SELECT s.id,s.root_id,s.relative_path,s.kind,s.recorded_at,s.origin,
                   COALESCE(f.kind,''),s.state,
                   EXISTS(SELECT 1 FROM name_rectification_monitor_links l WHERE l.job_id=s.id)
              FROM selected s LEFT JOIN file_inventory f ON f.root_id=s.root_id AND f.relative_path=s.relative_path
              ORDER BY s.sort_rank, CASE WHEN s.kind='delete' THEN length(s.relative_path) ELSE 0 END DESC, s.id;
            """
        let stmt=try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let size=max(1,min(limit,500))
        let values:[(Int32,Int64)]=[(1,cursor?.upperID ?? Int64.max),(2,cursor?.uploadCursor ?? 0),
            (3,cursor?.deleteLength ?? Int64.max),(4,cursor?.deleteCursor ?? 0),
            (5,cursor?.currentID ?? -1),(7,cutoff ?? -1),(8,held ? 1:0),
            (13,Int64(size+1)),(14,Int64(max(0,offset)))]
        for (index,value) in values {
            guard sqlite3_bind_int64(stmt,index,value)==SQLITE_OK else { throw databaseFailure() }
        }
        try bind(phase,at:6,in:stmt)
        guard sqlite3_bind_double(stmt,9,now.timeIntervalSince1970)==SQLITE_OK else { throw databaseFailure() }
        try bind(kind,at:10,in:stmt);try bind(search,at:11,in:stmt);try bind(statusFilter,at:12,in:stmt)
        var rows:[QueuePreviewRow]=[]
        while true {
            let rc=sqlite3_step(stmt)
            if rc==SQLITE_DONE { break }
            guard rc==SQLITE_ROW,let kind=ChangeKind(rawValue:columnText(stmt,at:3)),
                  let state=QueuePreviewStatus(rawValue:columnText(stmt,at:7)) else { throw databaseFailure() }
            let job=QueuedChange(id:sqlite3_column_int64(stmt,0),rootID:columnText(stmt,at:1),
                relativePath:columnText(stmt,at:2),kind:kind,
                recordedAt:Date(timeIntervalSince1970:sqlite3_column_double(stmt,4)))
            rows.append(.init(job:job,origin:columnText(stmt,at:5),objectKind:columnText(stmt,at:6),status:state,
                relatedToRectification:sqlite3_column_int(stmt,8) != 0))
        }
        return .init(rows:Array(rows.prefix(size)),hasMore:rows.count>size)
    }

    public func pendingUploads(limit: Int = 100, afterID: Int64 = 0,
                               throughID: Int64 = Int64.max) throws -> [QueuedChange] {
        let statement = try prepare("""
            SELECT id, root_id, relative_path, kind, recorded_at
              FROM change_queue
             WHERE completed = 0 AND kind = 'upsert' AND id > ? AND id <= ?
             ORDER BY \(QueueExecutionOrder.idSQL) LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, max(0, afterID)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, throughID) == SQLITE_OK,
              sqlite3_bind_int(statement, 3, Int32(max(1, min(limit, 1000)))) == SQLITE_OK else {
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

    /// Atomic, conditional baseline acknowledgement. A verified candidate is only
    /// accepted when the SAME job is still pending, its source inventory
    /// still records that exact file size and modification timestamp, the
    /// source root has not been rebound and no concurrent newer operation for
    /// the same path is pending. No DELETE job can ever be completed here.
    ///
    /// All eligible jobs are acknowledged in one transaction. A cancelled
    /// verification never calls this method.
    public func acknowledgeVerifiedFiles(
        _ entries: [SeedVerifiedMatch],
        sourceRoots: [String: String],
        shouldContinue: () -> Bool = { true },
        onCounts: (Int, Int) -> Void = { _,_ in }
    ) throws -> Int {
        guard !entries.isEmpty else { onCounts(0,0); return 0 }
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
                          AND f.kind=?
                          AND (f.kind='directory' OR (f.file_size=? AND ABS(f.modified_at - ?) < 0.002))
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
            var directories = 0
            for entry in entries {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                guard let root = sourceRoots[entry.rootID] else { continue }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                guard sqlite3_bind_int64(statement, 1, entry.jobID) == SQLITE_OK
                else { throw databaseFailure() }
                try bind(entry.rootID, at: 2, in: statement)
                try bind(entry.relativePath, at: 3, in: statement)
                guard entry.objectKind == "file" || entry.objectKind == "directory" else { continue }
                try bind(entry.objectKind,at:4,in:statement)
                guard sqlite3_bind_int64(statement, 5, entry.source.size) == SQLITE_OK,
                      sqlite3_bind_double(statement, 6, entry.source.modifiedAt) == SQLITE_OK
                else { throw databaseFailure() }
                try bind(root, at: 7, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseFailure() }
                let delta = Int(sqlite3_changes(connection))
                changed += delta
                if entry.objectKind == "directory" { directories += delta }
            }
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
            onCounts(changed-directories,directories)
            return changed
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Reconcile only IDs captured before the operational audit. Equal
    /// metadata is a policy-level match, not a guarantee of equal bytes.
    /// Fresh local fingerprints and the inventory change stamp prevent
    /// acknowledging a same-size/mtime edit that the monitor has not committed.
    public func acknowledgeOperationalAuditMatches(_ entries:[SeedVerifiedMatch],
        mappings:[MountedFolderMapping],shouldContinue:()->Bool) throws -> (files:Int,directories:Int) {
        guard !entries.isEmpty else { return (0,0) }
        let bindings = try verifiedDirectoryBindingSnapshot(mappings)
        let maps=Dictionary(uniqueKeysWithValues:mappings.map{($0.rootID,$0)})
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            if try queueRebuildToken() != nil {
                try execute("COMMIT;"); return (0,0)
            }
            let protection=try NameRectification.pendingProtection(journal:self)
            var shadowBindings: [String: [String:String]] = [:]
            if experimentalSourceNameLineage {
                guard let connection else { throw databaseFailure() }
                try SourceNameLineageStore.install(connection)
                let lookup = try prepare("SELECT stamp FROM directory_bindings WHERE root_id=? AND role=?;")
                defer { sqlite3_finalize(lookup) }
                for (rootID, role, stamp) in bindings {
                    sqlite3_reset(lookup); sqlite3_clear_bindings(lookup)
                    try bind(rootID,at:1,in:lookup); try bind(role,at:2,in:lookup)
                    let rc=sqlite3_step(lookup)
                    guard rc == SQLITE_ROW, columnText(lookup,at:0).utf8.elementsEqual(stamp.utf8) else {
                        throw MountedCopyError.invalidMapping
                    }
                    shadowBindings[rootID,default:[:]][role] = stamp
                }
            }
            let stmt=try prepare("""
                UPDATE change_queue SET completed=1
                WHERE id=?1 AND root_id=?2 AND relative_path=?3 AND completed=0 AND kind='upsert'
                  AND origin IN ('initial_inventory','source_monitor','archive_audit')
                  AND EXISTS(SELECT 1 FROM watched_roots w WHERE w.root_id=?2 AND w.absolute_path=?4)
                  AND EXISTS(SELECT 1 FROM file_inventory f WHERE f.root_id=?2 AND f.relative_path=?3
                    AND f.kind=?5 AND (f.kind='directory' OR
                      (f.file_size=?6 AND ABS(f.modified_at-?7)<0.002 AND f.change_stamp=?8)))
                  AND NOT EXISTS(SELECT 1 FROM change_queue q WHERE q.root_id=?2 AND q.relative_path=?3
                    AND q.id<>?1 AND (q.completed=0 OR q.id>?1))
                  AND NOT EXISTS(SELECT 1 FROM publication_intents p WHERE p.root_id=?2 AND p.relative_path=?3)
                  AND NOT EXISTS(SELECT 1 FROM transfer_recovery p WHERE p.root_id=?2 AND p.relative_path=?3)
                  AND NOT EXISTS(SELECT 1 FROM blocked_name_jobs b WHERE b.job_id=?1)
                  AND NOT EXISTS(SELECT 1 FROM upload_retry u WHERE u.root_id=?2 AND (u.job_id=?1 OR u.scope='root'));
                """)
            defer { sqlite3_finalize(stmt) }
            var files=0, directories=0
            for entry in entries {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                guard let map=maps[entry.rootID],
                      entry.objectKind=="file" || entry.objectKind=="directory",
                      WindowsPathSafety.validRelativePath(entry.relativePath),
                      !FileExclusionPolicy.excludes(entry.relativePath,enabled:FileExclusionPolicy.ignoreDSStore),
                      !protection.protects(rootID:entry.rootID,path:entry.relativePath) else { continue }
                let url=try map.fileURL(relativePath:entry.relativePath,destination:false)
                guard url.resolvingSymlinksInPath().path==url.path else { continue }
                // Same live no-follow stat as fingerprint(), with identity
                // obtained from the same observation when shadow mode is on.
                var info = stat()
                guard url.path.withCString({ lstat($0, &info) }) == 0,
                      (info.st_mode & mode_t(S_IFMT)) == mode_t(entry.objectKind == "directory" ? S_IFDIR : S_IFREG),
                      SeedFileFingerprint(fileStat: info) == entry.source else { continue }
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                guard sqlite3_bind_int64(stmt,1,entry.jobID)==SQLITE_OK else { throw databaseFailure() }
                try bind(entry.rootID,at:2,in:stmt); try bind(entry.relativePath,at:3,in:stmt)
                try bind(map.source.path,at:4,in:stmt); try bind(entry.objectKind,at:5,in:stmt)
                guard sqlite3_bind_int64(stmt,6,entry.source.size)==SQLITE_OK,
                      sqlite3_bind_double(stmt,7,entry.source.modifiedAt)==SQLITE_OK else { throw databaseFailure() }
                try bind("\(entry.source.inode):\(entry.source.ctimeSeconds):\(entry.source.ctimeNanos)",at:8,in:stmt)
                guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
                let changed=Int(sqlite3_changes(connection))
                if experimentalSourceNameLineage, changed == 1,
                   let identity = SourceNameLineage.Identity(stat: info),
                   let sourceBinding = shadowBindings[entry.rootID]?["source"],
                   let targetBinding = shadowBindings[entry.rootID]?["target"],
                   let connection {
                    // Only a genuinely accepted audit match, never a generic
                    // completed job. Absence of a prior identity observation
                    // cannot be upgraded to a historical publication proof.
                    let initial = SourceNameLineage.Record(identity: identity,
                        rootID: entry.rootID, sourceBinding: sourceBinding,
                        targetBinding: targetBinding, path: entry.relativePath)
                    let key = SourceNameLineageStore.Key(initial)
                    if let saved = try SourceNameLineageStore.read(connection,key:key),
                       saved.record.currentPath.utf8.elementsEqual(entry.relativePath.utf8) {
                        var record = saved.record
                        record.recognize(path:entry.relativePath)
                        try SourceNameLineageStore.write(connection,record:record,expectedRevision:saved.revision)
                        try SourceNameLineageStore.releaseConfirmed(connection,record:record)
                    }
                }
                if entry.objectKind=="directory" { directories+=changed } else { files+=changed }
            }
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
            return (files,directories)
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    /// Historical observations from the final matching findings of a single
    /// QUICK/INTELLIGENT audit. Does not acknowledge, enqueue or delete.
    /// No target filesystem access. Newer/pending events take precedence.
    func observeUnqueuedAuditLineage(_ items: [TrackedItem], mapping: MountedFolderMapping,
                                      sourceBinding: String, targetBinding: String,
                                      cutoff: Int64, shouldContinue: () -> Bool) throws {
        guard experimentalSourceNameLineage, !items.isEmpty, let connection else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try SourceNameLineageStore.install(connection)
            let stamps = try prepare("SELECT role,stamp FROM directory_bindings WHERE root_id=?;")
            defer { sqlite3_finalize(stamps) }
            try bind(mapping.rootID,at:1,in:stamps)
            var found: [String:String] = [:]
            var rc = sqlite3_step(stamps)
            while rc == SQLITE_ROW {
                found[columnText(stamps,at:0)] = columnText(stamps,at:1)
                rc = sqlite3_step(stamps)
            }
            guard rc == SQLITE_DONE else { throw databaseFailure() }
            guard found["source"] == sourceBinding, found["target"] == targetBinding,
                  try watchedRootPath(rootID:mapping.rootID) == mapping.source.path,
                  try queueRebuildToken() == nil else {
                try execute("COMMIT;"); return
            }
            let protection = try NameRectification.pendingProtection(journal:self)
            let eligibility = try prepare("""
                SELECT 1 FROM file_inventory f
                WHERE f.root_id=?1 AND f.relative_path=?2 AND f.kind=?3
                  AND (f.kind='directory' OR
                    (f.file_size=?4 AND ABS(f.modified_at-?5)<0.002 AND f.change_stamp=?6))
                  AND NOT EXISTS(SELECT 1 FROM change_queue q
                    WHERE q.root_id=?1 AND q.relative_path=?2 AND (q.completed=0 OR q.id>?7))
                  AND NOT EXISTS(SELECT 1 FROM publication_intents p
                    WHERE p.root_id=?1 AND p.relative_path=?2)
                  AND NOT EXISTS(SELECT 1 FROM transfer_recovery r
                    WHERE r.root_id=?1 AND r.relative_path=?2)
                  AND NOT EXISTS(SELECT 1 FROM upload_retry u
                    WHERE u.root_id=?1 AND (u.scope='root' OR EXISTS(SELECT 1 FROM change_queue q WHERE q.id=u.job_id AND q.relative_path=?2)));
                """)
            defer { sqlite3_finalize(eligibility) }
            var batch: SourceNameLineageStore.Batch?
            let counts = Dictionary(grouping:items.compactMap(\.sourceLineageIdentity),by:{$0})
            for item in items {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                guard let identity = item.sourceLineageIdentity, counts[identity]?.count == 1,
                      let fingerprint = item.verificationFingerprint,
                      WindowsPathSafety.validRelativePath(item.relativePath),
                      !protection.protects(rootID:mapping.rootID,path:item.relativePath) else { continue }
                let initial = SourceNameLineage.Record(identity:identity,rootID:mapping.rootID,
                    sourceBinding:sourceBinding,targetBinding:targetBinding,path:item.relativePath)
                let key = SourceNameLineageStore.Key(initial)
                if batch == nil { batch = try SourceNameLineageStore.batch(connection,key:key,create:true) }
                guard let batch else { throw databaseFailure() }
                let prior = try batch.read(key:key)
                if let prior {
                    guard prior.record.currentPath.utf8.elementsEqual(item.relativePath.utf8),
                          !prior.record.uncertainPublication else { continue }
                    // Ordinary unchanged recognized entries need no writes or
                    // fresh stat. This is historical evidence, not permission.
                    if prior.record.recognizedPaths.contains(where:{$0.utf8.elementsEqual(item.relativePath.utf8)}) { continue }
                }
                sqlite3_reset(eligibility); sqlite3_clear_bindings(eligibility)
                try bind(mapping.rootID,at:1,in:eligibility)
                try bind(item.relativePath,at:2,in:eligibility)
                try bind(item.kind,at:3,in:eligibility)
                guard sqlite3_bind_int64(eligibility,4,fingerprint.size)==SQLITE_OK,
                      sqlite3_bind_double(eligibility,5,fingerprint.modifiedAt)==SQLITE_OK,
                      sqlite3_bind_int64(eligibility,7,cutoff)==SQLITE_OK else { throw databaseFailure() }
                try bind("\(fingerprint.inode):\(fingerprint.ctimeSeconds):\(fingerprint.ctimeNanos)",at:6,in:eligibility)
                let eligible = sqlite3_step(eligibility)
                if eligible == SQLITE_DONE { continue }
                guard eligible == SQLITE_ROW else { throw databaseFailure() }
                let url = mapping.source.appendingPathComponent(item.relativePath)
                var live = stat()
                guard url.resolvingSymlinksInPath().path == url.path,
                      url.path.withCString({ lstat($0,&live) }) == 0,
                      SourceNameLineage.Identity(stat:live) == identity,
                      SeedFileFingerprint(fileStat:live) == fingerprint else { continue }
                var record = prior?.record ?? initial
                record.recognize(path:item.relativePath)
                try batch.write(record:record,expectedRevision:prior?.revision)
                try batch.releaseConfirmed(record)
            }
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    /// Close already-absent deletions; no filesystem mutation, no mirror
    /// authorization change and no increase to actual deletion statistics.
    /// Caller provides pre-audit IDs absent from both complete inventories.
    public func acknowledgeAbsentAuditDeletes(_ entries:[QueuedChange],
        mappings:[MountedFolderMapping],auditTargetMissingPrefixes:[Int64:String] = [:],
        onAcknowledged: ((QueuedChange)->Void)? = nil,
        shouldContinue:()->Bool) throws -> Int {
        guard !entries.isEmpty else { return 0 }
        try verifyDirectoryBindings(mappings)
        if try queueRebuildToken() != nil { return 0 }
        let maps=Dictionary(uniqueKeysWithValues:mappings.map{($0.rootID,$0)})
        let cache=AuditDirectoryListingCache()
        // Check only the absent candidates, never walk a remote tree.
        // A visible alias, symlink, inaccessible parent or ambiguous name
        // is not proof of absence. No SQLite write lock while reading SMB.
        func absentPrefix(_ path:String,under root:URL,native:Bool) throws -> String? {
            var parent=root
            var components:[String]=[]
            for part in path.split(separator:"/").map(String.init) {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                components.append(part)
                let aliases=try cache.aliases(for:part,in:parent)
                let url=parent.appendingPathComponent(part)
                var info=stat()
                let rc=url.path.withCString{lstat($0,&info)}
                if rc != 0 {
                    let code=errno
                    guard code==ENOENT else { return nil }
                    if aliases.isEmpty { return components.joined(separator:"/") }
                    // APFS/HFS can enumerate the exact old spelling even when
                    // Win32 comparison folds its corrected trailing-space name
                    // together with it. ENOENT plus that sole exact corrected
                    // spelling is proof of absence only on a native filesystem.
                    // Never apply this exception to SMB or to case-only aliases.
                    guard native,!WindowsPathSafety.validRelativePath(part),
                          let corrected=NameRectification.proposedName(part),
                          aliases.count==1,
                          aliases[0].utf8.elementsEqual(corrected.utf8),
                          !aliases[0].utf8.elementsEqual(part.utf8) else { return nil }
                    return components.joined(separator:"/")
                }
                guard aliases.count==1,aliases[0].utf8.elementsEqual(part.utf8),
                      info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { return nil }
                if info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) { return nil }
                parent=url
            }
            return nil
        }
        struct ProofKey:Hashable { let rootID:String;let prefix:Data }
        var sourceProofs=Set<ProofKey>(),targetProofs=Set<ProofKey>()
        var verified:[(job:QueuedChange,targetPrefix:String)]=[]
        // Exact UTF-8 prefix keys; never reuse a case-folded alias as proof.
        func knownPrefix(_ path:String,rootID:String,proofs:Set<ProofKey>)->String? {
            var prefix=""
            for part in path.split(separator:"/") {
                prefix=prefix.isEmpty ? String(part) : prefix+"/"+part
                if proofs.contains(ProofKey(rootID:rootID,prefix:Data(prefix.utf8))) { return prefix }
            }
            return nil
        }
        var nativeSources=Set<String>()
        for map in mappings {
            if let binding=try? verifyLocalSourceBinding(rootID:map.rootID,root:map.source),
               ["apfs","hfs"].contains(binding.volume.fileSystem.lowercased()) { nativeSources.insert(map.rootID) }
        }
        for job in entries.sorted(by:{ $0.relativePath.utf8.count < $1.relativePath.utf8.count }) {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard job.kind == .delete,let map=maps[job.rootID],
                  WindowsPathSafety.validDeletionPath(job.relativePath),
                  // SMB can hide an incompatible server-side name even when
                  // enumeration and stat report no object. Only native local
                  // target filesystems may prove literal absence this way.
                  WindowsPathSafety.validRelativePath(job.relativePath) || ["apfs","hfs"].contains(map.targetVolume.fileSystem.lowercased()),
                  !FileExclusionPolicy.excludes(job.relativePath,enabled:FileExclusionPolicy.ignoreDSStore) else { continue }
            do {
                let sourcePrefix=try knownPrefix(job.relativePath,rootID:job.rootID,proofs:sourceProofs)
                    ?? absentPrefix(job.relativePath,under:map.source,native:nativeSources.contains(job.rootID))
                guard let sourcePrefix else { continue }
                sourceProofs.insert(ProofKey(rootID:job.rootID,prefix:Data(sourcePrefix.utf8)))
                // A complete audit can supply a grouping hint, not proof.
                // Skip the redundant preliminary remote probe, but require
                // the same fresh literal-absence check below before ACK.
                let hint=auditTargetMissingPrefixes[job.id].flatMap { prefix -> String? in
                    guard WindowsPathSafety.validRelativePath(prefix),
                          job.relativePath.utf8.elementsEqual(prefix.utf8) ||
                          job.relativePath.utf8.starts(with:(prefix+"/").utf8) else { return nil }
                    return prefix
                }
                let targetPrefix=try knownPrefix(job.relativePath,rootID:job.rootID,proofs:targetProofs)
                    ?? hint
                    ?? absentPrefix(job.relativePath,under:map.target,native:["apfs","hfs"].contains(map.targetVolume.fileSystem.lowercased()))
                guard let targetPrefix else { continue }
                targetProofs.insert(ProofKey(rootID:job.rootID,prefix:Data(targetPrefix.utf8)))
                verified.append((job,targetPrefix))
            } catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
            catch { cache.invalidate();sourceProofs.removeAll();targetProofs.removeAll() }
        }
        // Recheck each distinct absent target ancestor once, with fresh
        // listings. A failure invalidates only that group. Never hold the
        // SQLite writer while reading the remote filesystem.
        cache.invalidate()
        var confirmed=Set<ProofKey>(),rejected=Set<ProofKey>()
        for entry in verified {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            let key=ProofKey(rootID:entry.job.rootID,prefix:Data(entry.targetPrefix.utf8))
            guard !confirmed.contains(key),!rejected.contains(key),let map=maps[entry.job.rootID] else { continue }
            do {
                if try absentPrefix(entry.targetPrefix,under:map.target,native:["apfs","hfs"].contains(map.targetVolume.fileSystem.lowercased())) != nil {
                    confirmed.insert(key)
                } else { rejected.insert(key) }
            } catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
            catch { rejected.insert(key);cache.invalidate() }
        }
        try verifyDirectoryBindings(mappings)
        guard !confirmed.isEmpty else { return 0 }
        cache.invalidate()
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            if try queueRebuildToken() != nil { try execute("COMMIT;");return 0 }
            let protection=try NameRectification.pendingProtection(journal:self)
            let stmt=try prepare("""
                UPDATE change_queue SET completed=1
                WHERE id=?1 AND root_id=?2 AND relative_path=?3 AND kind='delete' AND completed=0
                  AND origin IN ('source_monitor','archive_audit')
                  AND EXISTS(SELECT 1 FROM watched_roots w WHERE w.root_id=?2 AND w.absolute_path=?4)
                  AND NOT EXISTS(SELECT 1 FROM file_inventory f WHERE f.root_id=?2 AND f.relative_path=?3)
                  AND NOT EXISTS(SELECT 1 FROM change_queue q WHERE q.root_id=?2 AND q.relative_path=?3
                    AND q.id<>?1 AND (q.completed=0 OR q.id>?1))
                  AND NOT EXISTS(SELECT 1 FROM publication_intents p WHERE p.root_id=?2 AND p.relative_path=?3)
                  AND NOT EXISTS(SELECT 1 FROM transfer_recovery p WHERE p.root_id=?2 AND p.relative_path=?3);
                """)
            defer { sqlite3_finalize(stmt) }
            var count=0
            var acknowledged:[QueuedChange]=[]
            for entry in verified {
                let job=entry.job
                guard confirmed.contains(ProofKey(rootID:job.rootID,prefix:Data(entry.targetPrefix.utf8))) else { continue }
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                guard let map=maps[job.rootID],!protection.protects(rootID:job.rootID,path:job.relativePath) else { continue }
                // Only metadata reads on the local source in the write transaction.
                // Recheck the same strict absence predicate for repairable
                // literal names; an equivalent spelling is not absence.
                guard WindowsPathSafety.validDeletionPath(job.relativePath) else { continue }
                let url=map.source.appendingPathComponent(job.relativePath)
                var info=stat()
                guard url.resolvingSymlinksInPath().path==url.path,
                      url.path.withCString({lstat($0,&info)}) != 0,errno==ENOENT else { continue }
                if !WindowsPathSafety.validRelativePath(job.relativePath) {
                    do { guard try absentPrefix(job.relativePath,under:map.source,native:nativeSources.contains(job.rootID)) != nil else { continue } }
                    catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
                    catch { cache.invalidate(); continue }
                }
                sqlite3_reset(stmt);sqlite3_clear_bindings(stmt)
                guard sqlite3_bind_int64(stmt,1,job.id)==SQLITE_OK else { throw databaseFailure() }
                try bind(job.rootID,at:2,in:stmt);try bind(job.relativePath,at:3,in:stmt)
                try bind(map.source.path,at:4,in:stmt)
                guard sqlite3_step(stmt)==SQLITE_DONE else { throw databaseFailure() }
                let changed=Int(sqlite3_changes(connection))
                count+=changed
                if changed == 1,onAcknowledged != nil { acknowledged.append(job) }
            }
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
            // Observers see only committed acknowledgments, never a rolled-back batch.
            if let onAcknowledged { for job in acknowledged { onAcknowledged(job) } }
            return count
        } catch { try? execute("ROLLBACK;");throw error }
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

    /// Durable authorization starts after the SQLite sequence, not after a
    /// wall clock time (which can move backwards or forwards).
    public func queueSequence() throws -> Int64 {
        let stmt = try prepare("SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='change_queue'),0);")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Do not authorize a newly selected/replaced source against stale
    /// inventory paths. Contents and timestamps are irrelevant to deletion
    /// consent, but every tracked path and object kind must agree.
    public func inventoryPathsMatch(rootID: String, scanned: [TrackedItem]) throws -> Bool {
        var expected: [String: String] = [:]
        for item in scanned {
            guard expected.updateValue(item.kind, forKey: item.relativePath) == nil else { return false }
        }
        let stmt = try prepare("SELECT relative_path,kind FROM file_inventory WHERE root_id=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return expected.isEmpty }
            guard rc == SQLITE_ROW else { throw databaseFailure() }
            guard expected.removeValue(forKey: columnText(stmt,at:0)) == columnText(stmt,at:1)
            else { return false }
        }
    }

    /// Exact source inventory comparison used only before requesting a normal shutdown.
    /// Includes ctime/inode change stamps to detect edits with preserved mtime.
    public func inventoryMatchesForShutdown(rootID: String, scanned: [TrackedItem]) throws -> Bool {
        var expected = Dictionary(uniqueKeysWithValues:scanned.map { ($0.relativePath,$0) })
        let stmt = try prepare("SELECT relative_path,kind,file_size,modified_at,change_stamp FROM file_inventory WHERE root_id=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return expected.isEmpty }
            guard rc == SQLITE_ROW else { throw databaseFailure() }
            guard let item = expected.removeValue(forKey:columnText(stmt,at:0)), item.kind == columnText(stmt,at:1) else { return false }
            if item.kind == "file" {
                guard item.size == sqlite3_column_int64(stmt,2), abs(item.modifiedAt-sqlite3_column_double(stmt,3)) < 0.002,
                      let stamp = item.changeStamp, sqlite3_column_type(stmt,4) != SQLITE_NULL, stamp == columnText(stmt,at:4) else { return false }
            }
        }
    }

    public func databaseIdentity() throws -> String {
        try execute("CREATE TABLE IF NOT EXISTS macsync_identity(id TEXT NOT NULL);")
        try execute("INSERT INTO macsync_identity(id) SELECT lower(hex(randomblob(16))) WHERE NOT EXISTS (SELECT 1 FROM macsync_identity);")
        let stmt = try prepare("SELECT id FROM macsync_identity;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        let identity = columnText(stmt, at: 0)
        guard !identity.isEmpty else { throw databaseFailure() }
        return identity
    }

    /// Explicit audit repair: only UPSERTs, never replace a live queue job
    /// or rebind a source. A concurrent monitor event wins.
    public func enqueueAuditRepairs(_ items: [(rootID:String, sourcePath:String, item:TrackedItem)],
                                    shouldContinue: () -> Bool = { true },
                                    onProgress: (Int,Int) -> Void = { _,_ in }) throws -> Int {
        guard !items.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let stmt = try prepare("""
                INSERT INTO change_queue(root_id,relative_path,kind,recorded_at,origin)
                SELECT ?1,?2,'upsert',?3,'archive_audit'
                WHERE EXISTS(SELECT 1 FROM watched_roots WHERE root_id=?1 AND absolute_path=?4)
                  AND NOT EXISTS(SELECT 1 FROM change_queue WHERE root_id=?1 AND relative_path=?2 AND completed=0)
                  AND NOT EXISTS(SELECT 1 FROM file_inventory WHERE root_id=?1 AND relative_path=?2
                     AND (kind<>?5 OR (kind='file' AND (file_size<>?6 OR ABS(modified_at-?7)>0.002))));
                """)
            defer { sqlite3_finalize(stmt) }
            var count = 0
            let started=ProcessInfo.processInfo.systemUptime
            var lastProgress=started
            onProgress(0,items.count)
            for (index,entry) in items.enumerated() {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                let now=ProcessInfo.processInfo.systemUptime
                if now-lastProgress >= 0.5 {
                    lastProgress=now
                    onProgress(index,items.count)
                }
                let item = entry.item
                guard item.kind == "file" || item.kind == "directory",
                      !FileExclusionPolicy.excludes(item.relativePath,enabled:FileExclusionPolicy.ignoreDSStore),
                      !item.relativePath.isEmpty,
                      item.relativePath.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({
                        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") &&
                        !$0.lowercased().hasPrefix(".macsync-")
                      }) else { continue }
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                try bind(entry.rootID,at:1,in:stmt)
                try bind(item.relativePath,at:2,in:stmt)
                guard sqlite3_bind_double(stmt,3,Date().timeIntervalSince1970) == SQLITE_OK else { throw databaseFailure() }
                try bind(entry.sourcePath,at:4,in:stmt); try bind(item.kind,at:5,in:stmt)
                guard sqlite3_bind_int64(stmt,6,item.size) == SQLITE_OK,
                      sqlite3_bind_double(stmt,7,item.modifiedAt) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
                count += Int(sqlite3_changes(connection))
            }
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
            onProgress(items.count,items.count)
            return count
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    /// Queue verified audit-only extras, without mutating the destination.
    /// Existing events win; only the current, bound source/target pair is eligible.
    func enqueueAuditDeletes(_ entries: [(rootID:String, path:String, sourcePath:String, sourceBinding:String, targetBinding:String)],
                             shouldContinue: () -> Bool) throws -> Set<String> {
        guard !entries.isEmpty else { return [] }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let insert = try prepare("""
                INSERT INTO change_queue(root_id,relative_path,kind,recorded_at,origin)
                SELECT ?1,?2,'delete',?6,'archive_audit'
                WHERE EXISTS(SELECT 1 FROM watched_roots WHERE root_id=?1 AND absolute_path=?3)
                  AND EXISTS(SELECT 1 FROM directory_bindings WHERE root_id=?1 AND role='source' AND stamp=?4)
                  AND EXISTS(SELECT 1 FROM directory_bindings WHERE root_id=?1 AND role='target' AND stamp=?5)
                  AND NOT EXISTS(SELECT 1 FROM file_inventory WHERE root_id=?1 AND relative_path=?2)
                  AND NOT EXISTS(SELECT 1 FROM change_queue WHERE root_id=?1 AND relative_path=?2 AND completed=0);
                """)
            defer { sqlite3_finalize(insert) }
            let current = try prepare("""
                SELECT q.id FROM change_queue q
                WHERE q.root_id=?1 AND q.relative_path=?2 AND q.completed=0 AND q.kind='delete'
                  AND EXISTS(SELECT 1 FROM watched_roots WHERE root_id=?1 AND absolute_path=?3)
                  AND EXISTS(SELECT 1 FROM directory_bindings WHERE root_id=?1 AND role='source' AND stamp=?4)
                  AND EXISTS(SELECT 1 FROM directory_bindings WHERE root_id=?1 AND role='target' AND stamp=?5)
                  AND NOT EXISTS(SELECT 1 FROM file_inventory WHERE root_id=?1 AND relative_path=?2)
                  AND NOT EXISTS(SELECT 1 FROM change_queue other WHERE other.root_id=?1 AND other.relative_path=?2 AND other.completed=0 AND other.id<>q.id);
                """)
            defer { sqlite3_finalize(current) }
            let protection = try NameRectification.pendingProtection(journal:self)
            var eligible = Set<String>()
            for e in entries {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                guard WindowsPathSafety.validDeletionPath(e.path),
                      !FileExclusionPolicy.excludes(e.path,enabled:FileExclusionPolicy.ignoreDSStore),
                      !protection.protects(rootID:e.rootID,path:e.path) else { continue }
                for stmt in [insert,current] {
                    sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                    try bind(e.rootID,at:1,in:stmt); try bind(e.path,at:2,in:stmt)
                    try bind(e.sourcePath,at:3,in:stmt); try bind(e.sourceBinding,at:4,in:stmt)
                    try bind(e.targetBinding,at:5,in:stmt)
                }
                guard sqlite3_bind_double(insert,6,Date().timeIntervalSince1970)==SQLITE_OK,
                      sqlite3_step(insert)==SQLITE_DONE else { throw databaseFailure() }
                let rc = sqlite3_step(current)
                if rc == SQLITE_ROW { eligible.insert(e.rootID+"\0"+e.path) }
                else if rc != SQLITE_DONE { throw databaseFailure() }
                sqlite3_reset(current)
            }
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
            return eligible
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    /// Local-only query for diagnostics/tests. A migrated job is always
    /// legacy_unknown unless it was explicitly created after the migration.
    public func originOfJob(id: Int64) throws -> QueuedChangeOrigin? {
        let statement = try prepare("SELECT origin FROM change_queue WHERE id=?;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, id) == SQLITE_OK else { throw databaseFailure() }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let origin = QueuedChangeOrigin(rawValue: columnText(statement, at: 0)) else {
                throw JournalError.database("Invalid job origin stored in database")
            }
            return origin
        default: throw databaseFailure()
        }
    }

    /// Complete ONLY confirmed initial-inventory jobs using the matching
    /// entries of an already acquired archive snapshot. This does not access
    /// source or destination files, and never marks monitor/audit/legacy jobs
    /// completed. Source root, exact current inventory and newer-job guards
    /// are checked within one atomic SQLite transaction.
    public func acknowledgeInitialInventoryMatches(
        _ findings: [AuditFinding],
        shouldContinue: () -> Bool = { true },
        onProgress: (Int,Int) -> Void = { _,_ in }
    ) throws -> (files: Int, directories: Int) {
        guard !findings.isEmpty else { return (0,0) }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            // A queue rebuild or interrupted publication is NOT evidence of
            // completed delivery; never use a snapshot to clear such jobs.
            if try queueRebuildToken() != nil {
                try execute("COMMIT;")
                return (0,0)
            }
            let candidates = try prepare("""
                SELECT root_id,relative_path
                FROM change_queue
                WHERE completed=0 AND kind='upsert' AND origin='initial_inventory';
                """)
            var initialPaths: Set<String> = []
            var step = sqlite3_step(candidates)
            while step == SQLITE_ROW {
                guard shouldContinue() else {
                    sqlite3_finalize(candidates)
                    throw SeedVerificationError.cancelled
                }
                initialPaths.insert(columnText(candidates,at:0) + "\0" + columnText(candidates,at:1))
                step = sqlite3_step(candidates)
            }
            sqlite3_finalize(candidates)
            guard step == SQLITE_DONE else { throw databaseFailure() }
            if initialPaths.isEmpty {
                try execute("COMMIT;")
                return (0,0)
            }
            let sql = """
                UPDATE change_queue SET completed=1
                WHERE completed=0 AND kind='upsert' AND origin='initial_inventory'
                  AND root_id=?1 AND relative_path=?2
                  AND NOT EXISTS (SELECT 1 FROM queue_rebuild_hold)
                  AND EXISTS (SELECT 1 FROM watched_roots w
                              WHERE w.root_id=change_queue.root_id AND w.absolute_path=?3)
                  AND EXISTS (SELECT 1 FROM file_inventory f
                              WHERE f.root_id=change_queue.root_id
                                AND f.relative_path=change_queue.relative_path AND f.kind=?4
                                AND (f.kind='directory' OR
                                    (f.file_size=?5 AND ABS(f.modified_at-?6)<0.002)))
                  AND NOT EXISTS (SELECT 1 FROM change_queue newer
                                  WHERE newer.root_id=change_queue.root_id
                                    AND newer.relative_path=change_queue.relative_path
                                    AND newer.id>change_queue.id)
                  AND NOT EXISTS (SELECT 1 FROM publication_intents i WHERE i.job_id=change_queue.id)
                  AND NOT EXISTS (SELECT 1 FROM transfer_recovery t WHERE t.job_id=change_queue.id)
                  AND NOT EXISTS (SELECT 1 FROM blocked_name_jobs b WHERE b.job_id=change_queue.id)
                  AND NOT EXISTS (SELECT 1 FROM upload_retry r WHERE r.job_id=change_queue.id);
                """
            let update = try prepare(sql)
            defer { sqlite3_finalize(update) }
            var files=0, directories=0
            let total=findings.count
            var lastProgress=ProcessInfo.processInfo.systemUptime
            onProgress(0,total)
            for (index,finding) in findings.enumerated() {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                let now=ProcessInfo.processInfo.systemUptime
                if now-lastProgress >= 0.5 {
                    onProgress(index,total); lastProgress=now
                }
                guard finding.kind == .matching,
                      finding.objectKind == "file" || finding.objectKind == "directory",
                      WindowsPathSafety.validRelativePath(finding.relativePath),
                      initialPaths.contains(finding.id) else { continue }
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                try bind(finding.rootID, at:1, in:update)
                try bind(finding.relativePath, at:2, in:update)
                try bind(finding.sourceRoot, at:3, in:update)
                try bind(finding.objectKind, at:4, in:update)
                guard sqlite3_bind_int64(update,5,finding.sourceBytes ?? -1) == SQLITE_OK,
                      sqlite3_bind_double(update,6,finding.sourceModifiedAt ?? -1) == SQLITE_OK,
                      sqlite3_step(update) == SQLITE_DONE else { throw databaseFailure() }
                let changed=Int(sqlite3_changes(connection))
                if finding.objectKind == "file" { files += changed }
                else { directories += changed }
            }
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
            onProgress(total,total)
            return (files,directories)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func plannedUploadCount(throughID: Int64 = Int64.max) throws -> Int {
        try plannedCount(kind: .upsert, afterID: 0, throughID: throughID)
    }

    public func plannedDeleteCount(afterID: Int64, throughID: Int64 = Int64.max) throws -> Int {
        try plannedCount(kind: .delete, afterID: afterID, throughID: throughID)
    }

    private func plannedCount(kind: ChangeKind, afterID: Int64, throughID: Int64) throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM change_queue WHERE completed=0 AND kind=? AND id>? AND id<=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(kind.rawValue, at: 1, in: stmt)
        guard sqlite3_bind_int64(stmt, 2, afterID) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 3, throughID) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func pendingDeleteUpperBound(afterID: Int64) throws -> Int64? {
        let stmt = try prepare("SELECT MAX(id) FROM change_queue WHERE completed=0 AND kind='delete' AND id>?;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, afterID) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0)
    }

    // A single bounded snapshot, leaf paths first. Cursor follows SQL
    // length in Unicode scalars, not Swift grapheme clusters.
    public func pendingDeletePage(afterID: Int64, throughID: Int64,
                                  previousLength: Int64 = Int64.max,
                                  previousID: Int64 = 0, limit: Int = 100) throws -> [QueuedChange] {
        let stmt = try prepare("""
            SELECT id,root_id,relative_path,kind,recorded_at FROM change_queue
            WHERE completed=0 AND kind='delete' AND id>? AND id<=?
              AND (length(relative_path)<? OR (length(relative_path)=? AND id>?))
            ORDER BY \(QueueExecutionOrder.deleteSQL) LIMIT ?;
            """)
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [afterID, throughID, previousLength, previousLength, previousID,
                               Int64(max(1,min(limit,1000)))].enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(index+1), value) == SQLITE_OK else { throw databaseFailure() }
        }
        var jobs: [QueuedChange] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return jobs }
            guard rc == SQLITE_ROW else { throw databaseFailure() }
            jobs.append(QueuedChange(id: sqlite3_column_int64(stmt,0), rootID: columnText(stmt,at:1),
                relativePath: columnText(stmt,at:2), kind: .delete,
                recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt,4))))
        }
    }

    // Count all eligible pending jobs, even old ones, plus recent reserved
    // attempts no longer pending. A pending attempted job is counted once.
    public func deletionWindow(rootID: String, afterID: Int64, since: Date) throws -> (pending: Int, total: Int, inventory: Int) {
        let stmt = try prepare("""
            SELECT
              (SELECT COUNT(*) FROM change_queue q WHERE q.root_id=?1 AND q.kind='delete' AND q.completed=0 AND q.id>?2),
              (SELECT COUNT(*) FROM mirror_attempts a WHERE a.root_id=?1 AND a.attempted_at>=?3
                AND NOT EXISTS (SELECT 1 FROM change_queue q WHERE q.id=a.job_id AND q.completed=0 AND q.kind='delete' AND q.id>?2)),
              (SELECT COUNT(*) FROM file_inventory f WHERE f.root_id=?1);
            """)
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt)
        guard sqlite3_bind_int64(stmt,2,afterID) == SQLITE_OK,
              sqlite3_bind_double(stmt,3,since.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { throw databaseFailure() }
        let pending = Int(sqlite3_column_int64(stmt,0))
        let recent = Int(sqlite3_column_int64(stmt,1))
        return (pending, pending + recent, Int(sqlite3_column_int64(stmt,2)))
    }

    /// Reserve before any filesystem removal: a crash between SMB and the
    /// SQLite acknowledgment must not erase the safety history.
    public func recordMirrorAttempt(_ job: QueuedChange, at date: Date = Date()) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO mirror_attempts(job_id,root_id,attempted_at) VALUES(?,?,?);")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt,1,job.id) == SQLITE_OK else { throw databaseFailure() }
        try bind(job.rootID,at:2,in:stmt)
        guard sqlite3_bind_double(stmt,3,date.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
    }

    public func pruneMirrorAttempts(before date: Date) throws {
        let stmt = try prepare("DELETE FROM mirror_attempts WHERE attempted_at<?;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_double(stmt,1,date.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
    }

    public func mirrorBlockReason() throws -> String? {
        let stmt = try prepare("SELECT reason FROM mirror_safety_lock WHERE singleton=1;")
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw databaseFailure() }
        return columnText(stmt,at:0)
    }

    public func latchMirrorBlock(_ reason: String) throws {
        let stmt = try prepare("INSERT OR IGNORE INTO mirror_safety_lock(singleton,reason) VALUES(1,?);")
        defer { sqlite3_finalize(stmt) }
        try bind(reason,at:1,in:stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
    }

    public func clearMirrorBlock() throws {
        try execute("DELETE FROM mirror_safety_lock WHERE singleton=1;")
    }

    /// Any new upload or inventory entry makes an old delete unsafe.
    /// Check both before the move/remove and again when acknowledging it.
    public func deletionIsCurrent(id: Int64, rootID: String, relativePath: String) throws -> Bool {
        if let connection,try SourceNameLineageStore.protected(connection,root:rootID,path:relativePath) { return false }
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
        if let connection,try SourceNameLineageStore.protected(connection,root:rootID,path:relativePath) { return false }
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

    /// Confirm precisely the upsert that was published. A replaced or
    /// superseded event cannot authorize destruction of its safety copy.
    @discardableResult
    public func acknowledgeUpload(_ job: QueuedChange) throws -> Bool {
        let stmt = try prepare("""
            UPDATE change_queue SET completed=1
            WHERE id=? AND root_id=? AND relative_path=? AND kind='upsert'
              AND completed=0
              AND NOT EXISTS (
                  SELECT 1 FROM change_queue n
                  WHERE n.root_id=change_queue.root_id
                    AND n.relative_path=change_queue.relative_path
                    AND n.completed=0 AND n.id>change_queue.id
              );
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, job.id) == SQLITE_OK else {
            throw databaseFailure()
        }
        try bind(job.rootID, at: 2, in: stmt)
        try bind(job.relativePath, at: 3, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseFailure() }
        return sqlite3_changes(connection) == 1
    }

    // Capture the durable source inventory version and queue sequence before
    // the already-existing mirror scan. A newer event invalidates absence.
    struct LineageAbsenceSnapshot: Equatable {
        let sequence:Int64
        let scan: String
        let event: String
    }
    func lineageAbsenceSnapshot(rootID:String) throws -> LineageAbsenceSnapshot? {
        guard let connection,try SourceNameLineageStore.protectionInstalled(connection) else { return nil }
        let stmt=try prepare("SELECT CAST(last_scan_at AS TEXT),COALESCE(last_event_id,'') FROM watched_roots WHERE root_id=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(rootID,at:1,in:stmt)
        let rc=sqlite3_step(stmt)
        if rc==SQLITE_DONE { return nil }
        guard rc==SQLITE_ROW else { throw databaseFailure() }
        return LineageAbsenceSnapshot(sequence:try queueSequence(),scan:columnText(stmt,at:0),event:columnText(stmt,at:1))
    }

    func resolveLineageMissing(rootID:String,rows:[TrackedItem],snapshot:LineageAbsenceSnapshot?,shouldContinue:()->Bool) throws {
        guard let connection,let snapshot else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard try lineageAbsenceSnapshot(rootID:rootID)==snapshot,shouldContinue() else {
                try execute("COMMIT;"); return
            }
            try SourceNameLineageStore.resolveMissing(connection,root:rootID,rows:rows,shouldContinue:shouldContinue)
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    // Shadow publication evidence is never derived from a generic completed
    // job. The worker supplies the exact local source identity before transfer.
    struct LineageTransferToken {
        let jobID: Int64
        let record: SourceNameLineage.Record
        let revision: Int64
        let priorUncertainty: Bool
        let fingerprint: SeedFileFingerprint
        let sourceURL: URL
    }

    func lineageCopyBindings(_ maps: [MountedFolderMapping]) throws -> [String:[String:String]] {
        guard experimentalSourceNameLineage else { return [:] }
        let stamps = try verifiedDirectoryBindingSnapshot(maps)
        var result: [String:[String:String]] = [:]
        for (root,role,stamp) in stamps { result[root,default:[:]][role] = stamp }
        return result
    }

    private func lineageBindingsCurrent(_ record: SourceNameLineage.Record) throws -> Bool {
        let stmt = try prepare("SELECT role,stamp FROM directory_bindings WHERE root_id=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(record.rootID,at:1,in:stmt)
        var found: [String:String] = [:]
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            found[columnText(stmt,at:0)] = columnText(stmt,at:1)
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw databaseFailure() }
        return found["source"]?.utf8.elementsEqual(record.sourceBinding.utf8) == true &&
            found["target"]?.utf8.elementsEqual(record.targetBinding.utf8) == true
    }

    func beginLineageTransfer(_ job: QueuedChange, mapping: MountedFolderMapping,
                              bindings: [String:String]) throws -> LineageTransferToken? {
        guard experimentalSourceNameLineage, job.kind == .upsert, let connection,
              job.rootID == mapping.rootID, WindowsPathSafety.validRelativePath(job.relativePath),
              let src = bindings["source"], let dst = bindings["target"] else { return nil }
        let url = try mapping.fileURL(relativePath:job.relativePath,destination:false)
        var info = stat()
        guard url.resolvingSymlinksInPath().path == url.path,
              url.path.withCString({ lstat($0,&info) }) == 0,
              let id = SourceNameLineage.Identity(stat:info) else { return nil }
        let initial = SourceNameLineage.Record(identity:id,rootID:job.rootID,
            sourceBinding:src,targetBinding:dst,path:job.relativePath)
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard try uploadIsCurrent(job), try lineageBindingsCurrent(initial),
                  try watchedRootPath(rootID:job.rootID) == mapping.source.path else {
                try execute("COMMIT;"); return nil
            }
            try SourceNameLineageStore.install(connection)
            let saved = try SourceNameLineageStore.read(connection,key:.init(initial))
            guard saved == nil || saved?.record.currentPath.utf8.elementsEqual(job.relativePath.utf8) == true else {
                try execute("COMMIT;"); return nil
            }
            var record = saved?.record ?? initial
            let prior = record.uncertainPublication
            record.publicationStarted()
            let written = try SourceNameLineageStore.write(connection,record:record,expectedRevision:saved?.revision)
            try execute("COMMIT;")
            return LineageTransferToken(jobID:job.id,record:record,revision:written.revision,
                priorUncertainty:prior,fingerprint:SeedFileFingerprint(fileStat:info),sourceURL:url)
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    /// The successful-transfer branch is the only caller. Atomic ACK and
    /// history commit; no new SMB read or change to generic completion.
    func acknowledgeLineageTransfer(_ job: QueuedChange, token: LineageTransferToken?) throws -> Bool {
        guard experimentalSourceNameLineage, let token, let connection else {
            return try acknowledgeUpload(job)
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let accepted = try acknowledgeUpload(job)
            if accepted, token.jobID == job.id,
               token.record.rootID == job.rootID,
               token.record.currentPath.utf8.elementsEqual(job.relativePath.utf8),
               try lineageBindingsCurrent(token.record),
               let saved = try SourceNameLineageStore.read(connection,key:.init(token.record)),
               saved.revision == token.revision,
               saved.record.currentPath.utf8.elementsEqual(job.relativePath.utf8) {
                var info = stat()
                if token.sourceURL.resolvingSymlinksInPath().path == token.sourceURL.path,
                   token.sourceURL.path.withCString({ lstat($0,&info) }) == 0,
                   SourceNameLineage.Identity(stat:info) == token.record.identity,
                   SeedFileFingerprint(fileStat:info) == token.fingerprint {
                    var updated = saved.record
                    updated.confirmAttempt(path:job.relativePath,previousUncertainty:token.priorUncertainty)
                    try SourceNameLineageStore.write(connection,record:updated,expectedRevision:saved.revision)
                    try SourceNameLineageStore.releaseConfirmed(connection,record:updated)
                }
            }
            try execute("COMMIT;")
            return accepted
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    public func markCompleted(id: Int64) throws {
        let statement = try prepare("UPDATE change_queue SET completed = 1 WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, id) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseFailure()
        }
    }

    /// One conservative retention batch, called only by a drained operational
    /// owner. Never infer completion from enqueue date. Retain the newest
    /// event per exact path (including when newer work is pending), all
    /// recovery/rectification evidence, and unknown legacy completion dates.
    /// No filesystem work, VACUUM, checkpoint or authorization changes.
    public func pruneCompletedQueueBatch(now:Date=Date(),limit:Int=250,
                                         shouldContinue:()->Bool={true}) throws -> Int {
        try pruneCompletedQueuePage(now:now,limit:limit,shouldContinue:shouldContinue).removed
    }

    public func pruneCompletedQueuePage(afterID:Int64=0,now:Date=Date(),limit:Int=250,
                                        shouldContinue:()->Bool={true}) throws -> RetentionPage {
        guard shouldContinue() else { return .init(removed:0,examined:0,nextAfterID:afterID,finished:false,held:true) }
        let cutoff=now.addingTimeInterval(-30*86400).timeIntervalSince1970
        guard cutoff.isFinite else { throw JournalError.database("Invalid retention date") }
        // This connection is owned by the serial worker; maintenance may
        // yield to an FSEvents writer rather than wait five seconds.
        guard sqlite3_busy_timeout(connection,25)==SQLITE_OK else {throw databaseFailure()}
        defer {sqlite3_busy_timeout(connection,5000)}
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            if try queueRebuildToken() != nil || hasPendingNameRectification() || mirrorBlockReason() != nil {
                try execute("COMMIT;")
                return .init(removed:0,examined:0,nextAfterID:afterID,finished:false,held:true)
            }
            let count=max(1,min(250,limit))
            let scan=try prepare("SELECT job_id FROM queue_completion_ledger WHERE job_id>? ORDER BY job_id LIMIT ?;")
            defer {sqlite3_finalize(scan)}
            guard sqlite3_bind_int64(scan,1,afterID)==SQLITE_OK,
                  sqlite3_bind_int(scan,2,Int32(count))==SQLITE_OK else {throw databaseFailure()}
            var last=afterID,examined=0
            while true {
                let rc=sqlite3_step(scan)
                if rc==SQLITE_DONE {break}
                guard rc==SQLITE_ROW,shouldContinue() else {
                    if !shouldContinue() {throw SeedVerificationError.cancelled}
                    throw databaseFailure()
                }
                last=sqlite3_column_int64(scan,0);examined+=1
            }
            guard examined>0 else {
                try execute("COMMIT;")
                return .init(removed:0,examined:0,nextAfterID:afterID,finished:true,held:false)
            }
            // Bound VM work even if many expired rows are protected. Never
            // retry inside a maintenance batch after an interrupted statement.
            let stmt=try prepare("""
                DELETE FROM change_queue WHERE id IN (
                    SELECT q.id FROM queue_completion_ledger t
                    CROSS JOIN change_queue q ON q.id=t.job_id
                    WHERE t.job_id>?3 AND t.job_id<=?4 AND t.completed_at<=?1 AND q.completed=1
                      AND EXISTS(SELECT 1 FROM change_queue n WHERE n.root_id=q.root_id
                        AND n.relative_path=q.relative_path AND n.id>q.id AND n.completed=1)
                      AND NOT EXISTS(SELECT 1 FROM change_queue p WHERE p.root_id=q.root_id
                        AND p.relative_path=q.relative_path AND p.completed=0)
                      AND NOT EXISTS(SELECT 1 FROM retired_delete_evidence e WHERE e.job_id=q.id)
                      AND NOT EXISTS(SELECT 1 FROM retired_publication_evidence e WHERE e.job_id=q.id)
                      AND NOT EXISTS(SELECT 1 FROM publication_intents e WHERE e.job_id=q.id OR (e.root_id=q.root_id AND e.relative_path=q.relative_path))
                      AND NOT EXISTS(SELECT 1 FROM transfer_recovery e WHERE e.job_id=q.id OR (e.root_id=q.root_id AND e.relative_path=q.relative_path))
                      AND NOT EXISTS(SELECT 1 FROM blocked_name_jobs e WHERE e.job_id=q.id)
                      AND NOT EXISTS(SELECT 1 FROM upload_retry e WHERE e.job_id=q.id OR (e.scope='root' AND e.root_id=q.root_id))
                      AND NOT EXISTS(SELECT 1 FROM mirror_attempts e WHERE e.job_id=q.id)
                      AND NOT EXISTS(SELECT 1 FROM name_rectification_monitor_links e WHERE e.job_id=q.id)
                    ORDER BY t.job_id LIMIT ?2
                ) AND completed=1;
                """)
            defer {sqlite3_finalize(stmt)}
            guard let connection else {throw databaseFailure()}
            final class Budget {
                let deadline=ProcessInfo.processInfo.systemUptime+0.15
            }
            let budget=Budget()
            let context=Unmanaged.passUnretained(budget).toOpaque()
            sqlite3_progress_handler(connection,1000,{ raw in
                guard let raw else {return 1}
                let budget=Unmanaged<Budget>.fromOpaque(raw).takeUnretainedValue()
                return ProcessInfo.processInfo.systemUptime>=budget.deadline ? 1:0
            },context)
            defer {sqlite3_progress_handler(connection,0,nil,nil);withExtendedLifetime(budget){}}
            guard sqlite3_bind_double(stmt,1,cutoff)==SQLITE_OK,
                  sqlite3_bind_int(stmt,2,Int32(count))==SQLITE_OK,
                  sqlite3_bind_int64(stmt,3,afterID)==SQLITE_OK,
                  sqlite3_bind_int64(stmt,4,last)==SQLITE_OK,
                  sqlite3_step(stmt)==SQLITE_DONE else {throw databaseFailure()}
            let removed=Int(sqlite3_changes(connection))
            guard shouldContinue() else {throw SeedVerificationError.cancelled}
            try execute("COMMIT;")
            return .init(removed:removed,examined:examined,nextAfterID:last,finished:examined<count,held:false)
        } catch {try? execute("ROLLBACK;");throw error}
    }

    /// Historical receipts are diagnostic associations, not remote deletion
    /// evidence. Retain the newest receipt for each old name so pruning never
    /// resurrects an older candidate. Only prune older unlinked records after
    /// the matching source has been scanned again and has no pending work.
    public func pruneRectificationReceiptPage(afterID:Int64=0,now:Date=Date(),limit:Int=100,
                                               shouldContinue:()->Bool={true}) throws -> RetentionPage {
        guard shouldContinue() else {return .init(removed:0,examined:0,nextAfterID:afterID,finished:false,held:true)}
        let cutoff=now.addingTimeInterval(-90*86400)
        guard cutoff.timeIntervalSince1970.isFinite else {throw JournalError.database("Invalid retention date")}
        // This connection is owned by the serial worker; maintenance may
        // yield to an FSEvents writer rather than wait five seconds.
        guard sqlite3_busy_timeout(connection,25)==SQLITE_OK else {throw databaseFailure()}
        defer {sqlite3_busy_timeout(connection,5000)}
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard shouldContinue() else {throw SeedVerificationError.cancelled}
            if try queueRebuildToken() != nil || hasPendingNameRectification() || mirrorBlockReason() != nil {
                try execute("COMMIT;")
                return .init(removed:0,examined:0,nextAfterID:afterID,finished:false,held:true)
            }
            guard let connection else {throw databaseFailure()}
            final class ReceiptBudget {
                let deadline=ProcessInfo.processInfo.systemUptime+0.15
            }
            let budget=ReceiptBudget()
            let context=Unmanaged.passUnretained(budget).toOpaque()
            sqlite3_progress_handler(connection,1000,{ raw in
                guard let raw else {return 1}
                let budget=Unmanaged<ReceiptBudget>.fromOpaque(raw).takeUnretainedValue()
                return ProcessInfo.processInfo.systemUptime>=budget.deadline ? 1:0
            },context)
            defer {sqlite3_progress_handler(connection,0,nil,nil);withExtendedLifetime(budget){}}
            let count=max(1,min(100,limit))
            let scan=try prepare("""
                SELECT id,root_id,old_path,new_path,receipt
                FROM name_rectification_receipts WHERE id>? ORDER BY id LIMIT ?;
                """)
            defer {sqlite3_finalize(scan)}
            guard sqlite3_bind_int64(scan,1,afterID)==SQLITE_OK,
                  sqlite3_bind_int(scan,2,Int32(count))==SQLITE_OK else {throw databaseFailure()}
            var candidates:[(Int64,NameRectificationReceipt)]=[]
            var last=afterID,examined=0
            while true {
                let rc=sqlite3_step(scan)
                if rc==SQLITE_DONE {break}
                guard rc==SQLITE_ROW else {throw databaseFailure()}
                guard shouldContinue(),ProcessInfo.processInfo.systemUptime<budget.deadline else {throw SeedVerificationError.cancelled}
                last=sqlite3_column_int64(scan,0);examined+=1
                // Unknown or malformed evidence is preserved, not repaired.
                guard let r=try? JSONDecoder().decode(NameRectificationReceipt.self,from:Data(columnText(scan,at:4).utf8)),
                      r.rootID==columnText(scan,at:1),
                      r.oldPath.utf8.elementsEqual(columnText(scan,at:2).utf8),
                      r.newPath.utf8.elementsEqual(columnText(scan,at:3).utf8),
                      r.completedAt<=cutoff else {continue}
                candidates.append((last,r))
            }
            let remove=try prepare("""
                DELETE FROM name_rectification_receipts
                WHERE id=?1 AND root_id=?2 AND old_path=?3
                  AND EXISTS(SELECT 1 FROM name_rectification_receipts n
                    WHERE n.root_id=?2 AND n.old_path=?3 AND n.id>?1)
                  AND EXISTS(SELECT 1 FROM watched_roots w
                    WHERE w.root_id=?2 AND w.absolute_path=?4 AND w.last_scan_at>?5)
                  AND EXISTS(SELECT 1 FROM directory_bindings b
                    WHERE b.root_id=?2 AND b.role='source' AND b.stamp=?6)
                  AND NOT EXISTS(SELECT 1 FROM name_rectification_monitor_links l WHERE l.receipt_id=?1)
                  AND NOT EXISTS(SELECT 1 FROM change_queue q WHERE q.root_id=?2 AND q.completed=0)
                  AND NOT EXISTS(SELECT 1 FROM publication_intents p WHERE p.root_id=?2)
                  AND NOT EXISTS(SELECT 1 FROM transfer_recovery t WHERE t.root_id=?2)
                  AND NOT EXISTS(SELECT 1 FROM retired_delete_evidence e JOIN change_queue q ON q.id=e.job_id WHERE q.root_id=?2)
                  AND NOT EXISTS(SELECT 1 FROM retired_publication_evidence e JOIN change_queue q ON q.id=e.job_id WHERE q.root_id=?2);
                """)
            defer {sqlite3_finalize(remove)}
            var removed=0
            // Match the exact persisted binding encoding through decoding,
            // not a newly serialized JSON string with different key order.
            let binding=try prepare("SELECT stamp FROM directory_bindings WHERE root_id=? AND role='source';")
            defer {sqlite3_finalize(binding)}
            for (id,r) in candidates {
                guard shouldContinue(),ProcessInfo.processInfo.systemUptime<budget.deadline else {throw SeedVerificationError.cancelled}
                sqlite3_reset(binding);sqlite3_clear_bindings(binding)
                try bind(r.rootID,at:1,in:binding)
                let rc=sqlite3_step(binding)
                if rc==SQLITE_DONE {continue}
                guard rc==SQLITE_ROW else {throw databaseFailure()}
                let stamp=columnText(binding,at:0)
                guard let saved=try? JSONDecoder().decode(DirectoryBinding.self,from:Data(stamp.utf8)),
                      saved==r.sourceBinding else {continue}
                sqlite3_reset(binding)
                sqlite3_reset(remove);sqlite3_clear_bindings(remove)
                guard sqlite3_bind_int64(remove,1,id)==SQLITE_OK else {throw databaseFailure()}
                try bind(r.rootID,at:2,in:remove)
                try bind(r.oldPath,at:3,in:remove)
                try bind(r.sourceRoot,at:4,in:remove)
                guard sqlite3_bind_double(remove,5,r.completedAt.timeIntervalSince1970)==SQLITE_OK else {throw databaseFailure()}
                try bind(stamp,at:6,in:remove)
                guard sqlite3_step(remove)==SQLITE_DONE else {throw databaseFailure()}
                removed+=Int(sqlite3_changes(connection))
            }
            guard shouldContinue() else {throw SeedVerificationError.cancelled}
            try execute("COMMIT;")
            return .init(removed:removed,examined:examined,nextAfterID:last,finished:examined<count,held:false)
        } catch {try? execute("ROLLBACK;");throw error}
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
