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
        try UpdateRecoveryCoordinator(root: folder).createSnapshot(application: Bundle.main.bundleURL,
            preferences: UserDefaults.standard.dictionaryRepresentation())
    }

    func beginSignedUpdate(previous: String, requested: String, snapshot: URL) throws {
        try UpdateRecoveryCoordinator(root: folder).begin(application: Bundle.main.bundleURL, previous: previous,
            requested: requested, snapshot: snapshot, defaults: .standard)
    }

    func scheduleFactoryReset(configuredPaths: [String]) throws {
        try FactoryReset.schedule(in: folder, configuredPaths: configuredPaths)
    }

    private static func inspectPendingUpdate(folder: URL, defaults: UserDefaults) throws -> UpdateRecoveryCoordinator.Pending? {
        guard let pending = try UpdateRecoveryCoordinator(root: folder).startup(application: Bundle.main.bundleURL,
                                                                                   defaults: defaults) else { return nil }
        let actual = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let alert = NSAlert()
        alert.messageText = actual == pending.marker.requestedVersion ? "Aggiornamento verificato" : "Aggiornamento non completato"
        alert.informativeText = "Archivio e copia precedente verificati.\nBackup: " + pending.snapshot.path +
            "\n\nCopie automatiche, cancellazioni e verifiche pianificate restano disattivate. Controlla le impostazioni e riabilitale esplicitamente."
        alert.addButton(withTitle: "Continua")
        alert.addButton(withTitle: "Apri backup ed esci")
        if alert.runModal() != .alertFirstButtonReturn {
            NSWorkspace.shared.open(pending.snapshot)
            Darwin.exit(0)
        }
        return pending
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
            try FactoryReset.completeIfScheduled(in: folder) {
                if let identifier = Bundle.main.bundleIdentifier {
                    defaults.removePersistentDomain(forName: identifier)
                }
                let legacyKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("MacSync.") }
                for key in legacyKeys { defaults.removeObject(forKey: key) }
                guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            }
            let exists = FileManager.default.fileExists(atPath:db.path)
            let previousIdentity = defaults.string(forKey:"MacSync.databaseFileIdentity.v014")
            guard exists || previousIdentity == nil else { throw JournalError.database("Database operativo mancante: ripristinare una copia verificata") }
            if exists { try ArchiveDatabaseSafety.verify(db) }
            let pendingUpdate = try inspectPendingUpdate(folder: folder, defaults: defaults)
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
            if let pendingUpdate { try UpdateRecoveryCoordinator(root: folder).complete(pendingUpdate, defaults: defaults) }
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
    private var awaitingReply = false

    private func finish(_ sender: NSApplication) {
        guard awaitingReply else { return }
        awaitingReply = false
        sender.reply(toApplicationShouldTerminate:true)
    }

    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let runtime = MacSyncRuntime.operationalRuntime else { return .terminateNow }
        // Never bypass the signed updater's independent drain and snapshot.
        if runtime.preparingSignedUpdate { return .terminateCancel }
        if awaitingReply { return .terminateLater }
        if runtime.readyForTermination { return .terminateNow }
        awaitingReply = true
        runtime.requestShutdown { [weak self] in
            DispatchQueue.main.async { self?.finish(sender) }
        }
        // An SMB syscall may block indefinitely. SQLite WAL/transactions and
        // staged atomic publishing are also the crash-recovery boundary; a
        // normal OS quit must not be vetoed while waiting for network I/O.
        DispatchQueue.main.asyncAfter(deadline:.now()+15) { [weak self] in self?.finish(sender) }
        return .terminateLater
    }
}
