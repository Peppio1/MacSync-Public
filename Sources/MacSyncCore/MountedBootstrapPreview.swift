import Foundation

/// Optional, read-only comparison for existing manually seeded archives.
/// Intentionally scans the mounted destination ONLY on user request, not
/// every five-minute incremental cycle. No file or SQLite mutations occur.
public enum MountedBootstrapPreview {
    public static func inspect(mapping: MountedFolderMapping, shouldContinue: () -> Bool = { true }) throws -> BootstrapPreview {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        try mapping.verify()
        let sourceItems = try LocalScanner.scan(root: mapping.source, shouldContinue: shouldContinue)
        let targetItems = try LocalScanner.scan(root: mapping.target, shouldContinue: shouldContinue)
        try mapping.verify()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let remote = try targetItems.map { item in
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            RemoteFileMetadata(
                path: item.relativePath,
                size: item.size,
                modTime: formatter.string(
                    from: Date(timeIntervalSince1970: item.modifiedAt)
                ),
                isDir: item.kind == "directory"
            )
        }
        let result = try BootstrapPlanner.preview(local: sourceItems, remote: remote)
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        return result
    }
}
