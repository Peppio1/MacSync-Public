import Foundation
import SQLite3

public enum SyncEventKind: String, Codable, CaseIterable, Sendable {
    case newFile, updatedFile, deleted, recovered, deferred, failed
    case directoryCreated, directoryRemoved, noChange, missing, stageCopy, backupCopy, recoveryExpired
    public var isJob: Bool {
        self != .stageCopy && self != .backupCopy && self != .recoveryExpired
    }
}
public struct SyncCycleEvent: Codable, Equatable, Sendable {
    public let kind: SyncEventKind
    public let rootID: String
    public let relativePath: String
    public let sourceRoot: String
    public let targetRoot: String
    public let recoveryPath: String?
    public let bytes: Int64?
    public let seconds: Double
    public let at: Date
    public let detail: String
    public let isDeleteJob: Bool
    public init(kind: SyncEventKind, job: QueuedChange, mapping: MountedFolderMapping?,
                bytes: Int64? = nil, seconds: Double = 0, recoveryPath: String? = nil,
                detail: String = "", at: Date = Date()) {
        self.kind = kind; rootID = job.rootID; relativePath = job.relativePath
        sourceRoot = mapping?.source.path ?? ""; targetRoot = mapping?.target.path ?? ""
        self.recoveryPath = recoveryPath; self.bytes = bytes
        self.seconds = seconds.isFinite ? max(0, seconds) : 0
        self.at = at; self.detail = detail; isDeleteJob = job.kind == .delete
    }
}
public struct SyncCycleRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let started: Date
    public let ended: Date?
    public let seconds: Double?
    public let state: String
}
public struct SyncHistoryRow: Identifiable, Sendable {
    public let id: Int64
    public let cycleID: String
    public let event: SyncCycleEvent
}
public struct SyncHistoryTotals: Equatable, Sendable {
    public var stats = SyncDashboardStats()
    public var stageBytes: Int64 = 0
    public var backupBytes: Int64 = 0
    public var stageSeconds: Double = 0
    public var backupSeconds: Double = 0
    public var byRoot: [String: SyncDashboardStats] = [:]
    public init() {}
    public var meanCopyRate: Double? { stageSeconds > 0 ? Double(stageBytes) / stageSeconds : nil }
    public mutating func add(_ event: SyncCycleEvent) {
        var item = SyncDashboardStats()
        let bytes = max(0, event.bytes ?? 0)
        switch event.kind {
        case .newFile: item.newFiles = 1; item.bytesTransferred = bytes
        case .updatedFile: item.updatedFiles = 1; item.bytesTransferred = bytes
        case .deleted: item.permanentlyDeleted = 1
        case .recovered: item.movedToRecovery = 1
        case .deferred: item.deferred = 1
        case .failed: item.failed = 1
        case .directoryCreated: item.createdDirectories = 1
        case .directoryRemoved: item.removedDirectories = 1
        case .recoveryExpired: item.expiredRecovery = 1
        case .stageCopy: stageBytes = Self.sum(stageBytes, bytes); stageSeconds += event.seconds
        case .backupCopy: backupBytes = Self.sum(backupBytes, bytes); backupSeconds += event.seconds
        case .noChange, .missing: break
        }
        stats.accumulate(item)
        byRoot[event.rootID, default: SyncDashboardStats()].accumulate(item)
    }
    private static func sum(_ a: Int64, _ b: Int64) -> Int64 {
        let s = a.addingReportingOverflow(b); return s.overflow ? Int64.max : s.partialValue
    }
}
public struct SyncLiveProgress: Equatable, Sendable {
    public let started: Date
    public var planned: Int
    public var processed = 0
    public var phase = "Verifica"
    public var currentFile = ""
    public var lastCopyRate: Double?
    public var fraction: Double { planned > 0 ? min(0.99, Double(processed) / Double(planned)) : 0 }
    public init(started: Date, planned: Int = 0) { self.started = started; self.planned = max(0, planned) }
    public mutating func observe(_ event: SyncCycleEvent) {
        if event.kind.isJob { processed += 1 }
        if event.kind == .stageCopy || event.kind == .backupCopy {
            if event.seconds > 0, let bytes = event.bytes {
                lastCopyRate = Double(bytes) / event.seconds
            }
        }
    }
    public static func formatRate(_ value: Double?) -> String {
        guard let v = value, v.isFinite, v >= 0 else { return "—" }
        if v >= 1_000_000_000 { return String(format: "%.2f GB/s", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.2f MB/s", v / 1_000_000) }
        return String(format: "%.1f kB/s", v / 1_000)
    }
}

/// Separate local history tables. These never acknowledge jobs or participate
/// in copy/deletion decisions. One instance per serial queue.
public final class SyncCycleHistory {
    private var db: OpaquePointer?
    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            if handle != nil { sqlite3_close(handle) }
            throw JournalError.database("Cannot open cycle history")
        }
        db = handle
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;")
            try execute("""
                CREATE TABLE IF NOT EXISTS sync_cycles_v1(
                    id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started REAL NOT NULL,
                    ended REAL, elapsed REAL, state TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_cycles_started ON sync_cycles_v1(started DESC);
                CREATE INDEX IF NOT EXISTS idx_cycles_session ON sync_cycles_v1(session_id,started DESC);
                CREATE TABLE IF NOT EXISTS sync_cycle_events_v1(
                    id INTEGER PRIMARY KEY AUTOINCREMENT, cycle_id TEXT NOT NULL REFERENCES sync_cycles_v1(id) ON DELETE CASCADE,
                    root_id TEXT NOT NULL, kind TEXT NOT NULL, relative_path TEXT NOT NULL, payload TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_cycle_events ON sync_cycle_events_v1(cycle_id,kind,id);
                """)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    public func begin(id: String, sessionID: String, at: Date) throws {
        let s = try prepare("INSERT INTO sync_cycles_v1(id,session_id,started,state) VALUES(?,?,?,'running');")
        defer { sqlite3_finalize(s) }
        try bind(id,1,s); try bind(sessionID,2,s)
        guard sqlite3_bind_double(s,3,at.timeIntervalSince1970) == SQLITE_OK, sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    public func finish(id: String, at: Date, seconds: Double, state: String) throws {
        let s = try prepare("UPDATE sync_cycles_v1 SET ended=?,elapsed=?,state=? WHERE id=? AND state='running';")
        defer { sqlite3_finalize(s) }
        guard sqlite3_bind_double(s,1,at.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(s,2,max(0,seconds)) == SQLITE_OK else { throw failure() }
        try bind(state,3,s); try bind(id,4,s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    public func markInterrupted(exceptSession: String) throws {
        let s = try prepare("UPDATE sync_cycles_v1 SET state='interrupted' WHERE state='running' AND session_id<>?;")
        defer { sqlite3_finalize(s) }; try bind(exceptSession,1,s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    public func append(cycleID: String, event: SyncCycleEvent) throws {
        let payload = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        let s = try prepare("INSERT INTO sync_cycle_events_v1(cycle_id,root_id,kind,relative_path,payload) VALUES(?,?,?,?,?);")
        defer { sqlite3_finalize(s) }
        for (i,v) in [cycleID,event.rootID,event.kind.rawValue,event.relativePath,payload].enumerated() { try bind(v,Int32(i+1),s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    public func cycles(limit: Int = 100, offset: Int = 0) throws -> [SyncCycleRecord] {
        let s = try prepare("SELECT id,session_id,started,ended,elapsed,state FROM sync_cycles_v1 ORDER BY started DESC,id DESC LIMIT ? OFFSET ?;")
        defer { sqlite3_finalize(s) }
        guard sqlite3_bind_int64(s,1,Int64(max(1,min(limit,500)))) == SQLITE_OK,
              sqlite3_bind_int64(s,2,Int64(max(0,offset))) == SQLITE_OK else { throw failure() }
        var result: [SyncCycleRecord] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return result }; guard rc == SQLITE_ROW else { throw failure() }
            result.append(SyncCycleRecord(id: col(s,0),sessionID: col(s,1),
                started: Date(timeIntervalSince1970: sqlite3_column_double(s,2)),
                ended: sqlite3_column_type(s,3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s,3)),
                seconds: sqlite3_column_type(s,4) == SQLITE_NULL ? nil : sqlite3_column_double(s,4), state: col(s,5)))
        }
    }
    public func events(cycleID: String? = nil, sessionID: String? = nil,
                       kinds: [SyncEventKind] = [], rootID: String? = nil,
                       search: String = "", afterID: Int64 = 0, limit: Int = 200) throws -> [SyncHistoryRow] {
        var sql = """
            SELECT e.id,e.cycle_id,e.payload FROM sync_cycle_events_v1 e
            JOIN sync_cycles_v1 c ON c.id=e.cycle_id WHERE e.id>?
            """
        var params: [String] = []
        if let cycleID { sql += " AND e.cycle_id=?"; params.append(cycleID) }
        if let sessionID { sql += " AND c.session_id=?"; params.append(sessionID) }
        if !kinds.isEmpty {
            sql += " AND e.kind IN (" + Array(repeating: "?",count:kinds.count).joined(separator:",") + ")"
            params += kinds.map(\.rawValue)
        }
        if let rootID { sql += " AND e.root_id=?"; params.append(rootID) }
        if !search.isEmpty { sql += " AND instr(lower(e.relative_path),lower(?))>0"; params.append(search) }
        sql += " ORDER BY e.id LIMIT ?;"
        let s = try prepare(sql); defer { sqlite3_finalize(s) }
        guard sqlite3_bind_int64(s,1,afterID) == SQLITE_OK else { throw failure() }
        for (i,v) in params.enumerated() { try bind(v,Int32(i+2),s) }
        guard sqlite3_bind_int64(s,Int32(params.count+2),Int64(max(1,min(limit,1000)))) == SQLITE_OK else { throw failure() }
        var result: [SyncHistoryRow] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return result }; guard rc == SQLITE_ROW else { throw failure() }
            let event = try JSONDecoder().decode(SyncCycleEvent.self,from:Data(col(s,2).utf8))
            result.append(SyncHistoryRow(id:sqlite3_column_int64(s,0),cycleID:col(s,1),event:event))
        }
    }
    public func totals(cycleID: String? = nil, sessionID: String? = nil) throws -> SyncHistoryTotals {
        var result = SyncHistoryTotals(), cursor: Int64 = 0
        while true {
            let page = try events(cycleID:cycleID,sessionID:sessionID,afterID:cursor,limit:1000)
            guard let last = page.last else { return result }
            for row in page { result.add(row.event) }; cursor = last.id
        }
    }
    public func prune(before: Date) throws {
        let s = try prepare("DELETE FROM sync_cycles_v1 WHERE started<? AND state<>'running';")
        defer { sqlite3_finalize(s) }
        guard sqlite3_bind_double(s,1,before.timeIntervalSince1970) == SQLITE_OK, sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw failure() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&s,nil) == SQLITE_OK, let s else { throw failure() }; return s
    }
    private func bind(_ value: String,_ index:Int32,_ s:OpaquePointer) throws {
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        guard value.withCString({ sqlite3_bind_text(s,index,$0,-1,transient) }) == SQLITE_OK else { throw failure() }
    }
    private func col(_ s:OpaquePointer,_ i:Int32)->String {
        guard let p = sqlite3_column_text(s,i) else { return "" }; return String(cString:p)
    }
    private func failure()->JournalError { .database(db.map { String(cString:sqlite3_errmsg($0)) } ?? "History unavailable") }
}
