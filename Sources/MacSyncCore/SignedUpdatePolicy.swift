import Foundation

/// Production trust configuration. GitHub's unsigned discovery response is
/// advisory only; a Sparkle session is permitted only for the selected stable
/// version and the canonical update asset after the runtime has been drained.
public enum SignedUpdatePolicy {
    public static let publicKey = "SDsuoQo3jF5WNHSC1yo6B92Nanc9bBdjHJ8O474h9LU="
    public static let feedURL = "https://github.com/Peppio1/MacSync-Public/releases/latest/download/appcast.xml"

    public static func assetURL(version: String) -> URL? {
        guard let parts = StableUpdateRelease.version(version),
              parts.map(String.init).joined(separator: ".") == version else { return nil }
        return URL(string: "https://github.com/Peppio1/MacSync-Public/releases/download/v\(version)/MacSync-v\(version)-macOS-universal.zip")
    }

    public static func accepts(installed: String, requested: String, offered: String,
                               channel: String?, asset: URL?) -> Bool {
        guard let old = StableUpdateRelease.version(installed),
              let new = StableUpdateRelease.version(requested),
              old.lexicographicallyPrecedes(new), requested == offered,
              channel == nil || channel == "",
              let canonical = assetURL(version: requested), asset == canonical else { return false }
        return true
    }
}

/// No user-provided paths. The backup ID is constrained to a single UUID
/// directory under update-backups, and the marker survives failed relaunches.
public struct UpdateTransactionMarker: Codable, Equatable, Sendable {
    public let previousVersion: String
    public let requestedVersion: String
    public let snapshotName: String

    public enum MarkerError: LocalizedError {
        case invalid
        public var errorDescription: String? { "Transazione aggiornamento non valida; operazioni bloccate." }
    }

    public init(previousVersion: String, requestedVersion: String, snapshotName: String) throws {
        guard SignedUpdatePolicy.accepts(installed: previousVersion, requested: requestedVersion,
                                         offered: requestedVersion, channel: nil,
                                         asset: SignedUpdatePolicy.assetURL(version: requestedVersion)),
              snapshotName.hasPrefix("update-backup-"),
              let id = UUID(uuidString: String(snapshotName.dropFirst("update-backup-".count))),
              snapshotName == "update-backup-" + id.uuidString else { throw MarkerError.invalid }
        self.previousVersion = previousVersion
        self.requestedVersion = requestedVersion
        self.snapshotName = snapshotName
    }

    public func write(to url: URL) throws {
        // Never silently overwrite a pending transaction.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw MarkerError.invalid }
        try JSONEncoder().encode(self).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        guard try Self.read(from: url) == self else { throw MarkerError.invalid }
    }

    public static func read(from url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 4096 else { throw MarkerError.invalid }
        let decoded = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        return try Self(previousVersion: decoded.previousVersion, requestedVersion: decoded.requestedVersion,
                        snapshotName: decoded.snapshotName)
    }
}
