import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SourceNameLineageRuntimeTests: XCTestCase {
    func testSharedRuntimePolicyAndHashReconciliation() throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_INTERNAL_NAME_LINEAGE"]=="1" else {
            throw XCTSkip("Integrated candidate policy opt-in")
        }
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent("MacSync-runtime-"+UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let src=base.appendingPathComponent("source"),dst=base.appendingPathComponent("target")
        for root in [src,dst] { try fm.createDirectory(at:root,withIntermediateDirectories:true) }
        let db=base.appendingPathComponent("state.sqlite")
        let inventory=try LocalInventory(path:db.path), journal=try ChangeJournal(path:db.path)
        XCTAssertTrue(inventory.experimentalSourceNameLineage)
        XCTAssertTrue(inventory.experimentalLineageQueueProtection)
        XCTAssertTrue(journal.experimentalSourceNameLineage)
        XCTAssertFalse(try ChangeJournal(path:db.path,readOnly:true).experimentalSourceNameLineage)
        let date=Date(timeIntervalSinceNow:-1000)
        for root in [src,dst] {
            let url=root.appendingPathComponent("old.jpg")
            try Data("photo".utf8).write(to:url)
            try fm.setAttributes([.modificationDate:date],ofItemAtPath:url.path)
        }
        _=try inventory.reconcile(rootID:"photos",root:src,origin:.initialInventory)
        let map=try MountedFolderMapping(rootID:"photos",source:src,target:dst)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        _=try inventory.reconcile(rootID:"photos",root:src)
        _=try SeededArchiveSession(database:db,mappings:[map]).auditPreservingQueuedChanges(mode:.quick,repair:true,reconcileOrdinaryJobs:true)
        let bad=src.appendingPathComponent("old.jpg.")
        try fm.moveItem(at:src.appendingPathComponent("old.jpg"),to:bad)
        _=try inventory.reconcile(rootID:"photos",root:src,eventID:1)
        let fixed=src.appendingPathComponent("fixed.jpg")
        try fm.moveItem(at:bad,to:fixed)
        _=try inventory.reconcile(rootID:"photos",root:src,eventID:2)
        // The corrected copy is already present; the existing SHA path must
        // acknowledge it without a second transfer and release the old hold.
        try fm.copyItem(at:fixed,to:dst.appendingPathComponent("fixed.jpg"))
        try fm.setAttributes([.modificationDate:date],ofItemAtPath:dst.appendingPathComponent("fixed.jpg").path)
        let old=try XCTUnwrap(journal.pending().first{$0.kind == .delete && $0.relativePath=="old.jpg"})
        XCTAssertFalse(try journal.deletionIsCurrent(id:old.id,rootID:old.rootID,relativePath:old.relativePath))
        let worker=try MountedFolderCopyWorker(journal:journal,log:SyncActivityLog(path:db.path),mappings:[map],minimumStableAge:0)
        let result=try worker.runCycle(enabled:true)
        XCTAssertEqual(result.reconciled,1)
        XCTAssertEqual(result.copied,0)
        XCTAssertTrue(try journal.deletionIsCurrent(id:old.id,rootID:old.rootID,relativePath:old.relativePath))
        XCTAssertEqual(try Data(contentsOf:dst.appendingPathComponent("old.jpg")),Data("photo".utf8))
    }

    func testRollbackArchivesProtectedDeletesWithoutChangingOtherJobs() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent("MacSync-rollback-hold-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        let db=base.appendingPathComponent("state.sqlite")
        _=try LocalInventory(path:db.path)
        let journal=try ChangeJournal(path:db.path)
        let protected=try journal.enqueue(rootID:"photos",relativePath:"old/child.jpg",kind:.delete,origin:.sourceMonitor)
        let ordinary=try journal.enqueue(rootID:"photos",relativePath:"other.jpg",kind:.upsert,origin:.sourceMonitor)
        var connection:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(db.path,&connection,SQLITE_OPEN_READWRITE,nil),SQLITE_OK)
        let handle=try XCTUnwrap(connection)
        defer { sqlite3_close(handle) }
        try SourceNameLineageStore.installProtection(handle)
        XCTAssertEqual(sqlite3_exec(handle,"INSERT INTO source_lineage_mapping(id,root_id,source_binding,target_binding) VALUES(1,'photos','s','t'); INSERT INTO source_lineage_hold VALUES(1,zeroblob(33),'old',1);",nil,nil,nil),SQLITE_OK)
        XCTAssertThrowsError(try SignedRollbackTransaction.validateCompatibility(database:db))
        XCTAssertNoThrow(try SignedRollbackTransaction.validateCompatibility(database:db,allowProtectedDeletions:true))
        let backup=base.appendingPathComponent("backup.sqlite")
        try ArchiveDatabaseSafety.backup(db,to:backup)
        let original=try journal.pending()
        try SignedRollbackTransaction.preparePredecessorDatabase(database:db,allowProtectedDeletions:true)
        XCTAssertEqual(try journal.pending().map(\.id),[ordinary])
        XCTAssertEqual(try ChangeJournal(path:backup.path,readOnly:true).pending(),original)
        XCTAssertNotNil(try journal.mirrorBlockReason())
        var q:OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,"SELECT job_id,relative_path,original_completed FROM rollback_protected_deletions;",-1,&q,nil),SQLITE_OK)
        defer { sqlite3_finalize(q) }
        XCTAssertEqual(sqlite3_step(q),SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(q,0),protected)
        XCTAssertEqual(String(cString:sqlite3_column_text(q,1)),"old/child.jpg")
        XCTAssertEqual(sqlite3_column_int(q,2),0)
        XCTAssertEqual(sqlite3_step(q),SQLITE_DONE)
        XCTAssertNoThrow(try SignedRollbackTransaction.validateCompatibility(database:db))
    }
}
