import Foundation
import Darwin

/// Read-only, experimental recursive scanner. Never used by the live
/// archive audit until equivalence and failure behaviour are validated.
/// Do not infer literal absence on SMB from any successful enumeration.
enum BulkArchiveScanner {
    enum Failure: Error, Equatable {
        case changed, limit, filesystem(Int32)
    }
    private enum Capability: Error { case unsupported }
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// For grouping only, never construct a filesystem path from this key.
    /// SFM maps reserved characters and final space/dot to private-use codes.
    static func comparisonKey(_ name: String) -> String {
        var decoded = String.UnicodeScalarView()
        let mapping: [UInt32: UInt32] = [
            0xF020: 0x22, 0xF021: 0x2A, 0xF022: 0x3A, 0xF023: 0x3C,
            0xF024: 0x3E, 0xF025: 0x3F, 0xF026: 0x5C, 0xF027: 0x7C,
            0xF028: 0x20, 0xF029: 0x2E
        ]
        for scalar in name.unicodeScalars {
            decoded.append(mapping[scalar.value].flatMap(Unicode.Scalar.init) ?? scalar)
        }
        return WindowsPathSafety.comparisonFold(String(decoded))
    }

    static func scan(root: URL, excludeManaged: Bool = false,
                     ignoreDSStore: Bool = FileExclusionPolicy.ignoreDSStore,
                     maximumDepth: Int = 128,
                     shouldContinue: @escaping () -> Bool = { true },
                     onVisit: (String) -> Void = { _ in }) throws -> BulkInventoryFallback.Attempt<[TrackedItem]> {
        guard root.isFileURL, maximumDepth >= 0 else { throw Failure.limit }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var found: [TrackedItem] = []
        func check() throws {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
        }
        func metadata(_ fd: Int32) throws -> stat {
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw Failure.filesystem(errno) }
            return value
        }
        func named(_ fd: Int32, _ name: String) throws -> stat {
            var value = stat()
            guard name.withCString({ fstatat(fd, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw Failure.filesystem(errno)
            }
            return value
        }
        func matches(_ row: BulkDirectoryMetadata.Entry, _ value: stat) -> Bool {
            let f = SeedFileFingerprint(fileStat: value)
            return row.device == f.device && row.inode == f.inode &&
                row.mtimeSeconds == f.mtimeSeconds && row.mtimeNanos == f.mtimeNanos &&
                row.ctimeSeconds == f.ctimeSeconds && row.ctimeNanos == f.ctimeNanos
        }
        func directory(_ value: stat) -> Bool {
            value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        }
        func sameDirectory(_ a: stat, _ b: stat) -> Bool {
            directory(a) && directory(b) &&
                SeedFileFingerprint(fileStat: a) == SeedFileFingerprint(fileStat: b)
        }
        func visit(_ fd: Int32, prefix: String, depth: Int, before: stat) throws {
            try check()
            guard depth <= maximumDepth, directory(before) else { throw Failure.limit }
            onVisit(prefix.isEmpty ? "[radice]" : prefix)
            try check()
            let listing = try BulkDirectoryMetadata.read(fd: fd, shouldContinue: shouldContinue)
            guard case .complete(let rows) = listing else { throw Capability.unsupported }
            // Group the whole parent before visiting any child. Mark both
            // spellings of a case/trailing-dot/SFM alias, regardless of order.
            let visible = rows.filter { row in
                !(excludeManaged && row.name.lowercased().hasPrefix(".macsync-")) &&
                !FileExclusionPolicy.excludes(row.name, enabled: ignoreDSStore)
            }
            let groups = Dictionary(grouping: visible, by: { comparisonKey($0.name) })
            for row in visible {
                try check()
                let path = prefix.isEmpty ? row.name : prefix + "/" + row.name
                let ambiguous = (groups[comparisonKey(row.name)]?.count ?? 0) > 1
                let incompatible = !WindowsPathSafety.validComponent(row.name) ||
                    row.name.unicodeScalars.contains(where: { (0xF000...0xF0FF).contains($0.value) })
                let uncertain = ambiguous || incompatible
                let reason = ambiguous ? "Nomi equivalenti o ambigui nella destinazione" :
                    "Nome incompatibile o rappresentazione SFM nella destinazione"
                onVisit(path)
                try check()
                guard row.device == UInt64(bitPattern: Int64(before.st_dev)) else { throw Failure.changed }
                if uncertain && row.kind != "file" {
                    // A directory or link with a problematic spelling might
                    // resolve to a different object. Preserve the enumerated
                    // name, type and timestamp; do not address it or descend.
                    // Size is unavailable, not proof of an empty directory.
                    found.append(TrackedItem(relativePath: path, kind: row.kind, size: 0,
                        modifiedAt: Double(row.mtimeSeconds) + Double(row.mtimeNanos) / 1_000_000_000,
                        verificationUncertainty: reason + " · contenuto non verificato"))
                    continue
                }
                switch row.kind {
                case "file":
                    guard let f = row.fileFingerprint else { throw Failure.changed }
                    found.append(TrackedItem(relativePath: path, kind: row.kind, size: f.size,
                        modifiedAt: f.modifiedAt,
                        changeStamp: uncertain ? nil : "\(f.inode):\(f.ctimeSeconds):\(f.ctimeNanos)",
                        verificationFingerprint: uncertain ? nil : f,
                        verificationUncertainty: uncertain ? reason : nil))
                case "directory":
                    let child = row.name.withCString { openat(fd, $0, directoryFlags) }
                    guard child >= 0 else { throw Failure.filesystem(errno) }
                    defer { close(child) }
                    let opened = try metadata(child)
                    guard directory(opened), matches(row, opened) else { throw Failure.changed }
                    let f = SeedFileFingerprint(fileStat: opened)
                    found.append(TrackedItem(relativePath: path, kind: row.kind, size: f.size,
                        modifiedAt: f.modifiedAt, verificationFingerprint: f))
                    try visit(child, prefix: path, depth: depth + 1, before: opened)
                    guard try sameDirectory(opened, named(fd, row.name)) else { throw Failure.changed }
                case "symlink":
                    // Preserve the legacy no-follow link size. Never descend.
                    let value = try named(fd, row.name)
                    guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                          matches(row, value) else { throw Failure.changed }
                    let f = SeedFileFingerprint(fileStat: value)
                    found.append(TrackedItem(relativePath: path, kind: row.kind, size: f.size,
                        modifiedAt: f.modifiedAt))
                default: throw Failure.changed
                }
            }
            try check()
            guard try sameDirectory(before, metadata(fd)) else { throw Failure.changed }
        }
        try check()
        let fd = root.path.withCString { open($0, directoryFlags) }
        guard fd >= 0 else { throw Failure.filesystem(errno) }
        defer { close(fd) }
        let original = try metadata(fd)
        do {
            try visit(fd, prefix: "", depth: 0, before: original)
            try check()
            var live = stat()
            guard root.path.withCString({ lstat($0, &live) }) == 0,
                  sameDirectory(original, live) else { throw Failure.changed }
            return .complete(found)
        } catch Capability.unsupported {
            // Unsupported capability is the only permitted fallback.
            // No partial rows escape; verify root binding before restart.
            try check()
            var live = stat()
            guard root.path.withCString({ lstat($0, &live) }) == 0,
                  sameDirectory(original, live) else { throw Failure.changed }
            return .unsupported
        }
    }
}
