import Foundation

/// Read-only assessment for a one-off initial migration. Matching metadata is
/// only a *candidate match*, NEVER a proof of identical contents. This planner
/// does not write to SQLite or execute rclone or filesystem operations.
public struct RemoteFileMetadata: Decodable, Equatable {
    public let path: String
    public let size: Int64
    public let modTime: String
    public let isDir: Bool

    public init(path: String, size: Int64, modTime: String, isDir: Bool) {
        self.path = path
        self.size = size
        self.modTime = modTime
        self.isDir = isDir
    }

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case size = "Size"
        case modTime = "ModTime"
        case isDir = "IsDir"
    }
}

public enum BootstrapMismatch: Equatable {
    case missingOnServer
    case sizeMismatch
    case timestampMismatch
    case unverifiedTimestamp
    case unsupportedLocalItem
}

public struct BootstrapAssessment: Equatable {
    public let path: String
    public let mismatch: BootstrapMismatch?
}

public struct BootstrapPreview: Equatable {
    public let candidateMatches: Int
    public let requiresCopyOrReview: [BootstrapAssessment]
    public let remoteOnlyPaths: [String]
    public let macOSCaseCollisions: [[String]]
    public let stagingFiles: Int

    public var isSafeForAutomaticProductionBootstrap: Bool { false }

    public init(
        candidateMatches: Int,
        requiresCopyOrReview: [BootstrapAssessment],
        remoteOnlyPaths: [String],
        macOSCaseCollisions: [[String]],
        stagingFiles: Int
    ) {
        self.candidateMatches = candidateMatches
        self.requiresCopyOrReview = requiresCopyOrReview
        self.remoteOnlyPaths = remoteOnlyPaths
        self.macOSCaseCollisions = macOSCaseCollisions
        self.stagingFiles = stagingFiles
    }
}

public enum BootstrapPlanner {
    /// Example remote listing: rclone lsjson REMOTE:share/root --recursive --files-only
    /// This is permitted for the INITIAL baseline or occasional audit only,
    /// never on each regular 5-minute sync cycle.
    public static func decodeRcloneJSON(_ data: Data) throws -> [RemoteFileMetadata] {
        try JSONDecoder().decode([RemoteFileMetadata].self, from: data)
    }

    public static func preview(
        local: [TrackedItem],
        remote: [RemoteFileMetadata],
        timestampTolerance: TimeInterval = 2
    ) throws -> BootstrapPreview {
        guard timestampTolerance >= 0 && timestampTolerance.isFinite else {
            throw JournalError.database("Invalid timestamp tolerance")
        }

        let localFiles = local.filter { $0.kind != "directory" }
        let byFoldedName = Dictionary(grouping: localFiles, by: { $0.relativePath.lowercased() })
        let collisions = byFoldedName.values
            .filter { $0.count > 1 }
            .map { $0.map(\.relativePath).sorted() }
            .sorted { $0.first ?? "" < $1.first ?? "" }

        var seen: [String: RemoteFileMetadata] = [:]
        var stagingCount = 0
        for item in remote where !item.isDir {
            guard !item.path.isEmpty, !item.path.hasPrefix("/"),
                  !item.path.split(separator: "/").contains("..") else {
                throw JournalError.database("Unsafe path from remote listing")
            }
            if item.path == ".macsync-staging" ||
                item.path.hasPrefix(".macsync-staging/") {
                stagingCount += 1
                continue
            }
            if seen.updateValue(item, forKey: item.path) != nil {
                throw JournalError.database("Duplicated path in remote listing")
            }
        }

        var matching = 0
        var review: [BootstrapAssessment] = []
        for item in localFiles.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard item.kind == "file" else {
                review.append(.init(path: item.relativePath, mismatch: .unsupportedLocalItem))
                continue
            }
            guard let onServer = seen[item.relativePath] else {
                review.append(.init(path: item.relativePath, mismatch: .missingOnServer))
                continue
            }
            if item.size != onServer.size {
                review.append(.init(path: item.relativePath, mismatch: .sizeMismatch))
                continue
            }
            guard let serverTime = parseDate(onServer.modTime) else {
                review.append(.init(path: item.relativePath, mismatch: .unverifiedTimestamp))
                continue
            }
            if abs(item.modifiedAt - serverTime.timeIntervalSince1970) <= timestampTolerance {
                matching += 1
            } else {
                review.append(.init(path: item.relativePath, mismatch: .timestampMismatch))
            }
        }

        let localPaths = Set(localFiles.map(\.relativePath))
        return BootstrapPreview(
            candidateMatches: matching,
            requiresCopyOrReview: review,
            remoteOnlyPaths: seen.keys.filter { !localPaths.contains($0) }.sorted(),
            macOSCaseCollisions: collisions,
            stagingFiles: stagingCount
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = full.date(from: raw) { return value }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }
}
