import Foundation
import Darwin
import SQLite3
import XCTest
@testable import MacSyncCore

final class SourceNameLineageStoreTests: XCTestCase {
    private func open(_ path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        try SQLiteConnectionSetup.configureWriter(connection)
        return connection
    }
    private func sql(_ db: OpaquePointer, _ statement: String) throws {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw JournalError.database(String(cString: sqlite3_errmsg(db)))
        }
    }
    private func fixture(_ body: (String, SourceNameLineage.Record) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: file)
        var st = stat()
        XCTAssertEqual(file.path.withCString { lstat($0, &st) }, 0)
        let identity = try XCTUnwrap(SourceNameLineage.Identity(stat: st))
        var record = SourceNameLineage.Record(identity: identity, rootID: "photos",
            sourceBinding: "source", targetBinding: "target", path: "photo.jpg")
        record.recognize(path: "photo.jpg")
        try body(base.appendingPathComponent("state.sqlite").path, record)
    }
    private func rename(_ record: inout SourceNameLineage.Record, _ path: String) {
        _ = record.observe(identity: record.identity, path: path, rootID: record.rootID,
            sourceBinding: record.sourceBinding, targetBinding: record.targetBinding,
            uniqueObservation: true)
    }
    func testReopenAndAtomicRollbackWithInventory() throws {
        try fixture { path, initial in
            let key = SourceNameLineageStore.Key(initial)
            do {
                let db = try open(path)
                defer { sqlite3_close(db) }
                try SourceNameLineageStore.install(db)
                try sql(db, "CREATE TABLE checkpoint(event INTEGER); INSERT INTO checkpoint VALUES(1); BEGIN IMMEDIATE;")
                let stored = try SourceNameLineageStore.write(db, record: initial, expectedRevision: nil)
                XCTAssertEqual(stored.revision, 1)
                try sql(db, "COMMIT;")
                var changed = initial
                rename(&changed, "photo.jpg.")
                try sql(db, "BEGIN IMMEDIATE; UPDATE checkpoint SET event=2;")
                _ = try SourceNameLineageStore.write(db, record: changed, expectedRevision: 1)
                try sql(db, "ROLLBACK;")
                XCTAssertEqual(try SourceNameLineageStore.read(db, key: key)?.record, initial)
                try sql(db, "BEGIN IMMEDIATE; UPDATE checkpoint SET event=3;")
                _ = try SourceNameLineageStore.write(db, record: changed, expectedRevision: 1)
                try sql(db, "COMMIT;")
            }
            let db = try open(path)
            defer { sqlite3_close(db) }
            let restored = try XCTUnwrap(try SourceNameLineageStore.read(db, key: key))
            XCTAssertEqual(restored.revision, 2)
            XCTAssertEqual(restored.record.currentPath, "photo.jpg.")
            XCTAssertEqual(restored.record.recognizedPaths, ["photo.jpg"])
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT event FROM checkpoint;", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(stmt, 0), 3)
        }
    }
    func testStaleWriterCannotOverwritePublicationEvidence() throws {
        try fixture { path, initial in
            let a = try open(path)
            defer { sqlite3_close(a) }
            try SourceNameLineageStore.install(a)
            let b = try open(path)
            defer { sqlite3_close(b) }
            try sql(a, "BEGIN IMMEDIATE;")
            _ = try SourceNameLineageStore.write(a, record: initial, expectedRevision: nil)
            try sql(a, "COMMIT;")
            let key = SourceNameLineageStore.Key(initial)
            let old = try XCTUnwrap(try SourceNameLineageStore.read(b, key: key))
            var changed = initial
            changed.publicationStarted()
            try sql(a, "BEGIN IMMEDIATE;")
            _ = try SourceNameLineageStore.write(a, record: changed, expectedRevision: old.revision)
            try sql(a, "COMMIT;")
            try sql(b, "BEGIN IMMEDIATE;")
            XCTAssertThrowsError(try SourceNameLineageStore.write(b, record: old.record, expectedRevision: old.revision)) {
                XCTAssertEqual($0 as? SourceNameLineageStore.Failure, .stale)
            }
            try sql(b, "ROLLBACK;")
            XCTAssertEqual(try SourceNameLineageStore.read(b, key: key)?.record.uncertainPublication, true)
        }
    }
    func testConditionalInsertCannotReplaceExistingIdentity() throws {
        try fixture { path, initial in
            let db = try open(path)
            defer { sqlite3_close(db) }
            try SourceNameLineageStore.installProtection(db)
            try sql(db, "BEGIN IMMEDIATE;")
            let batch = try XCTUnwrap(try SourceNameLineageStore.batch(db,key:.init(initial),create:true))
            let first = try batch.write(record:initial,expectedRevision:nil)
            XCTAssertFalse(try batch.hasHold(initial))
            let before = try batch.readForAudit(key:.init(initial))
            XCTAssertEqual(before.0,first)
            XCTAssertFalse(before.1)
            try batch.protectRename(initial)
            XCTAssertTrue(try batch.hasHold(initial))
            let after = try batch.readForAudit(key:.init(initial))
            XCTAssertEqual(after.0,first)
            XCTAssertTrue(after.1)
            var changed = initial
            changed.publicationStarted()
            XCTAssertThrowsError(try batch.write(record:changed,expectedRevision:nil)) {
                XCTAssertEqual($0 as? SourceNameLineageStore.Failure,.stale)
            }
            XCTAssertEqual(try batch.read(key:.init(initial)),first)
            XCTAssertTrue(try batch.hasHold(initial))
            try sql(db, "COMMIT;")
            XCTAssertEqual(try SourceNameLineageStore.read(db,key:.init(initial)),first)
        }
    }

    func testBindingIsolationNoOpAndTransactionRequirement() throws {
        try fixture { path, initial in
            let db = try open(path)
            defer { sqlite3_close(db) }
            try SourceNameLineageStore.install(db)
            try SourceNameLineageStore.install(db)
            XCTAssertThrowsError(try SourceNameLineageStore.write(db, record: initial, expectedRevision: nil)) {
                XCTAssertEqual($0 as? SourceNameLineageStore.Failure, .transactionRequired)
            }
            try sql(db, "BEGIN IMMEDIATE;")
            let first = try SourceNameLineageStore.write(db, record: initial, expectedRevision: nil)
            let second = try SourceNameLineageStore.write(db, record: initial, expectedRevision: first.revision)
            XCTAssertEqual(first, second)
            let other = SourceNameLineage.Record(identity: initial.identity, rootID: initial.rootID,
                sourceBinding: initial.sourceBinding, targetBinding: "new-target", path: initial.currentPath)
            XCTAssertNil(try SourceNameLineageStore.read(db, key: .init(other)))
            _ = try SourceNameLineageStore.write(db, record: other, expectedRevision: nil)
            try sql(db, "COMMIT;")
            XCTAssertEqual(try SourceNameLineageStore.read(db, key: .init(other))?.record.evidence, .unknown)
            XCTAssertEqual(try SourceNameLineageStore.read(db, key: .init(initial))?.record.recognizedPaths, ["photo.jpg"])
        }
    }
    func testAdditiveSchemaPreservesExistingQueueAndRejectsCorruptRecord() throws {
        try fixture { path, initial in
            let journal = try ChangeJournal(path: path)
            let db = try open(path)
            defer { sqlite3_close(db) }
            try sql(db, "INSERT INTO change_queue(root_id,relative_path,kind,recorded_at) VALUES('photos','photo.jpg','upsert',1);")
            let before = try journal.pending(limit: 100).map(\.id)
            try SourceNameLineageStore.install(db)
            try sql(db, "BEGIN IMMEDIATE;")
            _ = try SourceNameLineageStore.write(db, record: initial, expectedRevision: nil)
            try sql(db, "COMMIT;")
            XCTAssertEqual(try journal.pending(limit: 100).map(\.id), before)
            try sql(db, "UPDATE source_lineage_index SET recognized_paths=x'00';")
            XCTAssertThrowsError(try SourceNameLineageStore.read(db, key: .init(initial)))
            XCTAssertEqual(try journal.pending(limit: 100).map(\.id), before)
        }
    }

    func testVerifiedRemountPreservesNamespaceAndHoldsAndRejectsCollision() throws {
        try fixture { path, initial in
            let db=try open(path)
            defer { sqlite3_close(db) }
            try SourceNameLineageStore.installProtection(db)
            try sql(db,"CREATE TABLE directory_bindings(root_id TEXT,role TEXT,stamp TEXT); INSERT INTO directory_bindings VALUES('photos','source','source');")
            try sql(db,"BEGIN IMMEDIATE;")
            let saved=try SourceNameLineageStore.write(db,record:initial,expectedRevision:nil)
            let batch=try XCTUnwrap(try SourceNameLineageStore.batch(db,key:.init(initial),create:false))
            try batch.protectRename(initial)
            try sql(db,"COMMIT;")
            XCTAssertTrue(try SourceNameLineageStore.protected(db,root:"photos",path:"photo.jpg"))
            try sql(db,"BEGIN IMMEDIATE;")
            try SourceNameLineageStore.rebindVerifiedTarget(db,root:"photos",old:"target",new:"remounted")
            try sql(db,"COMMIT;")
            let new=SourceNameLineage.Record(identity:initial.identity,rootID:initial.rootID,
                sourceBinding:initial.sourceBinding,targetBinding:"remounted",path:initial.currentPath)
            XCTAssertNil(try SourceNameLineageStore.read(db,key:.init(initial)))
            let moved=try XCTUnwrap(try SourceNameLineageStore.read(db,key:.init(new)))
            XCTAssertEqual(moved.revision,saved.revision)
            XCTAssertEqual(moved.record.recognizedPaths,initial.recognizedPaths)
            XCTAssertTrue(try SourceNameLineageStore.protected(db,root:"photos",path:"photo.jpg"))
            try sql(db,"BEGIN IMMEDIATE;")
            _=try SourceNameLineageStore.write(db,record:initial,expectedRevision:nil)
            try sql(db,"COMMIT;")
            try sql(db,"BEGIN IMMEDIATE;")
            XCTAssertThrowsError(try SourceNameLineageStore.rebindVerifiedTarget(db,root:"photos",old:"remounted",new:"target"))
            try sql(db,"ROLLBACK;")
            XCTAssertNotNil(try SourceNameLineageStore.read(db,key:.init(new)))
            XCTAssertTrue(try SourceNameLineageStore.protected(db,root:"photos",path:"photo.jpg"))
        }
    }

    func testUnknownHistoryHoldAndAliasAreConservative() throws {
        try fixture { path, initial in
            let db=try open(path)
            defer { sqlite3_close(db) }
            try SourceNameLineageStore.installProtection(db)
            var record=SourceNameLineage.Record(identity:initial.identity,rootID:initial.rootID,
                sourceBinding:initial.sourceBinding,targetBinding:initial.targetBinding,path:"Folder/photo.jpg")
            try sql(db,"BEGIN IMMEDIATE;")
            let first=try SourceNameLineageStore.write(db,record:record,expectedRevision:nil)
            let batch=try XCTUnwrap(try SourceNameLineageStore.batch(db,key:.init(record),create:false))
            try batch.protectRename(record)
            rename(&record,"folder/photo.jpg")
            record.recognize(path:"folder/photo.jpg")
            _=try batch.write(record:record,expectedRevision:first.revision)
            try batch.releaseConfirmed(record)
            XCTAssertTrue(try batch.hasHold(record))
            XCTAssertTrue(try SourceNameLineageStore.protected(db,root:"photos",path:"Folder"))
            try sql(db,"COMMIT;")
        }
    }

}
