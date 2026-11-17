import Foundation

/// Pre-install snapshot primitive. The caller MUST drain and hold all
/// operational workers and the exclusive archive lock before invoking it.
/// This never changes the live app, database or preferences.
public enum UpdateRecoverySnapshot {
    public enum SnapshotError: LocalizedError {
        case invalidBundle, invalidDestination
        public var errorDescription: String? { "Backup aggiornamento non valido." }
    }

    @discardableResult
    public static func create(database: URL, application: URL,
                              preferences: [String: Any], parent: URL) throws -> URL {
        let fm = FileManager.default
        let resource = try application.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard resource.isDirectory == true, resource.isSymbolicLink != true,
              application.pathExtension == "app",
              fm.fileExists(atPath: application.appendingPathComponent("Contents/Info.plist").path)
        else { throw SnapshotError.invalidBundle }
        let parentInfo = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentInfo.isDirectory == true, parentInfo.isSymbolicLink != true else { throw SnapshotError.invalidDestination }
        let id = UUID().uuidString
        let staging = parent.appendingPathComponent(".update-stage-\(id)", isDirectory: true)
        let final = parent.appendingPathComponent("update-backup-\(id)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let db = staging.appendingPathComponent("inventory.sqlite")
        try ArchiveDatabaseSafety.backup(database, to: db)
        try ArchiveDatabaseSafety.verify(db, readOnly: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: preferences.filter { $0.key.hasPrefix("MacSync.") }, format: .binary, options: 0)
        let prefs = staging.appendingPathComponent("preferences.plist")
        try plist.write(to: prefs, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prefs.path)
        try fm.copyItem(at: application, to: staging.appendingPathComponent("MacSync.app"))
        // Unique sibling publication; no replacement of older backups.
        try fm.moveItem(at: staging, to: final)
        return final
    }
}
