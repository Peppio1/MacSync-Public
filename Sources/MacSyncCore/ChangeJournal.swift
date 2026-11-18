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
    private let databasePath: String

    public init(path: String) throws {
        self.databasePath = path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let description = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if handle != nil { sqlite3_close(handle) }
            throw JournalError.database("Unable to open SQLite: " + description)
        }
        connection = handle

        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
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
            try execute("CREATE TABLE IF NOT EXISTS publication_intents(job_id INTEGER PRIMARY KEY, root_id TEXT NOT NULL, relative_path TEXT NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS queue_rebuild_hold(singleton INTEGER PRIMARY KEY CHECK(singleton=1), token TEXT NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS retired_delete_evidence(job_id INTEGER PRIMARY KEY);")
            try execute("CREATE TABLE IF NOT EXISTS verified_content_cache(root_id TEXT NOT NULL, relative_path TEXT NOT NULL, binding TEXT NOT NULL, source_stamp TEXT NOT NULL, target_stamp TEXT NOT NULL, PRIMARY KEY(root_id,relative_path));")
            try execute("CREATE TABLE IF NOT EXISTS directory_bindings(root_id TEXT NOT NULL, role TEXT NOT NULL, stamp TEXT NOT NULL, PRIMARY KEY(root_id,role));")
            try execute("CREATE INDEX IF NOT EXISTS idx_queue_pending ON change_queue(completed, id);")
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
            try clearVerifiedContentCache()
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
            try execute("DELETE FROM queue_rebuild_hold WHERE singleton=1;")
            try execute("COMMIT;")
            return restored
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
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
    /// Capture a bounded snapshot of pending work. Newly queued events
    /// receive larger AUTOINCREMENT IDs and wait until the next cycle.
    /// First opt-in after migration establishes the target baseline. Never
    /// replace an existing binding automatically, even on reconnection.
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

    public func verifyDirectoryBindings(_ maps: [MountedFolderMapping], allowNewTarget: Bool = false) throws {
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

    public func pendingUploads(limit: Int = 100, afterID: Int64 = 0,
                               throughID: Int64 = Int64.max) throws -> [QueuedChange] {
        let statement = try prepare("""
            SELECT id, root_id, relative_path, kind, recorded_at
              FROM change_queue
             WHERE completed = 0 AND kind = 'upsert' AND id > ? AND id <= ?
             ORDER BY id LIMIT ?;
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
                                    shouldContinue: () -> Bool = { true }) throws -> Int {
        guard !items.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let stmt = try prepare("""
                INSERT INTO change_queue(root_id,relative_path,kind,recorded_at)
                SELECT ?1,?2,'upsert',?3
                WHERE EXISTS(SELECT 1 FROM watched_roots WHERE root_id=?1 AND absolute_path=?4)
                  AND NOT EXISTS(SELECT 1 FROM change_queue WHERE root_id=?1 AND relative_path=?2 AND completed=0)
                  AND NOT EXISTS(SELECT 1 FROM file_inventory WHERE root_id=?1 AND relative_path=?2
                     AND (kind<>?5 OR (kind='file' AND (file_size<>?6 OR ABS(modified_at-?7)>0.002))));
                """)
            defer { sqlite3_finalize(stmt) }
            var count = 0
            for entry in items {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
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
            return count
        } catch { try? execute("ROLLBACK;"); throw error }
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
            ORDER BY length(relative_path) DESC, id LIMIT ?;
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
