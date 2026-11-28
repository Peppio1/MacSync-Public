import Foundation
import SQLite3

/// Compact candidate storage, caller-owned connection and transaction.
/// The old JSON prototype was never operational; use new tables rather than
/// interpreting or dropping its records. No runtime authorization.
enum SourceNameLineageStore {
    struct Key: Equatable, Sendable {
        let rootID: String
        let sourceBinding: String
        let targetBinding: String
        let identity: SourceNameLineage.Identity

        init(_ record: SourceNameLineage.Record) {
            rootID = record.rootID
            sourceBinding = record.sourceBinding
            targetBinding = record.targetBinding
            identity = record.identity
        }
    }

    struct Versioned: Equatable, Sendable {
        let record: SourceNameLineage.Record
        let revision: Int64
    }

    enum Failure: Error, Equatable { case stale, invalid, transactionRequired }

    static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS source_lineage_mapping(
            id INTEGER PRIMARY KEY,
            root_id TEXT NOT NULL,
            source_binding TEXT NOT NULL,
            target_binding TEXT NOT NULL,
            UNIQUE(root_id,source_binding,target_binding)
        );
        CREATE TABLE IF NOT EXISTS source_lineage_index(
            mapping_id INTEGER NOT NULL,
            identity BLOB NOT NULL CHECK(length(identity)=33),
            current_path TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision>0),
            evidence INTEGER NOT NULL CHECK(evidence BETWEEN 0 AND 2),
            uncertain INTEGER NOT NULL CHECK(uncertain IN (0,1)),
            recognized_paths BLOB,
            PRIMARY KEY(mapping_id,identity)
        ) WITHOUT ROWID;
        """

    // Installed only by the queue-protection prototype, not by the ordinary
    // shadow index. The hold is protective, never a new deletion permission.
    private static let protectionSQL = """
        CREATE INDEX IF NOT EXISTS idx_lineage_current_path ON source_lineage_index(mapping_id,current_path);
        CREATE TABLE IF NOT EXISTS source_lineage_hold(
            mapping_id INTEGER NOT NULL, identity BLOB NOT NULL, protected_path TEXT NOT NULL,
            reason INTEGER NOT NULL CHECK(reason IN (0,1)),
            PRIMARY KEY(mapping_id,identity,protected_path)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS idx_lineage_hold_path ON source_lineage_hold(mapping_id,protected_path);
        CREATE TABLE IF NOT EXISTS source_lineage_invalid_observation(
            mapping_id INTEGER NOT NULL, path TEXT NOT NULL, identity BLOB NOT NULL CHECK(length(identity)=33),
            PRIMARY KEY(mapping_id,path)
        ) WITHOUT ROWID;
        """

    private static let maximumRecordBytes = 1_048_576
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func failure(_ db: OpaquePointer) -> JournalError {
        .database(String(cString: sqlite3_errmsg(db)))
    }
    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw failure(db)
        }
        return stmt
    }
    private static func reset(_ stmt: OpaquePointer) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }
    private static func bind(_ value: String, _ i: Int32, _ stmt: OpaquePointer, _ db: OpaquePointer) throws {
        guard !value.utf8.contains(0) else { throw Failure.invalid }
        guard value.withCString({ sqlite3_bind_text(stmt, i, $0, -1, transient) }) == SQLITE_OK else {
            throw failure(db)
        }
    }
    private static func bindBlob(_ value: Data, _ i: Int32, _ stmt: OpaquePointer, _ db: OpaquePointer) throws {
        guard value.count <= maximumRecordBytes,
              value.withUnsafeBytes({ sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), transient) }) == SQLITE_OK else {
            throw failure(db)
        }
    }
    /// Exact, fixed-width binary identity. Never truncate a UInt64 inode.
    private static func identityBytes(_ id: SourceNameLineage.Identity) throws -> Data {
        guard id.inode != 0, id.birthSeconds > 0, (0..<1_000_000_000).contains(id.birthNanos),
              id.kind == "file" || id.kind == "directory" else { throw Failure.invalid }
        var result = Data(capacity: 33)
        for value in [id.device, id.inode, UInt64(bitPattern: id.birthSeconds), UInt64(bitPattern: id.birthNanos)] {
            var word = value.bigEndian
            withUnsafeBytes(of: &word) { result.append(contentsOf: $0) }
        }
        result.append(id.kind == "file" ? 1 : 2)
        return result
    }
    private static func validate(_ record: SourceNameLineage.Record) throws {
        let path = record.currentPath
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(0),
              record.recognizedPaths.allSatisfy({ WindowsPathSafety.validRelativePath($0) }),
              record.evidence != .neverPublished ||
                (record.recognizedPaths.isEmpty && !record.uncertainPublication),
              record.evidence != .recognized || !record.recognizedPaths.isEmpty,
              Set(record.recognizedPaths.map { Data($0.utf8) }).count == record.recognizedPaths.count else {
            throw Failure.invalid
        }
    }
    static func install(_ db: OpaquePointer) throws {
        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    static func installProtection(_ db: OpaquePointer) throws {
        try install(db)
        guard sqlite3_exec(db,protectionSQL,nil,nil,nil) == SQLITE_OK else { throw failure(db) }
    }

    static func protectionInstalled(_ db: OpaquePointer) throws -> Bool {
        let q = try prepare(db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_lineage_hold';")
        defer { sqlite3_finalize(q) }
        let rc = sqlite3_step(q)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw failure(db) }
        return rc == SQLITE_ROW
    }

    private static func bindScope(_ root: String,_ source: String,_ target: String,
                                  _ stmt: OpaquePointer,_ db: OpaquePointer) throws {
        try bind(root,1,stmt,db); try bind(source,2,stmt,db); try bind(target,3,stmt,db)
    }

    // Before the old path can enter the queue, persist a provisional hold.
    // Even an event containing only a disappearance is not proof of deletion.
    static func holdMissing(_ db: OpaquePointer,root: String,source: String,target: String,path: String) throws {
        guard WindowsPathSafety.validRelativePath(path) else { return }
        let q = try prepare(db,"""
            INSERT OR IGNORE INTO source_lineage_hold(mapping_id,identity,protected_path,reason)
            SELECT i.mapping_id,i.identity,i.current_path,0 FROM source_lineage_index i
            JOIN source_lineage_mapping m ON m.id=i.mapping_id
            WHERE m.root_id=?1 AND m.source_binding=?2 AND m.target_binding=?3
              AND i.current_path=?4 AND (i.evidence<>1 OR i.uncertain=1);
            """)
        defer { sqlite3_finalize(q) }
        try bindScope(root,source,target,q,db); try bind(path,4,q,db)
        guard sqlite3_step(q)==SQLITE_DONE else { throw failure(db) }
    }

    // A known new local invalid spelling cannot have been published by this
    // worker. This is NOT a statement that a legacy server object is absent.
    // Only retire speculative source-monitor uploads; never consume existing
    // DELETE jobs, completed historical jobs or unresolved recovery evidence.
    static func retireSpeculativeInvalidUpload(_ db: OpaquePointer,root: String,source: String,target: String,
                                               path: String,old: TrackedItem) throws -> Bool {
        guard !WindowsPathSafety.validRelativePath(path) else { return false }
        // Only the exact invalid observation from the previous committed
        // inventory is eligible, including directories. A historical
        // recognized path is not a claim that a server spelling is absent.
        let q = try prepare(db,"""
            SELECT o.identity,j.id FROM source_lineage_invalid_observation o
            JOIN source_lineage_mapping m ON m.id=o.mapping_id
            JOIN source_lineage_index i ON i.mapping_id=o.mapping_id AND i.identity=o.identity
            JOIN change_queue j ON j.root_id=m.root_id AND j.relative_path=o.path
            WHERE m.root_id=?1 AND m.source_binding=?2 AND m.target_binding=?3
              AND o.path=?4 AND i.uncertain=0 AND i.evidence IN (1,2)
              AND j.completed=0 AND j.kind='upsert' AND j.origin='source_monitor'
              AND NOT EXISTS(SELECT 1 FROM change_queue q
                WHERE q.root_id=?1 AND q.relative_path=?4 AND q.id<>j.id)
              AND NOT EXISTS(SELECT 1 FROM publication_intents p WHERE p.root_id=?1 AND p.relative_path=?4)
              AND NOT EXISTS(SELECT 1 FROM transfer_recovery r WHERE r.root_id=?1 AND r.relative_path=?4)
              AND NOT EXISTS(SELECT 1 FROM upload_retry r WHERE r.root_id=?1 AND (r.scope='root' OR r.job_id=j.id))
              AND NOT EXISTS(SELECT 1 FROM retired_publication_evidence r WHERE r.job_id=j.id)
              AND NOT EXISTS(SELECT 1 FROM retired_delete_evidence r WHERE r.job_id=j.id)
              AND NOT EXISTS(SELECT 1 FROM name_rectification_monitor_links r WHERE r.job_id=j.id)
              AND NOT EXISTS(SELECT 1 FROM mirror_attempts r WHERE r.job_id=j.id);
            """)
        defer { sqlite3_finalize(q) }
        try bindScope(root,source,target,q,db); try bind(path,4,q,db)
        let rc=sqlite3_step(q)
        if rc==SQLITE_DONE { return false }
        guard rc==SQLITE_ROW, sqlite3_column_bytes(q,0)==33, let bytes=sqlite3_column_blob(q,0) else { throw Failure.invalid }
        let identity=Data(bytes:bytes,count:33)
        let jobID=sqlite3_column_int64(q,1)
        if old.kind=="file" {
            guard identity.last==1,let inode=old.changeStamp?.split(separator:":").first.flatMap({UInt64($0)}) else { return false }
            var encoded=inode.bigEndian
            guard Data(identity.dropFirst(8).prefix(8))==withUnsafeBytes(of:&encoded,{Data($0)}) else { return false }
        } else {
            guard old.kind=="directory",identity.last==2 else { return false }
        }
        let next=sqlite3_step(q)
        if next==SQLITE_ROW { return false }
        guard next==SQLITE_DONE else { throw failure(db) }
        // A blocked-name marker is diagnostic only. Remove exactly that
        // marker alongside its never-published speculative upload.
        for sql in ["DELETE FROM blocked_name_jobs WHERE job_id=?;",
                    "DELETE FROM change_queue WHERE id=? AND completed=0 AND kind='upsert' AND origin='source_monitor';"] {
            let retire=try prepare(db,sql)
            defer { sqlite3_finalize(retire) }
            guard sqlite3_bind_int64(retire,1,jobID)==SQLITE_OK,sqlite3_step(retire)==SQLITE_DONE else { throw failure(db) }
        }
        guard sqlite3_changes(db)==1 else { throw Failure.stale }
        return true
    }

    static func forgetInvalidObservation(_ db: OpaquePointer,root:String,source:String,target:String,path:String) throws {
        guard !WindowsPathSafety.validRelativePath(path) else { return }
        let q=try prepare(db,"""
            DELETE FROM source_lineage_invalid_observation WHERE path=?4 AND mapping_id IN
              (SELECT id FROM source_lineage_mapping WHERE root_id=?1 AND source_binding=?2 AND target_binding=?3);
            """)
        defer { sqlite3_finalize(q) }
        try bindScope(root,source,target,q,db); try bind(path,4,q,db)
        guard sqlite3_step(q)==SQLITE_DONE else { throw failure(db) }
    }

    static func protected(_ db: OpaquePointer,root: String,path: String) throws -> Bool {
        guard try protectionInstalled(db) else { return false }
        let q=try prepare(db,"""
            SELECT 1 FROM source_lineage_hold h JOIN source_lineage_mapping m ON m.id=h.mapping_id
            WHERE m.root_id=?1 AND (h.protected_path=?2 OR
              instr(h.protected_path,?2||'/')=1 OR instr(?2,h.protected_path||'/')=1) LIMIT 1;
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db); try bind(path,2,q,db)
        let rc=sqlite3_step(q)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw failure(db) }
        return rc==SQLITE_ROW
    }

    // Resolve only provisional disappearance holds using a complete local
    // scan already required by mirror. Hard links (not eligible for lineage)
    // still contribute their device/inode fingerprints and retain the hold.
    static func resolveMissing(_ db: OpaquePointer,root: String,rows: [TrackedItem],
                               shouldContinue: () -> Bool) throws {
        guard try protectionInstalled(db) else { return }
        // Query the sparse provisional holds FIRST. The ordinary mirror
        // cycle does not construct an archive-sized identity set.
        let q=try prepare(db,"""
            SELECT h.mapping_id,h.identity,h.protected_path FROM source_lineage_hold h
            JOIN source_lineage_mapping m ON m.id=h.mapping_id
            JOIN source_lineage_index i ON i.mapping_id=h.mapping_id AND i.identity=h.identity
            JOIN directory_bindings s ON s.root_id=m.root_id AND s.role='source' AND s.stamp=m.source_binding
            JOIN directory_bindings t ON t.root_id=m.root_id AND t.role='target' AND t.stamp=m.target_binding
            WHERE m.root_id=?1 AND h.reason=0 AND i.uncertain=0 AND i.evidence IN (0,2)
              AND i.current_path=h.protected_path
              AND NOT EXISTS(SELECT 1 FROM file_inventory f WHERE f.root_id=?1 AND f.relative_path=h.protected_path);
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db)
        var candidates:[(Int64,Data,String)]=[]
        var rc=sqlite3_step(q)
        while rc==SQLITE_ROW {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard sqlite3_column_bytes(q,1)==33,let p=sqlite3_column_blob(q,1),let name=sqlite3_column_text(q,2) else { throw Failure.invalid }
            candidates.append((sqlite3_column_int64(q,0),Data(bytes:p,count:33),String(cString:name)))
            rc=sqlite3_step(q)
        }
        guard rc==SQLITE_DONE else { throw failure(db) }
        guard !candidates.isEmpty else { return }
        // A potentially incomplete enumeration cannot prove absence.
        // Match device+inode, including hard-linked files with fingerprints.
        var missing=Set(candidates.map{Data($0.1.prefix(16))})
        for row in rows {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard row.kind != "symlink",let f=row.verificationFingerprint else { return }
            var key=Data(capacity:16)
            for value in [f.device,f.inode] {
                var word=value.bigEndian
                withUnsafeBytes(of:&word){key.append(contentsOf:$0)}
            }
            missing.remove(key)
            if missing.isEmpty { return }
        }
        let removable=candidates.filter{missing.contains(Data($0.1.prefix(16)))}
        let remove=try prepare(db,"DELETE FROM source_lineage_hold WHERE mapping_id=? AND identity=? AND protected_path=? AND reason=0;")
        defer { sqlite3_finalize(remove) }
        for (namespace,id,name) in removable {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            reset(remove)
            guard sqlite3_bind_int64(remove,1,namespace)==SQLITE_OK else { throw failure(db) }
            try bindBlob(id,2,remove,db); try bind(name,3,remove,db)
            guard sqlite3_step(remove)==SQLITE_DONE else { throw failure(db) }
        }
    }

    // Caller has independently verified the same remote directory identity
    // and is updating directory_bindings in this same writer transaction.
    // Keep the numeric namespace and every hold/observation intact. Never
    // merge histories if another namespace already occupies the new binding.
    static func rebindVerifiedTarget(_ db:OpaquePointer,root:String,old:String,new:String) throws {
        guard sqlite3_get_autocommit(db)==0 else { throw Failure.transactionRequired }
        if old.utf8.elementsEqual(new.utf8) { return }
        let exists=try prepare(db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_lineage_mapping';")
        defer { sqlite3_finalize(exists) }
        let rc=sqlite3_step(exists)
        if rc==SQLITE_DONE { return }
        guard rc==SQLITE_ROW else { throw failure(db) }
        reset(exists)
        let q=try prepare(db,"""
            UPDATE source_lineage_mapping SET target_binding=?3
            WHERE root_id=?1 AND target_binding=?2
              AND source_binding=(SELECT stamp FROM directory_bindings WHERE root_id=?1 AND role='source');
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db); try bind(old,2,q,db); try bind(new,3,q,db)
        guard sqlite3_step(q)==SQLITE_DONE else { throw failure(db) }
    }

    // Explicit mapping retirement only. Never remove archive files.
    static func retireRoot(_ db: OpaquePointer,root: String) throws {
        let q=try prepare(db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_lineage_mapping';")
        defer { sqlite3_finalize(q) }
        let rc=sqlite3_step(q)
        if rc==SQLITE_DONE { return }
        guard rc==SQLITE_ROW else { throw failure(db) }
        reset(q)
        var tables=["source_lineage_index"]
        if try protectionInstalled(db) { tables.append("source_lineage_hold") }
        let observed=try prepare(db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_lineage_invalid_observation';")
        defer { sqlite3_finalize(observed) }
        let exists=sqlite3_step(observed)
        guard exists==SQLITE_ROW || exists==SQLITE_DONE else { throw failure(db) }
        if exists==SQLITE_ROW { tables.append("source_lineage_invalid_observation") }
        reset(observed)
        for table in tables {
            let remove=try prepare(db,"DELETE FROM "+table+" WHERE mapping_id IN (SELECT id FROM source_lineage_mapping WHERE root_id=?);")
            defer { sqlite3_finalize(remove) }
            try bind(root,1,remove,db)
            guard sqlite3_step(remove)==SQLITE_DONE else { throw failure(db) }
        }
        let remove=try prepare(db,"DELETE FROM source_lineage_mapping WHERE root_id=?;")
        defer { sqlite3_finalize(remove) }
        try bind(root,1,remove,db)
        guard sqlite3_step(remove)==SQLITE_DONE else { throw failure(db) }
    }

    private static func mapping(_ db: OpaquePointer, key: Key, create: Bool) throws -> Int64? {
        guard !key.rootID.isEmpty, !key.sourceBinding.isEmpty, !key.targetBinding.isEmpty else { throw Failure.invalid }
        func bindMapping(_ stmt: OpaquePointer) throws {
            try bind(key.rootID, 1, stmt, db)
            try bind(key.sourceBinding, 2, stmt, db)
            try bind(key.targetBinding, 3, stmt, db)
        }
        if create {
            guard sqlite3_get_autocommit(db) == 0 else { throw Failure.transactionRequired }
            let insert = try prepare(db, "INSERT OR IGNORE INTO source_lineage_mapping(root_id,source_binding,target_binding) VALUES(?,?,?);")
            defer { sqlite3_finalize(insert) }
            try bindMapping(insert)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw failure(db) }
        }
        let query = try prepare(db, "SELECT id FROM source_lineage_mapping WHERE root_id=? AND source_binding=? AND target_binding=?;")
        defer { sqlite3_finalize(query) }
        try bindMapping(query)
        let rc = sqlite3_step(query)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw failure(db) }
        let id = sqlite3_column_int64(query, 0)
        guard id > 0 else { throw Failure.invalid }
        return id
    }

    /// One mapping lookup and two prepared statements per scan, reused for
    /// every eligible observation. Ordinary records need no JSON at all.
    /// Must not outlive the caller's connection or its write transaction.
    final class Batch {
        private let db: OpaquePointer
        private let namespace: Int64
        private let rootID: String
        private let sourceBinding: String
        private let targetBinding: String
        private let query: OpaquePointer
        private let upsert: OpaquePointer
        private let protectionAvailable: Bool
        private var holdQuery: OpaquePointer?
        private var holdExistsQuery: OpaquePointer?
        private var auditQuery: OpaquePointer?
        private let decoder = JSONDecoder()
        private let encoder = JSONEncoder()

        fileprivate init(_ db: OpaquePointer, key: Key, namespace: Int64) throws {
            self.db = db
            self.namespace = namespace
            rootID = key.rootID
            sourceBinding = key.sourceBinding
            targetBinding = key.targetBinding
            protectionAvailable = try protectionInstalled(db)
            let q = try prepare(db, """
                SELECT current_path,revision,evidence,uncertain,recognized_paths
                FROM source_lineage_index WHERE mapping_id=? AND identity=?;
                """)
            do {
                upsert = try prepare(db, """
                    INSERT INTO source_lineage_index(mapping_id,identity,current_path,revision,evidence,uncertain,recognized_paths)
                    VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(mapping_id,identity) DO UPDATE SET
                        current_path=excluded.current_path,revision=excluded.revision,
                        evidence=excluded.evidence,uncertain=excluded.uncertain,recognized_paths=excluded.recognized_paths
                    WHERE source_lineage_index.revision=?8;
                    """)
            } catch {
                sqlite3_finalize(q)
                throw error
            }
            query = q
        }
        deinit {
            sqlite3_finalize(query)
            sqlite3_finalize(upsert)
            if let holdQuery { sqlite3_finalize(holdQuery) }
            if let holdExistsQuery { sqlite3_finalize(holdExistsQuery) }
            if let auditQuery { sqlite3_finalize(auditQuery) }
        }

        private func verify(_ key: Key) throws {
            guard key.rootID.utf8.elementsEqual(rootID.utf8),
                  key.sourceBinding.utf8.elementsEqual(sourceBinding.utf8),
                  key.targetBinding.utf8.elementsEqual(targetBinding.utf8) else { throw Failure.invalid }
        }
        private func bindIdentity(_ key: Key, _ stmt: OpaquePointer) throws {
            try verify(key)
            guard sqlite3_bind_int64(stmt, 1, namespace) == SQLITE_OK else { throw failure(db) }
            try bindBlob(identityBytes(key.identity), 2, stmt, db)
        }

        func read(key: Key) throws -> Versioned? {
            try readRow(key:key,statement:query,includeHold:false).0
        }

        // A single indexed lookup for ordinary audit observations. Keep the
        // full record validation; only avoid a second lookup for hold status.
        func readForAudit(key: Key) throws -> (Versioned?,Bool) {
            guard protectionAvailable else { return (try read(key:key),false) }
            if auditQuery == nil {
                auditQuery = try prepare(db, """
                    SELECT i.current_path,i.revision,i.evidence,i.uncertain,i.recognized_paths,
                           EXISTS(SELECT 1 FROM source_lineage_hold h
                                  WHERE h.mapping_id=i.mapping_id AND h.identity=i.identity)
                    FROM source_lineage_index i WHERE i.mapping_id=? AND i.identity=?;
                    """)
            }
            guard let auditQuery else { throw Failure.invalid }
            return try readRow(key:key,statement:auditQuery,includeHold:true)
        }

        private func readRow(key:Key,statement:OpaquePointer,includeHold:Bool) throws -> (Versioned?,Bool) {
            let query = statement
            reset(query)
            defer { reset(query) }
            try bindIdentity(key, query)
            let rc = sqlite3_step(query)
            if rc == SQLITE_DONE { return (nil,false) }
            guard rc == SQLITE_ROW else { throw failure(db) }
            let revision = sqlite3_column_int64(query, 1)
            let uncertain = sqlite3_column_int(query, 3)
            guard revision > 0, let path = sqlite3_column_text(query, 0),
                  uncertain == 0 || uncertain == 1 else { throw Failure.invalid }
            let evidence: SourceNameLineage.Evidence
            switch sqlite3_column_int(query, 2) {
            case 0: evidence = .unknown
            case 1: evidence = .neverPublished
            case 2: evidence = .recognized
            default: throw Failure.invalid
            }
            var paths: [String] = []
            if sqlite3_column_type(query, 4) != SQLITE_NULL {
                let length = Int(sqlite3_column_bytes(query, 4))
                guard length > 0, length <= maximumRecordBytes,
                      let bytes = sqlite3_column_blob(query, 4) else { throw Failure.invalid }
                paths = try decoder.decode([String].self, from: Data(bytes: bytes, count: length))
            }
            let pathBytes=Data(bytes:path,count:Int(sqlite3_column_bytes(query,0)))
            guard !pathBytes.contains(0),let exactPath=String(data:pathBytes,encoding:.utf8) else { throw Failure.invalid }
            let record = SourceNameLineage.Record(identity: key.identity, rootID: rootID,
                sourceBinding: sourceBinding, targetBinding: targetBinding,
                path: exactPath, evidence: evidence,
                recognizedPaths: paths, uncertainPublication: uncertain == 1)
            try validate(record)
            return (Versioned(record: record, revision: revision),includeHold && sqlite3_column_int(query,5) != 0)
        }

        func rememberInvalidObservation(_ record: SourceNameLineage.Record) throws {
            guard !WindowsPathSafety.validRelativePath(record.currentPath) else { return }
            let q=try prepare(db,"""
                INSERT INTO source_lineage_invalid_observation(mapping_id,identity,path) VALUES(?,?,?)
                ON CONFLICT(mapping_id,path) DO UPDATE SET identity=excluded.identity;
                """)
            defer { sqlite3_finalize(q) }
            try bindIdentity(Key(record),q); try bind(record.currentPath,3,q,db)
            guard sqlite3_step(q)==SQLITE_DONE else { throw failure(db) }
        }

        func protectRename(_ record: SourceNameLineage.Record) throws {
            let key=Key(record)
            let q=try prepare(db,"""
                INSERT INTO source_lineage_hold(mapping_id,identity,protected_path,reason) VALUES(?,?,?,1)
                ON CONFLICT(mapping_id,identity,protected_path) DO UPDATE SET reason=1;
                """)
            defer { sqlite3_finalize(q) }
            // Unknown pre-existing archives can also contain the old copy.
            // Never assume a compatible path was absent merely because no
            // completed audit or transfer has been recorded yet.
            var paths=record.recognizedPaths
            if (record.evidence != .neverPublished || record.uncertainPublication), WindowsPathSafety.validRelativePath(record.currentPath),
               !paths.contains(where:{$0.utf8.elementsEqual(record.currentPath.utf8)}) { paths.append(record.currentPath) }
            for path in paths {
                reset(q)
                try bindIdentity(key,q); try bind(path,3,q,db)
                guard sqlite3_step(q)==SQLITE_DONE else { throw failure(db) }
            }
        }

        // Reuse a single primary-key query for the whole inventory/audit
        // batch. Most unchanged records have no holds and need no writes.
        private func heldPaths(_ record:SourceNameLineage.Record) throws -> [String] {
            guard protectionAvailable else { return [] }
            if holdQuery==nil {
                holdQuery=try prepare(db,"SELECT protected_path FROM source_lineage_hold WHERE mapping_id=? AND identity=?;")
            }
            guard let q=holdQuery else { throw Failure.invalid }
            reset(q)
            defer { reset(q) }
            try bindIdentity(Key(record),q)
            var paths:[String]=[]
            var rc=sqlite3_step(q)
            while rc==SQLITE_ROW {
                guard let p=sqlite3_column_text(q,0),
                      let path=String(data:Data(bytes:p,count:Int(sqlite3_column_bytes(q,0))),encoding:.utf8),
                      !path.utf8.contains(0) else { throw Failure.invalid }
                paths.append(path)
                rc=sqlite3_step(q)
            }
            guard rc==SQLITE_DONE else { throw failure(db) }
            return paths
        }

        func hasHold(_ record:SourceNameLineage.Record) throws -> Bool {
            guard protectionAvailable else { return false }
            if holdExistsQuery == nil {
                holdExistsQuery = try prepare(db,"SELECT 1 FROM source_lineage_hold WHERE mapping_id=? AND identity=? LIMIT 1;")
            }
            guard let q = holdExistsQuery else { throw Failure.invalid }
            reset(q)
            defer { reset(q) }
            try bindIdentity(Key(record),q)
            let rc = sqlite3_step(q)
            guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw failure(db) }
            return rc == SQLITE_ROW
        }

        // Release only after the exact corrected path is confirmed. Check
        // provisional unknown-history paths too, not only recognized names.
        func releaseConfirmed(_ record: SourceNameLineage.Record) throws {
            guard !record.uncertainPublication, WindowsPathSafety.validRelativePath(record.currentPath),
                  record.recognizedPaths.contains(where:{$0.utf8.elementsEqual(record.currentPath.utf8)}) else { return }
            let paths=try heldPaths(record)
            guard !paths.isEmpty else { return }
            func fold(_ value:String)->String {
                value.split(separator:"/",omittingEmptySubsequences:false)
                    .map{WindowsPathSafety.comparisonFold(String($0))}.joined(separator:"/")
            }
            let folded=fold(record.currentPath)
            guard !(record.recognizedPaths+paths).contains(where:{
                !$0.utf8.elementsEqual(record.currentPath.utf8) && fold($0)==folded
            }) else { return }
            let q=try prepare(db,"DELETE FROM source_lineage_hold WHERE mapping_id=? AND identity=?;")
            defer { sqlite3_finalize(q) }
            try bindIdentity(Key(record),q)
            guard sqlite3_step(q)==SQLITE_DONE else { throw failure(db) }
        }

        @discardableResult
        func write(record: SourceNameLineage.Record, expectedRevision: Int64?) throws -> Versioned {
            guard sqlite3_get_autocommit(db) == 0 else { throw Failure.transactionRequired }
            try validate(record)
            let key = Key(record)
            // New records use the conditional INSERT below: a conflicting
            // existing positive revision cannot match the zero sentinel.
            // Existing records still undergo full decoding and validation.
            let existing: Versioned?
            if let expectedRevision {
                existing = try read(key: key)
                guard existing?.revision == expectedRevision else { throw Failure.stale }
            } else {
                existing = nil
            }
            if let existing, existing.record.evidence == record.evidence,
               existing.record.uncertainPublication == record.uncertainPublication,
               existing.record.currentPath.utf8.elementsEqual(record.currentPath.utf8),
               existing.record.recognizedPaths.map({ Data($0.utf8) }) == record.recognizedPaths.map({ Data($0.utf8) }) {
                return existing
            }
            let next = (expectedRevision ?? 0).addingReportingOverflow(1)
            guard !next.overflow, next.partialValue > 0 else { throw Failure.invalid }
            reset(upsert)
            defer { reset(upsert) }
            try bindIdentity(key, upsert)
            try bind(record.currentPath, 3, upsert, db)
            let evidence: Int32 = record.evidence == .unknown ? 0 : (record.evidence == .neverPublished ? 1 : 2)
            guard sqlite3_bind_int64(upsert, 4, next.partialValue) == SQLITE_OK,
                  sqlite3_bind_int(upsert, 5, evidence) == SQLITE_OK,
                  sqlite3_bind_int(upsert, 6, record.uncertainPublication ? 1 : 0) == SQLITE_OK,
                  sqlite3_bind_int64(upsert, 8, expectedRevision ?? 0) == SQLITE_OK else { throw failure(db) }
            if record.recognizedPaths.isEmpty {
                guard sqlite3_bind_null(upsert, 7) == SQLITE_OK else { throw failure(db) }
            } else {
                try bindBlob(encoder.encode(record.recognizedPaths), 7, upsert, db)
            }
            guard sqlite3_step(upsert) == SQLITE_DONE else { throw failure(db) }
            guard sqlite3_changes(db) == 1 else { throw Failure.stale }
            return Versioned(record: record, revision: next.partialValue)
        }
    }

    static func batch(_ db: OpaquePointer, key: Key, create: Bool) throws -> Batch? {
        guard let id = try mapping(db, key: key, create: create) else { return nil }
        return try Batch(db, key: key, namespace: id)
    }
    static func releaseConfirmed(_ db: OpaquePointer,record: SourceNameLineage.Record) throws {
        guard try protectionInstalled(db),let batch=try batch(db,key:Key(record),create:false) else { return }
        try batch.releaseConfirmed(record)
    }
    static func read(_ db: OpaquePointer, key: Key) throws -> Versioned? {
        try batch(db, key: key, create: false)?.read(key: key)
    }
    @discardableResult
    static func write(_ db: OpaquePointer, record: SourceNameLineage.Record,
                      expectedRevision: Int64?) throws -> Versioned {
        guard sqlite3_get_autocommit(db) == 0 else { throw Failure.transactionRequired }
        guard let writer = try batch(db, key: Key(record), create: true) else { throw Failure.invalid }
        return try writer.write(record: record, expectedRevision: expectedRevision)
    }
}
