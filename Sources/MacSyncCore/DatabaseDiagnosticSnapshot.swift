import Foundation
import SQLite3

/// Export-time inspection only: no DDL, checkpoint, VACUUM, or changes to
/// queue/evidence. Measurements are numeric and contain no paths or values.
public struct DatabaseDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let measuredAt:Date
    public let databaseBytes:Int64?
    public let walBytes:Int64?
    public let pageSize:Int64?
    public let pageCount:Int64?
    public let freePages:Int64?
    public let counts:[String:Int64]
    public let elapsedSeconds:Double
    public let complete:Bool

    public static func collect(databasePath:String, includeCounts:Bool=true) -> DatabaseDiagnosticSnapshot {
        collect(databasePath: databasePath, includeCounts: includeCounts, allowWALRecovery: false)
    }

    /// Only for offline maintenance under the archive lock. The ordinary
    /// export remains read-only. No SQL writes or CREATE are permitted.
    static func collectForCompaction(databasePath:String) -> DatabaseDiagnosticSnapshot {
        collect(databasePath: databasePath, includeCounts: false, allowWALRecovery: true)
    }

    private static func collect(databasePath:String, includeCounts:Bool, allowWALRecovery:Bool) -> DatabaseDiagnosticSnapshot {
        let start=ProcessInfo.processInfo.systemUptime
        let now=Date()
        func size(_ path:String,optional:Bool=false)->Int64? {
            do {
                let attributes=try FileManager.default.attributesOfItem(atPath:path)
                return (attributes[.size] as? NSNumber)?.int64Value
            } catch let error as NSError {
                if optional,error.domain==NSCocoaErrorDomain,
                   error.code==NSFileNoSuchFileError || error.code==NSFileReadNoSuchFileError { return 0 }
                return nil
            }
        }
        let bytes=size(databasePath),wal=size(databasePath+"-wal",optional:true)
        var pageSize:Int64?,pageCount:Int64?,freePages:Int64?
        var counts:[String:Int64]=[:]
        var complete=false
        var db:OpaquePointer?
        if sqlite3_open_v2(databasePath,&db,allowWALRecovery ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY,nil)==SQLITE_OK,let db {
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db,100)
            // Bound read lock duration and total query work. A busy/large
            // archive may return partial measurements; never stall sync.
            let deadline=start+0.75
            final class Deadline {
                let end:Double
                init(_ end:Double) { self.end=end }
            }
            let timer=Deadline(deadline)
            let context=Unmanaged.passUnretained(timer).toOpaque()
            sqlite3_progress_handler(db,1000,{ raw in
                guard let raw else { return 1 }
                let timer=Unmanaged<Deadline>.fromOpaque(raw).takeUnretainedValue()
                return ProcessInfo.processInfo.systemUptime>=timer.end ? 1:0
            },context)
            defer { sqlite3_progress_handler(db,0,nil,nil);withExtendedLifetime(timer) {} }
            func scalar(_ sql:String)->Int64? {
                guard ProcessInfo.processInfo.systemUptime<deadline else { return nil }
                var stmt:OpaquePointer?
                guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK,let stmt else { return nil }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt)==SQLITE_ROW,sqlite3_column_type(stmt,0)==SQLITE_INTEGER else { return nil }
                return sqlite3_column_int64(stmt,0)
            }
            if sqlite3_exec(db,"PRAGMA query_only=ON; BEGIN;",nil,nil,nil)==SQLITE_OK {
                defer { _=sqlite3_exec(db,"ROLLBACK;",nil,nil,nil) }
                pageSize=scalar("PRAGMA page_size;")
                pageCount=scalar("PRAGMA page_count;")
                freePages=scalar("PRAGMA freelist_count;")
                // Fixed known schema names; no arbitrary table or user data.
                let tables=["change_queue","queue_completion_ledger","file_inventory","name_rectification_receipts",
                    "name_rectification_monitor_links","publication_intents","transfer_recovery",
                    "retired_delete_evidence","retired_publication_evidence","blocked_name_jobs",
                    "sync_activity","sync_cycles_v1","sync_cycle_events_v1","mirror_recovery"]
                var all=true
                for table in includeCounts ? tables : [] {
                    let exists=scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='"+table+"';")
                    if exists==0 { continue } // older/partial archives
                    guard exists==1,let count=scalar("SELECT count(*) FROM "+table+";") else { all=false;continue }
                    counts[table]=count
                    if table=="change_queue" {
                        for (key,condition) in [("queue_pending","completed=0"),("queue_completed","completed=1")] {
                            if let n=scalar("SELECT count(*) FROM change_queue WHERE "+condition+";") { counts[key]=n }
                            else { all=false }
                        }
                    }
                }
                complete=all && pageSize != nil && pageCount != nil && freePages != nil
            }
        } else if let db { sqlite3_close(db) }
        return .init(measuredAt:now,databaseBytes:bytes,walBytes:wal,pageSize:pageSize,
                     pageCount:pageCount,freePages:freePages,counts:counts,
                     elapsedSeconds:max(0,ProcessInfo.processInfo.systemUptime-start),complete:complete)
    }
}
