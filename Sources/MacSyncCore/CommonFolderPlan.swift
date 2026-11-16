import Foundation
import Darwin

/// Persist one common parent plus explicit per-root identities. Validation
/// is lexical here; the configuration UI also validates actual volumes,
/// directory type and symlinks before saving. Never merge two source trees.
public struct CommonFolderSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public init(id: String = UUID().uuidString, path: String) {
        self.id = id; self.path = path
    }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
public struct CommonFolderPlan: Codable, Equatable, Sendable {
    public var sources: [CommonFolderSource]
    public var parent: String
    public var expected: VolumeFingerprint?
    public init(sources: [CommonFolderSource] = [], parent: String = "", expected: VolumeFingerprint? = nil) {
        self.sources = sources; self.parent = parent; self.expected = expected
    }
    public func target(for source: CommonFolderSource) -> String {
        guard !parent.isEmpty else { return "" }
        return URL(fileURLWithPath: parent).appendingPathComponent(source.name, isDirectory: true).standardizedFileURL.path
    }
    public var isValid: Bool {
        func fold(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        func overlaps(_ a: String, _ b: String) -> Bool {
            a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") || a == "/" || b == "/"
        }
        guard Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ !$0.id.isEmpty && $0.path.hasPrefix("/") && $0.path != "/" && WindowsPathSafety.validComponent($0.name) }),
              Set(sources.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() }).count == sources.count,
              parent.isEmpty || (parent.hasPrefix("/") && parent != "/" && expected?.isStrongIdentity == true)
        else { return false }
        let local = sources.map { fold($0.path) }
        for (i,p) in local.enumerated() {
            if !parent.isEmpty && overlaps(p,fold(parent)) { return false }
            if local.dropFirst(i+1).contains(where: { overlaps(p,$0) }) { return false }
        }
        return true
    }

    /// Directory creation anchored to an opened parent descriptor; a lost
    /// SMB mount must not fall back to an ordinary local /Volumes directory.
    public func prepareTargetDirectories(shouldContinue: () -> Bool = { true }) throws {
        guard isValid else { throw MountedCopyError.invalidMapping }
        guard !parent.isEmpty else { return }
        guard let expected, DestinationProbe.inspect(path:parent,expectedVolume:expected) == .ready,
              URL(fileURLWithPath:parent).resolvingSymlinksInPath().path == parent
        else { throw MountedCopyError.volumeChanged }
        let fd = parent.withCString { Darwin.open($0,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw MountedCopyError.rootUnavailable }
        defer { Darwin.close(fd) }
        guard try VolumeFingerprint.read(directoryDescriptor:fd) == expected else { throw MountedCopyError.volumeChanged }
        for source in sources {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try WindowsPathSafety.checkNames(relativePath:source.name,under:URL(fileURLWithPath:parent))
            var info = stat()
            let result = source.name.withCString { fstatat(fd,$0,&info,AT_SYMLINK_NOFOLLOW) }
            if result == 0 {
                guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw MountedCopyError.unsafeFile }
            } else if errno != ENOENT { throw MountedCopyError.rootUnavailable }
        }
        for source in sources {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard DestinationProbe.inspect(path:parent,expectedVolume:expected) == .ready else { throw MountedCopyError.volumeChanged }
            let result = source.name.withCString { mkdirat(fd,$0,mode_t(0o777)) }
            if result != 0 && errno != EEXIST { throw MountedCopyError.rootUnavailable }
            let child = source.name.withCString { openat(fd,$0,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard child >= 0 else { throw MountedCopyError.unsafeFile }
            defer { Darwin.close(child) }
            guard try VolumeFingerprint.read(directoryDescriptor:child) == expected else { throw MountedCopyError.volumeChanged }
            let path = target(for:source)
            guard DestinationProbe.inspect(path:path,expectedVolume:expected) == .ready,
                  URL(fileURLWithPath:path).resolvingSymlinksInPath().path == path
            else { throw MountedCopyError.volumeChanged }
        }
    }
}
