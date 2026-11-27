import Foundation
import SQLite3
import Darwin

/// Offline-only experiment. Never invoke from a running MacSync runtime:
/// the same exclusive lock is held for its lifetime. No automatic restore,
/// no file replacement, no removal of source sidecars.
public enum OfflineDatabaseCompaction {
    public enum Result: Equatable, Sendable {
        case skipped(DatabaseCompactionPolicy.Decision)
        case compacted(beforeBytes: Int64, afterBytes: Int64, backup: URL)
    }

    /// The caller supplies the existing private MacSync archive directory.
    /// The lock is acquired here, rather than trusting a caller's assertion
    /// that all runtime readers and writers have been drained.
    public static func run(in folder: URL) throws -> Result {
        var info = stat()
        guard folder.isFileURL,
              folder.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw JournalError.database("Directory archivio non valida")
        }
        let lock = try ExclusiveArchiveLock(url: folder.appendingPathComponent("archive.lock"))
        return try runBeforeRuntime(in: folder, lock: lock)
    }

    /// Startup only: the caller has acquired the archive lock but has
    /// not constructed any runtime readers, writers or source watchers.
    public static func runBeforeRuntime(in folder: URL, lock: ExclusiveArchiveLock) throws -> Result {
        defer { withExtendedLifetime(lock) {} }
        try lock.verifyHeld(at: folder.appendingPathComponent("archive.lock"))
        let db = folder.appendingPathComponent("inventory.sqlite")
        let identity = try ArchiveDatabaseSafety.fileIdentity(db)
        let sample = DatabaseDiagnosticSnapshot.collect(databasePath: db.path)
        guard sample.complete, let before = sample.databaseBytes else {
            return .skipped(.insufficientEvidence)
        }
        let capacity = try folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        let decision = DatabaseCompactionPolicy.evaluate(pageSize: sample.pageSize, pageCount: sample.pageCount,
            freePages: sample.freePages, walBytes: sample.walBytes, availableBytes: capacity.map { Int64($0) })
        guard decision == .eligible else { return .skipped(decision) }
        let digest = try ApplicationRollback.databaseDigest(db, scratch: folder)
        let backupFolder = folder.appendingPathComponent("compaction-backup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let backup = backupFolder.appendingPathComponent("inventory.sqlite")
        // Retain this recovery copy on any error; never automatically roll
        // back a database by replacing it with an older snapshot.
        try ArchiveDatabaseSafety.backup(db, to: backup)
        guard try ApplicationRollback.databaseDigest(backup, scratch: folder) == digest,
              try ApplicationRollback.databaseDigest(db, scratch: folder) == digest,
              try ArchiveDatabaseSafety.fileIdentity(db) == identity else {
            throw JournalError.database("Backup di compattazione non equivalente")
        }
        try lock.verifyHeld(at: folder.appendingPathComponent("archive.lock"))
        try compactSQLite(db)
        guard try ArchiveDatabaseSafety.fileIdentity(db) == identity,
              try ApplicationRollback.databaseDigest(db, scratch: folder) == digest else {
            throw JournalError.database("Verifica successiva alla compattazione non riuscita; backup preservato")
        }
        let size = try db.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size else { throw JournalError.database("Dimensione finale database non disponibile") }
        return .compacted(beforeBytes: before, afterBytes: Int64(size), backup: backup)
    }

    private static func compactSQLite(_ url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw JournalError.database("Database di compattazione non accessibile")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 100)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw JournalError.database(String(cString: sqlite3_errmsg(handle)))
            }
        }
        func checkpoint() throws {
            var log: Int32 = -1
            var copied: Int32 = -1
            let rc = sqlite3_wal_checkpoint_v2(handle, "main", SQLITE_CHECKPOINT_TRUNCATE, &log, &copied)
            guard rc == SQLITE_OK, log == copied else {
                throw JournalError.database("Checkpoint esclusivo non riuscito; backup preservato")
            }
        }
        // SQLite owns the transaction and its crash recovery. Do not change
        // journal mode or manually unlink WAL/SHM.
        try checkpoint()
        try execute("PRAGMA synchronous=FULL;")
        try execute("VACUUM main;")
        try checkpoint()
    }
}
