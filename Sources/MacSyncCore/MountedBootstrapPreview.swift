import Foundation

/// Optional, read-only comparison for existing manually seeded archives.
/// Intentionally scans the mounted destination ONLY on user request, not
/// every five-minute incremental cycle. No file or SQLite mutations occur.
public enum MountedBootstrapPreview {
    public static func inspect(mapping: MountedFolderMapping) throws -> BootstrapPreview {
        try mapping.verify()
        let sourceItems = try LocalScanner.scan(root: mapping.source)
        let targetItems = try LocalScanner.scan(root: mapping.target)
        try mapping.verify()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let remote = targetItems.map { item in
            RemoteFileMetadata(
                path: item.relativePath,
                size: item.size,
                modTime: formatter.string(
                    from: Date(timeIntervalSince1970: item.modifiedAt)
                ),
                isDir: item.kind == "directory"
            )
        }
        return try BootstrapPlanner.preview(local: sourceItems, remote: remote)
    }
}
