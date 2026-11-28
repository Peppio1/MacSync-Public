import Foundation
import Darwin
import SQLite3

/// Offline voluntary rollback, separate from Sparkle's forward transaction.
/// Only explicitly pinned predecessor packages and validated schemas are supported.
/// The caller must hold the exclusive operational archive lock.
public enum SignedRollbackTransaction {
    private static func open(_ url:URL,write:Bool=false) throws -> OpaquePointer {
        _ = try ArchiveDatabaseSafety.fileIdentity(url)
        var db:OpaquePointer?
        guard sqlite3_open_v2(url.path,&db,write ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY,nil)==SQLITE_OK,let db else {
            if let db { sqlite3_close(db) }
            throw ApplicationRollback.Failure("Archivio non accessibile per rollback.")
        }
        sqlite3_busy_timeout(db,5000)
        return db
    }
    private static func scalar(_ db:OpaquePointer,_ sql:String) throws -> Int64 {
        var statement:OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,
              let statement,sqlite3_step(statement)==SQLITE_ROW else {
            throw ApplicationRollback.Failure("Schema SQLite non riconosciuto per rollback.")
        }
        let value=sqlite3_column_int64(statement,0)
        guard sqlite3_step(statement)==SQLITE_DONE else {
            throw ApplicationRollback.Failure("Controllo SQLite non riuscito.")
        }
        return value
    }
    public static func validateCompatibility(database:URL, allowProtectedDeletions:Bool = false) throws {
        try ArchiveDatabaseSafety.verify(database,readOnly:true)
        let db=try open(database)
        defer { sqlite3_close(db) }
        guard try scalar(db,"PRAGMA user_version;")==0,
              try scalar(db,"PRAGMA application_id;")==0 else {
            throw ApplicationRollback.Failure("Versione dello schema SQLite non compatibile.")
        }
        let layouts:[String:Set<String>]=[
            "file_inventory":["root_id","relative_path","kind","file_size","modified_at","change_stamp"],
            "watched_roots":["root_id","absolute_path","last_event_id","last_scan_at"],
            "change_queue":["id","root_id","relative_path","kind","recorded_at","completed","origin"],
            "directory_bindings":["root_id","role","stamp"],
            "source_name_index_ready":["root_id"]
        ]
        for (table,expected) in layouts {
            var stmt:OpaquePointer?
            defer { if let stmt { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db,"PRAGMA table_info(\(table));",-1,&stmt,nil)==SQLITE_OK,let stmt else {
                throw ApplicationRollback.Failure("Schema SQLite non riconosciuto.")
            }
            var actual=Set<String>()
            var rc=sqlite3_step(stmt)
            while rc==SQLITE_ROW {
                guard let name=sqlite3_column_text(stmt,1) else { throw ApplicationRollback.Failure("Colonna SQLite non riconosciuta.") }
                actual.insert(String(cString:name));rc=sqlite3_step(stmt)
            }
            let knownIntegrated = table=="file_inventory" &&
                actual==expected.union(SourceNameLineageStore.integratedColumns)
            let compatible = actual==expected ? true : (knownIntegrated ? try SourceNameLineageStore.integratedLayoutInstalled(db) : false)
            guard rc==SQLITE_DONE,compatible else {
                throw ApplicationRollback.Failure("Schema non compatibile: "+table)
            }
        }
        guard try scalar(db,"SELECT COUNT(*) FROM change_queue WHERE kind NOT IN ('upsert','delete') OR origin NOT IN ('initial_inventory','source_monitor','archive_audit','destination_rebind','legacy_unknown');")==0 else {
            throw ApplicationRollback.Failure("Operazioni in coda di formato non compatibile.")
        }
        if !allowProtectedDeletions,try SelectiveNameExceptionStore.hasExceptions(db) {
            throw ApplicationRollback.Failure("Eccezioni di rinomina ancora protette.")
        }
        if !allowProtectedDeletions,try SourceNameLineageStore.protectionInstalled(db) {
            guard try scalar(db,"SELECT COUNT(*) FROM source_lineage_hold;")==0 else {
                throw ApplicationRollback.Failure("Rettifiche con copie protette ancora pendenti: completa la riconciliazione prima del rollback.")
            }
        }
        for table in ["name_rectification_batch","name_rectification_groups","queue_rebuild_hold","publication_intents","transfer_recovery","retired_publication_evidence"] {
            guard try scalar(db,"SELECT COUNT(*) FROM \(table);")==0 else {
                throw ApplicationRollback.Failure("Operazioni di recupero o rettifiche non concluse: completa la riconciliazione prima del rollback.")
            }
        }
    }
    public static func invalidateDerivedNameIndex(database:URL) throws {
        try preparePredecessorDatabase(database:database,allowProtectedDeletions:false)
    }

    /// Only call after a verified snapshot and explicit rollback consent.
    /// A predecessor cannot understand the lineage hold table. Archive the
    /// exact protected delete jobs instead of exposing them as executable.
    /// No filesystem mutation; the full pre-rollback database is retained.
    static func preparePredecessorDatabase(database:URL,allowProtectedDeletions:Bool) throws {
        let db=try open(database,write:true)
        defer { sqlite3_close(db) }
        // Rebuild the derived index on the predecessor to avoid stale classification.
        guard sqlite3_exec(db,"BEGIN IMMEDIATE TRANSACTION;",nil,nil,nil)==SQLITE_OK else {
            throw ApplicationRollback.Failure("Impossibile invalidare l’indice derivato.")
        }
        do {
            if try SourceNameLineageStore.protectionInstalled(db),
               try scalar(db,"SELECT COUNT(*) FROM source_lineage_hold;") > 0 {
                guard allowProtectedDeletions else {
                    throw ApplicationRollback.Failure("Rettifiche con copie protette ancora pendenti.")
                }
                let sql = """
                    CREATE TABLE IF NOT EXISTS rollback_protected_deletions(
                        job_id INTEGER PRIMARY KEY, root_id TEXT NOT NULL, relative_path TEXT NOT NULL,
                        kind TEXT NOT NULL, recorded_at REAL NOT NULL, original_completed INTEGER NOT NULL,
                        origin TEXT NOT NULL, archived_at REAL NOT NULL
                    );
                    INSERT INTO rollback_protected_deletions
                    SELECT q.id,q.root_id,q.relative_path,q.kind,q.recorded_at,q.completed,q.origin,
                           (julianday('now')-2440587.5)*86400.0
                    FROM change_queue q
                    WHERE q.kind='delete'
                      AND (q.completed=0 OR EXISTS(SELECT 1 FROM retired_delete_evidence e WHERE e.job_id=q.id))
                      AND EXISTS(SELECT 1 FROM source_lineage_hold h JOIN source_lineage_mapping m ON m.id=h.mapping_id
                        WHERE m.root_id=q.root_id AND
                        (h.protected_path=q.relative_path OR instr(h.protected_path,q.relative_path||'/')=1
                         OR instr(q.relative_path,h.protected_path||'/')=1));
                    DELETE FROM retired_delete_evidence WHERE job_id IN (SELECT job_id FROM rollback_protected_deletions);
                    DELETE FROM blocked_name_jobs WHERE job_id IN (SELECT job_id FROM rollback_protected_deletions);
                    DELETE FROM change_queue WHERE id IN (SELECT job_id FROM rollback_protected_deletions);
                    INSERT OR IGNORE INTO mirror_safety_lock(singleton,reason)
                        VALUES(1,'Rollback: cancellazioni protette conservate nel backup e sospese. Verifica archivio e controlla la coda prima di riprendere la sincronizzazione.');
                    """
                guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {
                    throw ApplicationRollback.Failure("Impossibile conservare le cancellazioni protette.")
                }
            }
            try SelectiveNameExceptionStore.prepareRollback(db,allowProtectedDeletions:allowProtectedDeletions)
            try SourceNameLineageStore.removeIntegratedLayoutForRollback(db)
            // The predecessor cannot maintain these derived observations.
            // Invalidate them instead of allowing stale evidence on re-upgrade.
            for table in ["source_lineage_invalid_observation","source_lineage_hold","source_lineage_index","source_lineage_mapping"] {
                if try scalar(db,"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='"+table+"';") == 1 {
                    guard sqlite3_exec(db,"DELETE FROM "+table+";",nil,nil,nil)==SQLITE_OK else {
                        throw ApplicationRollback.Failure("Impossibile invalidare lo storico derivato.")
                    }
                }
            }
            guard sqlite3_exec(db,"DELETE FROM source_name_index_ready; COMMIT;",nil,nil,nil)==SQLITE_OK else {
                throw ApplicationRollback.Failure("Impossibile invalidare l’indice derivato.")
            }
        } catch { sqlite3_exec(db,"ROLLBACK;",nil,nil,nil); throw error }
    }
    private static func requirePrivateDirectory(_ url:URL) throws {
        let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory==true,values.isSymbolicLink != true,
              url.standardizedFileURL.path==url.resolvingSymlinksInPath().path else {
            throw ApplicationRollback.Failure("Percorso rollback non valido.")
        }
        var info=stat()
        guard url.path.withCString({lstat($0,&info)})==0,info.st_uid==getuid(),
              info.st_mode & 0o077 == 0 else {
            throw ApplicationRollback.Failure("Cartella rollback non privata.")
        }
    }
    private static func requireAbsent(_ url:URL) throws {
        var info=stat()
        guard url.path.withCString({lstat($0,&info)}) != 0,errno==ENOENT else {
            throw ApplicationRollback.Failure("Altra manutenzione in corso.")
        }
    }
    public static func install(root:URL,snapshot:URL,target:URL,defaults:UserDefaults) throws {
        try install(root:root,snapshot:snapshot,target:target,defaults:defaults,
            allowsLocation:ApplicationRollback.allowedInstallLocation)
    }

    // Internal boundary for an isolated filesystem laboratory. The public
    // installer always applies the production install-location restriction.
    static func install(root:URL,snapshot:URL,target:URL,defaults:UserDefaults,
                        allowsLocation:(URL)->Bool) throws {
        let coordinator=UpdateRecoveryCoordinator(root:root)
        let backupRoot=coordinator.backupRoot
        guard allowsLocation(target),
              snapshot.deletingLastPathComponent().path==backupRoot.path,
              snapshot.lastPathComponent.hasPrefix("update-backup-"),
              let uuid=UUID(uuidString:String(snapshot.lastPathComponent.dropFirst("update-backup-".count))),
              snapshot.lastPathComponent=="update-backup-"+uuid.uuidString else {
            throw ApplicationRollback.Failure("Destinazione o versione rollback non autorizzata.")
        }
        let stage=snapshot.appendingPathComponent("signed-rollback",isDirectory:true)
        try requirePrivateDirectory(backupRoot)
        try requirePrivateDirectory(snapshot)
        try requirePrivateDirectory(stage)
        try requireAbsent(coordinator.markerURL)
        try requireAbsent(root.appendingPathComponent("factory-reset.pending"))
        let saved=snapshot.appendingPathComponent("inventory.sqlite")
        let current=coordinator.database
        let info=try Data(contentsOf:target.appendingPathComponent("Contents/Info.plist"))
        guard let plist=try PropertyListSerialization.propertyList(from:info,format:nil) as? [String:Any],
              let installed=plist["CFBundleShortVersionString"] as? String,
              let package=SignedRollbackPackage.previous(for:installed) else {
            throw ApplicationRollback.Failure("Versione rollback non autorizzata.")
        }
        try ApplicationRollback.validateBundle(target,version:installed)
        try ApplicationRollback.validateBundle(snapshot.appendingPathComponent("MacSync.app"),version:installed)
        try validateCompatibility(database:current,allowProtectedDeletions:true)
        try ArchiveDatabaseSafety.verify(saved,readOnly:true)
        guard try ApplicationRollback.databaseDigest(current,scratch:stage)==ApplicationRollback.databaseDigest(saved,scratch:stage) else {
            throw ApplicationRollback.Failure("L’archivio è cambiato dopo il backup. Nessun ripristino effettuato.")
        }
        let candidate=try package.extractVerified(in:stage)
        try Self.validateCompatibility(database:current,allowProtectedDeletions:true)
        try UpdateRecoveryCoordinator.disableCopyAuthorizations(defaults)
        defaults.set("v"+installed,forKey:"MacSync.updates.skippedStableTag")
        guard defaults.synchronize() else { throw ApplicationRollback.Failure("Preferenze non salvate.") }
        try preparePredecessorDatabase(database:current,allowProtectedDeletions:true)
        _ = try ApplicationRollback.replaceApplication(target:target,backup:candidate) {
            try package.validateApplication($0)
        }
    }
}
