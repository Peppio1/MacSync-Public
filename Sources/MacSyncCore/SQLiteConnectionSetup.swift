import Foundation
import SQLite3

/// Configure local writer connections before schema operations. Query WAL
/// mode first; acquire a migration write transaction only when necessary.
enum SQLiteConnectionSetup {
    private static func failure(_ db: OpaquePointer?) -> JournalError {
        .database(db.map { String(cString:sqlite3_errmsg($0)) } ?? "SQLite unavailable")
    }
    private static func execute(_ db: OpaquePointer?, _ sql:String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw failure(db) }
    }
    private static func journalMode(_ db: OpaquePointer?, sql:String) throws -> String {
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK, let stmt else { throw failure(db) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt)==SQLITE_ROW, let raw=sqlite3_column_text(stmt,0) else { throw failure(db) }
        return String(cString:raw).lowercased()
    }
    static func configureWriter(_ db: OpaquePointer?) throws {
        guard sqlite3_busy_timeout(db,5000)==SQLITE_OK else { throw failure(db) }
        if try journalMode(db,sql:"PRAGMA journal_mode;") != "wal" {
            guard try journalMode(db,sql:"PRAGMA journal_mode=WAL;") == "wal" else {
                throw JournalError.database("SQLite WAL non disponibile")
            }
        }
    }
    private static func hasColumn(_ db:OpaquePointer?, table:String, column:String) throws -> Bool {
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,"PRAGMA table_info("+table+");",-1,&stmt,nil)==SQLITE_OK,let stmt else {
            throw failure(db)
        }
        defer { sqlite3_finalize(stmt) }
        var found=false
        while true {
            let rc=sqlite3_step(stmt)
            if rc==SQLITE_DONE { return found }
            guard rc==SQLITE_ROW else { throw failure(db) }
            if let name=sqlite3_column_text(stmt,1),String(cString:name)==column { found=true }
        }
    }
    static func addColumnIfMissing(_ db:OpaquePointer?,table:String,column:String,sql:String) throws {
        guard try !hasColumn(db,table:table,column:column) else { return }
        try execute(db,"BEGIN IMMEDIATE TRANSACTION;")
        do {
            if try !hasColumn(db,table:table,column:column) { try execute(db,sql) }
            try execute(db,"COMMIT;")
        } catch {
            try? execute(db,"ROLLBACK;")
            throw error
        }
    }
    /// Retry only initialization before work starts, not filesystem actions.
    static func openWithBoundedRetry<T>(shouldContinue:()->Bool, open:() throws -> T) throws -> T {
        for attempt in 0..<3 {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            do { return try open() }
            catch let error as JournalError {
                let detail=error.localizedDescription.lowercased()
                guard attempt<2, detail.contains("locked") || detail.contains("busy") else { throw error }
                Thread.sleep(forTimeInterval:0.2 * Double(attempt+1))
            }
        }
        throw JournalError.database("SQLite non disponibile dopo i tentativi di apertura")
    }
}
