import Foundation
import Darwin
import SQLite3

public struct MirrorDeletionPolicy: Equatable, Sendable {
    public let enabled: Bool
    public let recoveryEnabled: Bool
    /// nil means never delete automatically. Valid day values are 1...30.
    public let retentionDays: Int?

    public init(enabled: Bool, recoveryEnabled: Bool, retentionDays: Int?) throws {
        guard retentionDays == nil || (1...30).contains(retentionDays!) else {
            throw JournalError.database("Retention must be 1...30 days, or never")
        }
        self.enabled = enabled
        self.recoveryEnabled = recoveryEnabled
        self.retentionDays = retentionDays
    }
}

/// Stops processing future destructive operations after the user presses
/// Ferma copie or changes the configured folders. A filesystem operation
/// already started may finish; no process can roll back a completed unlink.
public final class MirrorDeletionCancellation {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

public enum MirrorDeletionFailure: Error, LocalizedError {
    case disabled
    case noBaseline
    case unsafePath
    case sourceChanged
    case volumeChanged
    case bulkDeletion(String)
    case unsupportedObject
    case pendingTransfer
    case destinationChanged

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Cancellazioni disabilitate"
        case .noBaseline: return "Inventario iniziale non verificato: cancellazioni sospese"
        case .unsafePath: return "Percorso protetto o symlink: cancellazione rifiutata"
        case .sourceChanged: return "La sorgente non corrisponde più all'inventario"
        case .volumeChanged: return "Il volume della destinazione è cambiato o assente"
        case .bulkDeletion(let reason): return "Cancellazioni massive bloccate: " + reason
        case .unsupportedObject: return "Elemento speciale: nessuna cancellazione"
        case .pendingTransfer: return "File ricreato o nuovo evento in coda"
        case .destinationChanged: return "Destinazione modificata durante l'operazione"
        }
    }
}

public struct MirrorDeletionSummary {
    public var removed = 0
    public var recovered = 0
    public var directories = 0
    public var missing = 0
    public var deferred = 0
    public var blocked = false
    public var detail = ""
    public init() {}
}

fileprivate struct MirrorRootIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let volume: VolumeFingerprint
    let targetDevice: UInt64
    let targetInode: UInt64
    let baselineCount: Int
}

/// Three independent, optional anti-error protections. Technical
/// validation is performed regardless of these settings.
public struct MirrorProtectionSettings: Codable, Equatable, Sendable {
    public var absoluteEnabled = false
    public var absoluteLimit = 1000
    public var fractionEnabled = false
    public var percentLimit = 50
    public var emptyEnabled = false
    public var windowHours = 24

    public init() {}
    public var isValid: Bool {
        (1...1_000_000).contains(absoluteLimit) && (1...100).contains(percentLimit)
            && (1...48).contains(windowHours)
    }
    public var anyEnabled: Bool { absoluteEnabled || fractionEnabled || emptyEnabled }
}

/// Only created following explicit user consent. The DB identity prevents
/// replaying an old authorization against a newly created database.
public struct MirrorAuthorization: Codable, Equatable, Sendable {
    fileprivate struct Root: Codable, Equatable, Sendable {
        let sourcePath: String
        let targetPath: String
        let targetVolume: VolumeFingerprint
        let identity: MirrorRootIdentity
    }
    fileprivate let roots: [String: Root]
    fileprivate let databaseID: String
    fileprivate let cutoff: Int64

    public static func capture(journal: ChangeJournal, mappings: [MountedFolderMapping]) throws -> MirrorAuthorization {
        guard !mappings.isEmpty, Set(mappings.map(\.rootID)).count == mappings.count else {
            throw MirrorDeletionFailure.noBaseline
        }
        // No overlapping pairs; otherwise the same folder could be
        // indirectly modified by a different independent synchronization.
        let paths = mappings.flatMap { [$0.source.path.lowercased(), $0.target.path.lowercased()] }
        for i in paths.indices {
            for j in paths.indices where j > i {
                guard paths[i] != paths[j], !paths[i].hasPrefix(paths[j] + "/"),
                      !paths[j].hasPrefix(paths[i] + "/") else { throw MountedCopyError.invalidMapping }
            }
        }
        var roots: [String: Root] = [:]
        for map in mappings {
            let before = try captureIdentity(map, journal: journal, count: 0)
            let inventory = try LocalScanner.scan(root: map.source)
            let after = try captureIdentity(map, journal: journal, count: 0)
            guard before == after else { throw MirrorDeletionFailure.sourceChanged }
            let identity = MirrorRootIdentity(device: after.device, inode: after.inode,
                volume: after.volume, targetDevice: after.targetDevice,
                targetInode: after.targetInode, baselineCount: inventory.count)
            roots[map.rootID] = Root(sourcePath: map.source.path, targetPath: map.target.path,
                targetVolume: map.targetVolume, identity: identity)
        }
        return MirrorAuthorization(roots: roots, databaseID: try journal.databaseIdentity(),
            cutoff: try journal.queueSequence())
    }

    fileprivate static func captureIdentity(_ map: MountedFolderMapping, journal: ChangeJournal,
                                            count: Int) throws -> MirrorRootIdentity {
        try map.verify()
        guard try journal.watchedRootPath(rootID: map.rootID) == map.source.path else {
            throw MirrorDeletionFailure.noBaseline
        }
        var src = stat(), dst = stat()
        guard map.source.path.withCString({ lstat($0, &src) }) == 0,
              map.target.path.withCString({ lstat($0, &dst) }) == 0,
              src.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              dst.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MirrorDeletionFailure.sourceChanged
        }
        return MirrorRootIdentity(device: UInt64(bitPattern: Int64(src.st_dev)), inode: UInt64(src.st_ino),
            volume: try VolumeFingerprint.read(at: map.source),
            targetDevice: UInt64(bitPattern: Int64(dst.st_dev)), targetInode: UInt64(dst.st_ino),
            baselineCount: count)
    }

    fileprivate func validated(journal: ChangeJournal, mappings: [MountedFolderMapping]) throws -> [String: MirrorRootIdentity] {
        guard try journal.databaseIdentity() == databaseID,
              try journal.queueSequence() >= cutoff,
              roots.count == mappings.count else { throw MirrorDeletionFailure.noBaseline }
        var result: [String: MirrorRootIdentity] = [:]
        for map in mappings {
            guard let root = roots[map.rootID], root.sourcePath == map.source.path,
                  root.targetPath == map.target.path, root.targetVolume == map.targetVolume else {
                throw MirrorDeletionFailure.volumeChanged
            }
            let current = try Self.captureIdentity(map, journal: journal, count: root.identity.baselineCount)
            guard current == root.identity else { throw MirrorDeletionFailure.sourceChanged }
            result[map.rootID] = root.identity
        }
        return result
    }
}

private struct RecoveredRecord {
    let id: String
    let rootID: String
    let targetRoot: String
    let managedRelativePath: String
    let size: Int64
    let inode: UInt64
    let mtime: Double
}

/// Recovery manifests live ONLY in MacSync's local SQLite database.
/// If a move succeeds but the DB insert fails, the moved file remains safely
/// in the recovery folder as an orphan; no automatic broad cleanup follows.
public final class RecoveryManifest {
    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            if handle != nil { sqlite3_close(handle) }
            throw JournalError.database("Cannot open recovery manifest")
        }
        db = handle
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA busy_timeout=5000;")
            try execute("""
                CREATE TABLE IF NOT EXISTS mirror_recovery(
                    id TEXT PRIMARY KEY,
                    root_id TEXT NOT NULL,
                    target_root TEXT NOT NULL,
                    managed_path TEXT NOT NULL,
                    stored_at REAL NOT NULL,
                    expires_at REAL,
                    file_size INTEGER NOT NULL,
                    inode INTEGER NOT NULL,
                    modified_at REAL NOT NULL
                );
                """)
            // Existing early prototypes may have recovery records without a
            // destination identity. Migrate conservatively with an empty value:
            // such records will never be auto-purged on an unknown target.
            let migration = try prepare("PRAGMA table_info(mirror_recovery);")
            var hasTargetRoot = false
            while sqlite3_step(migration) == SQLITE_ROW {
                if column(migration, 1) == "target_root" { hasTargetRoot = true }
            }
            sqlite3_finalize(migration)
            if !hasTargetRoot {
                try execute("ALTER TABLE mirror_recovery ADD COLUMN target_root TEXT NOT NULL DEFAULT '';")
            }
            try execute("CREATE INDEX IF NOT EXISTS idx_mirror_recovery_expiry ON mirror_recovery(expires_at);")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func record(
        id: String, rootID: String, targetRoot: String, managedPath: String,
        size: Int64, inode: UInt64, mtime: Double,
        retentionDays: Int?
    ) throws {
        guard !id.isEmpty, !rootID.isEmpty, !targetRoot.isEmpty, !managedPath.isEmpty,
              !managedPath.hasPrefix("/"), size >= 0,
              retentionDays == nil || (1...30).contains(retentionDays!) else {
            throw JournalError.database("Invalid recovery record")
        }
        let statement = try prepare("""
            INSERT INTO mirror_recovery
            (id,root_id,target_root,managed_path,stored_at,expires_at,file_size,inode,modified_at)
            VALUES(?,?,?,?,?,?,?,?,?);
            """)
        defer { sqlite3_finalize(statement) }
        try bind(id, 1, statement)
        try bind(rootID, 2, statement)
        try bind(targetRoot, 3, statement)
        try bind(managedPath, 4, statement)
        let at = Date().timeIntervalSince1970
        guard sqlite3_bind_double(statement, 5, at) == SQLITE_OK else { throw failure() }
        if let retentionDays {
            guard sqlite3_bind_double(statement, 6, at + Double(retentionDays) * 86_400) == SQLITE_OK else {
                throw failure()
            }
        } else {
            guard sqlite3_bind_null(statement, 6) == SQLITE_OK else { throw failure() }
        }
        guard inode <= UInt64(Int64.max), sqlite3_bind_int64(statement, 7, size) == SQLITE_OK,
              sqlite3_bind_int64(statement, 8, Int64(inode)) == SQLITE_OK,
              sqlite3_bind_double(statement, 9, mtime) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    fileprivate func expired(before: Date, limit: Int = 200) throws -> [RecoveredRecord] {
        let statement = try prepare("""
            SELECT id,root_id,target_root,managed_path,file_size,inode,modified_at
            FROM mirror_recovery
            WHERE expires_at IS NOT NULL AND expires_at <= ?
            ORDER BY expires_at, id LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, before.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 500)))) == SQLITE_OK
        else { throw failure() }
        var items: [RecoveredRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            let inodeValue = sqlite3_column_int64(statement, 5)
            guard inodeValue >= 0 else { continue }
            items.append(RecoveredRecord(
                id: column(statement, 0),
                rootID: column(statement, 1),
                targetRoot: column(statement, 2),
                managedRelativePath: column(statement, 3),
                size: sqlite3_column_int64(statement, 4),
                inode: UInt64(inodeValue),
                mtime: sqlite3_column_double(statement, 6)
            ))
        }
        return items
    }

    fileprivate func forget(id: String) throws {
        let statement = try prepare("DELETE FROM mirror_recovery WHERE id=?;")
        defer { sqlite3_finalize(statement) }
        try bind(id, 1, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
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
    private func bind(_ text: String, _ index: Int32, _ statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard status == SQLITE_OK else { throw failure() }
    }
    private func column(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
    }
    private func failure() -> JournalError {
        JournalError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite closed")
    }
}

/// One-SESSION opt-in, safe-by-default experimental mirror worker.
/// The persisted UI toggle alone NEVER enables filesystem deletions.
/// Only DELETE jobs observed AFTER arming are candidates. Empty directories
/// are removed after regular files; symlinks and unexpected objects are not.
public final class MirrorDeletionWorker {
    private let journal: ChangeJournal
    private let manifest: RecoveryManifest
    private let log: SyncActivityLog
    private let policy: MirrorDeletionPolicy
    private let mappings: [String: MountedFolderMapping]
    private let baselines: [String: MirrorRootIdentity]
    private let armedAt: Date
    private let cancellation: MirrorDeletionCancellation
    private var appliedDuringSession = 0
    private let authorization: MirrorAuthorization?
    private let protections: MirrorProtectionSettings

    public init(
        journal: ChangeJournal, manifest: RecoveryManifest, log: SyncActivityLog,
        mappings: [MountedFolderMapping], policy: MirrorDeletionPolicy,
        cancellation: MirrorDeletionCancellation = MirrorDeletionCancellation(),
        authorization: MirrorAuthorization? = nil,
        protections: MirrorProtectionSettings = MirrorProtectionSettings()
    ) throws {
        guard policy.enabled, !mappings.isEmpty,
              Set(mappings.map(\.rootID)).count == mappings.count else {
            throw MirrorDeletionFailure.disabled
        }
        self.journal = journal
        self.manifest = manifest
        self.log = log
        self.policy = policy
        self.cancellation = cancellation
        self.authorization = authorization
        self.protections = protections
        guard protections.isValid else { throw MirrorDeletionFailure.noBaseline }
        self.mappings = Dictionary(uniqueKeysWithValues: mappings.map { ($0.rootID, $0) })

        if let authorization {
            self.baselines = try authorization.validated(journal: journal, mappings: mappings)
            self.armedAt = Date()
            return
        }
        // Compatibility for explicit legacy session-only core callers.
        // The application requires a persisted authorization instead.
        var captured: [String: MirrorRootIdentity] = [:]
        for mapping in mappings {
            try mapping.verify()
            // The watcher's durable SQLite source mapping must agree with the
            // selected folder; never apply historical deletes to a new root.
            guard try journal.watchedRootPath(rootID: mapping.rootID) == mapping.source.path
            else { throw MirrorDeletionFailure.noBaseline }
            let inventory = try LocalScanner.scan(root: mapping.source)
            // An empty source is allowed ONLY so that previously recovered
            // items can still expire. DeletionSafety rejects fresh deletes
            // against a zero-item baseline (no verified source inventory).
            let rootStamp = try Self.statFile(mapping.source)
            let targetStamp = try Self.statFile(mapping.target)
            guard Self.isDirectory(rootStamp), Self.isDirectory(targetStamp)
            else { throw MirrorDeletionFailure.noBaseline }
            captured[mapping.rootID] = MirrorRootIdentity(
                device: UInt64(bitPattern: Int64(rootStamp.st_dev)), inode: UInt64(rootStamp.st_ino),
                volume: try VolumeFingerprint.read(at: mapping.source),
                targetDevice: UInt64(bitPattern: Int64(targetStamp.st_dev)),
                targetInode: UInt64(targetStamp.st_ino),
                baselineCount: inventory.count
            )
        }
        self.baselines = captured
        // Earlier deletion events are not implicitly trusted, even when the
        // UI settings had already been switched on before this session.
        self.armedAt = Date()
    }

    public func runOnce(maxFiles: Int = 25) throws -> MirrorDeletionSummary {
        var result = MirrorDeletionSummary()
        guard !cancellation.isCancelled else {
            result.blocked = true
            result.detail = "Operazioni annullate"
            return result
        }
        let total = try journal.pendingDeleteCount(after: armedAt)
        guard total > 0 else { return result }
        // A rename may produce an upload for the new path and a deletion
        // for the old path. Keep the old server copy until uploads drain.
        guard try journal.pendingUploads(limit: 1).isEmpty else {
            result.blocked = true
            result.detail = "Cancellazioni sospese: copie o aggiornamenti ancora in coda"
            return result
        }
        // Check mass-delete thresholds for ALL candidate jobs, not only the
        // batch size, to prevent evading the gate by paging.
        let baselineCount = baselines.values.reduce(0) { $0 + $1.baselineCount }
        // Include deletions completed in earlier five-minute cycles of THIS
        // session. Otherwise repeated small batches could evade the limit.
        let cumulative = total > Int.max - appliedDuringSession
            ? Int.max : total + appliedDuringSession
        let decision = DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: true,
            trackedFileCount: baselineCount, pendingDeleteCount: cumulative
        )
        guard decision.allowed else {
            result.blocked = true
            result.detail = decision.reason ?? "Cancellazione anomala"
            try? log.record(level: .warning, rootID: "app", action: "mirror_blocked",
                            message: "Protezione cancellazioni: " + result.detail)
            return result
        }

        let jobs = try journal.pendingDeletes(after: armedAt, limit: 1000)
        // Process leaf items first and directories from deepest to shallowest.
        let sorted = jobs.sorted {
            if $0.relativePath.count == $1.relativePath.count {
                return $0.id < $1.id
            }
            return $0.relativePath.count > $1.relativePath.count
        }
        var availableRoots: Set<String> = []
        try process(Array(sorted.prefix(max(1, min(100, maxFiles)))), result: &result, availableRoots: &availableRoots)
        return result
    }

    /// Called before any upload and again before mirror/retention. A safety
    /// latch is persistent even if the operator disables a protection.
    public func verifyBeforeSynchronization(now: Date = Date()) throws {
        guard let authorization else { return }
        if let reason = try journal.mirrorBlockReason() {
            throw MirrorDeletionFailure.bulkDeletion(reason)
        }
        for (id, mapping) in mappings {
            guard let baseline = baselines[id] else { throw MirrorDeletionFailure.noBaseline }
            try verifyRoots(mapping, baseline)
        }
        try evaluateProtection(authorization: authorization, now: now, verifyEmpty: true)
    }

    private func evaluateProtection(authorization: MirrorAuthorization, now: Date,
                                    verifyEmpty: Bool) throws {
        if let reason = try journal.mirrorBlockReason() {
            throw MirrorDeletionFailure.bulkDeletion(reason)
        }
        guard protections.anyEnabled else { return }
        let since = now.addingTimeInterval(-Double(protections.windowHours) * 3600)
        for (id, mapping) in mappings {
            let counts = try journal.deletionWindow(rootID: id, afterID: authorization.cutoff, since: since)
            guard counts.pending > 0 else { continue }
            let denominator = Double(counts.inventory) + Double(counts.total)
            let fraction = denominator > 0 ? Double(counts.total) * 100 / denominator : 0
            var reason: String?
            if protections.absoluteEnabled && counts.total >= protections.absoluteLimit {
                reason = "Limite numerico: \(counts.total) elementi"
            } else if protections.fractionEnabled && fraction >= Double(protections.percentLimit) {
                reason = "Limite percentuale: \(Int(fraction))%"
            } else if protections.emptyEnabled && counts.inventory == 0 {
                if !verifyEmpty || (try LocalScanner.scan(root: mapping.source)).isEmpty {
                    reason = "Sorgente completamente vuota"
                }
            }
            if let reason {
                let detail = id + ": " + reason
                try journal.latchMirrorBlock(detail)
                try? log.record(level: .warning, rootID: id, action: "mirror_blocked", message: detail)
                throw MirrorDeletionFailure.bulkDeletion(detail)
            }
        }
    }

    /// Entire eligible snapshot, ordered deepest/longest paths first.
    /// Every job is attempted once, even if older jobs are deferred.
    public func runCycle(pageSize: Int = 100) throws -> MirrorDeletionSummary {
        guard let authorization else { return try runOnce(maxFiles: 100) }
        var result = MirrorDeletionSummary()
        try verifyBeforeSynchronization()
        guard !cancellation.isCancelled else { return result }
        guard try journal.pendingUploads(limit: 1).isEmpty else {
            result.blocked = true
            result.detail = "Cancellazioni sospese: copie o aggiornamenti ancora in coda"
            return result
        }
        guard let upper = try journal.pendingDeleteUpperBound(afterID: authorization.cutoff) else { return result }
        var length = Int64.max
        var lastID: Int64 = 0
        var availableRoots: Set<String> = []
        while !cancellation.isCancelled {
            try evaluateProtection(authorization: authorization, now: Date(), verifyEmpty: false)
            let page = try journal.pendingDeletePage(afterID: authorization.cutoff, throughID: upper,
                previousLength: length, previousID: lastID, limit: pageSize)
            guard let last = page.last else { break }
            length = Int64(last.relativePath.unicodeScalars.count)
            lastID = last.id
            try process(page, result: &result, availableRoots: &availableRoots)
            if result.blocked { break }
        }
        // Keep history for the longest configurable window, regardless of
        // current settings. Pending jobs remain in the original queue.
        try journal.pruneMirrorAttempts(before: Date().addingTimeInterval(-48 * 3600))
        return result
    }

    private func process(_ jobs: [QueuedChange], result: inout MirrorDeletionSummary,
                         availableRoots: inout Set<String>) throws {
        for job in jobs {
            if cancellation.isCancelled { break }
            if !(try journal.pendingUploads(limit: 1).isEmpty) {
                result.blocked = true
                result.detail = "Nuove copie in coda: cancellazioni sospese"
                break
            }
            if let authorization {
                // Recheck local counters before each action, so new events
                // cannot evade the window by arriving mid-page.
                try evaluateProtection(authorization: authorization, now: Date(), verifyEmpty: false)
            }
            guard let mapping = mappings[job.rootID],
                  let baseline = baselines[job.rootID] else {
                result.deferred += 1
                continue
            }
            do {
                try self.verifyRoots(mapping, baseline)
                if !availableRoots.contains(job.rootID) {
                    _ = try LocalScanner.scan(root: mapping.source)
                    availableRoots.insert(job.rootID)
                }
                guard try journal.deletionIsCurrent(
                    id: job.id, rootID: job.rootID, relativePath: job.relativePath
                ) else { throw MirrorDeletionFailure.pendingTransfer }

                let source = try validatedPath(job.relativePath, under: mapping.source, allowMissingParents: true)
                let destination = try validatedPath(job.relativePath, under: mapping.target)
                // Source leaf must still be absent, including dangling symlinks.
                guard try Self.statIfPresent(source) == nil else {
                    throw MirrorDeletionFailure.sourceChanged
                }
                guard let target = try Self.statIfPresent(destination) else {
                    if try journal.acknowledgeDeletion(
                        id: job.id, rootID: job.rootID, relativePath: job.relativePath
                    ) {
                        result.missing += 1
                        appliedDuringSession += 1
                    }
                    continue
                }
                try verifyRoots(mapping, baseline)
                guard try journal.deletionIsCurrent(
                    id: job.id, rootID: job.rootID, relativePath: job.relativePath
                ) else { throw MirrorDeletionFailure.pendingTransfer }
                // Recheck at the last possible moment, including the
                // destination identity. Another client must not be able to
                // replace a file and have us move/unlink the replacement.
                guard try Self.statIfPresent(source) == nil,
                      let latest = try Self.statIfPresent(destination),
                      latest.st_dev == target.st_dev,
                      latest.st_ino == target.st_ino,
                      latest.st_mode == target.st_mode,
                      latest.st_size == target.st_size,
                      latest.st_mtimespec.tv_sec == target.st_mtimespec.tv_sec,
                      latest.st_mtimespec.tv_nsec == target.st_mtimespec.tv_nsec,
                      latest.st_ctimespec.tv_sec == target.st_ctimespec.tv_sec,
                      latest.st_ctimespec.tv_nsec == target.st_ctimespec.tv_nsec else {
                    throw MirrorDeletionFailure.destinationChanged
                }
                if cancellation.isCancelled { break }
                if authorization != nil {
                    try journal.recordMirrorAttempt(job)
                    // The reservation is durable before touching the share.
                    if cancellation.isCancelled { break }
                }
                if Self.isRegularFile(target) {
                    // Never execute destructive operations on symlinks or
                    // directories with content.
                    if policy.recoveryEnabled {
                        try moveToRecovery(destination, job: job, mapping: mapping)
                        result.recovered += 1
                        try? log.record(level: .success, rootID: job.rootID,
                                        action: "mirror_recovered",
                                        relativePath: job.relativePath,
                                        message: "Spostato in cartella recupero")
                    } else {
                        // No recovery was explicitly chosen. There is NO
                        // automatic way to restore this file in MacSync.
                        try Self.unlinkLeaf(destination)
                        result.removed += 1
                        try? log.record(level: .success, rootID: job.rootID,
                                        action: "mirror_permanent",
                                        relativePath: job.relativePath,
                                        message: "Eliminazione definitiva richiesta")
                    }
                } else if Self.isDirectory(target) {
                    // Empty dirs only. A directory containing untracked files
                    // or a pending child operation will block automatically.
                    guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty
                    else { throw MirrorDeletionFailure.destinationChanged }
                    try Self.removeEmptyDirectory(destination)
                    result.directories += 1
                } else {
                    throw MirrorDeletionFailure.unsupportedObject
                }
                appliedDuringSession += 1
                _ = try journal.acknowledgeDeletion(
                    id: job.id, rootID: job.rootID, relativePath: job.relativePath
                )
            } catch {
                result.deferred += 1
                try? log.record(
                    level: .warning, rootID: job.rootID, action: "mirror_deferred",
                    relativePath: job.relativePath,
                    message: "Operazione non eseguita o non completata: "
                        + ((error as? MirrorDeletionFailure)?.localizedDescription ?? "filesystem/volume non disponibile")
                )
            }
        }
    }

    /// Automatic expiry only for manifest-owned, unchanged recovery files.
    /// A retention setting of "never" writes NULL expires_at and never purges.
    /// This cleanup cannot remove ordinary destination photos or backups.
    @discardableResult
    public func pruneExpiredRecovery(now: Date = Date()) throws -> Int {
        guard policy.enabled, !cancellation.isCancelled else { return 0 }
        if authorization != nil { try verifyBeforeSynchronization() }
        guard try journal.pendingUploads(limit: 1).isEmpty else { return 0 }
        var removed = 0
        for item in try manifest.expired(before: now) {
            if cancellation.isCancelled { break }
            guard let mapping = mappings[item.rootID], let baseline = baselines[item.rootID],
                  mapping.target.path == item.targetRoot else { continue }
            do {
                try verifyRoots(mapping, baseline)
                let safe = try validatedRecovery(item.managedRelativePath, mapping: mapping)
                guard let current = try Self.statIfPresent(safe) else {
                    try manifest.forget(id: item.id)
                    continue
                }
                guard Self.isRegularFile(current),
                      UInt64(current.st_ino) == item.inode,
                      Int64(current.st_size) == item.size,
                      abs(Self.modificationTime(current) - item.mtime) < 0.001 else { continue }
                if cancellation.isCancelled { break }
                try Self.unlinkLeaf(safe)
                try manifest.forget(id: item.id)
                removed += 1
                try? log.record(level: .info, rootID: item.rootID, action: "recovery_expired",
                                message: "Elemento di recupero scaduto e rimosso")
            } catch {
                // A disconnected server, unexpected symlink or modified file
                // must NOT result in cleanup elsewhere.
                continue
            }
        }
        return removed
    }

    private func moveToRecovery(
        _ destination: URL, job: QueuedChange, mapping: MountedFolderMapping
    ) throws {
        let uuid = UUID().uuidString
        // Store original relative path inside a unique UUID namespace.
        // Hidden folder is inside target, always on the SAME mounted volume.
        let managed = ".macsync-recovery/" + uuid + "/" + job.relativePath
        let recovered = try validatedRecovery(managed, mapping: mapping, createParents: true)
        guard try Self.statIfPresent(recovered) == nil else {
            throw MirrorDeletionFailure.destinationChanged
        }
        try mapping.verify()
        try FileManager.default.moveItem(at: destination, to: recovered)
        guard let after = try Self.statIfPresent(recovered), Self.isRegularFile(after) else {
            throw MirrorDeletionFailure.destinationChanged
        }
        try manifest.record(
            id: uuid, rootID: job.rootID, targetRoot: mapping.target.path,
            managedPath: managed,
            size: Int64(after.st_size), inode: UInt64(after.st_ino),
            mtime: Self.modificationTime(after),
            retentionDays: policy.retentionDays
        )
    }

    private func verifyRoots(_ mapping: MountedFolderMapping, _ baseline: MirrorRootIdentity) throws {
        try mapping.verify()
        guard try journal.watchedRootPath(rootID: mapping.rootID) == mapping.source.path
        else { throw MirrorDeletionFailure.sourceChanged }
        let source = try Self.statFile(mapping.source)
        let target = try Self.statFile(mapping.target)
        guard Self.isDirectory(source),
              UInt64(bitPattern: Int64(source.st_dev)) == baseline.device,
              UInt64(source.st_ino) == baseline.inode,
              try VolumeFingerprint.read(at: mapping.source) == baseline.volume
        else { throw MirrorDeletionFailure.sourceChanged }
        guard Self.isDirectory(target),
              UInt64(bitPattern: Int64(target.st_dev)) == baseline.targetDevice,
              UInt64(target.st_ino) == baseline.targetInode
        else { throw MirrorDeletionFailure.volumeChanged }
    }

    private func validatedRecovery(
        _ path: String, mapping: MountedFolderMapping, createParents: Bool = false
    ) throws -> URL {
        guard path.hasPrefix(".macsync-recovery/"), path.count > ".macsync-recovery/".count
        else { throw MirrorDeletionFailure.unsafePath }
        return try validatedPath(path, under: mapping.target, createParents: createParents, recovery: true)
    }

    private func validatedPath(
        _ relative: String, under root: URL, createParents: Bool = false,
        recovery: Bool = false, allowMissingParents: Bool = false
    ) throws -> URL {
        let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0") }),
              recovery || segments.allSatisfy({
                  !$0.lowercased().hasPrefix(".macsync-")
              }) else { throw MirrorDeletionFailure.unsafePath }
        let url = root.appendingPathComponent(relative)
        var current = root
        for segment in segments.dropLast() {
            current.appendPathComponent(String(segment))
            if let state = try Self.statIfPresent(current) {
                guard Self.isDirectory(state) else { throw MirrorDeletionFailure.unsafePath }
            } else if createParents {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            } else if allowMissingParents {
                // A whole source folder may have been deleted. Its missing
                // descendants are valid DELETE events, provided all extant
                // ancestors are real directories (never symlinks).
                continue
            } else {
                throw MirrorDeletionFailure.unsafePath
            }
        }
        return url
    }

    private static func statIfPresent(_ url: URL) throws -> stat? {
        var info = stat()
        let status = url.path.withCString { lstat($0, &info) }
        if status == 0 { return info }
        // Do not treat EACCES, ENOTCONN, EIO or timeout as a deleted file.
        if errno == ENOENT { return nil }
        throw MirrorDeletionFailure.destinationChanged
    }

    private static func statFile(_ url: URL) throws -> stat {
        guard let info = try statIfPresent(url) else { throw MirrorDeletionFailure.sourceChanged }
        return info
    }

    /// POSIX unlink cannot recursively remove a directory even if one is
    /// unexpectedly substituted at the path after our final lstat.
    private static func unlinkLeaf(_ url: URL) throws {
        let rc = url.path.withCString { Darwin.unlink($0) }
        guard rc == 0 else { throw MirrorDeletionFailure.destinationChanged }
    }

    /// rmdir is deliberately used instead of FileManager.removeItem because
    /// removeItem may recursively delete a directory populated by another
    /// user between inspection and removal. rmdir fails when non-empty.
    private static func removeEmptyDirectory(_ url: URL) throws {
        let rc = url.path.withCString { Darwin.rmdir($0) }
        guard rc == 0 else { throw MirrorDeletionFailure.destinationChanged }
    }

    private static func isRegularFile(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func isDirectory(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func modificationTime(_ info: stat) -> Double {
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }
}
