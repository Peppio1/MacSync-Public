import Foundation
import Darwin
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
            digest: ApplicationRollback.operationalDatabaseDigest(db), backupID: id)
        try body(folder, db, backup, lock)
    }

    func testIntentBeforeMutationOrAfterVacuumRecoversWithoutRestore() throws {
        for vacuum in [false, true] {
            try fixture { folder, db, backup, lock in
                let digest = try ApplicationRollback.operationalDatabaseDigest(db)
                if vacuum { try execute(db, "VACUUM;") }
                XCTAssertTrue(try CompactionRecovery.verifyPending(in: folder, lock: lock))
                XCTAssertFalse(try CompactionRecovery.verifyPending(in: folder, lock: lock))
                XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db), digest)
                XCTAssertEqual(try ApplicationRollback.databaseDigest(backup, scratch: folder), digest)
            }
        }
    }

    func testUnexpectedDataChangePreservesIntentAndBothDatabases() throws {
        try fixture { folder, db, backup, lock in
            try execute(db, "INSERT INTO data(value) VALUES('unexpected');")
            let changed = try ApplicationRollback.operationalDatabaseDigest(db)
            XCTAssertThrowsError(try CompactionRecovery.verifyPending(in: folder, lock: lock))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("compaction-pending.json").path))
            XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db), changed)
            XCTAssertNotEqual(try ApplicationRollback.databaseDigest(backup, scratch: folder), changed)
        }
    }

    func testKilledSQLiteWriterWithUncommittedWALRecoversOriginal() throws {
        try fixture { folder, db, backup, lock in
            let digest = try ApplicationRollback.databaseDigest(backup, scratch: folder)
            try execute(db, "PRAGMA journal_mode=WAL;")
            print("WAL_RECOVERY phase=closed_wal_baseline")
            XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db), digest)
            let output = folder.appendingPathComponent("child-output.txt")
            XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            let input = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-batch", db.path]
            process.standardInput = input
            process.standardOutput = writer
            process.standardError = writer
            try process.run()
            defer {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try? input.fileHandleForWriting.close()
            }
            // Force dirty pages out of a tiny cache, but never commit.
            // The print is an explicit barrier, not a timing assumption.
            let sql = """
                .bail on
                PRAGMA cache_size=1;
                BEGIN IMMEDIATE;
                INSERT INTO data(value) VALUES(hex(zeroblob(1048576)));
                .print CHILD_READY

                """
            try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var ready = false
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                if (try String(contentsOf: output, encoding: .utf8)).contains("CHILD_READY") {
                    ready = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertTrue(ready, "SQLite child did not reach transaction barrier")
            guard ready else { return }
            XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGKILL), 0)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .uncaughtSignal)
            XCTAssertEqual(process.terminationStatus, SIGKILL)
            print("WAL_RECOVERY phase=after_sigkill")
            XCTAssertTrue(try CompactionRecovery.verifyPending(in: folder, lock: lock))
            print("WAL_RECOVERY phase=verified")
            XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db), digest)
            XCTAssertEqual(try ApplicationRollback.databaseDigest(backup, scratch: folder), digest)
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
