import Foundation
import Darwin
import SQLite3

/// A durable intent is written before the first compaction mutation.
/// Startup must resolve it before reset, migration, update or runtime work.
public enum CompactionRecovery {
    private struct Marker: Codable {
        let version: Int
        let identity: String
        let digest: Data
        let backupID: UUID
    }

    private static func markerURL(_ folder: URL) -> URL {
        folder.appendingPathComponent("compaction-pending.json")
    }

    private static func failure() -> JournalError {
        .database("Compattazione non verificata: conservare database e backup, sincronizzazione bloccata.")
    }

    private static func regularFileExists(_ url: URL) throws -> Bool {
        var info = stat()
        let rc = url.path.withCString { lstat($0, &info) }
        if rc != 0 {
            if errno == ENOENT { return false }
            throw failure()
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw failure() }
        return true
    }

    private static func flush(_ url: URL, directory: Bool) throws {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
        let fd = url.path.withCString { Darwin.open($0, flags) }
        guard fd >= 0 else { throw failure() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG),
              fsync(fd) == 0 else { throw failure() }
    }

    static func begin(in folder: URL, lock: ExclusiveArchiveLock, identity: String,
                      digest: Data, backupID: UUID) throws {
        try lock.verifyHeld(at: folder.appendingPathComponent("archive.lock"))
        let backupFolder = folder.appendingPathComponent("compaction-backup-" + backupID.uuidString)
        let backup = backupFolder.appendingPathComponent("inventory.sqlite")
        let marker = markerURL(folder)
        guard digest.count == 32, !identity.isEmpty,
              try !regularFileExists(marker) else { throw failure() }
        // Persist the recovery file and its directory entries first.
        try flush(backup, directory: false)
        try flush(backupFolder, directory: true)
        let data = try JSONEncoder().encode(Marker(version: 1, identity: identity,
                                                  digest: digest, backupID: backupID))
        // Publish only the fully written intent, without overwriting an
        // existing intent. Before publication the DB remains unmodified.
        let staged = folder.appendingPathComponent(".compaction-intent-" + UUID().uuidString)
        try data.write(to: staged, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: staged) }
        try flush(staged, directory: false)
        let rc = staged.path.withCString { old in
            marker.path.withCString { new in
                renameatx_np(AT_FDCWD, old, AT_FDCWD, new, UInt32(RENAME_EXCL))
            }
        }
        guard rc == 0 else { throw failure() }
        try flush(folder, directory: true)
    }

    /// Ensure committed WAL contents are durable in the main file before
    /// dropping the intent. Busy readers/writers leave the marker intact.
    private static func checkpointForRecovery(_ db: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw failure()
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 100)
        guard sqlite3_exec(handle, "PRAGMA synchronous=FULL;", nil, nil, nil) == SQLITE_OK else { throw failure() }
        var log: Int32 = -1
        var copied: Int32 = -1
        let rc = sqlite3_wal_checkpoint_v2(handle, "main", SQLITE_CHECKPOINT_TRUNCATE, &log, &copied)
        guard rc == SQLITE_OK, log == copied else { throw failure() }
    }

    /// Safe even after a crash before or after VACUUM. Never restores older
    /// data automatically. An unknown marker, mismatch or missing backup
    /// blocks startup and preserves all evidence.
    @discardableResult
    public static func verifyPending(in folder: URL, lock: ExclusiveArchiveLock) throws -> Bool {
        try lock.verifyHeld(at: folder.appendingPathComponent("archive.lock"))
        let url = markerURL(folder)
        guard try regularFileExists(url) else { return false }
        let marker: Marker
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 4096 else { throw failure() }
            marker = try JSONDecoder().decode(Marker.self, from: data)
        } catch { throw failure() }
        guard marker.version == 1, marker.digest.count == 32, !marker.identity.isEmpty else { throw failure() }
        let db = folder.appendingPathComponent("inventory.sqlite")
        let backupFolder = folder.appendingPathComponent("compaction-backup-" + marker.backupID.uuidString)
        let backup = backupFolder.appendingPathComponent("inventory.sqlite")
        var info = stat()
        guard backupFolder.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              try regularFileExists(backup),
              try ArchiveDatabaseSafety.fileIdentity(db) == marker.identity else { throw failure() }
        // SQLite may need to recover a committed WAL on restart.
        try ArchiveDatabaseSafety.verify(db)
        guard try ApplicationRollback.databaseDigest(db, scratch: folder) == marker.digest,
              try ApplicationRollback.databaseDigest(backup, scratch: folder) == marker.digest else { throw failure() }
        try lock.verifyHeld(at: folder.appendingPathComponent("archive.lock"))
        try checkpointForRecovery(db)
        guard try ArchiveDatabaseSafety.fileIdentity(db) == marker.identity,
              try ApplicationRollback.databaseDigest(db, scratch: folder) == marker.digest else { throw failure() }
        try flush(db, directory: false)
        // Never remove SQLite sidecars manually.
        try FileManager.default.removeItem(at: url)
        try flush(folder, directory: true)
        return true
    }
}
