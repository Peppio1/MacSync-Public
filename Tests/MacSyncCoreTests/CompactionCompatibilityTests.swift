import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class CompactionCompatibilityTests: XCTestCase {
    func testCompactOperationalSchemaAndExportForPredecessor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = folder.appendingPathComponent("inventory.sqlite")
        do {
            _ = try LocalInventory(path: db.path).reconcile(rootID: "demo", root: source)
            let journal = try ChangeJournal(path: db.path)
            let first = try journal.enqueue(rootID: "demo", relativePath: "completed.jpg", kind: .upsert)
            try journal.markCompleted(id: first)
            let second = try journal.enqueue(rootID: "demo", relativePath: "pending.jpg", kind: .upsert)
            XCTAssertEqual(first, 1)
            XCTAssertEqual(second, 2)
            XCTAssertEqual(try journal.pending().map(\.id), [second])
        }
        // Inflate then free SQLite pages without inventing operational jobs.
        do {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                throw JournalError.database("fixture open")
            }
            defer { sqlite3_close(handle) }
            let sql = """
                CREATE TABLE fixture_padding(value BLOB);
                INSERT INTO fixture_padding VALUES(zeroblob(75497472));
                DROP TABLE fixture_padding;
                """
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw JournalError.database("fixture padding")
            }
        }
        let identity = try ArchiveDatabaseSafety.fileIdentity(db)
        let digest = try ApplicationRollback.operationalDatabaseDigest(db)
        guard case let .compacted(before, after, _) = try OfflineDatabaseCompaction.run(in: folder) else {
            return XCTFail("Expected compaction of operational schema fixture")
        }
        XCTAssertGreaterThan(before - after, 64 * 1024 * 1024)
        XCTAssertEqual(try ArchiveDatabaseSafety.fileIdentity(db), identity)
        XCTAssertEqual(try ApplicationRollback.operationalDatabaseDigest(db), digest)
        // The rollback path uses a verified standalone snapshot.
        let snapshot = folder.appendingPathComponent("compacted.sqlite")
        try ArchiveDatabaseSafety.backup(db, to: snapshot)
        try SignedRollbackTransaction.validateCompatibility(database: snapshot)
        let journal = try ChangeJournal(path: snapshot.path, readOnly: true)
        XCTAssertEqual(try journal.queueSequence(), 2)
        XCTAssertEqual(try journal.pending().map(\.id), [2])
        if let output = ProcessInfo.processInfo.environment["MACSYNC_COMPACTION_COMPAT_DIR"], !output.isEmpty {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: snapshot, to: directory.appendingPathComponent("compacted.sqlite"))
        }
        print("COMPACTION_OPERATIONAL_SCHEMA_OK")
    }
}
