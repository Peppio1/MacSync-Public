import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class CompactionRecoveryTests: XCTestCase {
    private func execute(_ db: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(db.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw JournalError.database("fixture open")
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw JournalError.database("fixture SQL")
        }
    }

    private func fixture(_ body: (URL, URL, URL, ExclusiveArchiveLock) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = try ExclusiveArchiveLock(url: folder.appendingPathComponent("archive.lock"))
        let db = folder.appendingPathComponent("inventory.sqlite")
        try execute(db, "CREATE TABLE data(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT); INSERT INTO data(value) VALUES('original');")
        let id = UUID()
        let backupFolder = folder.appendingPathComponent("compaction-backup-" + id.uuidString)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: false)
        let backup = backupFolder.appendingPathComponent("inventory.sqlite")
        try ArchiveDatabaseSafety.backup(db, to: backup)
        try CompactionRecovery.begin(in: folder, lock: lock,
            identity: ArchiveDatabaseSafety.fileIdentity(db),
            digest: ApplicationRollback.databaseDigest(db, scratch: folder), backupID: id)
        try body(folder, db, backup, lock)
    }

    func testIntentBeforeMutationOrAfterVacuumRecoversWithoutRestore() throws {
        for vacuum in [false, true] {
            try fixture { folder, db, backup, lock in
                let digest = try ApplicationRollback.databaseDigest(db, scratch: folder)
                if vacuum { try execute(db, "VACUUM;") }
                XCTAssertTrue(try CompactionRecovery.verifyPending(in: folder, lock: lock))
                XCTAssertFalse(try CompactionRecovery.verifyPending(in: folder, lock: lock))
                XCTAssertEqual(try ApplicationRollback.databaseDigest(db, scratch: folder), digest)
                XCTAssertEqual(try ApplicationRollback.databaseDigest(backup, scratch: folder), digest)
            }
        }
    }

    func testUnexpectedDataChangePreservesIntentAndBothDatabases() throws {
        try fixture { folder, db, backup, lock in
            try execute(db, "INSERT INTO data(value) VALUES('unexpected');")
            let changed = try ApplicationRollback.databaseDigest(db, scratch: folder)
            XCTAssertThrowsError(try CompactionRecovery.verifyPending(in: folder, lock: lock))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("compaction-pending.json").path))
            XCTAssertEqual(try ApplicationRollback.databaseDigest(db, scratch: folder), changed)
            XCTAssertNotEqual(try ApplicationRollback.databaseDigest(backup, scratch: folder), changed)
        }
    }

    func testMissingBackupAndMalformedIntentFailClosed() throws {
        try fixture { folder, _, backup, lock in
            try FileManager.default.removeItem(at: backup)
            XCTAssertThrowsError(try CompactionRecovery.verifyPending(in: folder, lock: lock))
            let marker = folder.appendingPathComponent("compaction-pending.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            try Data("invalid".utf8).write(to: marker)
            XCTAssertThrowsError(try CompactionRecovery.verifyPending(in: folder, lock: lock))
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
    }
}
