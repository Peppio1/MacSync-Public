import Foundation
import XCTest
import SQLite3
@testable import MacSyncCore

final class ChangeJournalTests: XCTestCase {
    func testLegacyQueueSchemaMigrationRetainsAllUnknownJobsAndIDs() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("MacSync-origin-migration-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        for (i,firstOpener) in ["journal","inventory"].enumerated() {
            let path=base.appendingPathComponent("legacy-\(i).sqlite").path
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path,&handle),SQLITE_OK)
            guard let handle else { XCTFail("Cannot open legacy fixture"); return }
            let setup = """
                CREATE TABLE change_queue(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  root_id TEXT NOT NULL, relative_path TEXT NOT NULL,
                  kind TEXT NOT NULL, recorded_at REAL NOT NULL,
                  completed INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO change_queue(id,root_id,relative_path,kind,recorded_at,completed)
                VALUES(42,'photos','legacy.jpg','upsert',1700000000,0);
                """
            XCTAssertEqual(sqlite3_exec(handle,setup,nil,nil,nil),SQLITE_OK)
            XCTAssertEqual(sqlite3_close(handle),SQLITE_OK)
            if firstOpener == "inventory" { _ = try LocalInventory(path:path) }
            let journal=try ChangeJournal(path:path)
            let pending=try journal.pending()
            XCTAssertEqual(pending.count,1)
            XCTAssertEqual(pending[0].id,42)
            XCTAssertEqual(try journal.originOfJob(id:42),.legacyUnknown)
            let newID=try journal.enqueue(rootID:"photos",relativePath:"new.jpg",kind:.upsert)
            XCTAssertEqual(try journal.originOfJob(id:newID),.sourceMonitor)
            XCTAssertEqual(try journal.pending().count,2)
        }
    }

    func testDestinationRebindJobsCannotMasqueradeAsInitialInventory() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("MacSync-origin-rebind-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let source=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("same".utf8).write(to:source.appendingPathComponent("same.jpg"))
        let db=base.appendingPathComponent("db.sqlite").path
        let inventory=try LocalInventory(path:db)
        _ = try inventory.reconcile(rootID:"photos",root:source,origin:.initialInventory)
        try inventory.requeueAllForNewDestination(rootID:"photos")
        let journal=try ChangeJournal(path:db)
        let pending=try journal.pending()
        XCTAssertEqual(pending.count,1)
        XCTAssertEqual(try journal.originOfJob(id:pending[0].id),.destinationRebind)
    }

    func testQueuePersistsAcrossOpenAndMarkCompleted() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let queuedID: Int64
        do {
            let journal = try ChangeJournal(path: path)
            queuedID = try journal.enqueue(
                rootID: "photo-uploads", relativePath: "folder/example.psd", kind: .upsert
            )
            XCTAssertEqual(try journal.pending().map(\.id), [queuedID])
        }

        do {
            let journal = try ChangeJournal(path: path)
            let events = try journal.pending()
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0].relativePath, "folder/example.psd")
            XCTAssertEqual(events[0].kind, .upsert)
            try journal.markCompleted(id: queuedID)
            XCTAssertTrue(try journal.pending().isEmpty)
        }
    }

    func testRejectsPathEscape() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let journal = try ChangeJournal(path: path)
        XCTAssertThrowsError(
            try journal.enqueue(rootID: "a", relativePath: "../escaped", kind: .delete)
        )
    }

    func testDeletionFailsClosed() {
        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: false, serverAvailable: true, baselineVerified: true,
            trackedFileCount: 100, pendingDeleteCount: 1
        ).allowed)

        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: false, baselineVerified: true,
            trackedFileCount: 100, pendingDeleteCount: 1
        ).allowed)

        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: false,
            trackedFileCount: 100, pendingDeleteCount: 1
        ).allowed)
    }

    func testMassDeletionRequiresIntervention() {
        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: true,
            trackedFileCount: 200, pendingDeleteCount: 25
        ).allowed)

        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: true,
            trackedFileCount: 10_000, pendingDeleteCount: 250
        ).allowed)

        XCTAssertTrue(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: true,
            trackedFileCount: 200, pendingDeleteCount: 1
        ).allowed)
    }
}
