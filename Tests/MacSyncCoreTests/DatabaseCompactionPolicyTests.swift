import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class DatabaseCompactionPolicyTests: XCTestCase {
    func testEligibilityThresholdsAndFailClosedArithmetic() {
        let mib: Int64 = 1024 * 1024
        func decision(_ pages: Int64?, _ free: Int64?, _ space: Int64?, wal: Int64? = 0)
            -> DatabaseCompactionPolicy.Decision {
            DatabaseCompactionPolicy.evaluate(pageSize: 4096, pageCount: pages, freePages: free,
                                               walBytes: wal, availableBytes: space)
        }
        XCTAssertEqual(decision(65536, 16384, 832 * mib), .eligible)
        XCTAssertEqual(decision(65536, 16384, 832 * mib - 1), .insufficientSpace)
        XCTAssertEqual(decision(65536, 16384, 832 * mib, wal: 1), .insufficientSpace)
        XCTAssertEqual(decision(65536, 16383, 1024 * mib), .insufficientReclaim)
        XCTAssertEqual(decision(131072, 16384, 2048 * mib), .insufficientReclaim)
        XCTAssertEqual(decision(65536, 65536, Int64.max), .insufficientEvidence)
        XCTAssertEqual(decision(nil, 16384, Int64.max), .insufficientEvidence)
        XCTAssertEqual(decision(65536, 16384, nil), .insufficientEvidence)
        XCTAssertEqual(decision(Int64.max, Int64.max / 2, Int64.max), .insufficientEvidence)
        XCTAssertEqual(decision(65536, 16384, Int64.max, wal: Int64.max), .insufficientEvidence)
        XCTAssertEqual(decision(65536, -1, Int64.max), .insufficientEvidence)
        XCTAssertEqual(decision(65536, 16384, Int64.max, wal: -1), .insufficientEvidence)
        XCTAssertEqual(DatabaseCompactionPolicy.evaluate(pageSize: 3000, pageCount: 65536,
                       freePages: 16384, walBytes: 0, availableBytes: Int64.max), .insufficientEvidence)
    }

    /// Exercise existing compact-backup machinery on a tiny synthetic file.
    /// No replacement of the original database is performed.
    func testCompactSnapshotPreservesLogicalDataAndOriginalIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("source.sqlite")
        let target = root.appendingPathComponent("compact.sqlite")
        do {
            var handle: OpaquePointer?
            guard sqlite3_open(original.path, &handle) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                throw JournalError.database("fixture open")
            }
            defer { sqlite3_close(handle) }
            let sql = """
                CREATE TABLE fixture(id INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB);
                INSERT INTO fixture(payload) VALUES(zeroblob(4194304));
                INSERT INTO fixture(payload) VALUES(x'000102');
                DELETE FROM fixture WHERE id=1;
                """
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw JournalError.database("fixture SQL")
            }
        }
        let sample = DatabaseDiagnosticSnapshot.collect(databasePath: original.path, includeCounts: false)
        XCTAssertTrue(sample.complete)
        XCTAssertTrue(sample.counts.isEmpty)
        XCTAssertNotNil(sample.pageCount)
        XCTAssertGreaterThan(sample.freePages ?? 0, 0)
        let identity = try ArchiveDatabaseSafety.fileIdentity(original)
        let digest = try ApplicationRollback.databaseDigest(original, scratch: root)
        try ArchiveDatabaseSafety.backup(original, to: target)
        XCTAssertEqual(try ApplicationRollback.databaseDigest(target, scratch: root), digest)
        XCTAssertEqual(try ApplicationRollback.databaseDigest(original, scratch: root), digest)
        XCTAssertEqual(try ArchiveDatabaseSafety.fileIdentity(original), identity)
        let before = try XCTUnwrap(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let after = try XCTUnwrap(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(after, before)
        XCTAssertThrowsError(try ArchiveDatabaseSafety.backup(original, to: target))
        XCTAssertEqual(try ApplicationRollback.databaseDigest(target, scratch: root), digest)
    }
}
