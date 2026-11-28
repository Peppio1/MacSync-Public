import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SelectiveNameExceptionTests:XCTestCase {
    private func scalar(_ path:String,_ sql:String)throws->Int64 {
        var handle:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        let db=try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        var statement:OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,sql,-1,&statement,nil),SQLITE_OK)
        let q=try XCTUnwrap(statement)
        defer { sqlite3_finalize(q) }
        XCTAssertEqual(sqlite3_step(q),SQLITE_ROW)
        return sqlite3_column_int64(q,0)
    }
    private func lab(_ body:(URL,URL,String,LocalInventory,ChangeJournal)throws->Void)throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("target")
        let path=base.appendingPathComponent("state.sqlite").path
        let fixed=Date(timeIntervalSince1970:1_700_000_000)
        for root in [source,target] {
            let sub=root.appendingPathComponent("phone/sub")
            try fm.createDirectory(at:sub,withIntermediateDirectories:true)
            for k in 0..<8 {
                let file=sub.appendingPathComponent("photo-\(k).jpg")
                try Data([UInt8(k)]).write(to:file)
                try fm.setAttributes([.modificationDate:fixed],ofItemAtPath:file.path)
            }
        }
        let inventory=try LocalInventory(path:path),journal=try ChangeJournal(path:path)
        inventory.experimentalSourceNameLineage=false
        inventory.experimentalLineageQueueProtection=false
        inventory.experimentalSelectiveNameExceptions=true
        journal.experimentalSourceNameLineage=false
        _=try inventory.reconcile(rootID:"photos",root:source,origin:.initialInventory)
        let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        let report=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
        XCTAssertEqual(report.bytesRead,0)
        XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM source_lineage_records;"),0)
        XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),0)
        try body(source,target,path,inventory,journal)
    }

    func testOldFirstDirectoryExcursionPersistsOneRootAndProtectsDescendants()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let original=source.appendingPathComponent("phone"),bad=source.appendingPathComponent("phone.")
            try fm.moveItem(at:original,to:bad)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_detached;"),10)
            let pending=try journal.pending(limit:100)
            XCTAssertEqual(pending.filter{$0.kind == .delete}.count,10)
            let reopenedJournal=try ChangeJournal(path:path)
            for job in pending where job.kind == .delete {
                XCTAssertFalse(try reopenedJournal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath))
                XCTAssertFalse(try reopenedJournal.acknowledgeDeletion(id:job.id,rootID:job.rootID,relativePath:job.relativePath))
            }
            let reopened=try LocalInventory(path:path)
            reopened.experimentalSourceNameLineage=false
            reopened.experimentalLineageQueueProtection=false
            // The persisted laboratory mode continues to observe after reopen.
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:bad,eventID:2)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE state='incompatible' AND current_path='phone.';"),1)
            let next=source.appendingPathComponent("phone ")
            try fm.moveItem(at:bad,to:next)
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:next,eventID:3)
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:bad,eventID:4)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND current_path='phone ';"),1)
            // Content edits and ordinary queue semantics remain authoritative.
            try Data([88,99]).write(to:next.appendingPathComponent("sub/photo-0.jpg"))
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:next,eventID:5)
            try fm.moveItem(at:next,to:original)
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:next,eventID:6)
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:original,eventID:7)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND state='returned';"),1)
            XCTAssertTrue(try journal.pending(limit:100).contains{$0.relativePath=="phone/sub/photo-0.jpg" && $0.kind == .upsert})
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-0.jpg")),Data([0]))
            // Capture/veto only: never retire a hold or discard jobs on a
            // metadata match, timeout, or mere same-directory identity.
            XCTAssertGreaterThan(try scalar(path,"SELECT COUNT(*) FROM selective_name_guard;"),0)
        }
    }

    func testNewFirstAndNameReuseDoNotAuthorizeOldDeletion()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let old=source.appendingPathComponent("phone"),bad=source.appendingPathComponent("phone?")
            try fm.moveItem(at:old,to:bad)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND current_path='phone?';"),1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_detached;"),10)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:old,eventID:2)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),1)
            for job in try journal.pending(limit:100) where job.kind == .delete {
                XCTAssertFalse(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath))
            }
            try fm.createDirectory(at:old,withIntermediateDirectories:false)
            try Data([99]).write(to:old.appendingPathComponent("replacement.jpg"))
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:old,eventID:3)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND current_path='phone?';"),1)
            XCTAssertTrue(try journal.pending(limit:100).contains{$0.relativePath=="phone/replacement.jpg" && $0.kind == .upsert})
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-0.jpg")),Data([0]))
        }
    }

    func testNewInvalidAndRollbackRetainEvidenceWithoutAssumingRemoteAbsence()throws {
        try lab { source,_,path,inventory,journal in
            let fm=FileManager.default
            let bad=source.appendingPathComponent("new:"),fixed=source.appendingPathComponent("new")
            try fm.createDirectory(at:bad,withIntermediateDirectories:false)
            try Data([3]).write(to:bad.appendingPathComponent("file.jpg"))
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='new:';"),1)
            try fm.moveItem(at:bad,to:fixed)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:2)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:fixed,eventID:3)
            XCTAssertTrue(try journal.pending(limit:100).contains{$0.relativePath=="new/file.jpg" && $0.kind == .upsert})
            let db=URL(fileURLWithPath:path),backup=db.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
            try ArchiveDatabaseSafety.backup(db,to:backup)
            XCTAssertThrowsError(try SignedRollbackTransaction.validateCompatibility(database:db))
            try SignedRollbackTransaction.validateCompatibility(database:db,allowProtectedDeletions:true)
            try SignedRollbackTransaction.preparePredecessorDatabase(database:db,allowProtectedDeletions:true)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM pragma_table_info('file_inventory');"),6)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM sqlite_master WHERE name='selective_name_exception';"),0)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM mirror_safety_lock;"),1)
            XCTAssertGreaterThan(try scalar(backup.path,"SELECT COUNT(*) FROM selective_name_exception;"),0)
            XCTAssertNoThrow(try SignedRollbackTransaction.validateCompatibility(database:db))
        }
    }
}
