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

private struct MirrorRootIdentity {
    let device: UInt64
    let inode: UInt64
    let volume: VolumeFingerprint
    let baselineCount: Int
}

private struct RecoveredRecord {
    let id: String
    let rootID: String
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
                    managed_path TEXT NOT NULL,
                    stored_at REAL NOT NULL,
                    expires_at REAL,
                    file_size INTEGER NOT NULL,
                    inode INTEGER NOT NULL,
                    modified_at REAL NOT NULL
                );
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_mirror_recovery_expiry ON mirror_recovery(expires_at);")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func record(
        id: String, rootID: String, managedPath: String,
        size: Int64, inode: UInt64, mtime: Double,
        retentionDays: Int?
    ) throws {
        guard !id.isEmpty, !rootID.isEmpty, !managedPath.isEmpty,
              !managedPath.hasPrefix("/"), size >= 0,
              retentionDays == nil || (1...30).contains(retentionDays!) else {
            throw JournalError.database("Invalid recovery record")
        }
        let statement = try prepare("""
            INSERT INTO mirror_recovery
            (id,root_id,managed_path,stored_at,expires_at,file_size,inode,modified_at)
            VALUES(?,?,?,?,?,?,?,?);
            """)
        defer { sqlite3_finalize(statement) }
        try bind(id, 1, statement)
        try bind(rootID, 2, statement)
        try bind(managedPath, 3, statement)
        let at = Date().timeIntervalSince1970
        guard sqlite3_bind_double(statement, 4, at) == SQLITE_OK else { throw failure() }
        if let retentionDays {
            guard sqlite3_bind_double(statement, 5, at + Double(retentionDays) * 86_400) == SQLITE_OK else {
                throw failure()
            }
        } else {
            guard sqlite3_bind_null(statement, 5) == SQLITE_OK else { throw failure() }
        }
        guard inode <= UInt64(Int64.max), sqlite3_bind_int64(statement, 6, size) == SQLITE_OK,
              sqlite3_bind_int64(statement, 7, Int64(inode)) == SQLITE_OK,
              sqlite3_bind_double(statement, 8, mtime) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    fileprivate func expired(before: Date, limit: Int = 200) throws -> [RecoveredRecord] {
        let statement = try prepare("""
            SELECT id,root_id,managed_path,file_size,inode,modified_at
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
            let inodeValue = sqlite3_column_int64(statement, 4)
            guard inodeValue >= 0 else { continue }
            items.append(RecoveredRecord(
                id: column(statement, 0),
                rootID: column(statement, 1),
                managedRelativePath: column(statement, 2),
                size: sqlite3_column_int64(statement, 3),
                inode: UInt64(inodeValue),
                mtime: sqlite3_column_double(statement, 5)
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

    public init(
        journal: ChangeJournal, manifest: RecoveryManifest, log: SyncActivityLog,
        mappings: [MountedFolderMapping], policy: MirrorDeletionPolicy,
        cancellation: MirrorDeletionCancellation = MirrorDeletionCancellation()
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
        self.mappings = Dictionary(uniqueKeysWithValues: mappings.map { ($0.rootID, $0) })

        var captured: [String: MirrorRootIdentity] = [:]
        for mapping in mappings {
            try mapping.verify()
            let inventory = try LocalScanner.scan(root: mapping.source)
            // Never enable a mirror against a source that appears empty.
            guard !inventory.isEmpty else { throw MirrorDeletionFailure.noBaseline }
            let rootStamp = try Self.statFile(mapping.source)
            guard Self.isDirectory(rootStamp) else { throw MirrorDeletionFailure.noBaseline }
            captured[mapping.rootID] = MirrorRootIdentity(
                device: UInt64(rootStamp.st_dev), inode: UInt64(rootStamp.st_ino),
                volume: try VolumeFingerprint.read(at: mapping.source),
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
        // Check mass-delete thresholds for ALL candidate jobs, not only the
        // batch size, to prevent evading the gate by paging.
        let baselineCount = baselines.values.reduce(0) { $0 + $1.baselineCount }
        let decision = DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: true,
            trackedFileCount: baselineCount, pendingDeleteCount: total
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
        // One complete LOCAL check per affected source, never one scan per
        // job and NEVER a recursive scan of the SMB destination.
        var availableRoots: Set<String> = []
        for job in sorted.prefix(max(1, min(100, maxFiles))) {
            if cancellation.isCancelled { break }
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

                let source = try validatedPath(job.relativePath, under: mapping.source)
                let destination = try validatedPath(job.relativePath, under: mapping.target)
                // Source leaf must still be absent, including dangling symlinks.
                guard try Self.statIfPresent(source) == nil else {
                    throw MirrorDeletionFailure.sourceChanged
                }
                guard let target = try Self.statIfPresent(destination) else {
                    if try journal.acknowledgeDeletion(
                        id: job.id, rootID: job.rootID, relativePath: job.relativePath
                    ) { result.missing += 1 }
                    continue
                }
                try verifyRoots(mapping, baseline)
                guard try journal.deletionIsCurrent(
                    id: job.id, rootID: job.rootID, relativePath: job.relativePath
                ) else { throw MirrorDeletionFailure.pendingTransfer }
                if cancellation.isCancelled { break }
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
                        try FileManager.default.removeItem(at: destination)
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
                    try FileManager.default.removeItem(at: destination)
                    result.directories += 1
                } else {
                    throw MirrorDeletionFailure.unsupportedObject
                }
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
        return result
    }

    /// Automatic expiry only for manifest-owned, unchanged recovery files.
    /// A retention setting of "never" writes NULL expires_at and never purges.
    /// This cleanup cannot remove ordinary destination photos or backups.
    @discardableResult
    public func pruneExpiredRecovery(now: Date = Date()) throws -> Int {
        guard policy.enabled, policy.recoveryEnabled, policy.retentionDays != nil,
              !cancellation.isCancelled else { return 0 }
        var removed = 0
        for item in try manifest.expired(before: now) {
            if cancellation.isCancelled { break }
            guard let mapping = mappings[item.rootID], let baseline = baselines[item.rootID] else { continue }
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
                try FileManager.default.removeItem(at: safe)
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
            id: uuid, rootID: job.rootID, managedPath: managed,
            size: Int64(after.st_size), inode: UInt64(after.st_ino),
            mtime: Self.modificationTime(after),
            retentionDays: policy.retentionDays
        )
    }

    private func verifyRoots(_ mapping: MountedFolderMapping, _ baseline: MirrorRootIdentity) throws {
        try mapping.verify()
        let source = try Self.statFile(mapping.source)
        guard Self.isDirectory(source),
              UInt64(source.st_dev) == baseline.device,
              UInt64(source.st_ino) == baseline.inode,
              try VolumeFingerprint.read(at: mapping.source) == baseline.volume
        else { throw MirrorDeletionFailure.sourceChanged }
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
        recovery: Bool = false
    ) throws -> URL {
        let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0") }),
              recovery || segments.allSatisfy({
                  !$0.hasPrefix(".macsync-staging") &&
                  !$0.hasPrefix(".macsync-recovery") &&
                  !$0.hasPrefix(".macsync-backup-")
              }) else { throw MirrorDeletionFailure.unsafePath }
        let url = root.appendingPathComponent(relative)
        var current = root
        for segment in segments.dropLast() {
            current.appendPathComponent(String(segment))
            if let state = try Self.statIfPresent(current) {
                guard Self.isDirectory(state) else { throw MirrorDeletionFailure.unsafePath }
            } else if createParents {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
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
