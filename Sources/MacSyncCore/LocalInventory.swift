import Foundation
import SQLite3
import Darwin

public struct PendingQueueBreakdown: Equatable, Sendable {
    public var files = 0
    public var directories = 0
    public var deletions = 0
    public var other = 0
    public var total:Int { files+directories+deletions+other }
    public init() {}
}

/// Finder metadata is excluded by default, without generating mirror deletes.
public enum FileExclusionPolicy {
    public static let preferenceKey = "MacSync.ignoreDSStore.v1"
    public static var ignoreDSStore: Bool {
        (UserDefaults.standard.object(forKey:preferenceKey) as? Bool) ?? true
    }
    public static func excludes(_ relativePath:String, enabled:Bool) -> Bool {
        enabled && relativePath.split(separator:"/").contains(".DS_Store")
    }
}

public struct TrackedItem: Equatable, Sendable {
    public let relativePath: String
    public let kind: String
    public let size: Int64
    public let modifiedAt: Double
    public let changeStamp: String?
    /// Exact no-follow stat acquired during this scan, never a durable proof.
    /// Used only to avoid duplicating SMB calls in a quick archive audit;
    /// queue acknowledgements still require a live revalidation.
    public let verificationFingerprint: SeedFileFingerprint?

    public init(relativePath: String, kind: String, size: Int64, modifiedAt: Double, changeStamp: String? = nil,
                verificationFingerprint: SeedFileFingerprint? = nil) {
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.changeStamp = changeStamp
        self.verificationFingerprint = verificationFingerprint
    }

    /// Preserve the persisted inventory comparison semantics. The live
    /// fingerprint is an ephemeral audit snapshot, not a change-detection
    /// field: SQLite does not persist it and a second ordinary scan must
    /// not enqueue unchanged files or directories.
    public static func == (lhs: TrackedItem, rhs: TrackedItem) -> Bool {
        lhs.relativePath == rhs.relativePath &&
        lhs.kind == rhs.kind &&
        lhs.size == rhs.size &&
        lhs.modifiedAt == rhs.modifiedAt &&
        lhs.changeStamp == rhs.changeStamp
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
    private struct RootStamp: Equatable {
        let device: Int64
        let inode: UInt64
    }

    private static func stamp(_ root: URL) throws -> RootStamp {
        var info = stat()
        guard root.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw JournalError.database("Source root is unavailable or not a directory")
        }
        return RootStamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Validate the root identity again before accepting an enumeration.
    /// A vanished or replaced root must never be interpreted as empty.
    public static func scan(root: URL, subtree: URL? = nil,
                            excludeManaged: Bool = false,
                            ignoreDSStore: Bool = FileExclusionPolicy.ignoreDSStore,
                            preferPOSIXMetadata: Bool = false,
                            shouldContinue: () -> Bool = { true },
                            onVisit: (String) -> Void = { _ in },
                            onItem: (TrackedItem) -> Void = { _ in }) throws -> [TrackedItem] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = (subtree ?? root).standardizedFileURL.resolvingSymlinksInPath()
        guard root.isFileURL, target.isFileURL,
              target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw JournalError.database("Scan path is outside the source root")
        }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw JournalError.database("Source root is not a regular accessible directory")
        }

        let original = try stamp(root)
        func assertRootUnchanged() throws {
            guard try stamp(root) == original else {
                throw JournalError.database("Source root changed during scan")
            }
        }

        if target != root && FileExclusionPolicy.excludes(String(target.path.dropFirst(root.path.count+1)),enabled:ignoreDSStore) {
            try assertRootUnchanged(); return []
        }

        // Only ENOENT is a missing subtree. Access-denied or I/O failures
        // cannot create deletion jobs, and a missing root is never empty.
        var targetStat = stat()
        if target.path.withCString({ lstat($0, &targetStat) }) != 0 {
            let code = errno
            guard code == ENOENT, target.path != root.path else {
                throw JournalError.database("Source scan path inaccessible (filesystem code \(code))")
            }
            try assertRootUnchanged()
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        var found: [TrackedItem] = []

        func record(_ file: URL) throws -> String {
            let kind: String
            let size: Int64
            let modified: Double
            var changeStamp: String?
            var verificationFingerprint: SeedFileFingerprint?
            if preferPOSIXMetadata {
                // Remote read-only inventory: gather type, size, timestamps
                // and identity in ONE no-follow syscall instead of retrieving
                // URL resource metadata and then stat'ing the same file again.
                var actual = stat()
                guard file.path.withCString({ lstat($0,&actual) }) == 0 else {
                    throw JournalError.database("Source scan path inaccessible (filesystem code \(errno))")
                }
                switch actual.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFLNK): kind = "symlink"
                case mode_t(S_IFDIR): kind = "directory"
                case mode_t(S_IFREG): kind = "file"
                default: throw JournalError.database("Unsupported filesystem object: " + file.path)
                }
                size = Int64(actual.st_size)
                modified = Double(actual.st_mtimespec.tv_sec) + Double(actual.st_mtimespec.tv_nsec)/1_000_000_000
                if kind == "file" || kind == "directory" {
                    verificationFingerprint = SeedFileFingerprint(fileStat: actual)
                }
                if kind == "file" {
                    changeStamp = "\(actual.st_ino):\(actual.st_ctimespec.tv_sec):\(actual.st_ctimespec.tv_nsec)"
                }
            } else {
                // Local monitoring retains the original dual metadata check.
                let metadata = try file.resourceValues(forKeys: keys)
                if metadata.isSymbolicLink == true { kind = "symlink" }
                else if metadata.isDirectory == true { kind = "directory" }
                else if metadata.isRegularFile == true { kind = "file" }
                else { throw JournalError.database("Unsupported filesystem object: " + file.path) }
                if kind == "file" && (metadata.fileSize == nil || metadata.contentModificationDate == nil) {
                    throw JournalError.database("Metadati non disponibili durante la verifica completa")
                }
                size = Int64(metadata.fileSize ?? 0)
                modified = metadata.contentModificationDate?.timeIntervalSince1970 ?? 0
                if kind == "file" {
                    var actual = stat()
                    guard file.path.withCString({ lstat($0,&actual) }) == 0,
                          actual.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                          Int64(actual.st_size) == size else {
                        throw JournalError.database("File changed during inventory scan")
                    }
                    changeStamp = "\(actual.st_ino):\(actual.st_ctimespec.tv_sec):\(actual.st_ctimespec.tv_nsec)"
                    verificationFingerprint = SeedFileFingerprint(fileStat: actual)
                } else if kind == "directory" {
                    // This additional stat is local, not SMB. It avoids remote
                    // directory re-reads when the audit later recognizes it.
                    var actual = stat()
                    guard file.path.withCString({ lstat($0,&actual) }) == 0,
                          actual.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                        throw JournalError.database("Directory changed during inventory scan")
                    }
                    verificationFingerprint = SeedFileFingerprint(fileStat: actual)
                }
            }
            let prefix = root.path + "/"
            // macOS can surface the same path via /var and /private/var.
            // Resolve parent aliases, but do not dereference a symlink leaf.
            let effectivePath: String
            if file.path.hasPrefix(prefix) {
                effectivePath = file.path
            } else {
                effectivePath = file.deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .appendingPathComponent(file.lastPathComponent).path
            }
            guard effectivePath.hasPrefix(prefix) else {
                throw JournalError.database("Unexpected path outside root")
            }
            let relative = String(effectivePath.dropFirst(prefix.count))
            let item = TrackedItem(
                relativePath: relative, kind: kind, size: size,
                modifiedAt: modified, changeStamp: changeStamp,
                verificationFingerprint: verificationFingerprint
            )
            found.append(item)
            onItem(item)
            return kind
        }

        func visit(_ url:URL) {
            let prefix = root.path + "/"
            onVisit(url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : "[radice]")
        }
        if target != root {
            visit(target)
            let kind = try record(target)
            if kind != "directory" {
                try assertRootUnchanged()
                return found
            }
        }

        var enumerationError: Error?
        var enumerationErrorURL: URL?
        let enumerator = FileManager.default.enumerator(
            at: target, includingPropertiesForKeys: preferPOSIXMetadata ? [] : Array(keys), options: [],
            errorHandler: { url, error in
                // Keep the escaping Foundation handler independent of the
                // synchronous onVisit callback. Publish its path before throwing.
                enumerationErrorURL = url
                enumerationError = error
                return false
            }
        )
        guard let enumerator else {
            if let url = enumerationErrorURL { visit(url) }
            if let enumerationError { throw enumerationError }
            throw JournalError.database("Cannot enumerate source directory")
        }
        while enumerationError == nil && shouldContinue() {
            guard let file = enumerator.nextObject() as? URL else { break }
            visit(file)
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            if (excludeManaged && file.lastPathComponent.lowercased().hasPrefix(".macsync-")) ||
                FileExclusionPolicy.excludes(file.lastPathComponent,enabled:ignoreDSStore) {
                if try file.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey]).isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            do {
                let kind = try record(file)
                // DirectoryEnumerator already treats ordinary files as
                // leaves. Calling skipDescendants() after a REGULAR FILE can
                // inadvertently suppress the next nested directory on macOS.
                // Only skip symlink descendants, which must never be followed.
                if kind == "symlink" { enumerator.skipDescendants() }
            } catch {
                enumerationError = error
                break
            }
        }
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        if let enumerationError {
            if let url = enumerationErrorURL { visit(url) }
            throw enumerationError
        }
        try assertRootUnchanged()
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
                    completed INTEGER NOT NULL DEFAULT 0,
                    origin TEXT NOT NULL DEFAULT 'legacy_unknown'
                );
                """)
            // LocalInventory can be opened before ChangeJournal on startup,
            // so it must support the same additive, fail-closed migration.
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let queueCols = try prepare("PRAGMA table_info(change_queue);")
                var hasOrigin = false
                var queueStep = sqlite3_step(queueCols)
                while queueStep == SQLITE_ROW {
                    if column(queueCols,1) == "origin" { hasOrigin = true }
                    queueStep = sqlite3_step(queueCols)
                }
                sqlite3_finalize(queueCols)
                guard queueStep == SQLITE_DONE else { throw failure() }
                if !hasOrigin {
                    try execute("ALTER TABLE change_queue ADD COLUMN origin TEXT NOT NULL DEFAULT 'legacy_unknown';")
                }
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
            try execute("CREATE TABLE IF NOT EXISTS directory_bindings(root_id TEXT NOT NULL, role TEXT NOT NULL, stamp TEXT NOT NULL, PRIMARY KEY(root_id,role));")
            // Compatible migration: old rows learn the new stamp on their next scan.
            let columns = try prepare("PRAGMA table_info(file_inventory);")
            var hasStamp = false
            var infoResult = sqlite3_step(columns)
            while infoResult == SQLITE_ROW {
                if column(columns,1) == "change_stamp" { hasStamp = true }
                infoResult = sqlite3_step(columns)
            }
            sqlite3_finalize(columns)
            guard infoResult == SQLITE_DONE else { throw failure() }
            if !hasStamp { try execute("ALTER TABLE file_inventory ADD COLUMN change_stamp TEXT;") }
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


    /// Reconfigure a source deliberately without turning its old inventory
    /// into DELETE jobs. This is a LOCAL operation; it never accesses targets.
    /// Call only after the user confirms a change in the source folder.
    public func resetRootForNewSource(rootID: String, newRoot: URL) throws {
        let newPath = newRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard !rootID.isEmpty, FileManager.default.fileExists(atPath: newPath) else {
            throw JournalError.database("Source directory unavailable")
        }
        let attributes = try URL(fileURLWithPath: newPath)
            .resourceValues(forKeys: [.isDirectoryKey])
        guard attributes.isDirectory == true else {
            throw JournalError.database("Source must be a directory")
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for table in ["change_queue", "file_inventory", "watched_roots", "directory_bindings"] {
                let statement = try prepare("DELETE FROM " + table + " WHERE root_id = ?;")
                defer { sqlite3_finalize(statement) }
                try bind(rootID, at: 1, statement: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// A new destination needs a fresh copy of every known local file.
    /// Never generate DELETE jobs when only the target was reconfigured.
    /// This can be lengthy on a very large inventory and should run off-main.
    public func requeueAllForNewDestination(rootID: String) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let delete = try prepare("""
                DELETE FROM change_queue WHERE root_id=? AND completed=0;
                """)
            defer { sqlite3_finalize(delete) }
            try bind(rootID, at: 1, statement: delete)
            guard sqlite3_step(delete) == SQLITE_DONE else { throw failure() }

            let insert = try prepare("""
                INSERT INTO change_queue(root_id,relative_path,kind,recorded_at,completed,origin)
                SELECT root_id,relative_path,'upsert',?,0,'destination_rebind' FROM file_inventory
                WHERE root_id=? AND kind IN ('file','directory');
                """)
            defer { sqlite3_finalize(insert) }
            guard sqlite3_bind_double(insert, 1, Date().timeIntervalSince1970) == SQLITE_OK else {
                throw failure()
            }
            try bind(rootID, at: 2, statement: insert)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Retire only local inventory/unfinished jobs for explicitly removed
    /// configuration roots. Never touches archive files or activity history.
    public func retireInactiveRoots(keeping ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let query = try prepare("SELECT root_id FROM watched_roots UNION SELECT root_id FROM file_inventory UNION SELECT root_id FROM change_queue WHERE completed=0;")
            defer { sqlite3_finalize(query) }
            var old: [String] = []
            var code = sqlite3_step(query)
            while code == SQLITE_ROW {
                if let ptr = sqlite3_column_text(query,0) {
                    let id = String(cString:ptr)
                    if !ids.contains(id) { old.append(id) }
                }
                code = sqlite3_step(query)
            }
            guard code == SQLITE_DONE else { throw failure() }
            for id in old {
                for sql in ["DELETE FROM change_queue WHERE root_id=? AND completed=0;", "DELETE FROM file_inventory WHERE root_id=?;", "DELETE FROM watched_roots WHERE root_id=?;", "DELETE FROM directory_bindings WHERE root_id=?;"] {
                    let stmt = try prepare(sql)
                    defer { sqlite3_finalize(stmt) }
                    try bind(id,at:1,statement:stmt)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func pendingBreakdown() throws -> PendingQueueBreakdown {
        let stmt = try prepare("""
            SELECT
              COALESCE(SUM(CASE WHEN q.kind='upsert' AND f.kind='file' THEN 1 ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN q.kind='upsert' AND f.kind='directory' THEN 1 ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN q.kind='delete' THEN 1 ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN q.kind='upsert' AND (f.kind IS NULL OR f.kind NOT IN ('file','directory')) THEN 1 ELSE 0 END),0)
            FROM change_queue q LEFT JOIN file_inventory f ON f.root_id=q.root_id AND f.relative_path=q.relative_path
            WHERE q.completed=0;
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        var result=PendingQueueBreakdown()
        result.files=Int(sqlite3_column_int64(stmt,0))
        result.directories=Int(sqlite3_column_int64(stmt,1))
        result.deletions=Int(sqlite3_column_int64(stmt,2))
        result.other=Int(sqlite3_column_int64(stmt,3))
        return result
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
        eventID: UInt64? = nil,
        origin: QueuedChangeOrigin = .sourceMonitor,
        shouldContinue: () -> Bool = { true },
        onItem: (TrackedItem) -> Void = { _ in }
    ) throws -> ReconciliationResult {
        guard !rootID.isEmpty else { throw JournalError.database("Missing root identifier") }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = (subtree ?? root).standardizedFileURL.resolvingSymlinksInPath()
        let binding = try DirectoryBinding.encoded(root)
        let ignoreDSStore = FileExclusionPolicy.ignoreDSStore
        let rows = try LocalScanner.scan(root: root, subtree: subtree, ignoreDSStore:ignoreDSStore, shouldContinue: shouldContinue, onItem: onItem)
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        let fullScan = target.path == root.path
        let scope = fullScan ? "" : String(target.path.dropFirst(root.path.count + 1))

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let previousRootPath = try rootPath(rootID: rootID)
            if let previousRootPath, previousRootPath != root.path {
                throw JournalError.database("Source root moved; refusing to reconcile against a different path")
            }

            guard try DirectoryBinding.encoded(root) == binding else { throw MountedCopyError.sourceRootChanged }
            let existingBinding = try prepare("SELECT stamp FROM directory_bindings WHERE root_id=? AND role='source';")
            try bind(rootID,at:1,statement:existingBinding)
            let bindingResult = sqlite3_step(existingBinding)
            let matches = bindingResult == SQLITE_ROW && column(existingBinding,0) == binding
            sqlite3_finalize(existingBinding)
            guard bindingResult == SQLITE_DONE || matches else { throw MountedCopyError.sourceRootChanged }
            let pin = try prepare("INSERT OR IGNORE INTO directory_bindings(root_id,role,stamp) VALUES(?,'source',?);")
            defer { sqlite3_finalize(pin) }
            try bind(rootID,at:1,statement:pin); try bind(binding,at:2,statement:pin)
            guard sqlite3_step(pin) == SQLITE_DONE else { throw failure() }
            let before = try readEntries(rootID: rootID, scope: fullScan ? nil : scope)
            // FSEvents jobs and restart-recovery scans must never masquerade as
            // disposable bootstrap work. Decide atomically under the writer
            // lock, including old queue history without a watched_roots row.
            var pristine = false
            if origin == .initialInventory && fullScan && eventID == nil &&
               previousRootPath == nil && before.isEmpty {
                let history = try prepare("SELECT 1 FROM change_queue WHERE root_id=? LIMIT 1;")
                try bind(rootID, at: 1, statement: history)
                let check = sqlite3_step(history)
                sqlite3_finalize(history)
                guard check == SQLITE_ROW || check == SQLITE_DONE else { throw failure() }
                pristine = check == SQLITE_DONE
            }
            let jobOrigin: QueuedChangeOrigin = pristine ? .initialInventory : .sourceMonitor
            let affected = before
            let seen = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0) })
            var upserts = 0
            var deletes = 0
            for row in rows {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                if before[row.relativePath] != row {
                    try store(rootID: rootID, item: row)
                    // Upgrade legacy metadata without re-uploading the entire archive.
                    let old = before[row.relativePath]
                    if old == nil || old?.changeStamp != nil || old?.kind != row.kind || old?.size != row.size || old?.modifiedAt != row.modifiedAt {
                        try enqueue(rootID: rootID, relativePath: row.relativePath, kind: .upsert, origin: jobOrigin)
                        upserts += 1
                    }
                }
            }

            for (path, _) in affected where seen[path] == nil {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                try remove(rootID: rootID, relativePath: path)
                if FileExclusionPolicy.excludes(path,enabled:ignoreDSStore) { continue }
                try enqueue(rootID: rootID, relativePath: path, kind: .delete, origin: .sourceMonitor)
                deletes += 1
            }

            if ignoreDSStore {
                let retire=try prepare("UPDATE change_queue SET completed=1 WHERE root_id=? AND completed=0 AND instr('/'||relative_path||'/','/.DS_Store/')>0;")
                defer { sqlite3_finalize(retire) }
                try bind(rootID,at:1,statement:retire)
                guard sqlite3_step(retire)==SQLITE_DONE else { throw failure() }
            }

            // Keep existing event ID if caller is doing a scan independent of FSEvents.
            let prior = try lastEventID(rootID: rootID)
            let checkpoint: UInt64?
            if let eventID { checkpoint = max(prior ?? 0, eventID) }
            else { checkpoint = prior }
            guard try DirectoryBinding.encoded(root) == binding else { throw MountedCopyError.sourceRootChanged }
            try saveRoot(rootID: rootID, rootPath: root.path, eventID: checkpoint)
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try execute("COMMIT;")
            return ReconciliationResult(inspected: rows.count, queuedUpserts: upserts, queuedDeletes: deletes)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Snapshot of the locally maintained inventory only; never enumerate SMB.
    public func incompatibleNames(rootID:String,sourcePath:String,conflicts:Set<String> = []) throws -> [IncompatibleName] {
        guard try rootPath(rootID:rootID)==sourcePath else { throw MountedCopyError.invalidMapping }
        return IncompatibleName.collect(rootID:rootID,rootPath:sourcePath,side:.source,
                                       items:Array(try readEntries(rootID:rootID,scope:nil).values),conflicts:conflicts)
    }

    private func readEntries(rootID: String, scope: String?) throws -> [String: TrackedItem] {
        // The composite primary key (root_id, relative_path) makes this a
        // targeted index lookup for file events, even with huge local archives.
        // For scope="folder", descendants lie in ["folder/", "folder0")
        // because ASCII '/' is immediately followed by '0'.
        let sql: String
        if scope != nil {
            sql = """
                SELECT relative_path, kind, file_size, modified_at, change_stamp
                FROM file_inventory
                WHERE root_id = ? AND
                  (relative_path = ? OR
                    (relative_path >= ? AND relative_path < ?));
                """
        } else {
            sql = """
                SELECT relative_path, kind, file_size, modified_at, change_stamp
                FROM file_inventory WHERE root_id = ?;
                """
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        if let scope {
            try bind(scope, at: 2, statement: statement)
            try bind(scope + "/", at: 3, statement: statement)
            try bind(scope + "0", at: 4, statement: statement)
        }
        var items: [String: TrackedItem] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            let path = column(statement, 0)
            items[path] = TrackedItem(
                relativePath: path, kind: column(statement, 1),
                size: sqlite3_column_int64(statement, 2),
                modifiedAt: sqlite3_column_double(statement, 3),
                changeStamp: sqlite3_column_type(statement,4) == SQLITE_NULL ? nil : column(statement,4)
            )
        }
        return items
    }

    private func store(rootID: String, item: TrackedItem) throws {
        let statement = try prepare("""
            INSERT INTO file_inventory(root_id,relative_path,kind,file_size,modified_at,change_stamp)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(root_id,relative_path) DO UPDATE SET
              kind=excluded.kind,file_size=excluded.file_size,modified_at=excluded.modified_at,change_stamp=excluded.change_stamp;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(rootID, at: 1, statement: statement)
        try bind(item.relativePath, at: 2, statement: statement)
        try bind(item.kind, at: 3, statement: statement)
        if let stamp = item.changeStamp { try bind(stamp,at:6,statement:statement) }
        else { guard sqlite3_bind_null(statement,6) == SQLITE_OK else { throw failure() } }
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

    private func enqueue(rootID: String, relativePath: String, kind: ChangeKind,
                         origin: QueuedChangeOrigin) throws {
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
            INSERT INTO change_queue(root_id,relative_path,kind,recorded_at,origin) VALUES(?,?,?,?,?);
            """)
        defer { sqlite3_finalize(insert) }
        try bind(rootID, at: 1, statement: insert)
        try bind(relativePath, at: 2, statement: insert)
        try bind(kind.rawValue, at: 3, statement: insert)
        try bind(origin.rawValue, at: 5, statement: insert)
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
