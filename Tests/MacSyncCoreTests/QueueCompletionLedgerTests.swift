import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class QueueCompletionLedgerTests:XCTestCase {
    private func fixture(_ body:(String,OpaquePointer)throws->Void)throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("queue.sqlite").path
        var handle:OpaquePointer?
        XCTAssertEqual(sqlite3_open(path,&handle),SQLITE_OK)
        let db=try XCTUnwrap(handle)
        defer {sqlite3_close(db)}
        sqlite3_busy_timeout(db,1000)
        try body(path,db)
    }
    private func exec(_ db:OpaquePointer,_ sql:String)throws {
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {
            throw JournalError.database(String(cString:sqlite3_errmsg(db)))
        }
    }
    private func time(_ db:OpaquePointer,_ id:Int64)throws->Double? {
        var stmt:OpaquePointer?
        defer {if let stmt {sqlite3_finalize(stmt)}}
        guard sqlite3_prepare_v2(db,"SELECT completed_at FROM queue_completion_ledger WHERE job_id=?;",-1,&stmt,nil)==SQLITE_OK,
              let stmt,sqlite3_bind_int64(stmt,1,id)==SQLITE_OK else {throw JournalError.database("ledger query")}
        let rc=sqlite3_step(stmt)
        if rc==SQLITE_DONE {return nil}
        guard rc==SQLITE_ROW else {throw JournalError.database("ledger step")}
        return sqlite3_column_double(stmt,0)
    }
    func testCompletionUsesTransitionNotEnqueueTimeAndDoesNotResetOnRepeatedAcknowledgment()throws {
        try fixture {path,db in
            let journal=try ChangeJournal(path:path)
            let id=try journal.enqueue(rootID:"demo",relativePath:"old.jpg",kind:.upsert)
            try exec(db,"UPDATE change_queue SET recorded_at=1 WHERE id=\(id);")
            XCTAssertNil(try time(db,id))
            let start=Date().timeIntervalSince1970
            try journal.markCompleted(id:id)
            let first=try XCTUnwrap(try time(db,id))
            XCTAssertGreaterThanOrEqual(first,start-1)
            XCTAssertLessThanOrEqual(first,Date().timeIntervalSince1970+1)
            try journal.markCompleted(id:id)
            XCTAssertEqual(try time(db,id),first)
            XCTAssertTrue(try journal.pending().isEmpty)
            try exec(db,"UPDATE change_queue SET completed=0 WHERE id=\(id);")
            XCTAssertNil(try time(db,id))
            XCTAssertEqual(try journal.pending().map(\.id),[id])
            try journal.markCompleted(id:id)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(try time(db,id)),first)
            try exec(db,"DELETE FROM change_queue WHERE id=\(id);")
            XCTAssertNil(try time(db,id))
        }
    }
    func testInventoryFirstAndLegacyUnknownCompletionAndRollbackTransaction()throws {
        try fixture {path,db in
            // Exact predecessor queue layout with an already completed row.
            try exec(db,"""
                CREATE TABLE change_queue(
                id INTEGER PRIMARY KEY AUTOINCREMENT,root_id TEXT NOT NULL,relative_path TEXT NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN ('upsert','delete')),recorded_at REAL NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,origin TEXT NOT NULL DEFAULT 'legacy_unknown');
                INSERT INTO change_queue(root_id,relative_path,kind,recorded_at,completed)
                VALUES('demo','legacy.jpg','upsert',1,1);
                """)
            _=try LocalInventory(path:path)
            let journal=try ChangeJournal(path:path)
            XCTAssertNil(try time(db,1),"Do not infer completion time from recorded_at")
            let id=try journal.enqueue(rootID:"demo",relativePath:"pending.jpg",kind:.delete)
            try exec(db,"BEGIN IMMEDIATE; UPDATE change_queue SET completed=1 WHERE id=\(id);")
            XCTAssertNotNil(try time(db,id))
            try exec(db,"ROLLBACK;")
            XCTAssertNil(try time(db,id))
            XCTAssertEqual(try journal.pending().map(\.id),[id])
            try journal.markCompleted(id:id)
            XCTAssertNotNil(try time(db,id))
            _=try ChangeJournal(path:path)
            XCTAssertNotNil(try time(db,id))
            XCTAssertNil(try time(db,1))
        }
    }
    func testRetentionPreservesProtectedJobsAndPathWatermarks()throws {
        try fixture {path,db in
            let journal=try ChangeJournal(path:path)
            func add(_ name:String,_ kind:ChangeKind = .upsert,completed:Bool=true)throws->Int64 {
                let id=try journal.enqueue(rootID:"demo",relativePath:name,kind:kind)
                if completed {try journal.markCompleted(id:id)}
                return id
            }
            let obsolete=try add("repeat.jpg")
            let watermark=try add("repeat.jpg")
            let pendingOld=try add("pending.jpg")
            let pending=try add("pending.jpg",completed:false)
            let retired=try add("deleted.jpg",.delete)
            _=try add("deleted.jpg",.delete)
            let link=try add("rectified.jpg")
            _=try add("rectified.jpg")
            let recovery=try add("recover.jpg")
            _=try add("recover.jpg")
            let fresh=try add("fresh.jpg")
            _=try add("fresh.jpg")
            let unknown=try add("unknown.jpg")
            _=try add("unknown.jpg")
            try exec(db,"UPDATE queue_completion_ledger SET completed_at=1 WHERE job_id<>\(fresh);")
            try exec(db,"INSERT INTO retired_delete_evidence(job_id) VALUES(\(retired));")
            try exec(db,"INSERT INTO name_rectification_monitor_links(job_id,receipt_id) VALUES(\(link),123);")
            try exec(db,"INSERT INTO transfer_recovery(job_id,root_id,relative_path,record) VALUES(\(recovery),'demo','recover.jpg','{}');")
            try exec(db,"DELETE FROM queue_completion_ledger WHERE job_id=\(unknown);")
            let sequence=try journal.queueSequence()
            XCTAssertEqual(try journal.pruneCompletedQueueBatch(limit:1),1)
            XCTAssertNil(try time(db,obsolete))
            for id in [watermark,pendingOld,retired,link,recovery,fresh] { XCTAssertNotNil(try time(db,id),"Protected record \(id)") }
            XCTAssertEqual(try journal.pruneCompletedQueueBatch(),0)
            XCTAssertEqual(try journal.queueSequence(),sequence)
            XCTAssertEqual(try journal.pending().map(\.id),[pending])
            XCTAssertEqual(try ChangeJournal(path:path).pruneCompletedQueueBatch(),0)
        }
    }

    func testRetentionCancellationAndRebuildHoldAreNonMutating()throws {
        try fixture {path,db in
            let journal=try ChangeJournal(path:path)
            let old=try journal.enqueue(rootID:"demo",relativePath:"repeat.jpg",kind:.upsert)
            let newer=try journal.enqueue(rootID:"demo",relativePath:"repeat.jpg",kind:.upsert)
            try journal.markCompleted(id:old)
            try journal.markCompleted(id:newer)
            try exec(db,"UPDATE queue_completion_ledger SET completed_at=1;")
            var calls=0
            XCTAssertThrowsError(try journal.pruneCompletedQueueBatch(shouldContinue:{calls+=1;return calls<3}))
            XCTAssertNotNil(try time(db,old))
            try exec(db,"INSERT INTO queue_rebuild_hold(singleton,token) VALUES(1,'fixture');")
            XCTAssertEqual(try journal.pruneCompletedQueueBatch(),0)
            XCTAssertNotNil(try time(db,old))
            try exec(db,"DELETE FROM queue_rebuild_hold;")
            XCTAssertEqual(try journal.pruneCompletedQueueBatch(),1)
            XCTAssertNotNil(try time(db,newer))
        }
    }

    func testRetentionCursorPassesProtectedPrefix()throws {
        try fixture {path,db in
            let journal=try ChangeJournal(path:path)
            for i in 0..<12 {
                let id=try journal.enqueue(rootID:"demo",relativePath:"unique-\(i).jpg",kind:.upsert)
                try journal.markCompleted(id:id)
            }
            let old=try journal.enqueue(rootID:"demo",relativePath:"repeat.jpg",kind:.upsert)
            let newer=try journal.enqueue(rootID:"demo",relativePath:"repeat.jpg",kind:.upsert)
            try journal.markCompleted(id:old)
            try journal.markCompleted(id:newer)
            try exec(db,"UPDATE queue_completion_ledger SET completed_at=1;")
            var cursor:Int64=0
            var removed=0,examined=0
            for _ in 0..<10 {
                let page=try journal.pruneCompletedQueuePage(afterID:cursor,limit:3)
                XCTAssertFalse(page.held)
                XCTAssertLessThanOrEqual(page.examined,3)
                removed+=page.removed;examined+=page.examined
                cursor=page.nextAfterID
                if page.finished {break}
            }
            XCTAssertEqual(examined,14)
            XCTAssertEqual(removed,1)
            XCTAssertNil(try time(db,old))
            XCTAssertNotNil(try time(db,newer))
        }
    }

    func testReceiptRetentionPreservesLatestLinkedAndUnscanned()throws {
        try fixture {path,db in
            let source=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("source")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            let inventory=try LocalInventory(path:path)
            _=try inventory.reconcile(rootID:"demo",root:source)
            let journal=try ChangeJournal(path:path)
            let binding=try DirectoryBinding.read(source)
            let oldDate=Date().addingTimeInterval(-100*86400)
            func receipt(_ name:String,_ date:Date)throws->Int64 {
                let r=NameRectificationReceipt(rootID:"demo",oldPath:name,newPath:name+"-",isDirectory:false,
                    sourceRoot:source.path,sourceBinding:binding,inode:1,birthSeconds:1,birthNanos:0,
                    context:NameRectificationContext(plannedAt:date,queueSequence:0,targetBinding:nil),completedAt:date)
                let encoded=String(decoding:try JSONEncoder().encode(r),as:UTF8.self).replacingOccurrences(of:"'",with:"''")
                try exec(db,"INSERT INTO name_rectification_receipts(root_id,old_path,new_path,receipt) VALUES('demo','\(name)','\(name)-','\(encoded)');")
                return sqlite3_last_insert_rowid(db)
            }
            let obsolete=try receipt("repeat.",oldDate)
            let latest=try receipt("repeat.",oldDate)
            let linked=try receipt("linked.",oldDate)
            _=try receipt("linked.",oldDate)
            let recent=try receipt("recent.",Date())
            _=try receipt("recent.",Date())
            let job=try journal.enqueue(rootID:"demo",relativePath:"linked.",kind:.delete)
            try journal.markCompleted(id:job)
            try exec(db,"INSERT INTO name_rectification_monitor_links(job_id,receipt_id) VALUES(\(job),\(linked));")
            try exec(db,"UPDATE watched_roots SET last_scan_at=1 WHERE root_id='demo';")
            XCTAssertEqual(try journal.pruneRectificationReceiptPage().removed,0)
            try exec(db,"UPDATE watched_roots SET last_scan_at=strftime('%s','now') WHERE root_id='demo';")
            let page=try journal.pruneRectificationReceiptPage()
            XCTAssertEqual(page.removed,1)
            let remaining=try journal.nameRectificationReceipts(rootID:"demo").map(\.id)
            XCTAssertFalse(remaining.contains(obsolete))
            for id in [latest,linked,recent] {XCTAssertTrue(remaining.contains(id))}
            XCTAssertEqual(try journal.rectificationMonitorLink(jobID:job),linked)
        }
    }

    private func scalar(_ db:OpaquePointer,_ sql:String)throws->Int64 {
        var stmt:OpaquePointer?
        defer {if let stmt {sqlite3_finalize(stmt)}}
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK,
              let stmt,sqlite3_step(stmt)==SQLITE_ROW else {
            throw JournalError.database(String(cString:sqlite3_errmsg(db)))
        }
        let value=sqlite3_column_int64(stmt,0)
        guard sqlite3_step(stmt)==SQLITE_DONE else {throw JournalError.database("unexpected scalar result")}
        return value
    }

    /// Opt-in representative *database* workload, no actual file copies.
    /// Two operations per exact path; the newest remains a safety watermark.
    func testRepresentativeRetentionScaleAndPredecessorLayout()throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_RETENTION_SCALE"]=="1" else {
            throw XCTSkip("Representative retention test is opt-in")
        }
        try fixture {path,db in
            let source=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("source")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            _=try LocalInventory(path:path).reconcile(rootID:"demo",root:source)
            let journal=try ChangeJournal(path:path)
            let count=ProcessInfo.processInfo.environment["MACSYNC_RETENTION_ROWS"]=="200000" ? 200000 : 10000
            let half=count/2
            let started=ProcessInfo.processInfo.systemUptime
            try exec(db,"""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<\(count))
                INSERT INTO change_queue(root_id,relative_path,kind,recorded_at,completed,origin)
                SELECT 'demo','photo-'||((n-1)%\(half))||'.jpg','upsert',1,0,'source_monitor' FROM seq;
                COMMIT;
                """)
            let enqueue=ProcessInfo.processInfo.systemUptime-started
            let transition=ProcessInfo.processInfo.systemUptime
            try exec(db,"BEGIN IMMEDIATE; UPDATE change_queue SET completed=1; COMMIT;")
            let completion=ProcessInfo.processInfo.systemUptime-transition
            XCTAssertEqual(try scalar(db,"SELECT count(*) FROM queue_completion_ledger;"),Int64(count))
            let now=Date()
            try exec(db,"UPDATE queue_completion_ledger SET completed_at=1;")
            // Preserve a small set of older rows as explicit retired evidence.
            try exec(db,"INSERT INTO retired_delete_evidence(job_id) SELECT id FROM change_queue WHERE id<=100;")
            let sequence=try journal.queueSequence()
            let before=DatabaseDiagnosticSnapshot.collect(databasePath:path)
            var cursor:Int64=0,removed=0,examined=0,pages=0
            var maxSeconds=0.0
            let sweep=ProcessInfo.processInfo.systemUptime
            while true {
                let started=ProcessInfo.processInfo.systemUptime
                let page=try journal.pruneCompletedQueuePage(afterID:cursor,now:now,limit:250)
                maxSeconds=max(maxSeconds,ProcessInfo.processInfo.systemUptime-started)
                XCTAssertFalse(page.held)
                XCTAssertLessThanOrEqual(page.examined,250)
                removed+=page.removed;examined+=page.examined;pages+=1
                cursor=page.nextAfterID
                if page.finished {break}
                guard pages<=count/250+1 else {throw JournalError.database("retention cursor failed to progress")}
            }
            let sweepSeconds=ProcessInfo.processInfo.systemUptime-sweep
            XCTAssertEqual(examined,count)
            XCTAssertEqual(removed,half-100)
            XCTAssertEqual(try scalar(db,"SELECT count(*) FROM change_queue;"),Int64(half+100))
            XCTAssertEqual(try scalar(db,"SELECT count(*) FROM queue_completion_ledger;"),Int64(half+100))
            XCTAssertEqual(try scalar(db,"SELECT count(*) FROM change_queue WHERE id<=100 OR id>\(half);"),Int64(half+100))
            XCTAssertEqual(try journal.queueSequence(),sequence)
            XCTAssertTrue(try journal.pending().isEmpty)
            let after=DatabaseDiagnosticSnapshot.collect(databasePath:path)
            let url=URL(fileURLWithPath:path)
            try ArchiveDatabaseSafety.verify(url,readOnly:true)
            // The currently reviewed compatibility validator checks the
            // predecessor's operational column layouts. Not an install test.
            try SignedRollbackTransaction.validateCompatibility(database:url)
            let backup=url.deletingLastPathComponent().appendingPathComponent("retention-backup.sqlite")
            try ArchiveDatabaseSafety.backup(url,to:backup)
            try SignedRollbackTransaction.validateCompatibility(database:backup)
            XCTAssertEqual(try ChangeJournal(path:backup.path,readOnly:true).queueSequence(),sequence)
            print("RETENTION_SCALE rows=\(count) enqueueSeconds=\(enqueue) completionSeconds=\(completion) sweepSeconds=\(sweepSeconds) pages=\(pages) maxPageSeconds=\(maxSeconds) removed=\(removed) remaining=\(half+100) beforePages=\(before.pageCount ?? -1) afterPages=\(after.pageCount ?? -1) beforeFree=\(before.freePages ?? -1) afterFree=\(after.freePages ?? -1)")
            if let output=ProcessInfo.processInfo.environment["MACSYNC_RETENTION_COMPAT_DIR"],!output.isEmpty {
                let target=URL(fileURLWithPath:output,isDirectory:true)
                try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
                try FileManager.default.copyItem(at:backup,to:target.appendingPathComponent("retention-backup.sqlite"))
            }
        }
    }

    func testSweepResumesAndHonorsHourlyCadence()throws {
        try fixture {path,db in
            let journal=try ChangeJournal(path:path)
            let first=try journal.enqueue(rootID:"demo",relativePath:"repeat.jpg",kind:.upsert)
            let second=try journal.enqueue(rootID:"demo",relativePath:"repeat.jpg",kind:.upsert)
            try journal.markCompleted(id:first);try journal.markCompleted(id:second)
            try exec(db,"UPDATE queue_completion_ledger SET completed_at=1;")
            var sweep=RetentionSweep()
            var clock=100.0
            let disabled=try sweep.advance(journal:journal,uptime:{clock},shouldContinue:{false})
            XCTAssertFalse(disabled.attempted)
            let part=try sweep.advance(journal:journal,uptime:{clock},shouldContinue:{true},maxPages:1)
            XCTAssertTrue(part.attempted)
            XCTAssertEqual(part.queueRemoved,1)
            XCTAssertFalse(part.finished)
            let end=try sweep.advance(journal:journal,uptime:{clock},shouldContinue:{true},maxPages:1)
            XCTAssertTrue(end.finished)
            XCTAssertFalse(try sweep.advance(journal:journal,uptime:{clock},shouldContinue:{true}).attempted)
            clock+=3599
            XCTAssertFalse(try sweep.advance(journal:journal,uptime:{clock},shouldContinue:{true}).attempted)
            clock+=1
            XCTAssertTrue(try sweep.advance(journal:journal,uptime:{clock},shouldContinue:{true}).finished)
        }
    }

    func testSweepYieldsToBusyWriterAndResumesWithoutLosingCursor()throws {
        try fixture {path,db in
            let journal=try ChangeJournal(path:path)
            let first=try journal.enqueue(rootID:"demo",relativePath:"repeat.jpg",kind:.upsert)
            let second=try journal.enqueue(rootID:"demo",relativePath:"repeat.jpg",kind:.upsert)
            try journal.markCompleted(id:first);try journal.markCompleted(id:second)
            try exec(db,"UPDATE queue_completion_ledger SET completed_at=1;")
            var sweep=RetentionSweep()
            try exec(db,"BEGIN IMMEDIATE;")
            let start=ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try sweep.advance(journal:journal,shouldContinue:{true}))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,1.0)
            try exec(db,"ROLLBACK;")
            XCTAssertNotNil(try time(db,first))
            let result=try sweep.advance(journal:journal,shouldContinue:{true})
            XCTAssertEqual(result.queueRemoved,1)
            XCTAssertNotNil(try time(db,second))
        }
    }

}
