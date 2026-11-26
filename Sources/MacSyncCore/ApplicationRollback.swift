import Foundation
import Darwin
import CryptoKit

/// Explicit offline recovery, never restores a previous database or preferences.
/// Production callers hold the exclusive archive lock until the swap completes.
public enum ApplicationRollback {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    public static func verifyCode(_ url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", "--all-architectures", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("Firma del bundle non verificabile.") }
    }

    public static func validateBundle(_ url: URL, version: String,
                                     identifier: String = "com.macsync.prototype",
                                     publicKey: String = SignedUpdatePolicy.publicKey) throws {
        try requireDirectory(url)
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let data = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              data["CFBundleIdentifier"] as? String == identifier,
              data["CFBundleShortVersionString"] as? String == version,
              data["SUPublicEDKey"] as? String == publicKey,
              data["CFBundleExecutable"] as? String == "MacSync" else {
            throw Failure("Identità o versione dell’applicazione non corrispondente.")
        }
        try verifyCode(url)
    }

    private static func requireDirectory(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true else { throw Failure("Cartella non valida.") }
    }

    public static func allowedInstallLocation(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let allowed = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        return url.lastPathComponent == "MacSync.app" &&
            allowed.contains { $0.resolvingSymlinksInPath().path == parent.path } &&
            url.standardizedFileURL.path == parent.appendingPathComponent("MacSync.app").path
    }

    /// Hash the complete logical archive, not physical pages or CLI dump order.
    /// VACUUM INTO may reorder implicit rowids and sqlite_sequence entries.
    /// All schema objects, explicit IDs, values, duplicates and sequence
    /// counters are covered. No dump is written or exposed. Fail closed on
    /// unreadable/unsupported layouts. Caller holds the exclusive archive lock.
    public static func databaseDigest(_ url: URL, scratch: URL) throws -> Data {
        try ArchiveDatabaseSafety.verify(url, readOnly: true)
        return try LogicalArchiveDigest.compute(url)
    }

    /// Prepare and verify a copy on the target's own filesystem, then atomically
    /// exchange directories. The failed application stays intact in the staging
    /// directory; the original snapshot is also retained. No destructive fallback.
    /// Wrapping callers MUST validate the target location and hold the lock.
    @discardableResult
    public static func replaceApplication(target: URL, backup: URL,
                                          validate: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        try requireDirectory(target.deletingLastPathComponent())
        try requireDirectory(backup)
        try validate(backup)
        guard target.standardizedFileURL != backup.standardizedFileURL else {
            throw Failure("Origine e destinazione coincidono.")
        }
        let stage = target.deletingLastPathComponent()
            .appendingPathComponent(".MacSync-rollback-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let staged = stage.appendingPathComponent("MacSync.app")
        var published = false
        defer { if !published { try? fm.removeItem(at: stage) } }
        try fm.copyItem(at: backup, to: staged)
        try validate(staged)
        var st = stat()
        let result = target.path.withCString { lstat($0, &st) }
        let flags: UInt32
        if result == 0 {
            guard st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw Failure("Destinazione non valida; non verrà sostituita.")
            }
            flags = UInt32(RENAME_SWAP)
        } else {
            guard errno == ENOENT else { throw Failure("Destinazione non accessibile.") }
            flags = UInt32(RENAME_EXCL)
        }
        guard staged.path.withCString({ a in target.path.withCString { b in renamex_np(a, b, flags) } }) == 0 else {
            throw Failure("Scambio atomico non riuscito. Nessun ripristino non atomico verrà tentato.")
        }
        published = true
        try validate(target)
        return stage
    }
}

public struct ApplicationRecoveryManifest: Codable, Equatable {
    public let originalPath: String
    public let marker: UpdateTransactionMarker

    public init(application: URL, marker: UpdateTransactionMarker,
                allowsLocation: (URL) -> Bool = ApplicationRollback.allowedInstallLocation) throws {
        guard allowsLocation(application) else {
            throw ApplicationRollback.Failure("Sposta MacSync.app in Applicazioni prima di effettuare l’aggiornamento.")
        }
        originalPath = application.path
        self.marker = marker
    }

    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.synchronize()
    }

    public static func read(from url: URL,
                            allowsLocation: (URL) -> Bool = ApplicationRollback.allowedInstallLocation) throws -> Self {
        let r = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard r.isRegularFile == true, r.isSymbolicLink != true, let n = r.fileSize, n > 0, n < 8192 else {
            throw ApplicationRollback.Failure("Manifesto di ripristino non valido.")
        }
        let raw = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let marker = try UpdateTransactionMarker(previousVersion: raw.marker.previousVersion,
            requestedVersion: raw.marker.requestedVersion, snapshotName: raw.marker.snapshotName)
        return try Self(application: URL(fileURLWithPath: raw.originalPath), marker: marker, allowsLocation: allowsLocation)
    }
}
