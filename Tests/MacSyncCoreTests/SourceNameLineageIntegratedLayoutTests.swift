import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SourceNameLineageIntegratedLayoutTests: XCTestCase {
    private func scalar(_ path:String,_ sql:String)throws->Int64 {
        var connection:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path,&connection,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        let db=try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        var query:OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,sql,-1,&query,nil),SQLITE_OK)
        let q=try XCTUnwrap(query)
        defer { sqlite3_finalize(q) }
        XCTAssertEqual(sqlite3_step(q),SQLITE_ROW)
        return sqlite3_column_int64(q,0)
    }

    func testCompactIdentityDetachReopenReplacementAndRollback() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("target")
        let name="old.jpg",date=Date(timeIntervalSince1970:1_700_000_000)
        for root in [source,target] {
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            let url=root.appendingPathComponent(name)
            try Data([1]).write(to:url)
            try fm.setAttributes([.modificationDate:date],ofItemAtPath:url.path)
        }
        let db=base.appendingPathComponent("state.sqlite")
        var inventory=try LocalInventory(path:db.path)
        var journal=try ChangeJournal(path:db.path)
        inventory.experimentalInventoryLineageLayout=false
        inventory.experimentalSourceNameLineage=true
        inventory.experimentalLineageQueueProtection=true
        journal.experimentalSourceNameLineage=true
        _=try inventory.reconcile(rootID:"photos",root:source,origin:.initialInventory)
        let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        _=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM source_lineage_index;"),1)
        XCTAssertTrue(try journal.pending().isEmpty)

        // Additive migration of an existing legacy candidate, with no
        // synthetic completion or rewrite of a real queue.
        inventory.experimentalInventoryLineageLayout=true
        _=try inventory.reconcile(rootID:"photos",root:source)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM file_inventory WHERE lineage_mapping_id IS NOT NULL;"),1)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM source_lineage_index;"),0)
        XCTAssertTrue(try journal.pending().isEmpty)
        let old=source.appendingPathComponent(name),bad=source.appendingPathComponent(name+" ")
        try fm.moveItem(at:old,to:bad)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:old,eventID:1)
        let deletion=try XCTUnwrap(journal.pending().first{$0.relativePath==name && $0.kind == .delete})
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM source_lineage_index;"),1)
        XCTAssertFalse(try journal.deletionIsCurrent(id:deletion.id,rootID:deletion.rootID,relativePath:deletion.relativePath))
        inventory=try LocalInventory(path:db.path)
        journal=try ChangeJournal(path:db.path)
        inventory.experimentalSourceNameLineage=true
        inventory.experimentalLineageQueueProtection=true
        // Persistent layout remains readable even with the experimental
        // installation switch disabled after reopen.
        inventory.experimentalInventoryLineageLayout=false
        journal.experimentalSourceNameLineage=true
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:2)
        try Data([2]).write(to:old)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:old,eventID:3)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM source_lineage_records;"),2)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM file_inventory WHERE lineage_mapping_id IS NOT NULL AND lineage_evidence=0;"),1)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM source_lineage_hold WHERE protected_path='old.jpg';"),1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)),Data([1]))
        let backup=base.appendingPathComponent("backup.sqlite")
        try ArchiveDatabaseSafety.backup(db,to:backup)
        try SignedRollbackTransaction.validateCompatibility(database:db,allowProtectedDeletions:true)
        try SignedRollbackTransaction.preparePredecessorDatabase(database:db,allowProtectedDeletions:true)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM pragma_table_info('file_inventory');"),6)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM sqlite_master WHERE name='source_lineage_records';"),0)
        XCTAssertEqual(try scalar(backup.path,"SELECT COUNT(*) FROM source_lineage_records;"),2)
        XCTAssertEqual(try scalar(db.path,"SELECT COUNT(*) FROM file_inventory;"),2)
        XCTAssertNoThrow(try SignedRollbackTransaction.validateCompatibility(database:db))
    }
}
