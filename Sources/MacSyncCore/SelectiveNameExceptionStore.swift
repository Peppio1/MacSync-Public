import Foundation
import SQLite3
import Darwin

/// Candidate laboratory: persistent, sparse vetoes for suspicious source
/// transitions. Never grants delete, publication or queue acknowledgement
/// authority. Normal inventory is the only archive-sized identity index.
enum SelectiveNameExceptionStore {
    private static let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private static func fail(_ db:OpaquePointer)->JournalError {
        .database(String(cString:sqlite3_errmsg(db)))
    }
    private static func exec(_ db:OpaquePointer,_ sql:String)throws {
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw fail(db) }
    }
    private static func prepare(_ db:OpaquePointer,_ sql:String)throws->OpaquePointer {
        var q:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&q,nil)==SQLITE_OK,let q else { throw fail(db) }
        return q
    }
    private static func bind(_ text:String,_ index:Int32,_ q:OpaquePointer,_ db:OpaquePointer)throws {
        guard !text.utf8.contains(0),text.withCString({sqlite3_bind_text(q,index,$0,-1,transient)})==SQLITE_OK else { throw fail(db) }
    }
    private static func bind(_ bytes:Data?,_ index:Int32,_ q:OpaquePointer,_ db:OpaquePointer)throws {
        if let bytes {
            guard bytes.count==33,bytes.withUnsafeBytes({sqlite3_bind_blob(q,index,$0.baseAddress,33,transient)})==SQLITE_OK else { throw fail(db) }
        } else {
            guard sqlite3_bind_null(q,index)==SQLITE_OK else { throw fail(db) }
        }
    }
    private static func string(_ q:OpaquePointer,_ col:Int32)throws->String {
        guard let ptr=sqlite3_column_text(q,col) else { throw SourceNameLineageStore.Failure.invalid }
        let bytes=Data(bytes:ptr,count:Int(sqlite3_column_bytes(q,col)))
        guard !bytes.contains(0),let result=String(data:bytes,encoding:.utf8) else { throw SourceNameLineageStore.Failure.invalid }
        return result
    }
    private static func fold(_ path:String)->String {
        path.split(separator:"/",omittingEmptySubsequences:false)
            .map{WindowsPathSafety.comparisonFold(String($0))}.joined(separator:"/")
    }
    private static func ancestors(_ path:String)->[String] {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count>1 else { return [] }
        return (1..<parts.count).map{parts.prefix($0).joined(separator:"/")}
    }
    private static func exact(_ a:String,_ b:String)->Bool { a.utf8.elementsEqual(b.utf8) }
    static func installed(_ db:OpaquePointer)throws->Bool {
        let q=try prepare(db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='selective_name_exception';")
        defer { sqlite3_finalize(q) }
        let rc=sqlite3_step(q)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw fail(db) }
        return rc==SQLITE_ROW
    }
    static func install(_ db:OpaquePointer)throws {
        guard sqlite3_get_autocommit(db)==0 else { throw SourceNameLineageStore.Failure.transactionRequired }
        if try installed(db) {
            try installSpeculativeJobs(db)
            try installRestorationProof(db)
            return
        }
        try SourceNameLineageStore.installIntegratedLayout(db)
        // Do not mix the two experimental stores or reinterpret prior
        // publication evidence. Start on a fresh lab profile.
        let q=try prepare(db,"SELECT (SELECT COUNT(*) FROM source_lineage_index)+(SELECT COUNT(*) FROM source_lineage_hold)+(SELECT COUNT(*) FROM file_inventory WHERE lineage_mapping_id IS NOT NULL);")
        defer { sqlite3_finalize(q) }
        guard sqlite3_step(q)==SQLITE_ROW,sqlite3_column_int64(q,0)==0 else { throw SourceNameLineageStore.Failure.invalid }
        try exec(db,"""
            CREATE INDEX idx_selective_live_identity ON file_inventory(root_id,lineage_observed_identity)
              WHERE lineage_observed_identity IS NOT NULL;
            CREATE TABLE selective_name_exception(
                id INTEGER PRIMARY KEY AUTOINCREMENT, root_id TEXT NOT NULL,
                source_binding TEXT NOT NULL,target_binding TEXT NOT NULL,
                original_path TEXT NOT NULL,current_path TEXT,
                identity BLOB CHECK(identity IS NULL OR length(identity)=33),
                kind TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('missing','incompatible','returned','moved','ambiguous'))
            );
            CREATE INDEX idx_selective_exception_identity ON selective_name_exception(root_id,source_binding,target_binding,identity);
            CREATE INDEX idx_selective_exception_root ON selective_name_exception(root_id);
            CREATE TABLE selective_name_guard(
                exception_id INTEGER NOT NULL,root_id TEXT NOT NULL,path TEXT NOT NULL,folded TEXT NOT NULL,
                PRIMARY KEY(exception_id,path)
            ) WITHOUT ROWID;
            CREATE INDEX idx_selective_guard_root ON selective_name_guard(root_id);
            CREATE TABLE selective_name_detached(
                exception_id INTEGER NOT NULL,relative_path TEXT NOT NULL,kind TEXT NOT NULL,
                file_size INTEGER NOT NULL,modified_at REAL NOT NULL,change_stamp TEXT,identity BLOB,
                PRIMARY KEY(exception_id,relative_path)
            ) WITHOUT ROWID;
            """)
        try installSpeculativeJobs(db)
        try installRestorationProof(db)
    }

    private static func restorationInstalled(_ db:OpaquePointer)throws->Bool {
        let q=try prepare(db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='selective_restore_proof';")
        defer { sqlite3_finalize(q) }
        let rc=sqlite3_step(q)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw fail(db) }
        return rc==SQLITE_ROW
    }

    private static func installRestorationProof(_ db:OpaquePointer)throws {
        try exec(db,"""
            CREATE TABLE IF NOT EXISTS selective_clean_baseline(
                root_id TEXT PRIMARY KEY,source_binding TEXT NOT NULL,target_binding TEXT NOT NULL,
                scan TEXT NOT NULL,event TEXT NOT NULL,sequence INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS selective_restore_proof(
                exception_id INTEGER NOT NULL,path TEXT NOT NULL,
                delete_job INTEGER UNIQUE,restore_job INTEGER UNIQUE,
                PRIMARY KEY(exception_id,path)
            ) WITHOUT ROWID;
            """)
    }

    // One conservative certificate per clean, completely matching root.
    // It is not a permanent file history. A changed inventory checkpoint
    // or queue sequence makes it ineligible for NEW exception capture.
    static func certifyCleanBaseline(_ db:OpaquePointer,root:String,source:String,target:String,
                                    snapshot:ChangeJournal.LineageAbsenceSnapshot)throws {
        guard sqlite3_get_autocommit(db)==0 else { throw SourceNameLineageStore.Failure.transactionRequired }
        try installRestorationProof(db)
        let q=try prepare(db,"""
            INSERT INTO selective_clean_baseline(root_id,source_binding,target_binding,scan,event,sequence)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(root_id) DO UPDATE SET source_binding=excluded.source_binding,
              target_binding=excluded.target_binding,scan=excluded.scan,event=excluded.event,sequence=excluded.sequence;
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db);try bind(source,2,q,db);try bind(target,3,q,db)
        try bind(snapshot.scan,4,q,db);try bind(snapshot.event,5,q,db)
        guard sqlite3_bind_int64(q,6,snapshot.sequence)==SQLITE_OK,sqlite3_step(q)==SQLITE_DONE else { throw fail(db) }
    }

    static func invalidateCertificate(_ db:OpaquePointer,root:String)throws {
        let q=try prepare(db,"DELETE FROM selective_clean_baseline WHERE root_id=?;")
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db)
        guard sqlite3_step(q)==SQLITE_DONE else { throw fail(db) }
    }

    // Fail closed on all unresolved publication/rectification state in this
    // root. This is deliberately stricter than normal copy eligibility.
    static func rootUncertain(_ db:OpaquePointer,root:String)throws->Bool {
        let q=try prepare(db,"""
            SELECT 1 WHERE EXISTS(SELECT 1 FROM publication_intents WHERE root_id=?1)
               OR EXISTS(SELECT 1 FROM transfer_recovery WHERE root_id=?1)
               OR EXISTS(SELECT 1 FROM upload_retry WHERE root_id=?1)
               OR EXISTS(SELECT 1 FROM retired_publication_evidence r JOIN change_queue c ON c.id=r.job_id WHERE c.root_id=?1)
               OR EXISTS(SELECT 1 FROM queue_rebuild_hold)
               OR EXISTS(SELECT 1 FROM name_rectification_batch)
               OR EXISTS(SELECT 1 FROM name_rectification_groups WHERE root_id=?1);
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db)
        let rc=sqlite3_step(q)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw fail(db) }
        return rc==SQLITE_ROW
    }

    private static func captureRestoreProof(_ db:OpaquePointer,id:Int64,root:String,source:String,target:String)throws {
        guard try !rootUncertain(db,root:root) else { return }
        let q=try prepare(db,"""
            INSERT INTO selective_restore_proof(exception_id,path)
            SELECT d.exception_id,d.relative_path FROM selective_name_detached d
            JOIN selective_clean_baseline b ON b.root_id=?2
            JOIN watched_roots w ON w.root_id=b.root_id
            WHERE d.exception_id=?1 AND d.identity IS NOT NULL AND d.kind IN ('file','directory')
              AND b.source_binding=?3 AND b.target_binding=?4
              AND b.scan=CAST(w.last_scan_at AS TEXT) AND b.event=COALESCE(w.last_event_id,'')
              AND b.sequence=COALESCE((SELECT seq FROM sqlite_sequence WHERE name='change_queue'),0)
              AND NOT EXISTS(SELECT 1 FROM change_queue c WHERE c.root_id=?2 AND c.completed=0);
            """)
        defer { sqlite3_finalize(q) }
        guard sqlite3_bind_int64(q,1,id)==SQLITE_OK else { throw fail(db) }
        try bind(root,2,q,db);try bind(source,3,q,db);try bind(target,4,q,db)
        guard sqlite3_step(q)==SQLITE_DONE else { throw fail(db) }
    }

    static func markOriginalDelete(_ db:OpaquePointer,root:String,source:String,old:TrackedItem,job:Int64)throws {
        guard let identity=old.storedLineageIdentity else { return }
        let q=try prepare(db,"""
            UPDATE selective_restore_proof SET delete_job=?1
            WHERE path=?2 AND delete_job IS NULL AND restore_job IS NULL
              AND exception_id IN (SELECT e.id FROM selective_name_exception e
                JOIN directory_bindings t ON t.root_id=e.root_id AND t.role='target' AND t.stamp=e.target_binding
                JOIN selective_name_detached d ON d.exception_id=e.id AND d.relative_path=?2 AND d.identity=?5
                WHERE e.root_id=?3 AND e.source_binding=?4);
            """)
        defer { sqlite3_finalize(q) }
        guard sqlite3_bind_int64(q,1,job)==SQLITE_OK else { throw fail(db) }
        try bind(old.relativePath,2,q,db);try bind(root,3,q,db);try bind(source,4,q,db);try bind(identity,5,q,db)
        guard sqlite3_step(q)==SQLITE_DONE else { throw fail(db) }
    }

    // The old generated DELETE must still be the exact pending job. A
    // genuinely edited/replaced file, preexisting or superseding job,
    // collision, or uncertain publication can never get this capability.
    static func restoreCandidate(_ db:OpaquePointer,root:String,source:String,row:TrackedItem)throws->Int64? {
        guard WindowsPathSafety.validRelativePath(row.relativePath),
              let identity=row.sourceLineageIdentity else { return nil }
        let q=try prepare(db,"""
            SELECT p.exception_id FROM selective_restore_proof p
            JOIN selective_name_exception e ON e.id=p.exception_id
            JOIN selective_name_detached d ON d.exception_id=p.exception_id AND d.relative_path=p.path
            JOIN directory_bindings t ON t.root_id=e.root_id AND t.role='target' AND t.stamp=e.target_binding
            JOIN change_queue c ON c.id=p.delete_job AND c.root_id=e.root_id AND c.relative_path=p.path
            WHERE e.root_id=?1 AND e.source_binding=?2 AND e.state='returned' AND e.current_path=e.original_path
              AND p.path=?3 AND p.restore_job IS NULL AND d.identity=?4 AND d.kind=?5
              AND (d.kind='directory' OR (d.file_size=?6 AND d.modified_at=?7 AND d.change_stamp=?8))
              AND c.completed=0 AND c.kind='delete' AND c.origin='source_monitor'
              AND NOT EXISTS(SELECT 1 FROM change_queue other WHERE other.root_id=?1 AND other.relative_path=?3
                  AND other.id<>c.id AND (other.completed=0 OR other.id>c.id))
              AND NOT EXISTS(SELECT 1 FROM mirror_attempts m WHERE m.job_id=c.id)
              AND NOT EXISTS(SELECT 1 FROM retired_delete_evidence r WHERE r.job_id=c.id)
              AND NOT EXISTS(SELECT 1 FROM selective_name_exception other WHERE other.id<>e.id AND other.root_id=e.root_id
                  AND other.identity=e.identity);
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db);try bind(source,2,q,db);try bind(row.relativePath,3,q,db)
        try bind(try SourceNameLineageStore.identityBytes(identity),4,q,db);try bind(row.kind,5,q,db)
        guard sqlite3_bind_int64(q,6,row.size)==SQLITE_OK,sqlite3_bind_double(q,7,row.modifiedAt)==SQLITE_OK else { throw fail(db) }
        if let stamp=row.changeStamp { try bind(stamp,8,q,db) }
        else { guard sqlite3_bind_null(q,8)==SQLITE_OK else { throw fail(db) } }
        let rc=sqlite3_step(q)
        if rc==SQLITE_DONE { return nil }
        guard rc==SQLITE_ROW else { throw fail(db) }
        let id=sqlite3_column_int64(q,0)
        let next=sqlite3_step(q)
        if next==SQLITE_ROW { return nil }
        guard next==SQLITE_DONE else { throw fail(db) }
        guard try !rootUncertain(db,root:root) else { return nil }
        return id
    }

    static func markRestoredUpload(_ db:OpaquePointer,id:Int64,path:String,job:Int64)throws {
        let q=try prepare(db,"UPDATE selective_restore_proof SET restore_job=? WHERE exception_id=? AND path=? AND restore_job IS NULL;")
        defer { sqlite3_finalize(q) }
        guard sqlite3_bind_int64(q,1,job)==SQLITE_OK,sqlite3_bind_int64(q,2,id)==SQLITE_OK else { throw fail(db) }
        try bind(path,3,q,db)
        guard sqlite3_step(q)==SQLITE_DONE,sqlite3_changes(db)==1 else { throw SourceNameLineageStore.Failure.stale }
    }

    static func hasRestoredJob(_ db:OpaquePointer,job:Int64)throws->Bool {
        guard try installed(db),try restorationInstalled(db) else { return false }
        let q=try prepare(db,"SELECT 1 FROM selective_restore_proof WHERE restore_job=?;")
        defer { sqlite3_finalize(q) }
        guard sqlite3_bind_int64(q,1,job)==SQLITE_OK else { throw fail(db) }
        let rc=sqlite3_step(q)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw fail(db) }
        return rc==SQLITE_ROW
    }

    // The worker has to prove an exact live source and an exact metadata
    // match on the already mounted destination before consuming this marker.
    // No blanket QUICK acknowledgment of source-monitor jobs.
    static func restoredUploadEligible(_ db:OpaquePointer,job:QueuedChange,source:String,target:String,
                                       identity:Data?=nil,fingerprint:SeedFileFingerprint?=nil)throws->Bool {
        guard try installed(db),try restorationInstalled(db) else { return false }
        let q=try prepare(db,"""
            SELECT d.identity,d.kind,d.file_size,d.modified_at,d.change_stamp
            FROM selective_restore_proof p
            JOIN selective_name_exception e ON e.id=p.exception_id
            JOIN selective_name_detached d ON d.exception_id=p.exception_id AND d.relative_path=p.path
            JOIN change_queue c ON c.id=p.restore_job AND c.root_id=e.root_id AND c.relative_path=p.path
            JOIN file_inventory f ON f.root_id=e.root_id AND f.relative_path=p.path AND f.lineage_observed_identity=d.identity
            JOIN directory_bindings s ON s.root_id=e.root_id AND s.role='source' AND s.stamp=e.source_binding
            JOIN directory_bindings t ON t.root_id=e.root_id AND t.role='target' AND t.stamp=e.target_binding
            WHERE c.id=?1 AND c.root_id=?2 AND c.relative_path=?3 AND c.completed=0 AND c.kind='upsert'
              AND c.origin='source_monitor' AND e.source_binding=?4 AND e.target_binding=?5
              AND e.state='returned' AND e.current_path=e.original_path AND f.kind=d.kind
              AND (d.kind='directory' OR (f.file_size=d.file_size AND f.modified_at=d.modified_at AND f.change_stamp=d.change_stamp))
              AND NOT EXISTS(SELECT 1 FROM change_queue other WHERE other.root_id=?2 AND other.relative_path=?3
                    AND other.id<>c.id AND (other.completed=0 OR other.id>c.id))
              AND NOT EXISTS(SELECT 1 FROM blocked_name_jobs b WHERE b.job_id=c.id);
            """)
        defer { sqlite3_finalize(q) }
        guard sqlite3_bind_int64(q,1,job.id)==SQLITE_OK else { throw fail(db) }
        try bind(job.rootID,2,q,db);try bind(job.relativePath,3,q,db);try bind(source,4,q,db);try bind(target,5,q,db)
        let rc=sqlite3_step(q)
        if rc==SQLITE_DONE { return false }
        guard rc==SQLITE_ROW,sqlite3_column_bytes(q,0)==33,let p=sqlite3_column_blob(q,0) else { throw fail(db) }
        if let identity,let fingerprint {
            guard Data(bytes:p,count:33)==identity else { return false }
            let kind=try string(q,1)
            if kind=="file" {
                guard fingerprint.size==sqlite3_column_int64(q,2),
                      abs(fingerprint.modifiedAt-sqlite3_column_double(q,3))<0.002,
                      try string(q,4)=="\(fingerprint.inode):\(fingerprint.ctimeSeconds):\(fingerprint.ctimeNanos)" else { return false }
            }
        }
        let next=sqlite3_step(q)
        if next==SQLITE_ROW { return false }
        guard next==SQLITE_DONE else { throw fail(db) }
        return try !rootUncertain(db,root:job.rootID)
    }

    private static func installSpeculativeJobs(_ db:OpaquePointer)throws {
        try exec(db,"""
            CREATE TABLE IF NOT EXISTS selective_invalid_upload(
                job_id INTEGER PRIMARY KEY,root_id TEXT NOT NULL,source_binding TEXT NOT NULL,
                target_binding TEXT NOT NULL,path TEXT NOT NULL,
                identity BLOB NOT NULL CHECK(length(identity)=33)
            );
            """)
    }

    // Only the very first source-monitor upload of a new, unpublishable
    // spelling can receive this provenance. Not proof of remote absence.
    static func canMarkSpeculative(_ db:OpaquePointer,root:String,source:String,row:TrackedItem)throws->Bool {
        guard sqlite3_get_autocommit(db)==0 else { throw SourceNameLineageStore.Failure.transactionRequired }
        guard !WindowsPathSafety.validRelativePath(row.relativePath),
              let identity=row.sourceLineageIdentity else { return false }
        let birth=Double(identity.birthSeconds)+Double(identity.birthNanos)/1_000_000_000
        let q=try prepare(db,"""
            SELECT 1 FROM watched_roots w
            JOIN directory_bindings s ON s.root_id=w.root_id AND s.role='source' AND s.stamp=?2
            JOIN directory_bindings t ON t.root_id=w.root_id AND t.role='target' AND length(t.stamp)>0
            WHERE w.root_id=?1 AND
              ((w.last_scan_at<?5
                AND NOT EXISTS(SELECT 1 FROM selective_name_detached d JOIN selective_name_exception e ON e.id=d.exception_id
                    WHERE e.root_id=?1 AND d.identity=?4))
               OR EXISTS(SELECT 1 FROM selective_name_detached d JOIN selective_name_exception e ON e.id=d.exception_id
                    WHERE e.root_id=?1 AND e.source_binding=?2 AND e.target_binding=t.stamp
                      AND d.identity=?4 AND e.state='incompatible' AND e.current_path IS NOT NULL
                      AND (d.relative_path=e.original_path OR instr(d.relative_path,e.original_path||'/')=1)
                      AND ?3=e.current_path||substr(d.relative_path,length(e.original_path)+1)))
              AND NOT EXISTS(SELECT 1 FROM change_queue c WHERE c.root_id=?1 AND c.relative_path=?3)
              AND NOT EXISTS(SELECT 1 FROM file_inventory f WHERE f.root_id=?1 AND f.lineage_observed_identity=?4)
              AND NOT EXISTS(SELECT 1 FROM publication_intents p WHERE p.root_id=?1 AND p.relative_path=?3)
              AND NOT EXISTS(SELECT 1 FROM transfer_recovery r WHERE r.root_id=?1 AND r.relative_path=?3)
              AND NOT EXISTS(SELECT 1 FROM upload_retry r WHERE r.root_id=?1 AND r.scope='root');
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db);try bind(source,2,q,db);try bind(row.relativePath,3,q,db)
        try bind(try SourceNameLineageStore.identityBytes(identity),4,q,db)
        guard sqlite3_bind_double(q,5,birth)==SQLITE_OK else { throw fail(db) }
        let rc=sqlite3_step(q)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw fail(db) }
        return rc==SQLITE_ROW
    }

    static func markSpeculative(_ db:OpaquePointer,root:String,source:String,row:TrackedItem,job:Int64)throws {
        guard sqlite3_get_autocommit(db)==0,let identity=row.sourceLineageIdentity else { throw SourceNameLineageStore.Failure.invalid }
        let q=try prepare(db,"""
            INSERT INTO selective_invalid_upload(job_id,root_id,source_binding,target_binding,path,identity)
            SELECT ?1,?2,?3,t.stamp,?4,?5 FROM directory_bindings t
            WHERE t.root_id=?2 AND t.role='target';
            """)
        defer { sqlite3_finalize(q) }
        guard sqlite3_bind_int64(q,1,job)==SQLITE_OK else { throw fail(db) }
        try bind(root,2,q,db);try bind(source,3,q,db);try bind(row.relativePath,4,q,db)
        try bind(try SourceNameLineageStore.identityBytes(identity),5,q,db)
        guard sqlite3_step(q)==SQLITE_DONE,sqlite3_changes(db)==1 else { throw fail(db) }
    }

    /// Retire the exact speculative UPSERT, not an existing DELETE. A
    /// possible legacy target object remains protected and independently
    /// discoverable by archive maintenance. Never infer remote absence.
    static func retireSpeculative(_ db:OpaquePointer,root:String,source:String,old:TrackedItem)throws->Bool {
        guard sqlite3_get_autocommit(db)==0 else { throw SourceNameLineageStore.Failure.transactionRequired }
        guard !WindowsPathSafety.validRelativePath(old.relativePath),
              let identity=old.storedLineageIdentity else { return false }
        let q=try prepare(db,"""
            SELECT c.id FROM selective_invalid_upload x
            JOIN directory_bindings t ON t.root_id=x.root_id AND t.role='target' AND t.stamp=x.target_binding
            JOIN change_queue c ON c.id=x.job_id AND c.root_id=x.root_id AND c.relative_path=x.path
            WHERE x.root_id=?1 AND x.source_binding=?2 AND x.path=?3 AND x.identity=?4
              AND c.completed=0 AND c.kind='upsert' AND c.origin='source_monitor'
              AND NOT EXISTS(SELECT 1 FROM change_queue other WHERE other.root_id=?1 AND other.relative_path=?3 AND other.id<>c.id)
              AND NOT EXISTS(SELECT 1 FROM publication_intents p WHERE p.root_id=?1 AND p.relative_path=?3)
              AND NOT EXISTS(SELECT 1 FROM transfer_recovery r WHERE r.root_id=?1 AND r.relative_path=?3)
              AND NOT EXISTS(SELECT 1 FROM upload_retry r WHERE r.root_id=?1 AND (r.scope='root' OR r.job_id=c.id))
              AND NOT EXISTS(SELECT 1 FROM retired_publication_evidence r WHERE r.job_id=c.id)
              AND NOT EXISTS(SELECT 1 FROM retired_delete_evidence r WHERE r.job_id=c.id)
              AND NOT EXISTS(SELECT 1 FROM name_rectification_monitor_links r WHERE r.job_id=c.id)
              AND NOT EXISTS(SELECT 1 FROM mirror_attempts r WHERE r.job_id=c.id);
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db);try bind(source,2,q,db);try bind(old.relativePath,3,q,db);try bind(identity,4,q,db)
        let rc=sqlite3_step(q)
        if rc==SQLITE_DONE { return false }
        guard rc==SQLITE_ROW else { throw fail(db) }
        let job=sqlite3_column_int64(q,0)
        let next=sqlite3_step(q)
        if next==SQLITE_ROW { return false }
        guard next==SQLITE_DONE else { throw fail(db) }
        for sql in ["DELETE FROM blocked_name_jobs WHERE job_id=?;",
                    "DELETE FROM selective_invalid_upload WHERE job_id=?;",
                    "DELETE FROM change_queue WHERE id=? AND completed=0 AND kind='upsert' AND origin='source_monitor';"] {
            let remove=try prepare(db,sql)
            defer { sqlite3_finalize(remove) }
            guard sqlite3_bind_int64(remove,1,job)==SQLITE_OK,sqlite3_step(remove)==SQLITE_DONE else { throw fail(db) }
        }
        guard sqlite3_changes(db)==1 else { throw SourceNameLineageStore.Failure.stale }
        return true
    }

    /// Byte-exact and Windows-equivalent ancestry veto. This table is checked
    /// after restart irrespective of the lab installation switch. A veto
    /// protects ancestors as well as the entire descendant tree.
    static func protects(_ db:OpaquePointer,root:String,path:String)throws->Bool {
        guard try installed(db) else { return false }
        let q=try prepare(db,"""
            SELECT 1 FROM selective_name_guard WHERE root_id=?1 AND
              (path=?2 OR instr(path,?2||'/')=1 OR instr(?2,path||'/')=1
               OR folded=?3 OR instr(folded,?3||'/')=1 OR instr(?3,folded||'/')=1)
            LIMIT 1;
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db);try bind(path,2,q,db);try bind(fold(path),3,q,db)
        let rc=sqlite3_step(q)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw fail(db) }
        return rc==SQLITE_ROW
    }

    private struct Entry {
        let id:Int64
        let original:String
        let current:String?
        let kind:String
    }
    private final class Writer {
        let db:OpaquePointer
        let root:String
        let source:String
        let target:String
        private let byIdentity:OpaquePointer
        private let byPath:OpaquePointer
        private let liveIdentity:OpaquePointer
        private let insert:OpaquePointer
        private let guardInsert:OpaquePointer
        private let detach:OpaquePointer
        private let stateUpdate:OpaquePointer

        init(_ db:OpaquePointer,root:String,source:String,target:String)throws {
            self.db=db;self.root=root;self.source=source;self.target=target
            var prepared:[OpaquePointer]=[]
            func stmt(_ sql:String)throws->OpaquePointer {
                let q=try SelectiveNameExceptionStore.prepare(db,sql)
                prepared.append(q);return q
            }
            do {
                byIdentity=try stmt("""
                    SELECT id,original_path,current_path,kind FROM selective_name_exception
                    WHERE root_id=?1 AND source_binding=?2 AND target_binding=?3 AND identity=?4;
                    """)
                byPath=try stmt("""
                    SELECT e.id,e.original_path,e.current_path,e.kind FROM selective_name_exception e
                    WHERE e.root_id=?1 AND e.source_binding=?2 AND e.target_binding=?3
                      AND e.identity IS ?4
                      AND (e.original_path=?5 OR e.current_path=?5 OR EXISTS(
                        SELECT 1 FROM selective_name_guard g WHERE g.exception_id=e.id
                         AND g.root_id=e.root_id AND g.path=?5));
                    """)
                liveIdentity=try stmt("""
                    SELECT relative_path,kind FROM file_inventory
                    WHERE root_id=?1 AND lineage_observed_identity=?2;
                    """)
                insert=try stmt("""
                    INSERT INTO selective_name_exception(root_id,source_binding,target_binding,identity,original_path,current_path,kind,state)
                    VALUES(?1,?2,?3,?4,?5,?6,?7,?8);
                    """)
                guardInsert=try stmt("INSERT OR IGNORE INTO selective_name_guard(exception_id,root_id,path,folded) VALUES(?,?,?,?);")
                detach=try stmt("""
                    INSERT OR IGNORE INTO selective_name_detached
                    SELECT ?1,relative_path,kind,file_size,modified_at,change_stamp,lineage_observed_identity
                      FROM file_inventory WHERE root_id=?2 AND
                        (relative_path=?3 OR (?4=1 AND relative_path>=?5 AND relative_path<?6));
                    """)
                stateUpdate=try stmt("UPDATE selective_name_exception SET current_path=?,state=? WHERE id=?;")
            } catch {
                for q in prepared { sqlite3_finalize(q) }
                throw error
            }
        }
        deinit {
            for q in [byIdentity,byPath,liveIdentity,insert,guardInsert,detach,stateUpdate] { sqlite3_finalize(q) }
        }
        private func reset(_ q:OpaquePointer) { sqlite3_reset(q);sqlite3_clear_bindings(q) }
        private func scope(_ q:OpaquePointer,_ identity:Data?)throws {
            try bind(root,1,q,db);try bind(source,2,q,db);try bind(target,3,q,db);try bind(identity,4,q,db)
        }
        private func entries(_ q:OpaquePointer)throws->[Entry] {
            var values:[Entry]=[]
            var rc=sqlite3_step(q)
            while rc==SQLITE_ROW {
                values.append(Entry(id:sqlite3_column_int64(q,0),original:try string(q,1),
                    current:sqlite3_column_type(q,2)==SQLITE_NULL ? nil : try string(q,2),kind:try string(q,3)))
                rc=sqlite3_step(q)
            }
            guard rc==SQLITE_DONE else { throw fail(db) }
            return values
        }
        func matches(_ identity:Data)throws->[Entry] {
            reset(byIdentity);defer { reset(byIdentity) }
            try scope(byIdentity,identity)
            return try entries(byIdentity)
        }
        func exactEntries(_ identity:Data?,path:String)throws->[Entry] {
            reset(byPath);defer { reset(byPath) }
            try scope(byPath,identity);try bind(path,5,byPath,db)
            return try entries(byPath)
        }
        func livePaths(_ identity:Data)throws->[(String,String)] {
            reset(liveIdentity);defer { reset(liveIdentity) }
            try bind(root,1,liveIdentity,db);try bind(identity,2,liveIdentity,db)
            var found:[(String,String)]=[]
            var rc=sqlite3_step(liveIdentity)
            while rc==SQLITE_ROW {
                found.append((try string(liveIdentity,0),try string(liveIdentity,1)))
                rc=sqlite3_step(liveIdentity)
            }
            guard rc==SQLITE_DONE else { throw fail(db) }
            return found
        }
        func protect(_ id:Int64,_ path:String)throws {
            reset(guardInsert);defer { reset(guardInsert) }
            guard sqlite3_bind_int64(guardInsert,1,id)==SQLITE_OK else { throw fail(db) }
            try bind(root,2,guardInsert,db);try bind(path,3,guardInsert,db);try bind(fold(path),4,guardInsert,db)
            guard sqlite3_step(guardInsert)==SQLITE_DONE else { throw fail(db) }
        }
        func update(_ entry:Entry,current:String?,state:String)throws {
            reset(stateUpdate);defer { reset(stateUpdate) }
            if let current { try bind(current,1,stateUpdate,db);try protect(entry.id,current) }
            else { guard sqlite3_bind_null(stateUpdate,1)==SQLITE_OK else { throw fail(db) } }
            try bind(state,2,stateUpdate,db)
            guard sqlite3_bind_int64(stateUpdate,3,entry.id)==SQLITE_OK,
                  sqlite3_step(stateUpdate)==SQLITE_DONE,sqlite3_changes(db)==1 else { throw fail(db) }
        }
        func create(path:String,identity:Data?,kind:String,current:String?,state:String,capture:Bool)throws->Entry {
            reset(insert);defer { reset(insert) }
            try scope(insert,identity);try bind(path,5,insert,db)
            if let current { try bind(current,6,insert,db) }
            else { guard sqlite3_bind_null(insert,6)==SQLITE_OK else { throw fail(db) } }
            try bind(kind,7,insert,db);try bind(state,8,insert,db)
            guard sqlite3_step(insert)==SQLITE_DONE else { throw fail(db) }
            let id=sqlite3_last_insert_rowid(db)
            try protect(id,path)
            if let current { try protect(id,current) }
            if capture {
                // Capture metadata only for the affected subtree, not a
                // separate archive-wide history of all its descendants.
                reset(detach);defer { reset(detach) }
                guard sqlite3_bind_int64(detach,1,id)==SQLITE_OK,
                      sqlite3_bind_int(detach,4,kind=="directory" ? 1:0)==SQLITE_OK else { throw fail(db) }
                try bind(root,2,detach,db);try bind(path,3,detach,db)
                try bind(path+"/",5,detach,db);try bind(path+"0",6,detach,db)
                guard sqlite3_step(detach)==SQLITE_DONE else { throw fail(db) }
                try captureRestoreProof(db,id:id,root:root,source:source,target:target)
            }
            return Entry(id:id,original:path,current:current,kind:kind)
        }
        func missing(path:String,identity:Data?,kind:String)throws->[Entry] {
            let exactMatches=try exactEntries(identity,path:path)
            if !exactMatches.isEmpty {
                // A late disappearance of ANY previously guarded spelling
                // cannot reset the newer observation or fork the identity.
                // Match exact path AND full identity in the same binding.
                for entry in exactMatches {
                    try protect(entry.id,path)
                    let disappearingCurrent=entry.current.map{exact($0,path)} == true
                    if exactMatches.count>1 {
                        try update(entry,current:disappearingCurrent ? nil:entry.current,state:"ambiguous")
                    } else if disappearingCurrent {
                        try update(entry,current:nil,state:"missing")
                    }
                }
                return exactMatches
            }
            return [try create(path:path,identity:identity,kind:kind,current:nil,state:"missing",capture:true)]
        }
        func observed(path:String,identity:Data?,kind:String,compatible:Bool,lookForMove:Bool)throws->Bool {
            if let identity,lookForMove {
                let entries=try matches(identity)
                if entries.count==1,let entry=entries.first {
                    try update(entry,current:path,state:compatible ? (exact(entry.original,path) ? "returned":"moved"):"incompatible")
                    return true
                }
                if entries.count>1 {
                    for entry in entries { try update(entry,current:path,state:"ambiguous") }
                    return true
                }
                let old=try livePaths(identity).filter{!exact($0.0,path)}
                if !old.isEmpty {
                    for (previous,previousKind) in old {
                        let entries=try missing(path:previous,identity:identity,kind:previousKind)
                        for entry in entries {
                            try update(entry,current:path,state:old.count>1 || entries.count>1 ? "ambiguous":(compatible ? "moved":"incompatible"))
                        }
                    }
                    return true
                }
            }
            if !compatible {
                let entries=try exactEntries(identity,path:path)
                if entries.isEmpty {
                    _=try create(path:path,identity:identity,kind:kind,current:path,state:"incompatible",capture:false)
                } else {
                    for entry in entries {
                        try update(entry,current:path,state:entries.count==1 ? "incompatible":"ambiguous")
                    }
                }
                return true
            }
            return false
        }
    }

    /// Called under the same BEGIN IMMEDIATE as inventory and queue writes,
    /// BEFORE any old row is overwritten/deleted or delete job is inserted.
    static func observe(_ db:OpaquePointer,root:String,source:String,
                        before:[String:TrackedItem],rows:[TrackedItem],pristine:Bool,
                        ignoreDSStore:Bool,shouldContinue:()->Bool)throws {
        guard sqlite3_get_autocommit(db)==0 else { throw SourceNameLineageStore.Failure.transactionRequired }
        let stamp=try prepare(db,"SELECT stamp FROM directory_bindings WHERE root_id=? AND role='target';")
        defer { sqlite3_finalize(stamp) }
        try bind(root,1,stamp,db)
        let rc=sqlite3_step(stamp)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw fail(db) }
        let target=rc==SQLITE_ROW ? try string(stamp,0):""
        let writer=try Writer(db,root:root,source:source,target:target)
        let seen=Dictionary(uniqueKeysWithValues:rows.map{($0.relativePath,$0)})
        // Only changed/new objects and disappearances participate. The
        // initial scan needs to check incompatible paths, not publish history.
        var missing:[TrackedItem]=[]
        var candidates:[(TrackedItem,Data?)]=[]
        for (path,old) in before {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard !FileExclusionPolicy.excludes(path,enabled:ignoreDSStore) else { continue }
            if seen[path]==nil { missing.append(old) }
        }
        for row in rows {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            let old=before[row.relativePath]
            let identity=try row.sourceLineageIdentity.map{try SourceNameLineageStore.identityBytes($0)}
            if old == nil || old?.storedLineageIdentity != identity {
                candidates.append((row,identity))
                // Same-spelling replacement cannot inherit prior evidence.
                if let old,old.storedLineageIdentity != nil,old.storedLineageIdentity != identity {
                    missing.append(old)
                }
            }
        }
        var coveredMissing=Set<Data>()
        for old in missing.sorted(by:{$0.relativePath.utf8.count<$1.relativePath.utf8.count}) {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            if ancestors(old.relativePath).contains(where:{coveredMissing.contains(Data($0.utf8))}) { continue }
            _=try writer.missing(path:old.relativePath,identity:old.storedLineageIdentity,kind:old.kind)
            if old.kind=="directory" { coveredMissing.insert(Data(old.relativePath.utf8)) }
        }
        var coveredNew=Set<Data>()
        // Do not link an identity that appeared more than once in this scan.
        var counts:[Data:Int]=[:]
        for (_,identity) in candidates {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            if let identity { counts[identity,default:0]+=1 }
        }
        for (row,identity) in candidates.sorted(by:{$0.0.relativePath.utf8.count<$1.0.relativePath.utf8.count}) {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            if ancestors(row.relativePath).contains(where:{coveredNew.contains(Data($0.utf8))}) { continue }
            let compatible=WindowsPathSafety.validRelativePath(row.relativePath)
            let unique=identity.flatMap{counts[$0]==1 ? $0:nil}
            if try writer.observed(path:row.relativePath,identity:unique,kind:row.kind,
                compatible:compatible,lookForMove:!pristine && unique != nil),row.kind=="directory" {
                coveredNew.insert(Data(row.relativePath.utf8))
            }
        }
    }

    /// Local comparison of a restored subtree with the captured pre-rename
    /// inventory. NOT a publication proof: the destination may have been
    /// seeded manually or have pending writes. Do not retire a job/guard
    /// using this summary alone. No filesystem or remote read.
    struct RestorationSummary: Equatable, Sendable {
        let capturedFiles:Int
        let unchangedMetadata:Int
        let changedOrReplaced:Int
        let absent:Int
        let newFiles:Int
    }
    static func restorationSummary(_ db:OpaquePointer,root:String,originalPath:String)throws->RestorationSummary? {
        guard try installed(db) else { return nil }
        let q=try prepare(db,"""
            SELECT e.id,e.kind FROM selective_name_exception e
            JOIN directory_bindings s ON s.root_id=e.root_id AND s.role='source' AND s.stamp=e.source_binding
            JOIN directory_bindings t ON t.root_id=e.root_id AND t.role='target' AND t.stamp=e.target_binding
            JOIN file_inventory f ON f.root_id=e.root_id AND f.relative_path=e.original_path
              AND f.lineage_observed_identity=e.identity AND f.kind=e.kind
            WHERE e.root_id=?1 AND e.original_path=?2 AND e.state='returned'
              AND e.current_path=e.original_path AND e.identity IS NOT NULL
              AND NOT EXISTS(SELECT 1 FROM selective_name_exception other
                WHERE other.root_id=e.root_id AND other.source_binding=e.source_binding
                  AND other.target_binding=e.target_binding AND other.identity=e.identity AND other.id<>e.id);
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db);try bind(originalPath,2,q,db)
        let rc=sqlite3_step(q)
        if rc==SQLITE_DONE { return nil }
        guard rc==SQLITE_ROW else { throw fail(db) }
        let id=sqlite3_column_int64(q,0),kind=try string(q,1)
        let next=sqlite3_step(q)
        if next==SQLITE_ROW { return nil }
        guard next==SQLITE_DONE else { throw fail(db) }
        // Read a single consistent SQLite snapshot. Callers must enclose
        // this method in their read/write transaction if used for decisions.
        let compare=try prepare(db,"""
            SELECT COUNT(*),
              COALESCE(SUM(CASE WHEN f.relative_path IS NOT NULL AND f.kind='file'
                AND d.identity IS NOT NULL AND f.lineage_observed_identity=d.identity
                AND d.change_stamp IS NOT NULL AND f.change_stamp=d.change_stamp
                AND f.file_size=d.file_size AND f.modified_at=d.modified_at THEN 1 ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN f.relative_path IS NULL THEN 1 ELSE 0 END),0)
            FROM selective_name_detached d LEFT JOIN file_inventory f
              ON f.root_id=?2 AND f.relative_path=d.relative_path
            WHERE d.exception_id=?1 AND d.kind='file';
            """)
        defer { sqlite3_finalize(compare) }
        guard sqlite3_bind_int64(compare,1,id)==SQLITE_OK else { throw fail(db) }
        try bind(root,2,compare,db)
        guard sqlite3_step(compare)==SQLITE_ROW else { throw fail(db) }
        let captured=Int(sqlite3_column_int64(compare,0))
        let unchanged=Int(sqlite3_column_int64(compare,1))
        let absent=Int(sqlite3_column_int64(compare,2))
        guard sqlite3_step(compare)==SQLITE_DONE else { throw fail(db) }
        let additions=try prepare(db,"""
            SELECT COUNT(*) FROM file_inventory f
            WHERE f.root_id=?2 AND f.kind='file'
              AND (f.relative_path=?3 OR (?4=1 AND f.relative_path>=?5 AND f.relative_path<?6))
              AND NOT EXISTS(SELECT 1 FROM selective_name_detached d
                WHERE d.exception_id=?1 AND d.relative_path=f.relative_path AND d.kind='file');
            """)
        defer { sqlite3_finalize(additions) }
        guard sqlite3_bind_int64(additions,1,id)==SQLITE_OK,
              sqlite3_bind_int(additions,4,kind=="directory" ? 1:0)==SQLITE_OK else { throw fail(db) }
        try bind(root,2,additions,db);try bind(originalPath,3,additions,db)
        try bind(originalPath+"/",5,additions,db);try bind(originalPath+"0",6,additions,db)
        guard sqlite3_step(additions)==SQLITE_ROW else { throw fail(db) }
        let newFiles=Int(sqlite3_column_int64(additions,0))
        guard sqlite3_step(additions)==SQLITE_DONE else { throw fail(db) }
        return RestorationSummary(capturedFiles:captured,unchangedMetadata:unchanged,
            changedOrReplaced:captured-unchanged-absent,absent:absent,newFiles:newFiles)
    }

    /// Release only a simple, compatible disappearance after the existing
    /// complete local mirror scan and its durable sequence/event checkpoint.
    /// No alias, replacement, independent descendant move, unknown identity
    /// or unresolved publication can count as proof of absence.
    static func resolveSimpleDisappearances(_ db:OpaquePointer,root:String,rows:[TrackedItem],
                                           shouldContinue:()->Bool)throws {
        guard try installed(db) else { return }
        guard sqlite3_get_autocommit(db)==0 else { throw SourceNameLineageStore.Failure.transactionRequired }
        try installRestorationProof(db)
        let q=try prepare(db,"""
            SELECT e.id,e.original_path FROM selective_name_exception e
            JOIN directory_bindings s ON s.root_id=e.root_id AND s.role='source' AND s.stamp=e.source_binding
            JOIN directory_bindings t ON t.root_id=e.root_id AND t.role='target' AND t.stamp=e.target_binding
            WHERE e.root_id=?1 AND e.state='missing' AND e.current_path IS NULL AND e.identity IS NOT NULL
              AND (SELECT COUNT(*) FROM selective_name_guard g WHERE g.exception_id=e.id)=1
              AND EXISTS(SELECT 1 FROM selective_name_detached d WHERE d.exception_id=e.id AND d.relative_path=e.original_path AND d.identity=e.identity)
              AND NOT EXISTS(SELECT 1 FROM selective_name_detached d WHERE d.exception_id=e.id AND d.identity IS NULL)
              AND NOT EXISTS(SELECT 1 FROM file_inventory f WHERE f.root_id=e.root_id
                  AND (f.relative_path=e.original_path OR instr(f.relative_path,e.original_path||'/')=1))
              AND NOT EXISTS(SELECT 1 FROM selective_name_exception other WHERE other.id<>e.id AND other.root_id=e.root_id AND other.identity=e.identity)
              AND NOT EXISTS(SELECT 1 FROM publication_intents p WHERE p.root_id=e.root_id)
              AND NOT EXISTS(SELECT 1 FROM transfer_recovery r WHERE r.root_id=e.root_id)
              AND NOT EXISTS(SELECT 1 FROM upload_retry r WHERE r.root_id=e.root_id)
              AND NOT EXISTS(SELECT 1 FROM retired_publication_evidence r JOIN change_queue c ON c.id=r.job_id WHERE c.root_id=e.root_id)
              AND NOT EXISTS(SELECT 1 FROM change_queue c WHERE c.root_id=e.root_id AND c.completed=0 AND c.kind='upsert'
                  AND (c.relative_path=e.original_path OR instr(c.relative_path,e.original_path||'/')=1 OR instr(e.original_path,c.relative_path||'/')=1));
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db)
        var candidates:[(Int64,String)]=[]
        var rc=sqlite3_step(q)
        while rc==SQLITE_ROW {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            let path=try string(q,1)
            if WindowsPathSafety.validRelativePath(path) { candidates.append((sqlite3_column_int64(q,0),path)) }
            rc=sqlite3_step(q)
        }
        guard rc==SQLITE_DONE else { throw fail(db) }
        guard !candidates.isEmpty else { return }
        // Only a complete, unambiguous scan can exclude an identity. Compare
        // device+inode even for hard links and reused inodes; conservative.
        var live=Set<Data>()
        var livePaths=Set<String>()
        for row in rows {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard row.kind != "symlink",let f=row.verificationFingerprint else { return }
            var key=Data(capacity:16)
            for value in [f.device,f.inode] {
                var word=value.bigEndian
                withUnsafeBytes(of:&word){key.append(contentsOf:$0)}
            }
            live.insert(key)
            livePaths.insert(fold(row.relativePath))
        }
        let detached=try prepare(db,"SELECT identity FROM selective_name_detached WHERE exception_id=?;")
        defer { sqlite3_finalize(detached) }
        for (id,path) in candidates {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            let folded=fold(path)
            // A live spelling/descendant alias means the disappearance is
            // not unambiguous, even if its inode differs.
            if livePaths.contains(where:{$0==folded || $0.hasPrefix(folded+"/")}) { continue }
            sqlite3_reset(detached);sqlite3_clear_bindings(detached)
            guard sqlite3_bind_int64(detached,1,id)==SQLITE_OK else { throw fail(db) }
            var absent=true, count=0
            var step=sqlite3_step(detached)
            while step==SQLITE_ROW {
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                guard sqlite3_column_bytes(detached,0)==33,let p=sqlite3_column_blob(detached,0) else { throw SourceNameLineageStore.Failure.invalid }
                count+=1
                if live.contains(Data(bytes:p,count:16)) { absent=false }
                step=sqlite3_step(detached)
            }
            guard step==SQLITE_DONE else { throw fail(db) }
            guard absent,count>0 else { continue }
            // Remove ONLY this exception's veto. Normal mirror rules,
            // copy-first, current job validation and other guards still apply.
            for table in ["selective_restore_proof","selective_name_detached","selective_name_guard","selective_name_exception"] {
                let column=table=="selective_name_exception" ? "id":"exception_id"
                let remove=try prepare(db,"DELETE FROM "+table+" WHERE "+column+"=?;")
                defer { sqlite3_finalize(remove) }
                guard sqlite3_bind_int64(remove,1,id)==SQLITE_OK,sqlite3_step(remove)==SQLITE_DONE else { throw fail(db) }
            }
        }
    }

    static func resolveAuditedNativeRestorations(_ db:OpaquePointer,root:String,
                    source:String,target:String,sourceRows:[TrackedItem],targetRows:[TrackedItem],
                    shouldContinue:()->Bool)throws {
        guard try installed(db),try restorationInstalled(db),sqlite3_get_autocommit(db)==0,
              try !rootUncertain(db,root:root) else { return }
        // Caller proved a fully matching, current audit, no pending jobs and
        // a native target. Require exact root identity in live inventory.
        let q=try prepare(db,"""
            SELECT e.id,e.original_path,e.current_path FROM selective_name_exception e
            JOIN file_inventory f ON f.root_id=e.root_id AND f.relative_path=e.current_path
              AND f.lineage_observed_identity=e.identity AND f.kind=e.kind
            WHERE e.root_id=?1 AND e.source_binding=?2 AND e.target_binding=?3
              AND e.state IN ('returned','moved') AND e.identity IS NOT NULL
              AND NOT EXISTS(SELECT 1 FROM selective_name_exception other WHERE other.id<>e.id AND other.root_id=e.root_id AND other.identity=e.identity);
            """)
        defer { sqlite3_finalize(q) }
        try bind(root,1,q,db);try bind(source,2,q,db);try bind(target,3,q,db)
        var entries:[(Int64,String,String)]=[]
        var rc=sqlite3_step(q)
        while rc==SQLITE_ROW {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            entries.append((sqlite3_column_int64(q,0),try string(q,1),try string(q,2)))
            rc=sqlite3_step(q)
        }
        guard rc==SQLITE_DONE else { throw fail(db) }
        guard !entries.isEmpty else { return }
        let sourcePaths=Set(sourceRows.map{Data($0.relativePath.utf8)})
        let targetPaths=Set(targetRows.map{Data($0.relativePath.utf8)})
        let guards=try prepare(db,"SELECT path FROM selective_name_guard WHERE exception_id=?;")
        defer { sqlite3_finalize(guards) }
        for (id,original,current) in entries {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard WindowsPathSafety.validRelativePath(current),
                  sourcePaths.contains(Data(current.utf8)),targetPaths.contains(Data(current.utf8)) else { continue }
            // Native complete enumeration reveals literal spellings. Do not
            // use this release path on SMB, where a legacy name may be hidden.
            sqlite3_reset(guards);sqlite3_clear_bindings(guards)
            guard sqlite3_bind_int64(guards,1,id)==SQLITE_OK else { throw fail(db) }
            var safe=true
            var step=sqlite3_step(guards)
            while step==SQLITE_ROW {
                let path=try string(guards,0)
                if !exact(path,current) {
                    let prefix=Data((path+"/").utf8),key=Data(path.utf8)
                    if sourcePaths.contains(key) || targetPaths.contains(key) ||
                       sourcePaths.contains(where:{$0.starts(with:prefix)}) ||
                       targetPaths.contains(where:{$0.starts(with:prefix)}) { safe=false }
                }
                step=sqlite3_step(guards)
            }
            guard step==SQLITE_DONE else { throw fail(db) }
            guard safe else { continue }
            // A name reuse or overlapping unresolved exception must not
            // lose its independent veto. Only remove this exact record.
            _ = original
            for table in ["selective_restore_proof","selective_name_detached","selective_name_guard","selective_name_exception"] {
                let column=table=="selective_name_exception" ? "id":"exception_id"
                let remove=try prepare(db,"DELETE FROM "+table+" WHERE "+column+"=?;")
                defer { sqlite3_finalize(remove) }
                guard sqlite3_bind_int64(remove,1,id)==SQLITE_OK,sqlite3_step(remove)==SQLITE_DONE else { throw fail(db) }
            }
        }
    }

    static func hasExceptions(_ db:OpaquePointer)throws->Bool {
        guard try installed(db) else { return false }
        let q=try prepare(db,"SELECT 1 FROM selective_name_exception LIMIT 1;")
        defer { sqlite3_finalize(q) }
        let rc=sqlite3_step(q)
        guard rc==SQLITE_ROW || rc==SQLITE_DONE else { throw fail(db) }
        return rc==SQLITE_ROW
    }

    /// Existing signed rollback takes a verified backup before this method.
    /// The predecessor cannot enforce our vetoes: conservatively quarantine
    /// all delete jobs in affected roots and latch mirror before discarding
    /// derived records in the working database. Backup retains the evidence.
    static func prepareRollback(_ db:OpaquePointer,allowProtectedDeletions:Bool)throws {
        guard try installed(db) else { return }
        guard sqlite3_get_autocommit(db)==0 else { throw SourceNameLineageStore.Failure.transactionRequired }
        if try hasExceptions(db) {
            guard allowProtectedDeletions else { throw ApplicationRollback.Failure("Eccezioni di rinomina ancora protette.") }
            try exec(db,"""
                CREATE TABLE IF NOT EXISTS rollback_protected_deletions(
                    job_id INTEGER PRIMARY KEY,root_id TEXT NOT NULL,relative_path TEXT NOT NULL,
                    kind TEXT NOT NULL,recorded_at REAL NOT NULL,original_completed INTEGER NOT NULL,
                    origin TEXT NOT NULL,archived_at REAL NOT NULL
                );
                INSERT INTO rollback_protected_deletions
                SELECT q.id,q.root_id,q.relative_path,q.kind,q.recorded_at,q.completed,q.origin,
                       (julianday('now')-2440587.5)*86400.0
                FROM change_queue q WHERE q.kind='delete'
                  AND (q.completed=0 OR EXISTS(SELECT 1 FROM retired_delete_evidence e WHERE e.job_id=q.id))
                  AND EXISTS(SELECT 1 FROM selective_name_exception e WHERE e.root_id=q.root_id);
                DELETE FROM retired_delete_evidence WHERE job_id IN (SELECT job_id FROM rollback_protected_deletions);
                DELETE FROM blocked_name_jobs WHERE job_id IN (SELECT job_id FROM rollback_protected_deletions);
                DELETE FROM change_queue WHERE id IN (SELECT job_id FROM rollback_protected_deletions);
                INSERT OR IGNORE INTO mirror_safety_lock(singleton,reason)
                   VALUES(1,'Rollback: eccezioni rinomina conservate nel backup; cancellazioni sospese per verifica.');
                """)
        }
        try exec(db,"DROP TABLE IF EXISTS selective_clean_baseline; DROP TABLE IF EXISTS selective_restore_proof; DROP TABLE IF EXISTS selective_invalid_upload; DROP TABLE selective_name_detached; DROP TABLE selective_name_guard; DROP TABLE selective_name_exception; DROP INDEX idx_selective_live_identity;")
    }
}
