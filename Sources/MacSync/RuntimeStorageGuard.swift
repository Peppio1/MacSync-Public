import AppKit
import Foundation
import Darwin
import MacSyncCore

/// Acquire before creating the runtime/model; no second process may open
/// the operational database or start a watcher. Quit releases the OS lock.
@MainActor
final class RuntimeStorageGuard {
    private let lock: ExclusiveArchiveLock
    private init(lock: ExclusiveArchiveLock) { self.lock = lock }

    static func acquireOrExit() -> RuntimeStorageGuard {
        do {
            let folder = try FileManager.default.url(for:.applicationSupportDirectory,
                in:.userDomainMask,appropriateFor:nil,create:true)
                .appendingPathComponent("MacSync",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let lock = try ExclusiveArchiveLock(url:folder.appendingPathComponent("archive.lock"))
            let db = folder.appendingPathComponent("inventory.sqlite")
            let defaults = UserDefaults.standard
            let exists = FileManager.default.fileExists(atPath:db.path)
            let previousIdentity = defaults.string(forKey:"MacSync.databaseFileIdentity.v014")
            guard exists || previousIdentity == nil else { throw JournalError.database("Database operativo mancante: ripristinare una copia verificata") }
            if exists { try ArchiveDatabaseSafety.verify(db) }
            let currentIdentity = exists ? try ArchiveDatabaseSafety.fileIdentity(db) : nil
            let restored = previousIdentity != nil && currentIdentity != previousIdentity
            if !defaults.bool(forKey:"MacSync.safetyMigration.v014") || restored {
                if FileManager.default.fileExists(atPath:db.path) {
                    let backup = folder.appendingPathComponent((restored ? "restored-database-" : "migration-v0.13.9-")+UUID().uuidString,isDirectory:true)
                    try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:false,
                        attributes:[.posixPermissions:0o700])
                    try ArchiveDatabaseSafety.backup(db,to:backup.appendingPathComponent("inventory.sqlite"))
                    // Preserve only this application's own preferences locally.
                    let values = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("MacSync.") }
                    let plist = try PropertyListSerialization.data(fromPropertyList:values,format:.binary,options:0)
                    try plist.write(to:backup.appendingPathComponent("preferences.plist"),options:.atomic)
                }
                // Old consent predates the persistent directory bindings.
                // The old application also sees both automatic keys disabled.
                defaults.set(false,forKey:"MacSync.autoCopiesEnabled")
                defaults.set(false,forKey:"MacSync.autoCopiesEnabled.v2")
                defaults.removeObject(forKey:"MacSync.mirrorAuthorization.v1")
                defaults.removeObject(forKey:"MacSync.mirrorEnabled")
                if let data = defaults.data(forKey:"MacSync.archiveAuditSettings"),
                   var settings = try? JSONDecoder().decode(ArchiveAuditSettings.self,from:data) {
                    settings.enabled = false; settings.repair = false
                    defaults.set(try JSONEncoder().encode(settings),forKey:"MacSync.archiveAuditSettings")
                }
                defaults.set(true,forKey:"MacSync.safetyMigration.v014")
            }
            // Schema migration occurs only after the verified backup and disabling old authorizations.
            _ = try LocalInventory(path:db.path)
            _ = try ChangeJournal(path:db.path)
            try ArchiveDatabaseSafety.verify(db)
            defaults.set(try ArchiveDatabaseSafety.fileIdentity(db),forKey:"MacSync.databaseFileIdentity.v014")
            // One verified snapshot per calendar day on startup; the migration
            // backup is a separate immutable directory. No automatic restore.
            if FileManager.default.fileExists(atPath:db.path) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                let snapshots = folder.appendingPathComponent("database-backups",isDirectory:true)
                try FileManager.default.createDirectory(at:snapshots,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let day = snapshots.appendingPathComponent(formatter.string(from:Date())+".sqlite")
                if !FileManager.default.fileExists(atPath:day.path) {
                    try ArchiveDatabaseSafety.backup(db,to:day)
                } else { try ArchiveDatabaseSafety.verify(day,readOnly:true) }
            }
            return RuntimeStorageGuard(lock:lock)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "MacSync non può avviare l’archivio"
            alert.informativeText = error.localizedDescription + "\nNessuna sincronizzazione verrà eseguita. Non eliminare il database o il file di blocco."
            alert.addButton(withTitle:"Esci")
            alert.runModal()
            Darwin.exit(1)
        }
    }
}

@MainActor
final class MacSyncTerminationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let runtime = MacSyncRuntime.operationalRuntime else { return .terminateNow }
        runtime.requestShutdown { sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
}
