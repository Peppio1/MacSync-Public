import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class OfflineDatabaseCompactionTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = folder.appendingPathComponent("inventory.sqlite")
        try body(folder, db)
    }

    private func execute(_ db: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(db.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw JournalError.database("fixture open")
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw JournalError.database(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func testActiveArchiveLockPreventsMaintenanceAndSmallDatabaseSkips() throws {
        try fixture { folder, db in
            try execute(db, "CREATE TABLE data(id INTEGER PRIMARY KEY, payload BLOB); INSERT INTO data VALUES(1,x'01');")
            let digest = try ApplicationRollback.operationalDatabaseDigest(db)
            do {
                let lock = try ExclusiveArchiveLock(url: folder.appendingPathComponent("archive.lock"))
                defer { withExtendedLifetime(lock) {} }
                XCTAssertThrowsError(try OfflineDatabaseCompaction.run(in: folder))
            }
            XCTAssertEqual(try OfflineDatabaseCompaction.run(in: folder), .skipped(.insufficientReclaim))
            XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db), digest)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .contains(where: { $0.hasPrefix("compaction-backup-") }))
        }
    }

    func testOfflineVacuumPreservesIdentitySequenceAndVerifiedBackup() throws {
        try fixture { folder, db in
            // One synthetic ~72 MiB payload, not a filesystem stress test.
            try execute(db, """
                PRAGMA journal_mode=WAL;
                PRAGMA wal_autocheckpoint=0;
                CREATE TABLE data(id INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB);
                INSERT INTO data(payload) VALUES(zeroblob(75497472));
                INSERT INTO data(payload) VALUES(x'000102');
                DELETE FROM data WHERE id=1;
                CREATE TABLE file_inventory(id INTEGER PRIMARY KEY, root_id TEXT NOT NULL, relative_path TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL);
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<10000)
                INSERT INTO file_inventory SELECT i, 'synthetic', printf('folder-%05d/photo-%05d.jpg',i/9,i), 2500000+i, 1700000000+i FROM n;
                CREATE INDEX fixture_path_idx ON file_inventory(root_id,relative_path);
                """)
            let identity = try ArchiveDatabaseSafety.fileIdentity(db)
            let digest = try ApplicationRollback.operationalDatabaseDigest(db)
            do {
                let lock = try ExclusiveArchiveLock(url: folder.appendingPathComponent("archive.lock"))
                defer { withExtendedLifetime(lock) {} }
                let sample = DatabaseDiagnosticSnapshot.collectForCompaction(databasePath: db.path)
                XCTAssertTrue(sample.complete)
                XCTAssertTrue(sample.counts.isEmpty)
                print("COMPACTION_PREFLIGHT seconds=\(sample.elapsedSeconds) records=10000")
                let deferred = try OfflineDatabaseCompaction.runBeforeRuntime(in: folder, lock: lock,
                    prepareBackup: { _, _ in throw JournalError.database("synthetic backup error") })
                XCTAssertEqual(deferred, .skipped(.preparationFailed))
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("compaction-pending.json").path))
                XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db), digest)
                let dummy = (0..<2).map { _ in folder.appendingPathComponent("compaction-backup-" + UUID().uuidString) }
                for url in dummy { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
                XCTAssertEqual(try OfflineDatabaseCompaction.runBeforeRuntime(in: folder, lock: lock), .skipped(.backupLimit))
                for url in dummy { try FileManager.default.removeItem(at: url) }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result = try OfflineDatabaseCompaction.run(in: folder)
            print("COMPACTION_TOTAL seconds=\(ProcessInfo.processInfo.systemUptime - started) records=10000")
            guard case let .compacted(before, after, backup) = result else {
                return XCTFail("Expected eligible synthetic database to compact: " + String(describing: result))
            }
            XCTAssertGreaterThan(before - after, 64 * 1024 * 1024)
            XCTAssertEqual(try ArchiveDatabaseSafety.fileIdentity(db), identity)
            XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db), digest)
            XCTAssertEqual(try ApplicationRollback.databaseDigest(backup, scratch: folder), digest)
            XCTAssertEqual(try OfflineDatabaseCompaction.run(in: folder), .skipped(.insufficientReclaim))
            print("OFFLINE_COMPACTION before=\(before) after=\(after)")
            try execute(db, "INSERT INTO data(payload) VALUES(x'03');")
            // Compare against a copy with the same post-maintenance write.
            try execute(backup, "INSERT INTO data(payload) VALUES(x'03');")
            XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db),
                           try ApplicationRollback.databaseDigest(backup, scratch: folder))
        }
    }
}
