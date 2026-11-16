import Foundation
import Darwin

public struct StagingCandidate: Equatable, Sendable {
    public let fileName: String
    public let size: Int64
    public let modifiedAt: Date
    public let inode: UInt64
}

public struct StagingInspection: Equatable, Sendable {
    public let candidates: [StagingCandidate]
    public let totalBytes: Int64

    public var count: Int { candidates.count }
}

/// Conservative maintenance of MacSync's OWN UUID-named partial uploads.
/// This is never invoked by the 5-minute sync timer. It does not touch
/// destination photos, directories or .macsync-backup files.
public enum StagingMaintenance {
    public static let minimumAge: TimeInterval = 7 * 24 * 60 * 60

    /// Only the direct children of .macsync-staging are considered.
    public static func inspect(
        mapping: MountedFolderMapping,
        now: Date = Date(),
        minimumAge: TimeInterval = StagingMaintenance.minimumAge,
        shouldContinue: () -> Bool = { true }
    ) throws -> StagingInspection {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        guard minimumAge >= StagingMaintenance.minimumAge else {
            throw MountedCopyError.unsafeFile
        }
        try mapping.verify()
        let stageDir = mapping.target.appendingPathComponent(".macsync-staging")
        guard let directoryStat = statInfo(stageDir) else {
            return StagingInspection(candidates: [], totalBytes: 0)
        }
        guard (directoryStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw MountedCopyError.unsafeFile
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: stageDir.path)
        var candidates: [StagingCandidate] = []
        var total: Int64 = 0
        for name in names {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard isOwnedTemporaryName(name) else { continue }
            let location = stageDir.appendingPathComponent(name)
            guard let info = statInfo(location),
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { continue }
            let modified = Date(timeIntervalSince1970:
                Double(info.st_mtimespec.tv_sec) +
                Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            guard now.timeIntervalSince(modified) >= minimumAge else { continue }
            let size = max(0, Int64(info.st_size))
            let (sum, overflow) = total.addingReportingOverflow(size)
            total = overflow ? Int64.max : sum
            candidates.append(StagingCandidate(
                fileName: name, size: size, modifiedAt: modified,
                inode: UInt64(info.st_ino)
            ))
        }
        try mapping.verify()
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        return StagingInspection(
            candidates: candidates.sorted { $0.fileName < $1.fileName },
            totalBytes: total
        )
    }

    /// Explicitly approved maintenance; verifies fingerprint and each file
    /// identity again before deletion. Concurrent uploads must be stopped by
    /// the caller. Never traverse outside .macsync-staging.
    @discardableResult
    public static func cleanup(
        mapping: MountedFolderMapping,
        inspected: StagingInspection,
        approved: Bool = false,
        now: Date = Date(),
        shouldContinue: () -> Bool = { true }
    ) throws -> Int {
        guard approved, shouldContinue() else { return 0 }
        try mapping.verify()
        let stageDir = mapping.target.appendingPathComponent(".macsync-staging")
        guard let directoryStat = statInfo(stageDir),
              (directoryStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        else { throw MountedCopyError.unsafeFile }
        var removed = 0
        for candidate in inspected.candidates {
            guard shouldContinue() else { break }
            guard isOwnedTemporaryName(candidate.fileName) else { continue }
            try mapping.verify()
            let location = stageDir.appendingPathComponent(candidate.fileName)
            guard let current = statInfo(location),
                  (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  UInt64(current.st_ino) == candidate.inode,
                  Int64(current.st_size) == candidate.size
            else { continue }
            let modified = Date(timeIntervalSince1970:
                Double(current.st_mtimespec.tv_sec) +
                Double(current.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            guard abs(modified.timeIntervalSince(candidate.modifiedAt)) <= 0.001,
                  now.timeIntervalSince(modified) >= minimumAge else { continue }
            guard shouldContinue() else { break }
            try FileManager.default.removeItem(at: location)
            removed += 1
        }
        return removed
    }

    private static func isOwnedTemporaryName(_ name: String) -> Bool {
        guard name.hasSuffix(".partial") else { return false }
        let stem = String(name.dropLast(".partial".count))
        return stem.count == 36 && UUID(uuidString: stem) != nil
    }

    private static func statInfo(_ url: URL) -> stat? {
        var info = stat()
        return url.path.withCString({ lstat($0, &info) }) == 0 ? info : nil
    }
}
