import Foundation
import Darwin
import SQLite3

/// Persistent identity deliberately excludes timestamps changed by ordinary
/// directory edits. A changed inode/volume is NOT silently accepted on SMB.
public struct DirectoryBinding: Codable, Equatable, Sendable {
    public let volume: VolumeFingerprint
    public let inode: UInt64
    public let birthSeconds: Int64
    public let birthNanos: Int64

    public static func read(_ url: URL) throws -> DirectoryBinding {
        guard url.isFileURL, url.resolvingSymlinksInPath().path == url.path else {
            throw MountedCopyError.unsafeFile
        }
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw MountedCopyError.rootUnavailable }
        defer { Darwin.close(fd) }
        var s = stat()
        guard fstat(fd,&s) == 0 else { throw MountedCopyError.rootUnavailable }
        return DirectoryBinding(volume: try VolumeFingerprint.read(directoryDescriptor:fd),
            inode:UInt64(s.st_ino), birthSeconds:Int64(s.st_birthtimespec.tv_sec),
            birthNanos:Int64(s.st_birthtimespec.tv_nsec))
    }

    static func encoded(_ url: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding:try encoder.encode(read(url)),as:UTF8.self)
    }
}

/// Shared across monitor and transfer queues. Generation checks prevent an
/// older cancelled scan from declaring a newer configuration healthy.
public final class MonitorSafetyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var ready = false
    public init() {}
    @discardableResult public func invalidate() -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); ready = false; return generation
    }
    public func setReady(_ value: Bool, generation token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if generation == token { ready = value }
    }
    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }; return ready
    }
}

/// Conservative Windows/SMB component rules. Apply also to ordinary uploads,
/// not just archive audits. Reject rather than silently rename.
public enum WindowsPathSafety {
    public static func validComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf16.count <= 255, name != ".", name != "..",
              !name.hasSuffix("."), !name.hasSuffix(" "),
              !name.lowercased().hasPrefix(".macsync-"),
              !name.unicodeScalars.contains(where:{ $0.value < 32 || "<>:\"/\\|?*".unicodeScalars.contains($0) })
        else { return false }
        let stem = String(name.split(separator:".",omittingEmptySubsequences:false).first ?? "")
            .trimmingCharacters(in:.whitespaces).uppercased()
        let reserved = ["CON","PRN","AUX","NUL","CLOCK$","CONIN$","CONOUT$"]
            + (1...9).flatMap { ["COM\($0)","LPT\($0)"] }
            + ["COM¹","COM²","COM³","LPT¹","LPT²","LPT³"]
        return !reserved.contains(stem)
    }
    public static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy { validComponent(String($0)) }
    }
    public static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
    }
    /// Refuse ambiguous local siblings and aliases already on the target.
    /// Existing exact-spelling target is allowed. Never walk through symlinks.
    public static func checkNames(relativePath: String, under root: URL) throws {
        guard validRelativePath(relativePath) else { throw MountedCopyError.unsafeFile }
        var parent = root
        for part in relativePath.split(separator:"/").map(String.init) {
            var info = stat()
            if parent.path.withCString({ lstat($0,&info) }) != 0 {
                if errno == ENOENT { return }
                throw MountedCopyError.rootUnavailable
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw MountedCopyError.unsafeFile }
            let names = try FileManager.default.contentsOfDirectory(atPath:parent.path)
            let aliases = names.filter { folded($0) == folded(part) }
            guard aliases.count <= 1,
                  aliases.isEmpty || Array(aliases[0].utf8) == Array(part.utf8)
            else { throw MountedCopyError.destinationConflict }
            parent.appendPathComponent(part)
        }
    }
}

/// Anchor a leaf operation to an open directory rather than let a path
/// lookup silently fall back to an unmounted /Volumes path. A hostile writer
/// may still race the final leaf check; exclusive server write ACL is required.
public final class AnchoredDirectory {
    private let fd: Int32
    private let url: URL
    private let binding: DirectoryBinding

    public init(_ url: URL, expectedVolume: VolumeFingerprint) throws {
        self.url = url
        let stamp = try DirectoryBinding.read(url)
        guard stamp.volume == expectedVolume else { throw MountedCopyError.volumeChanged }
        let descriptor = url.path.withCString { Darwin.open($0,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw MountedCopyError.rootUnavailable }
        do {
            var s = stat()
            guard fstat(descriptor,&s) == 0, UInt64(s.st_ino) == stamp.inode,
                  Int64(s.st_birthtimespec.tv_sec) == stamp.birthSeconds,
                  Int64(s.st_birthtimespec.tv_nsec) == stamp.birthNanos,
                  try VolumeFingerprint.read(directoryDescriptor:descriptor) == expectedVolume
            else { throw MountedCopyError.volumeChanged }
        } catch { Darwin.close(descriptor); throw error }
        fd = descriptor; binding = stamp
    }
    deinit { Darwin.close(fd) }
    public func verify() throws {
        guard try DirectoryBinding.read(url) == binding,
              try VolumeFingerprint.read(directoryDescriptor:fd) == binding.volume
        else { throw MountedCopyError.volumeChanged }
    }
    func leaf(_ name:String) throws -> stat {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0")
        else { throw MountedCopyError.unsafeFile }
        var s = stat()
        guard name.withCString({ fstatat(fd,$0,&s,AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw MountedCopyError.rootUnavailable
        }
        return s
    }
    private static func sameFile(_ a: stat,_ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
        a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
        a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    func ensureDirectory(_ name:String, managed: Bool = false, shouldContinue: () -> Bool = { true }) throws {
        guard WindowsPathSafety.validComponent(name) || (managed && [".macsync-staging",".macsync-recovery"].contains(name))
        else { throw MountedCopyError.unsafeFile }
        try verify()
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        let rc = name.withCString { mkdirat(fd,$0,mode_t(0o777)) }
        guard rc == 0 || errno == EEXIST else { throw MountedCopyError.copyFailed(Int(errno)) }
        let s = try leaf(name)
        guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw MountedCopyError.destinationConflict }
    }
    func publish(_ name:String, matching original:stat, to target:AnchoredDirectory,
                 as targetName:String, replacing expected:stat?, shouldContinue: () -> Bool) throws {
        try verify(); try target.verify()
        guard Self.sameFile(try leaf(name),original),
              original.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              WindowsPathSafety.validComponent(targetName) else { throw MountedCopyError.destinationChanging }
        if let expected {
            guard Self.sameFile(try target.leaf(targetName),expected),
                  expected.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw MountedCopyError.destinationChanging }
        } else {
            var state = stat()
            let result = targetName.withCString { fstatat(target.fd,$0,&state,AT_SYMLINK_NOFOLLOW) }
            guard result != 0, errno == ENOENT else { throw MountedCopyError.destinationChanging }
        }
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        let rc = name.withCString { old in targetName.withCString { new in
            // macOS supports exclusive rename; if SMB cannot perform this
            // request, fail closed rather than fall back to an overwrite.
            if expected == nil { return renameatx_np(fd,old,target.fd,new,UInt32(RENAME_EXCL)) }
            return renameat(fd,old,target.fd,new)
        }}
        guard rc == 0 else { throw MountedCopyError.copyFailed(Int(errno)) }
    }
    public func remove(_ name:String, matching original: stat, directory: Bool = false,
                       shouldContinue: () -> Bool = { true }) throws {
        try verify()
        let current = try leaf(name)
        guard current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              current.st_mode == original.st_mode, current.st_size == original.st_size,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec,
              current.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG)
        else { throw MountedCopyError.destinationChanging }
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        guard name.withCString({ unlinkat(fd,$0,directory ? AT_REMOVEDIR : 0) }) == 0
        else { throw MountedCopyError.copyFailed(Int(errno)) }
    }
}

/// OS releases the lock on crash. Leave the lock file in place; unlinking
/// it could allow two processes to lock different inodes.
public final class ExclusiveArchiveLock {
    private let fd: Int32
    public init(url: URL) throws {
        let opened = url.path.withCString { Darwin.open($0,O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600)) }
        guard opened >= 0 else { throw JournalError.database("Blocco archivio non accessibile") }
        var s = stat()
        guard fstat(opened,&s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              flock(opened,LOCK_EX | LOCK_NB) == 0
        else { Darwin.close(opened); throw JournalError.database("Un'altra istanza usa già l'archivio MacSync") }
        fd = opened
    }
    deinit { Darwin.close(fd) }
}

public enum ArchiveDatabaseSafety {
    public static func fileIdentity(_ url: URL) throws -> String {
        var s = stat()
        guard url.path.withCString({ lstat($0,&s) }) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw JournalError.database("File database non valido")
        }
        return "\(s.st_ino):\(s.st_birthtimespec.tv_sec):\(s.st_birthtimespec.tv_nsec)"
    }
    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path,&db,flags,nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw JournalError.database("Database non accessibile")
        }
        sqlite3_busy_timeout(db,5000)
        return db
    }
    public static func verify(_ url: URL) throws {
        let db = try open(url,flags:SQLITE_OPEN_READONLY)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"PRAGMA quick_check;",-1,&stmt,nil) == SQLITE_OK else {
            throw JournalError.database("Controllo integrità SQLite non riuscito")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let value = sqlite3_column_text(stmt,0), String(cString:value) == "ok",
              sqlite3_step(stmt) == SQLITE_DONE else {
            throw JournalError.database("Database SQLite non integro: operazioni bloccate")
        }
    }
    /// sqlite3_backup includes committed WAL contents. Only publish a
    /// verified snapshot; never replace an existing migration backup.
    public static func backup(_ source: URL, to target: URL) throws {
        try verify(source)
        guard source.standardizedFileURL != target.standardizedFileURL,
              !FileManager.default.fileExists(atPath:target.path) else {
            throw JournalError.database("Percorso backup già esistente o non valido")
        }
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".backup-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:tmp) }
        let src = try open(source,flags:SQLITE_OPEN_READONLY)
        defer { sqlite3_close(src) }
        do {
            let dst = try open(tmp,flags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            defer { sqlite3_close(dst) }
            guard let backup = sqlite3_backup_init(dst,"main",src,"main") else {
                throw JournalError.database("Backup SQLite non inizializzato")
            }
            let result = sqlite3_backup_step(backup,-1)
            let finish = sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE, finish == SQLITE_OK else {
                throw JournalError.database("Backup SQLite non completato")
            }
        }
        try verify(tmp)
        try FileManager.default.moveItem(at:tmp,to:target)
    }
}
