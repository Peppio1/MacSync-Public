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
}
