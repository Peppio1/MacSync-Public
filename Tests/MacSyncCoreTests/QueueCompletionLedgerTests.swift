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

}
