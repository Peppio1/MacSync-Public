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
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),1)
            // Repeat late and duplicate old-path observations. They may not
            // fork a root exception or discard the most recent association.
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:bad,eventID:4)
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:original,eventID:4)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE current_path='phone ';"),1)
            // Content edits and ordinary queue semantics remain authoritative.
            try Data([88,99]).write(to:next.appendingPathComponent("sub/photo-0.jpg"))
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:next,eventID:5)
            try fm.moveItem(at:next,to:original)
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:next,eventID:6)
            _=try reopened.reconcile(rootID:"photos",root:source,subtree:original,eventID:7)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND state='returned';"),1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),1)
            XCTAssertFalse(try journal.pending(limit:100).contains{$0.relativePath=="phone" && $0.kind == .delete})
            var handle:OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
            let db=try XCTUnwrap(handle)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db,"BEGIN;",nil,nil,nil),SQLITE_OK)
            let summary=try XCTUnwrap(try SelectiveNameExceptionStore.restorationSummary(db,root:"photos",originalPath:"phone"))
            XCTAssertEqual(summary.capturedFiles,8)
            XCTAssertEqual(summary.unchangedMetadata,7)
            XCTAssertEqual(summary.changedOrReplaced,1)
            XCTAssertEqual(summary.absent,0)
            XCTAssertEqual(summary.newFiles,0)
            XCTAssertEqual(sqlite3_exec(db,"COMMIT;",nil,nil,nil),SQLITE_OK)
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

    func testConsecutiveNewFirstMovesAndReusedIntermediateSpelling()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let original=source.appendingPathComponent("phone")
            let one=source.appendingPathComponent("phone.")
            let two=source.appendingPathComponent("phone ")
            let three=source.appendingPathComponent("phone?")
            let moves=[(original,one),(one,two),(two,three)]
            for (index,move) in moves.enumerated() {
                try fm.moveItem(at:move.0,to:move.1)
                _=try inventory.reconcile(rootID:"photos",root:source,subtree:move.1,eventID:UInt64(index*2+1))
                _=try inventory.reconcile(rootID:"photos",root:source,subtree:move.0,eventID:UInt64(index*2+2))
                XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),1)
                XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_detached;"),10)
                for job in try journal.pending(limit:100) where job.kind == .delete {
                    XCTAssertFalse(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath))
                }
            }
            try fm.createDirectory(at:one,withIntermediateDirectories:false)
            try Data([99]).write(to:one.appendingPathComponent("other.jpg"))
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:one,eventID:7)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),2)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND current_path='phone?';"),1)
            try fm.moveItem(at:three,to:original)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:8)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:three,eventID:9)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND current_path='phone' AND state='returned';"),1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone.' AND current_path='phone.';"),1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),2)
            for k in 0..<8 {
                XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-\(k).jpg")),Data([UInt8(k)]))
            }
        }
    }

    func testRestorationComparisonPreservesChangedRemovedAndAddedFiles()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let original=source.appendingPathComponent("phone"),bad=source.appendingPathComponent("phone.")
            try fm.moveItem(at:original,to:bad)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:1)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:2)
            let sub=bad.appendingPathComponent("sub")
            try Data([101,102]).write(to:sub.appendingPathComponent("photo-0.jpg"))
            try fm.removeItem(at:sub.appendingPathComponent("photo-1.jpg"))
            try Data([103]).write(to:sub.appendingPathComponent("new.jpg"))
            try Data([104]).write(to:sub.appendingPathComponent("photo-2.jpg"),options:.atomic)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:3)
            try fm.moveItem(at:bad,to:original)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:4)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:5)
            var handle:OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
            let db=try XCTUnwrap(handle)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db,"BEGIN;",nil,nil,nil),SQLITE_OK)
            let summary=try XCTUnwrap(try SelectiveNameExceptionStore.restorationSummary(db,root:"photos",originalPath:"phone"))
            XCTAssertEqual(summary.capturedFiles,8)
            XCTAssertEqual(summary.unchangedMetadata,5)
            XCTAssertEqual(summary.changedOrReplaced,2)
            XCTAssertEqual(summary.absent,1)
            XCTAssertEqual(summary.newFiles,1)
            XCTAssertEqual(sqlite3_exec(db,"COMMIT;",nil,nil,nil),SQLITE_OK)
            let jobs=try journal.pending(limit:100)
            for name in ["photo-0.jpg","photo-2.jpg","new.jpg"] {
                XCTAssertTrue(jobs.contains{$0.relativePath=="phone/sub/"+name && $0.kind == .upsert})
            }
            let deletion=try XCTUnwrap(jobs.first{$0.relativePath=="phone/sub/photo-1.jpg" && $0.kind == .delete})
            XCTAssertFalse(try journal.deletionIsCurrent(id:deletion.id,rootID:"photos",relativePath:deletion.relativePath))
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-1.jpg")),Data([1]))
        }
    }

    func testProvenNewInvalidJobsRetireWithoutInventingDeletes()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let bad=source.appendingPathComponent("fresh?"),fixed=source.appendingPathComponent("fresh")
            // Separate creation from the persisted initial scan timestamp.
            Thread.sleep(forTimeInterval:0.03)
            try fm.createDirectory(at:bad,withIntermediateDirectories:false)
            try Data([8]).write(to:bad.appendingPathComponent("file.jpg"))
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_invalid_upload;"),2)
            try fm.moveItem(at:bad,to:fixed)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:2)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:fixed,eventID:3)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_invalid_upload;"),0)
            XCTAssertFalse(try journal.pending(limit:100).contains{$0.relativePath.hasPrefix("fresh?")})
            XCTAssertTrue(try journal.pending(limit:100).contains{$0.relativePath=="fresh/file.jpg" && $0.kind == .upsert})
            // A manually seeded legacy target spelling is not evidence of
            // prior publication by MacSync and must not be deleted blindly.
            try fm.createDirectory(at:target.appendingPathComponent("fresh?"),withIntermediateDirectories:false)
            try Data([9]).write(to:target.appendingPathComponent("fresh?/legacy.jpg"))
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("fresh?/legacy.jpg")),Data([9]))
            XCTAssertGreaterThan(try scalar(path,"SELECT COUNT(*) FROM selective_name_guard WHERE path='fresh?';"),0)
        }
    }

    func testActualDeletionNeedsCompleteCurrentScanAndNoMovedDescendants()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let original=source.appendingPathComponent("phone")
            let outside=source.appendingPathComponent("independent.jpg")
            try fm.moveItem(at:original.appendingPathComponent("sub/photo-0.jpg"),to:outside)
            try fm.removeItem(at:original)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:1)
            let first=try XCTUnwrap(try journal.lineageAbsenceSnapshot(rootID:"photos"))
            let rows=try LocalScanner.scan(root:source)
            try journal.resolveLineageMissing(rootID:"photos",rows:rows,snapshot:first,shouldContinue:{true})
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),1)
            let delete=try XCTUnwrap(journal.pending(limit:100).first{$0.relativePath=="phone/sub/photo-0.jpg" && $0.kind == .delete})
            XCTAssertFalse(try journal.deletionIsCurrent(id:delete.id,rootID:delete.rootID,relativePath:delete.relativePath))
            try fm.removeItem(at:outside)
            // A newer inventory checkpoint invalidates the old scan proof.
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:outside,eventID:2)
            try journal.resolveLineageMissing(rootID:"photos",rows:try LocalScanner.scan(root:source),snapshot:first,shouldContinue:{true})
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),1)
            let current=try XCTUnwrap(try journal.lineageAbsenceSnapshot(rootID:"photos"))
            try journal.resolveLineageMissing(rootID:"photos",rows:try LocalScanner.scan(root:source),snapshot:current,shouldContinue:{true})
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),0)
            XCTAssertTrue(try journal.deletionIsCurrent(id:delete.id,rootID:delete.rootID,relativePath:delete.relativePath))
            // Resolution does not perform any filesystem deletion.
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-0.jpg")),Data([0]))
        }
    }

    func testCleanBaselineRestorationAvoidsCopiesAndLeavesQuickQueueUntouched()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let original=source.appendingPathComponent("phone"),bad=source.appendingPathComponent("phone.")
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_clean_baseline;"),1)
            try fm.moveItem(at:original,to:bad)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_restore_proof;"),10)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:2)
            try fm.moveItem(at:bad,to:original)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:3)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:4)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_restore_proof WHERE restore_job IS NOT NULL;"),10)
            XCTAssertFalse(try journal.pending(limit:100).contains{$0.relativePath.hasPrefix("phone.")})
            let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
            let ids=try journal.pending(limit:100).map(\.id)
            let report=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
            XCTAssertEqual(report.bytesRead,0)
            XCTAssertEqual(try journal.pending(limit:100).map(\.id),ids)
            let log=try SyncActivityLog(path:path)
            let worker=try MountedFolderCopyWorker(journal:journal,log:log,mappings:[map],minimumStableAge:0)
            let result=try worker.runCycle(enabled:true)
            XCTAssertEqual(result.copied,0)
            XCTAssertEqual(result.reconciled,10)
            XCTAssertEqual(result.bytes,0)
            XCTAssertTrue(try journal.pending().isEmpty)
            _=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),0)
            for k in 0..<8 {
                XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-\(k).jpg")),Data([UInt8(k)]))
            }
        }
    }

    func testRestorationProofRejectsChangedAndUncertainJobs()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let original=source.appendingPathComponent("phone"),bad=source.appendingPathComponent("phone.")
            try fm.moveItem(at:original,to:bad)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:1)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:2)
            try Data([90,91]).write(to:bad.appendingPathComponent("sub/photo-0.jpg"))
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:3)
            try fm.moveItem(at:bad,to:original)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:4)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:5)
            let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
            let jobs=try journal.pending(limit:100)
            let changed=try XCTUnwrap(jobs.first{$0.relativePath=="phone/sub/photo-0.jpg" && $0.kind == .upsert})
            let unchanged=try XCTUnwrap(jobs.first{$0.relativePath=="phone/sub/photo-1.jpg" && $0.kind == .upsert})
            XCTAssertFalse(try journal.selectiveRestoredCandidate(changed,mapping:map))
            XCTAssertTrue(try journal.selectiveRestoredCandidate(unchanged,mapping:map))
            try journal.recordPublicationIntent(unchanged)
            XCTAssertFalse(try journal.selectiveRestoredCandidate(unchanged,mapping:map))
            XCTAssertGreaterThan(try scalar(path,"SELECT COUNT(*) FROM selective_name_guard;"),0)
            try journal.clearPublicationIntent(unchanged)
            XCTAssertTrue(try journal.selectiveRestoredCandidate(unchanged,mapping:map))
            // A genuine new modification supersedes the exact marked job.
            try Data([88,89]).write(to:original.appendingPathComponent("sub/photo-1.jpg"))
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:6)
            XCTAssertFalse(try journal.selectiveRestoredCandidate(unchanged,mapping:map))
            let new=try XCTUnwrap(journal.pending(limit:100).first{$0.relativePath=="phone/sub/photo-1.jpg" && $0.kind == .upsert})
            XCTAssertFalse(try journal.selectiveRestoredCandidate(new,mapping:map))
        }
    }

    func testPersistedSelectiveModeWithNativeFSEventsAndRestart()throws {
        try lab { source,target,path,_,_ in
            let ready=expectation(description:"Monitor ready")
            ready.assertForOverFulfill=false
            let monitor=LocalMonitorService { update in
                print("SELECTIVE_MONITOR active=\(update.monitoring) pending=\(update.pendingChanges) message=\(update.message)")
                if update.monitoring { ready.fulfill() }
            }
            monitor.start(roots:[MonitorRoot(id:"photos",url:source)],databasePath:path)
            defer {
                monitor.stop()
                let stopped=expectation(description:"Monitor stopped")
                monitor.afterStopped{stopped.fulfill()}
                wait(for:[stopped],timeout:12)
            }
            wait(for:[ready],timeout:15)
            XCTAssertTrue(monitor.safetyGate.isReady)
            // As in the standalone watcher test, allow the stream to start
            // delivering its initial historical marker before mutation.
            Thread.sleep(forTimeInterval:0.3)
            func eventually(_ query:String,_ expected:Int64)throws {
                let deadline=Date().addingTimeInterval(15)
                repeat {
                    if (try? scalar(path,query))==expected { return }
                    Thread.sleep(forTimeInterval:0.1)
                } while Date()<deadline
                let entries=try SyncActivityLog(path:path).recent(limit:20)
                for entry in entries {
                    print("SELECTIVE_MONITOR_LOG action=\(entry.action) message=\(entry.message)")
                }
                print("SELECTIVE_MONITOR_TIMEOUT ready=\(monitor.safetyGate.isReady) query=\(query)")
                XCTAssertEqual(try scalar(path,query),expected)
            }
            let original=source.appendingPathComponent("phone"),bad=source.appendingPathComponent("phone.")
            try FileManager.default.moveItem(at:original,to:bad)
            try eventually("SELECT COUNT(*) FROM file_inventory WHERE root_id='photos' AND relative_path='phone.';",1)
            try eventually("SELECT COUNT(*) FROM selective_name_exception WHERE current_path='phone.';",1)
            XCTAssertGreaterThan(try scalar(path,"SELECT COUNT(*) FROM selective_name_guard;"),0)
            try FileManager.default.moveItem(at:bad,to:original)
            try eventually("SELECT COUNT(*) FROM file_inventory WHERE root_id='photos' AND relative_path='phone';",1)
            try eventually("SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND state='returned';",1)
            XCTAssertTrue(monitor.safetyGate.isReady)
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-0.jpg")),Data([0]))
        }
    }

    func testSingleParentScanRetiresOnlyProvenInvalidJobs()throws {
        try lab { source,target,path,inventory,journal in
            let fm=FileManager.default
            let root=source.appendingPathComponent("phone"),bad=source.appendingPathComponent("phone.")
            try fm.moveItem(at:root,to:bad)
            _=try inventory.reconcile(rootID:"photos",root:source,eventID:1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND current_path='phone.';"),1)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_invalid_upload;"),10)
            for job in try journal.pending(limit:100) where job.kind == .delete {
                XCTAssertFalse(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath))
            }
            try fm.moveItem(at:bad,to:root)
            _=try inventory.reconcile(rootID:"photos",root:source,eventID:2)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception WHERE original_path='phone' AND state='returned';"),1)
            XCTAssertFalse(try journal.pending(limit:100).contains{$0.relativePath.hasPrefix("phone.")})
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_invalid_upload;"),0)
            XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_retired_invalid;"),1)
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-0.jpg")),Data([0]))
        }
    }

    func testMonitorPathKeepsRenamedAwayLeafThroughParentAlias()throws {
        try lab { source,_,_,_,_ in
            let alias=source.deletingLastPathComponent().appendingPathComponent("source-link")
            try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:source)
            let roots=[MonitorRoot(id:"photos",url:source)]
            let missing=alias.appendingPathComponent("missing.").path
            let match=try XCTUnwrap(LocalMonitorService.eventURL(missing,roots:roots))
            XCTAssertEqual(match.0.id,"photos")
            XCTAssertEqual(match.1.path,source.appendingPathComponent("missing.").path)
            XCTAssertNil(LocalMonitorService.eventURL(source.path+"-outside/file",roots:roots))
        }
    }

    func testIntelligentAuditDoesNotConsumeNewerSourceJob()throws {
        try lab { source,target,_,inventory,journal in
            let file=source.appendingPathComponent("phone/sub/photo-0.jpg")
            try Data([44]).write(to:file)
            _=try inventory.reconcile(rootID:"photos",root:source,subtree:file,eventID:1)
            let before=try journal.pending()
            let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
            _=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.intelligent,repair:true)
            XCTAssertTrue(try journal.pending().contains{$0.id==before.first?.id})
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("phone/sub/photo-0.jpg")),Data([0]))
        }
    }

    func testRepeated1200ManualCorrectionsPreserveNewFiles()throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_SELECTIVE_BULK"]=="1" else { throw XCTSkip("Bulk selective lab opt-in") }
        try lab { source,_,path,inventory,journal in
            let fm=FileManager.default
            for batch in 0..<2 {
                let root=source.appendingPathComponent("batch-\(batch)")
                try fm.createDirectory(at:root,withIntermediateDirectories:false)
                // Ensure the batch root is known before creating new
                // incompatible file identities; only these may be retired.
                _=try inventory.reconcile(rootID:"photos",root:source,subtree:root,eventID:UInt64(batch*3+1))
                Thread.sleep(forTimeInterval:0.03)
                let start=ProcessInfo.processInfo.systemUptime
                for index in 0..<1200 {
                    try Data("batch-\(batch)-\(index)".utf8).write(to:root.appendingPathComponent("photo-\(index).jpg."))
                }
                _=try inventory.reconcile(rootID:"photos",root:source,subtree:root,eventID:UInt64(batch*3+2))
                for index in 0..<1200 {
                    try fm.moveItem(at:root.appendingPathComponent("photo-\(index).jpg."),to:root.appendingPathComponent("photo-\(index).jpg"))
                }
                _=try inventory.reconcile(rootID:"photos",root:source,subtree:root,eventID:UInt64(batch*3+3))
                XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM change_queue WHERE completed=0 AND relative_path LIKE 'batch-\(batch)/%' AND kind='upsert';"),1200)
                XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM change_queue WHERE completed=0 AND relative_path LIKE 'batch-\(batch)/%' AND kind='delete';"),0)
                for index in 0..<1200 {
                    XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("photo-\(index).jpg")),Data("batch-\(batch)-\(index)".utf8))
                }
                print("SELECTIVE_BULK batch=\(batch+1) names=1200 seconds=\(ProcessInfo.processInfo.systemUptime-start)")
            }
            let reopened=try ChangeJournal(path:path)
            XCTAssertEqual(try reopened.pending(limit:10000).filter{$0.kind == .upsert && $0.relativePath.hasPrefix("batch-")}.count,2402)
            XCTAssertEqual(try journal.pending(limit:10000).filter{$0.kind == .delete}.count,0)
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
