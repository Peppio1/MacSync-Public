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
    private var cycleStopped = false
    private var runningCycle = false
    public init() {}
    public var isSessionCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var cycleInProgress: Bool { lock.lock(); defer { lock.unlock() }; return runningCycle }
    public func beginCycle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !runningCycle else { return false }
        cycleStopped = false; runningCycle = true; return true
    }
    @discardableResult public func cancelCurrentCycle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard runningCycle, !stopped, !cycleStopped else { return false }
        cycleStopped = true; return true
    }
    @discardableResult public func endCycle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        runningCycle = false; return stopped || cycleStopped
    }
    public func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped || cycleStopped
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
    case duplicateNotVerified

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
        case .duplicateNotVerified: return "Vecchio e nuovo contenuto non dimostrati identici: nessuna cancellazione"
        }
    }
}

public struct MirrorDeletionSummary {
    public var removed = 0
    public var recovered = 0
    public var directories = 0
    public var missing = 0
    public var deferred = 0
    /// Confirmed already-absent paths, never physical deletions.
    public var reconciledAbsences = 0
    public var reconciledDeferredByRoot:[String:Int] = [:]
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
    /// Advisory queue inspection only; no permission is granted by this value.
    public var queuePreviewCutoff:Int64 { cutoff }

    public static func capture(journal: ChangeJournal, mappings: [MountedFolderMapping],
                               includePendingDeletes: Bool = false,
                               shouldContinue: () -> Bool = { true }) throws -> MirrorAuthorization {
        // Broader consent requires already registered target identities.
        if includePendingDeletes { try journal.verifyDirectoryBindings(mappings) }
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
            let inventory = try LocalScanner.scan(root: map.source,shouldContinue:shouldContinue)
            let after = try captureIdentity(map, journal: journal, count: 0)
            guard before == after, try journal.inventoryPathsMatch(rootID: map.rootID, scanned: inventory)
            else { throw MirrorDeletionFailure.noBaseline }
            let identity = MirrorRootIdentity(device: after.device, inode: after.inode,
                volume: after.volume, targetDevice: after.targetDevice,
                targetInode: after.targetInode, baselineCount: inventory.count)
            roots[map.rootID] = Root(sourcePath: map.source.path, targetPath: map.target.path,
                targetVolume: map.targetVolume, identity: identity)
        }
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        return MirrorAuthorization(roots: roots, databaseID: try journal.databaseIdentity(),
            cutoff: includePendingDeletes ? 0 : try journal.queueSequence())
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

    /// Read-only candidates for display, not an authorization to execute deletion.
    /// The ordinary worker must still evaluate every technical and mass-delete protection.
    public func auditDeletionCandidates(journal: ChangeJournal, mappings: [MountedFolderMapping], shouldContinue: () -> Bool = { true }) throws -> Set<String> {
        _ = try validated(journal:journal,mappings:mappings)
        guard let upper = try journal.pendingDeleteUpperBound(afterID:cutoff) else { return [] }
        var result = Set<String>()
        var length = Int64.max, cursor: Int64 = 0
        while true {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            let page = try journal.pendingDeletePage(afterID:cutoff,throughID:upper,previousLength:length,previousID:cursor,limit:1000)
            if page.isEmpty { break }
            for job in page where roots[job.rootID] != nil && WindowsPathSafety.validDeletionPath(job.relativePath) {
                result.insert(job.rootID + "\0" + job.relativePath)
            }
            guard let last = page.last else { break }
            length = Int64(last.relativePath.unicodeScalars.count); cursor = last.id
        }
        return result
    }

    /// Rebuild after an explicit full audit, using the original authorized
    /// deletion evidence only. Runtime mirror checks still apply.
    public func completeQueueRebuild(journal:ChangeJournal,mappings:[MountedFolderMapping],token:String,
                                     report:ArchiveAuditReport,shouldContinue:() -> Bool) throws -> Int {
        _ = try validated(journal:journal,mappings:mappings)
        let extras = Set(report.findings.filter { $0.kind == .extra && roots[$0.rootID] != nil }.map(\.id))
        return try journal.completeQueueRebuild(token:token,verifiedExtraIDs:extras,
                                                authorizationCutoff:cutoff,shouldContinue:shouldContinue)
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
            try SQLiteConnectionSetup.configureWriter(db)
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
    private var pendingNameProtection = NameRectification.PendingProtection(relations: [])
    private var uploadUpperBoundAtStart: Int64 = 0
    private var postMirrorAbsence:PostMirrorAbsenceReconciliation?

    /// Upload-first remains mandatory for every unprotected upload. An
    /// approved pending rename may leave guarded uploads in the queue;
    /// those alone must not stop independent deletions elsewhere.
    private func prepareUploadPriorityGate() throws -> Bool {
        pendingNameProtection = try NameRectification.pendingProtection(journal: journal)
        let upper = try journal.pendingUploadUpperBound() ?? 0
        uploadUpperBoundAtStart = upper
        guard upper > 0 else { return true }
        guard !pendingNameProtection.isEmpty else { return false }
        var cursor: Int64 = 0
        while true {
            let page = try journal.pendingUploads(limit: 256, afterID: cursor)
            guard let last = page.last else { return true }
            if page.contains(where: { !pendingNameProtection.protects(rootID: $0.rootID, path: $0.relativePath) }) {
                return false
            }
            cursor = last.id
        }
    }

    /// A newly queued upload (ID above the monotonic snapshot) immediately
    /// reactivates the upload-first safety gate during a mirror cycle.
    private func newUploadSinceGate() throws -> Bool {
        (try journal.pendingUploadUpperBound() ?? 0) > uploadUpperBoundAtStart
    }
    public var operationAllowed: () -> Bool = { true }
    public var onEvent: ((SyncCycleEvent) -> Void)?
    public var onJobStarted: ((QueuedChange) -> Void)?
    public var onPlan: ((Int) -> Void)?
    public func plannedCount(throughID: Int64 = Int64.max) throws -> Int {
        guard let authorization else { return try journal.pendingDeleteCount(after: armedAt) }
        return try journal.plannedDeleteCount(afterID: authorization.cutoff, throughID: throughID)
    }
    private func emit(_ kind: SyncEventKind, job: QueuedChange, mapping: MountedFolderMapping?,
                      bytes: Int64? = nil, recoveryPath: String? = nil, detail: String = "") {
        postMirrorAbsence?.observe(kind,job:job)
        onEvent?(SyncCycleEvent(kind:kind,job:job,mapping:mapping,bytes:bytes,recoveryPath:recoveryPath,detail:detail))
    }
    private let authorization: MirrorAuthorization?
    private let protections: MirrorProtectionSettings
    private let transferEngine: StageTransferEngine

    public init(
        journal: ChangeJournal, manifest: RecoveryManifest, log: SyncActivityLog,
        mappings: [MountedFolderMapping], policy: MirrorDeletionPolicy,
        cancellation: MirrorDeletionCancellation = MirrorDeletionCancellation(),
        authorization: MirrorAuthorization? = nil,
        protections: MirrorProtectionSettings = MirrorProtectionSettings(),
        transferEngine: StageTransferEngine = .native
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
        self.transferEngine = transferEngine
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
        if authorization != nil { return try runCycle(pageSize: maxFiles) }
        var result = MirrorDeletionSummary()
        guard try journal.queueRebuildToken() == nil else {
            result.blocked=true; result.detail="Nuova verifica archivio necessaria dopo svuotamento coda"; return result
        }
        _ = try journal.retireExcludedJobs()
        guard !cancellation.isCancelled else {
            result.blocked = true
            result.detail = "Operazioni annullate"
            return result
        }
        let total = try journal.pendingDeleteCount(after: armedAt)
        guard total > 0 else { return result }
        // A rename may produce an upload for the new path and a deletion
        // for the old path. Keep the old server copy until uploads drain.
        guard try prepareUploadPriorityGate() else {
            result.blocked = true
            result.detail = "Cancellazioni sospese: copie indipendenti ancora in coda"
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
        guard !cancellation.isCancelled, operationAllowed() else { throw SeedVerificationError.cancelled }
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
            } else if protections.emptyEnabled {
                if verifyEmpty {
                    if try LocalScanner.scan(root: mapping.source,shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() }).isEmpty {
                        reason = "Sorgente completamente vuota"
                    }
                } else if counts.inventory == 0 {
                    // The persistent inventory has detected an empty source.
                    // Conservatively latch even if a concurrent scan is pending.
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
    public func runCycle(pageSize: Int = 100, throughID: Int64? = nil,
                         priorAbsenceCandidates:[QueuedChange] = []) throws -> MirrorDeletionSummary {
        guard let authorization else { return try runOnce(maxFiles: 100) }
        var result = MirrorDeletionSummary()
        guard try journal.queueRebuildToken() == nil else {
            result.blocked=true; result.detail="Nuova verifica archivio necessaria dopo svuotamento coda"; return result
        }
        _ = try journal.retireExcludedJobs()
        guard !cancellation.isCancelled,operationAllowed() else { return result }
        try verifyBeforeSynchronization()
        guard !cancellation.isCancelled else { return result }
        guard try prepareUploadPriorityGate() else {
            result.blocked = true
            result.detail = "Cancellazioni sospese: copie indipendenti ancora in coda"
            return result
        }
        guard let pendingUpper = try journal.pendingDeleteUpperBound(afterID: authorization.cutoff) else { onPlan?(0); return result }
        let upper = min(pendingUpper, throughID ?? Int64.max)
        let reconciliation=PostMirrorAbsenceReconciliation(mappings:Array(mappings.values),prior:priorAbsenceCandidates)
        postMirrorAbsence=reconciliation
        defer { postMirrorAbsence=nil }
        onPlan?(try journal.plannedDeleteCount(afterID: authorization.cutoff, throughID: upper))
        var length = Int64.max
        var lastID: Int64 = 0
        var availableRoots: Set<String> = []
        while !cancellation.isCancelled && operationAllowed() {
            try evaluateProtection(authorization: authorization, now: Date(), verifyEmpty: false)
            let page = try journal.pendingDeletePage(afterID: authorization.cutoff, throughID: upper,
                previousLength: length, previousID: lastID, limit: pageSize)
            guard let last = page.last else { break }
            length = Int64(last.relativePath.unicodeScalars.count)
            lastID = last.id
            try process(page, result: &result, availableRoots: &availableRoots)
            if result.blocked { break }
        }
        // A later successful deletion can remove the alias that prevented
        // a literal-absence check earlier in the cycle. No physical mutation
        // is performed here. Reuse the audit's live, transactional proof.
        if !result.blocked,!cancellation.isCancelled,operationAllowed() {
            let tick=ProcessInfo.processInfo.systemUptime
            do {
                try reconciliation.reconcile(journal:journal,throughID:throughID ?? upper,
                    onAcknowledged:{ job,wasDeferred in
                        result.reconciledAbsences+=1
                        if wasDeferred {
                            result.deferred=max(0,result.deferred-1)
                            result.reconciledDeferredByRoot[job.rootID,default:0]+=1
                        }
                    },shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() })
            } catch SeedVerificationError.cancelled {
                // Uncommitted candidates remain queued for the next cycle.
            } catch {
                try? log.record(level:.warning,rootID:"app",action:"queue_absence_check_deferred",
                    message:"Riconciliazione finale non conclusa: "+SyncDiagnostic.describe(error))
            }
            if result.reconciledAbsences>0 {
                try? log.record(level:.info,rootID:"app",action:"queue_absent_reconciled",
                    durationSeconds:ProcessInfo.processInfo.systemUptime-tick,
                    message:"Riconciliazione finale: \(result.reconciledAbsences); nessuna rimozione fisica")
            }
        }
        // Keep history for the longest configurable window, regardless of
        // current settings. Pending jobs remain in the original queue.
        try journal.pruneMirrorAttempts(before: Date().addingTimeInterval(-48 * 3600))
        return result
    }

    private func process(_ jobs: [QueuedChange], result: inout MirrorDeletionSummary,
                         availableRoots: inout Set<String>) throws {
        for job in jobs {
            if cancellation.isCancelled || !operationAllowed() { break }
            if try newUploadSinceGate() {
                result.blocked = true
                result.detail = "Nuove copie in coda: cancellazioni sospese"
                break
            }
            onJobStarted?(job)
            if pendingNameProtection.protects(rootID: job.rootID, path: job.relativePath) {
                result.deferred += 1
                emit(.deferred, job: job, mapping: mappings[job.rootID],
                     detail: "Rettifica nomi pendente: cancellazione sospesa")
                continue
            }
            if let authorization {
                // Recheck local counters before each action, so new events
                // cannot evade the window by arriving mid-page.
                try evaluateProtection(authorization: authorization, now: Date(), verifyEmpty: false)
            }
            guard let mapping = mappings[job.rootID],
                  let baseline = baselines[job.rootID] else {
                result.deferred += 1
                emit(.deferred,job:job,mapping:nil,detail:"Coppia non configurata")
                continue
            }
            let literalOnly = !WindowsPathSafety.validRelativePath(job.relativePath)
            // An exceptional source-monitor deletion may be a rectification.
            // No general colon permission, audit-generated colon extra or
            // recovery bypass. Candidate spelling is NOT proof of identity.
            let duplicateCandidate = RectifiedDuplicateProof.candidate(job.relativePath)
            let duplicateAllowed:Bool
            if duplicateCandidate != nil && authorization != nil && !policy.recoveryEnabled {
                duplicateAllowed = try journal.originOfJob(id:job.id) == .sourceMonitor
            } else { duplicateAllowed=false }
            if (!WindowsPathSafety.validDeletionPath(job.relativePath) && !duplicateAllowed) || (literalOnly && (authorization == nil || policy.recoveryEnabled)) {
                result.deferred += 1
                let reason = !WindowsPathSafety.validDeletionPath(job.relativePath)
                    ? "Percorso incompatibile non ammesso alla cancellazione letterale"
                    : (authorization == nil ? "Cancellazione letterale senza autorizzazione mirror" : "Cancellazione letterale incompatibile con recupero attivo")
                emit(.deferred,job:job,mapping:mapping,detail:reason)
                if try journal.noteBlockedName(job) {
                    try? log.record(level:.warning,rootID:job.rootID,action:"name_blocked",relativePath:job.relativePath,message:reason+"; coda preservata")
                }
                continue
            }
            var recordedRemoval = false
            do {
                try self.verifyRoots(mapping, baseline)
                if !availableRoots.contains(job.rootID) {
                    let absenceSnapshot=try journal.lineageAbsenceSnapshot(rootID:job.rootID)
                    let currentInventory = try LocalScanner.scan(root: mapping.source,shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() })
                    if authorization != nil && protections.emptyEnabled && currentInventory.isEmpty {
                        let reason = job.rootID + ": Sorgente completamente vuota"
                        try journal.latchMirrorBlock(reason)
                        throw MirrorDeletionFailure.bulkDeletion(reason)
                    }
                    try journal.resolveLineageMissing(rootID:job.rootID,rows:currentInventory,snapshot:absenceSnapshot,
                        shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() })
                    availableRoots.insert(job.rootID)
                }
                guard try journal.deletionIsCurrent(
                    id: job.id, rootID: job.rootID, relativePath: job.relativePath
                ) else { throw MirrorDeletionFailure.pendingTransfer }

                guard WindowsPathSafety.validDeletionPath(job.relativePath) || duplicateAllowed else { throw MirrorDeletionFailure.unsafePath }
                // Fresh SQLite protection check immediately before any mirror
                // mutation. It cannot be bypassed by stale plan snapshots.
                guard try !NameRectification.pendingProtection(journal: journal)
                    .protects(rootID: job.rootID, path: job.relativePath) else {
                    result.deferred += 1
                    emit(.deferred, job: job, mapping: mapping,
                         detail: "Rettifica nomi pendente: cancellazione sospesa")
                    continue
                }
                if duplicateAllowed,let candidate=duplicateCandidate,let authorization {
                    // The normal literal branch remains available for an
                    // ordinary trailing-space deletion with no corrected
                    // local alias. Colons always require exceptional proof.
                    let localCandidate=mapping.source.appendingPathComponent(candidate.correctedPath)
                    let correctedExists = try Self.statIfPresent(localCandidate) != nil
                    if job.relativePath.contains(":") || correctedExists {
                        guard try journal.pendingUploads(limit:1).isEmpty else { throw MirrorDeletionFailure.pendingTransfer }
                        let proof=try RectifiedDuplicateProof.prepare(candidate,mapping:mapping,
                            shouldContinue:{!self.cancellation.isCancelled && self.operationAllowed()})
                        try verifyRoots(mapping,baseline)
                        try evaluateProtection(authorization:authorization,now:Date(),verifyEmpty:false)
                        guard try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath),
                              try journal.pendingUploads(limit:1).isEmpty,
                              try !NameRectification.pendingProtection(journal:journal).protects(rootID:job.rootID,path:job.relativePath)
                        else { throw MirrorDeletionFailure.pendingTransfer }
                        try journal.recordMirrorAttempt(job)
                        guard !cancellation.isCancelled,operationAllowed() else { break }
                        try proof.remove(mapping:mapping,shouldContinue:{
                            !self.cancellation.isCancelled && self.operationAllowed() &&
                            ((try? self.journal.pendingUploads(limit:1).isEmpty) == true) &&
                            ((try? self.journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath)) == true)
                        })
                        try verifyRoots(mapping,baseline)
                        recordedRemoval=true
                        if proof.old.directory {
                            result.directories+=1;emit(.directoryRemoved,job:job,mapping:mapping,detail:"Vecchio percorso rettificato verificato")
                        } else {
                            result.removed+=1;emit(.deleted,job:job,mapping:mapping,bytes:Int64(proof.old.info.st_size),detail:"Duplicato rettificato verificato per contenuto")
                        }
                        try? log.record(level:.success,rootID:job.rootID,action:"mirror_rectified_duplicate",relativePath:job.relativePath,message:"Vecchio oggetto identificato; copia rettificata verificata")
                        appliedDuringSession+=1
                        _ = try journal.acknowledgeDeletion(id:job.id,rootID:job.rootID,relativePath:job.relativePath)
                        continue
                    }
                }
                let source:URL
                let destination:URL
                if literalOnly {
                    try WindowsPathSafety.confirmLiteralAbsence(job.relativePath,under:mapping.source)
                    source=mapping.source.appendingPathComponent(job.relativePath)
                    destination=try mapping.verificationURL(relativePath:job.relativePath,destination:true)
                } else {
                    try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.source)
                    try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.target)
                    source=try validatedPath(job.relativePath,under:mapping.source,allowMissingParents:true)
                    destination=try validatedPath(job.relativePath,under:mapping.target)
                }
                // Source leaf must still be absent, including dangling symlinks.
                guard try Self.statIfPresent(source) == nil else {
                    throw MirrorDeletionFailure.sourceChanged
                }
                guard let target = try Self.statIfPresent(destination) else {
                    // A hidden/vanished incompatible name is not proof of
                    // removal from SMB. Keep it pending for manual review.
                    if literalOnly { throw MirrorDeletionFailure.destinationChanged }
                    if try journal.acknowledgeDeletion(
                        id: job.id, rootID: job.rootID, relativePath: job.relativePath
                    ) {
                        result.missing += 1
                        appliedDuringSession += 1
                    }
                    emit(.missing,job:job,mapping:mapping)
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
                if cancellation.isCancelled || !operationAllowed() { break }
                if let authorization {
                    try evaluateProtection(authorization: authorization, now: Date(), verifyEmpty: false)
                    try journal.recordMirrorAttempt(job)
                    // The reservation is durable before touching the share.
                    if cancellation.isCancelled || !operationAllowed() { break }
                    guard try journal.pendingUploads(limit: 1).isEmpty,
                          try journal.deletionIsCurrent(id: job.id, rootID: job.rootID, relativePath: job.relativePath)
                    else { throw MirrorDeletionFailure.pendingTransfer }
                }
                if Self.isRegularFile(target) {
                    // Never execute destructive operations on symlinks or
                    // directories with content.
                    if policy.recoveryEnabled {
                        let recovered = try moveToRecovery(destination, job: job, mapping: mapping,
                            baseline: baseline, source: source, original: target)
                        result.recovered += 1
                        recordedRemoval = true
                        emit(.recovered,job:job,mapping:mapping,bytes:Int64(target.st_size),recoveryPath:recovered)
                        try? log.record(level: .success, rootID: job.rootID,
                                        action: "mirror_recovered",
                                        relativePath: job.relativePath,
                                        message: "Spostato in cartella recupero")
                    } else {
                        // No recovery was explicitly chosen. There is NO
                        // automatic way to restore this file in MacSync.
                        let parent = try AnchoredDirectory(destination.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
                        try verifyRoots(mapping,baseline)
                        guard try Self.statIfPresent(source) == nil else { throw MirrorDeletionFailure.sourceChanged }
                        if literalOnly {
                            try removeLiteral(destination,original:target,mapping:mapping,baseline:baseline,job:job,directory:false)
                        } else if transferEngine.isDirect {
                            try removeUsingRclone(destination,original:target,mapping:mapping,baseline:baseline,source:source,job:job,directory:false)
                        } else {
                            try parent.remove(destination.lastPathComponent,matching:target,shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() })
                        }
                        result.removed += 1
                        recordedRemoval = true
                        emit(.deleted,job:job,mapping:mapping,bytes:Int64(target.st_size))
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
                    let parent = try AnchoredDirectory(destination.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
                    try verifyRoots(mapping,baseline)
                    guard try Self.statIfPresent(source) == nil else { throw MirrorDeletionFailure.sourceChanged }
                    if literalOnly {
                        try removeLiteral(destination,original:target,mapping:mapping,baseline:baseline,job:job,directory:true)
                    } else if transferEngine.isDirect {
                        try removeUsingRclone(destination,original:target,mapping:mapping,baseline:baseline,source:source,job:job,directory:true)
                    } else {
                        try parent.remove(destination.lastPathComponent,matching:target,directory:true,shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() })
                    }
                    result.directories += 1
                    recordedRemoval = true
                    emit(.directoryRemoved,job:job,mapping:mapping)
                } else {
                    throw MirrorDeletionFailure.unsupportedObject
                }
                appliedDuringSession += 1
                _ = try journal.acknowledgeDeletion(
                    id: job.id, rootID: job.rootID, relativePath: job.relativePath
                )
            } catch {
                if let reason = try journal.mirrorBlockReason(), authorization != nil {
                    throw MirrorDeletionFailure.bulkDeletion(reason)
                }
                result.deferred += 1
                let detail = (error as? MirrorDeletionFailure)?.localizedDescription ?? SyncDiagnostic.describe(error)
                if !recordedRemoval { emit(.deferred,job:job,mapping:mapping,detail:detail) }
                try? log.record(
                    level: .warning, rootID: job.rootID, action: "mirror_deferred",
                    relativePath: job.relativePath,
                    message: "Operazione non eseguita o non completata: "
                        + detail
                )
            }
        }
    }

    /// Automatic expiry only for manifest-owned, unchanged recovery files.
    /// A retention setting of "never" writes NULL expires_at and never purges.
    /// This cleanup cannot remove ordinary destination photos or backups.
    @discardableResult
    public func pruneExpiredRecovery(now: Date = Date()) throws -> Int {
        guard policy.enabled, !cancellation.isCancelled, operationAllowed() else { return 0 }
        if authorization != nil { try verifyBeforeSynchronization() }
        guard try journal.pendingUploads(limit: 1).isEmpty else { return 0 }
        var removed = 0
        for item in try manifest.expired(before: now) {
            if cancellation.isCancelled || !operationAllowed() { break }
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
                if cancellation.isCancelled || !operationAllowed() { break }
                let parent = try AnchoredDirectory(safe.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
                try verifyRoots(mapping,baseline)
                try parent.remove(safe.lastPathComponent,matching:current,shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() })
                try manifest.forget(id: item.id)
                removed += 1
                let job = QueuedChange(id:0,rootID:item.rootID,relativePath:item.managedRelativePath,kind:.delete,recordedAt:now)
                emit(.recoveryExpired,job:job,mapping:mapping,bytes:item.size)
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

    /// Exceptional mounted-path removal: avoid Rclone's name encoding,
    /// use a pinned parent descriptor and exact leaf identity. No fallback
    /// to other spellings or recursive removal if the mount rejects unlink.
    private func removeLiteral(_ destination:URL,original:stat,mapping:MountedFolderMapping,
                               baseline:MirrorRootIdentity,job:QueuedChange,directory:Bool) throws {
        try verifyRoots(mapping,baseline)
        try WindowsPathSafety.confirmLiteralAbsence(job.relativePath,under:mapping.source)
        let exact=try mapping.verificationURL(relativePath:job.relativePath,destination:true)
        guard exact.path.utf8.elementsEqual(destination.path.utf8),
              try journal.pendingUploads(limit:1).isEmpty,
              try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath)
        else { throw MirrorDeletionFailure.pendingTransfer }
        let parent=try AnchoredDirectory(exact.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
        let leaf=exact.lastPathComponent
        let aliases=try parent.listedNames().filter { WindowsPathSafety.comparisonFold($0)==WindowsPathSafety.comparisonFold(leaf) }
        guard aliases.count==1,aliases[0].utf8.elementsEqual(leaf.utf8) else { throw MirrorDeletionFailure.destinationChanged }
        try parent.remove(leaf,matching:original,directory:directory,
            shouldContinue:{!self.cancellation.isCancelled && self.operationAllowed()})
        try verifyRoots(mapping,baseline)
        try WindowsPathSafety.confirmLiteralAbsence(job.relativePath,under:mapping.target)
    }

    private func removeUsingRclone(_ destination: URL, original: stat, mapping: MountedFolderMapping,
                                    baseline: MirrorRootIdentity, source: URL, job: QueuedChange, directory: Bool) throws {
        try verifyRoots(mapping,baseline)
        guard try journal.pendingUploads(limit:1).isEmpty,
              try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath),
              try Self.statIfPresent(source)==nil,
              let latest=try Self.statIfPresent(destination),
              latest.st_dev==original.st_dev,latest.st_ino==original.st_ino,latest.st_mode==original.st_mode,
              latest.st_size==original.st_size,
              latest.st_mtimespec.tv_sec==original.st_mtimespec.tv_sec,latest.st_mtimespec.tv_nsec==original.st_mtimespec.tv_nsec,
              latest.st_ctimespec.tv_sec==original.st_ctimespec.tv_sec,latest.st_ctimespec.tv_nsec==original.st_ctimespec.tv_nsec
        else { throw MirrorDeletionFailure.destinationChanged }
        try? log.record(level:.info,rootID:job.rootID,action:"rclone_delete_start",relativePath:job.relativePath,message:directory ? "Rclone rmdir" : "Rclone deletefile")
        try transferEngine.pathOperation(directory ? "rmdir" : "deletefile",url:destination,shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() },diagnostic:{ level,message in
            try? self.log.record(level:level,rootID:job.rootID,action:"rclone_diagnostic",relativePath:job.relativePath,message:message)
        })
        try verifyRoots(mapping,baseline)
        guard try Self.statIfPresent(destination)==nil else { throw MirrorDeletionFailure.destinationChanged }
    }

    private func moveToRecovery(
        _ destination: URL, job: QueuedChange, mapping: MountedFolderMapping,
        baseline: MirrorRootIdentity, source: URL, original: stat
    ) throws -> String {
        let uuid = UUID().uuidString
        // Store original relative path inside a unique UUID namespace.
        // Hidden folder is inside target, always on the SAME mounted volume.
        let managed = ".macsync-recovery/" + uuid + "/" + job.relativePath
        let recovered = try validatedRecovery(managed, mapping: mapping, createParents: true)
        guard try Self.statIfPresent(recovered) == nil else {
            throw MirrorDeletionFailure.destinationChanged
        }
        try verifyRoots(mapping, baseline)
        guard !cancellation.isCancelled, operationAllowed(),
              try journal.pendingUploads(limit: 1).isEmpty,
              try journal.deletionIsCurrent(id: job.id, rootID: job.rootID, relativePath: job.relativePath),
              try Self.statIfPresent(source) == nil,
              let latest = try Self.statIfPresent(destination),
              latest.st_dev == original.st_dev, latest.st_ino == original.st_ino,
              latest.st_mode == original.st_mode, latest.st_size == original.st_size,
              latest.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              latest.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              latest.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              latest.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
        else { throw MirrorDeletionFailure.destinationChanged }
        let oldParent = try AnchoredDirectory(destination.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
        let newParent = try AnchoredDirectory(recovered.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
        // Persist the recovery record before moving; missing reserved paths are harmless.
        try manifest.record(
            id: uuid, rootID: job.rootID, targetRoot: mapping.target.path,
            managedPath: managed,
            size: Int64(original.st_size), inode: UInt64(original.st_ino),
            mtime: Self.modificationTime(original),
            retentionDays: policy.retentionDays
        )
        try verifyRoots(mapping,baseline)
        guard try Self.statIfPresent(source) == nil,
              try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath),
              try journal.pendingUploads(limit:1).isEmpty else { throw MirrorDeletionFailure.pendingTransfer }
        try oldParent.publish(destination.lastPathComponent,matching:original,to:newParent,as:recovered.lastPathComponent,replacing:nil,
            shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() })
        guard let after = try Self.statIfPresent(recovered), Self.isRegularFile(after),
              after.st_ino == original.st_ino, after.st_size == original.st_size else { throw MirrorDeletionFailure.destinationChanged }
        return recovered.path
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
        return try validatedPath(path, under: mapping.target, createParents: createParents, recovery: true, expectedVolume:mapping.targetVolume)
    }

    private func validatedPath(
        _ relative: String, under root: URL, createParents: Bool = false,
        recovery: Bool = false, allowMissingParents: Bool = false, expectedVolume: VolumeFingerprint? = nil
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
                guard let expectedVolume else { throw MirrorDeletionFailure.unsafePath }
                let parent = try AnchoredDirectory(current.deletingLastPathComponent(),expectedVolume:expectedVolume)
                try parent.ensureDirectory(current.lastPathComponent,managed:recovery,shouldContinue:{ !self.cancellation.isCancelled && self.operationAllowed() })
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
