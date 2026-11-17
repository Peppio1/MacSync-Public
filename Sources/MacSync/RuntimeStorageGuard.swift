import AppKit
import Foundation
import Darwin
import MacSyncCore

/// Acquire before creating the runtime/model; no second process may open
/// the operational database or start a watcher. Quit releases the OS lock.
@MainActor
final class RuntimeStorageGuard {
    private let lock: ExclusiveArchiveLock
    private let folder: URL
    private init(lock: ExclusiveArchiveLock, folder: URL) {
        self.lock = lock
        self.folder = folder
    }

    /// Only called by the drained runtime while this guard owns the lock.
    func createUpdateSnapshot() throws -> URL {
        let directory = folder.appendingPathComponent("update-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try UpdateRecoverySnapshot.create(
            database: folder.appendingPathComponent("inventory.sqlite"),
            application: Bundle.main.bundleURL,
            preferences: UserDefaults.standard.dictionaryRepresentation(),
            parent: directory)
    }

    private static func disableCopyAuthorizations(_ defaults: UserDefaults) throws {
        defaults.set(false, forKey: "MacSync.autoCopiesEnabled")
        defaults.set(false, forKey: "MacSync.autoCopiesEnabled.v2")
        defaults.removeObject(forKey: "MacSync.mirrorAuthorization.v1")
        defaults.removeObject(forKey: "MacSync.mirrorEnabled")
        if let data = defaults.data(forKey: "MacSync.archiveAuditSettings"),
           var value = try? JSONDecoder().decode(ArchiveAuditSettings.self, from: data) {
            value.enabled = false
            value.repair = false
            defaults.set(try JSONEncoder().encode(value), forKey: "MacSync.archiveAuditSettings")
        }
        guard defaults.synchronize() else { throw UpdateTransactionMarker.MarkerError.invalid }
    }

    func beginSignedUpdate(previous: String, requested: String, snapshot: URL) throws {
        let backupApp = snapshot.appendingPathComponent("MacSync.app")
        try ApplicationRollback.validateBundle(backupApp, version: previous)
        let marker = try UpdateTransactionMarker(previousVersion: previous, requestedVersion: requested,
                                                 snapshotName: snapshot.lastPathComponent)
        let manifest = try ApplicationRecoveryManifest(application: Bundle.main.bundleURL, marker: marker)
        try manifest.write(to: snapshot.appendingPathComponent("recovery.json"))
        let helper = backupApp.appendingPathComponent("Contents/MacOS/MacSyncRecovery")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ApplicationRollback.Failure("Strumento di recupero mancante.")
        }
        let wrapper = snapshot.appendingPathComponent("Ripristina MacSync.command")
        let source = backupApp.appendingPathComponent("Contents/Resources/Ripristina MacSync.command")
        try FileManager.default.copyItem(at: source, to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        try marker.write(to: folder.appendingPathComponent("update-pending.json"))
        try Self.disableCopyAuthorizations(.standard)
    }

    private static func inspectPendingUpdate(folder: URL, database: URL, defaults: UserDefaults) throws -> URL? {
        let url = folder.appendingPathComponent("update-pending.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Run before creating any operational model, watcher or copy worker.
        try disableCopyAuthorizations(defaults)
        let marker = try UpdateTransactionMarker.read(from: url)
        let snapshot = folder.appendingPathComponent("update-backups", isDirectory: true)
            .appendingPathComponent(marker.snapshotName, isDirectory: true)
        try ArchiveDatabaseSafety.verify(snapshot.appendingPathComponent("inventory.sqlite"), readOnly: true)
        try ApplicationRollback.validateBundle(snapshot.appendingPathComponent("MacSync.app"), version: marker.previousVersion)
        try ArchiveDatabaseSafety.verify(database)
        guard let actual = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              actual == marker.previousVersion || actual == marker.requestedVersion else {
            throw ApplicationRollback.Failure("Versione inattesa. Apri il backup e usa il recupero solo a MacSync chiuso: " + snapshot.path)
        }
        try ApplicationRollback.validateBundle(Bundle.main.bundleURL, version: actual)
        let alert = NSAlert()
        alert.messageText = actual == marker.requestedVersion ? "Aggiornamento verificato" : "Aggiornamento non completato"
        alert.informativeText = "Archivio e copia della versione precedente verificati.\nBackup: " + snapshot.path +
            "\n\nLe copie automatiche, le cancellazioni e le verifiche pianificate restano disattivate: controlla la configurazione e riabilitale esplicitamente. Non verrà ripristinato automaticamente un database precedente."
        alert.addButton(withTitle: "Continua")
        alert.addButton(withTitle: "Apri backup ed esci")
        if alert.runModal() != .alertFirstButtonReturn {
            NSWorkspace.shared.open(snapshot)
            Darwin.exit(0)
        }
        // Keep the marker through all subsequent database initialization.
        return url
    }

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
            let pendingUpdate = try inspectPendingUpdate(folder: folder, database: db, defaults: defaults)
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
            if let pendingUpdate { try FileManager.default.removeItem(at: pendingUpdate) }
            return RuntimeStorageGuard(lock:lock, folder:folder)
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
        if runtime.preparingSignedUpdate { return .terminateCancel }
        if runtime.readyForTermination { return .terminateNow }
        runtime.requestShutdown {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
