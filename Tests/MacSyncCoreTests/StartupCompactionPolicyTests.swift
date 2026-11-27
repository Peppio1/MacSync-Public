import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class StartupCompactionPolicyTests: XCTestCase {
    func testCadenceAndUnsafeStartupStates() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func due(existing: Bool = true, stable: Bool = true, migration: Bool = false,
                 reset: Bool = false, update: Bool = false, last: Date? = nil) -> Bool {
            StartupCompactionPolicy.shouldCheck(existing: existing, stableIdentity: stable,
                migrationNeeded: migration, resetCompleted: reset, updatePending: update,
                lastCheck: last, now: now)
        }
        XCTAssertTrue(due())
        XCTAssertFalse(due(existing: false))
        XCTAssertFalse(due(stable: false))
        XCTAssertFalse(due(migration: true))
        XCTAssertFalse(due(reset: true))
        XCTAssertFalse(due(update: true))
        XCTAssertFalse(due(last: now))
        XCTAssertFalse(due(last: now.addingTimeInterval(60)))
        XCTAssertFalse(due(last: now.addingTimeInterval(-StartupCompactionPolicy.interval + 1)))
        XCTAssertTrue(due(last: now.addingTimeInterval(-StartupCompactionPolicy.interval)))
    }

    func testAlreadyHeldStartupLockAndWrongLock() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = folder.appendingPathComponent("inventory.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(db.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw JournalError.database("fixture open")
        }
        let rc = sqlite3_exec(handle, "CREATE TABLE data(id INTEGER PRIMARY KEY);", nil, nil, nil)
        sqlite3_close(handle)
        XCTAssertEqual(rc, SQLITE_OK)
        let lock = try ExclusiveArchiveLock(url: folder.appendingPathComponent("archive.lock"))
        let wrong = try ExclusiveArchiveLock(url: folder.appendingPathComponent("other.lock"))
        defer { withExtendedLifetime(lock) {}; withExtendedLifetime(wrong) {} }
        XCTAssertThrowsError(try OfflineDatabaseCompaction.runBeforeRuntime(in: folder, lock: wrong))
        XCTAssertEqual(try OfflineDatabaseCompaction.runBeforeRuntime(in: folder, lock: lock),
                       .skipped(.insufficientReclaim))
        XCTAssertThrowsError(try ExclusiveArchiveLock(url: folder.appendingPathComponent("archive.lock")))
    }
}
