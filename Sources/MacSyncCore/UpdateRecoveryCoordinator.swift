import Foundation
import Darwin

/// Shared implementation for runtime, offline recovery, and an isolated
/// multi-process CI laboratory. Production callers never override trust or
/// paths. Hold ExclusiveArchiveLock across every call and through any prompt.
public struct UpdateRecoveryCoordinator {
    public struct Pending {
        public let marker: UpdateTransactionMarker
        public let snapshot: URL
        public let target: URL
        public let markerURL: URL
    }

    public let root: URL
    private let identifier: String
    private let publicKey: String
    private let allowsLocation: (URL) -> Bool

    public init(root: URL, identifier: String = "com.macsync.prototype",
                publicKey: String = SignedUpdatePolicy.publicKey,
                allowsLocation: @escaping (URL) -> Bool = ApplicationRollback.allowedInstallLocation) {
        self.root = root
        self.identifier = identifier
        self.publicKey = publicKey
        self.allowsLocation = allowsLocation
    }

    public var database: URL { root.appendingPathComponent("inventory.sqlite") }
    public var markerURL: URL { root.appendingPathComponent("update-pending.json") }
    public var backupRoot: URL { root.appendingPathComponent("update-backups", isDirectory: true) }

    private func checkedDirectory(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true,
              url.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw ApplicationRollback.Failure("Percorso di recupero non valido o simbolico.")
        }
    }

    private func markerExists() throws -> Bool {
        var st = stat()
        let result = markerURL.path.withCString { lstat($0, &st) }
        if result == 0 { return true } // dangling links must not mean absence
        guard errno == ENOENT else { throw UpdateTransactionMarker.MarkerError.invalid }
        return false
    }

    public static func disableCopyAuthorizations(_ defaults: UserDefaults) throws {
        defaults.set(false, forKey: "MacSync.autoCopiesEnabled")
        defaults.set(false, forKey: "MacSync.autoCopiesEnabled.v2")
        defaults.removeObject(forKey: "MacSync.mirrorAuthorization.v1")
        defaults.removeObject(forKey: "MacSync.mirrorAuthorization.v2")
        defaults.removeObject(forKey: "MacSync.mirrorEnabled")
        if let data = defaults.data(forKey: "MacSync.archiveAuditSettings") {
            if var value = try? JSONDecoder().decode(ArchiveAuditSettings.self, from: data) {
                value.enabled = false
                value.repair = false
                defaults.set(try JSONEncoder().encode(value), forKey: "MacSync.archiveAuditSettings")
            } else {
                // Corrupt serialized authorizations are not preserved.
                defaults.removeObject(forKey: "MacSync.archiveAuditSettings")
            }
        }
        guard defaults.synchronize() else { throw UpdateTransactionMarker.MarkerError.invalid }
    }

    public func createSnapshot(application: URL, preferences: [String: Any]) throws -> URL {
        try checkedDirectory(root)
        guard try !markerExists(), allowsLocation(application) else {
            throw UpdateTransactionMarker.MarkerError.invalid
        }
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try checkedDirectory(backupRoot)
        return try UpdateRecoverySnapshot.create(database: database, application: application,
                                                  preferences: preferences, parent: backupRoot)
    }

    public func begin(application: URL, previous: String, requested: String,
                      snapshot: URL, defaults: UserDefaults) throws {
        let fm = FileManager.default
        try checkedDirectory(root)
        try checkedDirectory(backupRoot)
        try checkedDirectory(snapshot)
        guard snapshot.deletingLastPathComponent().standardizedFileURL == backupRoot.standardizedFileURL,
              try !markerExists() else { throw UpdateTransactionMarker.MarkerError.invalid }
        let marker = try UpdateTransactionMarker(previousVersion: previous, requestedVersion: requested,
                                                 snapshotName: snapshot.lastPathComponent)
        try validate(application, version: previous)
        let backup = snapshot.appendingPathComponent("MacSync.app")
        try validate(backup, version: previous)
        try ArchiveDatabaseSafety.verify(snapshot.appendingPathComponent("inventory.sqlite"), readOnly: true)
        let manifest = try ApplicationRecoveryManifest(application: application, marker: marker,
                                                        allowsLocation: allowsLocation)
        try manifest.write(to: snapshot.appendingPathComponent("recovery.json"))
        guard fm.isExecutableFile(atPath: backup.appendingPathComponent("Contents/MacOS/MacSyncRecovery").path) else {
            throw ApplicationRollback.Failure("Strumento di recupero mancante.")
        }
        let wrapper = snapshot.appendingPathComponent("Ripristina MacSync.command")
        try fm.copyItem(at: backup.appendingPathComponent("Contents/Resources/Ripristina MacSync.command"), to: wrapper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        // Persist before allowing the installer to exist. A partial failure
        // leaves the marker and disables operation on the next start.
        try marker.write(to: markerURL)
        try Self.disableCopyAuthorizations(defaults)
        _ = try loadPending()
    }

    private func validate(_ app: URL, version: String) throws {
        try ApplicationRollback.validateBundle(app, version: version, identifier: identifier, publicKey: publicKey)
    }

    public func loadPending() throws -> Pending {
        try checkedDirectory(root)
        try checkedDirectory(backupRoot)
        let marker = try UpdateTransactionMarker.read(from: markerURL)
        let snapshot = backupRoot.appendingPathComponent(marker.snapshotName, isDirectory: true)
        try checkedDirectory(snapshot)
        let manifest = try ApplicationRecoveryManifest.read(from: snapshot.appendingPathComponent("recovery.json"),
                                                              allowsLocation: allowsLocation)
        guard manifest.marker == marker else { throw UpdateTransactionMarker.MarkerError.invalid }
        let target = URL(fileURLWithPath: manifest.originalPath, isDirectory: true)
        try validate(snapshot.appendingPathComponent("MacSync.app"), version: marker.previousVersion)
        try ArchiveDatabaseSafety.verify(snapshot.appendingPathComponent("inventory.sqlite"), readOnly: true)
        return Pending(marker: marker, snapshot: snapshot, target: target, markerURL: markerURL)
    }

    public func startup(application: URL, defaults: UserDefaults) throws -> Pending? {
        guard try markerExists() else { return nil }
        try Self.disableCopyAuthorizations(defaults)
        let pending = try loadPending()
        guard application.standardizedFileURL.path == pending.target.standardizedFileURL.path else {
            throw ApplicationRollback.Failure("MacSync deve essere avviato dalla cartella originale: " + pending.target.path)
        }
        guard let plist = Bundle(url: application)?.infoDictionary,
              let version = plist["CFBundleShortVersionString"] as? String,
              version == pending.marker.previousVersion || version == pending.marker.requestedVersion else {
            throw ApplicationRollback.Failure("Versione inattesa. Backup: " + pending.snapshot.path)
        }
        try validate(application, version: version)
        try ArchiveDatabaseSafety.verify(database)
        return pending
    }

    /// Caller first finishes schema initialization, startup backup and all
    /// verification; this method never runs on a partially initialized archive.
    public func complete(_ pending: Pending, defaults: UserDefaults) throws {
        let current = try loadPending()
        guard current.marker == pending.marker, current.target.path == pending.target.path else {
            throw UpdateTransactionMarker.MarkerError.invalid
        }
        try ArchiveDatabaseSafety.verify(database)
        try Self.disableCopyAuthorizations(defaults)
        try FileManager.default.removeItem(at: markerURL)
    }

    public func recover(from given: URL, isStopped: () -> Bool,
                        confirm: (Pending) -> Bool) throws -> URL? {
        let pending = try loadPending()
        guard given.standardizedFileURL.path == pending.snapshot.path,
              given.resolvingSymlinksInPath().path == pending.snapshot.path,
              isStopped() else { throw ApplicationRollback.Failure("Backup non corrispondente o MacSync ancora aperto.") }
        let fm = FileManager.default
        let scratch = root.appendingPathComponent(".rollback-check-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let saved = pending.snapshot.appendingPathComponent("inventory.sqlite")
        func verifyArchiveAndTarget() throws {
            // Recover committed WAL if required, but never write older data.
            try ArchiveDatabaseSafety.verify(database)
            guard try ApplicationRollback.databaseDigest(database, scratch: scratch) ==
                      ApplicationRollback.databaseDigest(saved, scratch: scratch) else {
                throw ApplicationRollback.Failure("L’archivio è cambiato: recupero bloccato. Nessun dato sovrascritto.")
            }
            var st = stat()
            let rc = pending.target.path.withCString { lstat($0, &st) }
            if rc == 0 {
                guard st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      pending.target.resolvingSymlinksInPath().path == pending.target.path,
                      let data = try? Data(contentsOf: pending.target.appendingPathComponent("Contents/Info.plist")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      plist["CFBundleIdentifier"] as? String == identifier,
                      let version = plist["CFBundleShortVersionString"] as? String,
                      version == pending.marker.previousVersion || version == pending.marker.requestedVersion else {
                    throw ApplicationRollback.Failure("Identità dell’applicazione nella destinazione non verificabile.")
                }
            } else if errno != ENOENT { throw ApplicationRollback.Failure("Destinazione non accessibile.") }
        }
        try verifyArchiveAndTarget()
        guard confirm(pending) else { return nil }
        guard isStopped() else { throw ApplicationRollback.Failure("MacSync è ancora aperto.") }
        // Recheck after the operator prompt and before replacing anything.
        guard try loadPending().marker == pending.marker else { throw UpdateTransactionMarker.MarkerError.invalid }
        try verifyArchiveAndTarget()
        return try ApplicationRollback.replaceApplication(target: pending.target,
                    backup: pending.snapshot.appendingPathComponent("MacSync.app")) {
            try validate($0, version: pending.marker.previousVersion)
        }
    }
}
