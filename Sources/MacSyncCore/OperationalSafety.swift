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
            guard aliases.count <= 1 else { throw MountedCopyError.destinationConflict }
            if let actual = aliases.first, Array(actual.utf8) != Array(part.utf8) {
                // Finder/APFS can report decomposed Unicode names even
                // when the caller supplied the composed spelling. Accept
                // canonical equivalence ONLY when both spellings address
                // the same filesystem object; still reject case aliases
                // and normalization collisions on other filesystems.
                guard actual.precomposedStringWithCanonicalMapping == part.precomposedStringWithCanonicalMapping
                else { throw MountedCopyError.destinationConflict }
                var requested = stat(), listed = stat()
                let requestedURL = parent.appendingPathComponent(part)
                let listedURL = parent.appendingPathComponent(actual)
                guard requestedURL.path.withCString({ lstat($0,&requested) }) == 0,
                      listedURL.path.withCString({ lstat($0,&listed) }) == 0,
                      requested.st_dev == listed.st_dev, requested.st_ino == listed.st_ino,
                      requested.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK)
                else { throw MountedCopyError.destinationConflict }
            }
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
    /// The operational database is opened without CREATE, in read/write
    /// mode so SQLite can recover a committed WAL even when its SHM sidecar
    /// was removed on the previous clean close. Published snapshots use
    /// read-only verification and must not depend on WAL/SHM sidecars.
    public static func verify(_ url: URL, readOnly: Bool = false) throws {
        _ = try fileIdentity(url)
        let db = try open(url,flags:readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db,"PRAGMA quick_check;",-1,&stmt,nil)
        guard prepareResult == SQLITE_OK else {
            if let stmt { sqlite3_finalize(stmt) }
            throw JournalError.database("Controllo integrità SQLite non riuscito (codice \(prepareResult)): " + String(cString:sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let value = sqlite3_column_text(stmt,0), String(cString:value) == "ok",
              sqlite3_step(stmt) == SQLITE_DONE else {
            throw JournalError.database("Database SQLite non integro: operazioni bloccate")
        }
    }
    private static func requireAbsent(_ url: URL, phase: String) throws {
        var info = stat()
        let (rc,code) = url.path.withCString { path -> (Int32,Int32) in
            let result = lstat(path,&info)
            return (result,result == 0 ? 0 : errno)
        }
        guard rc != 0, code == ENOENT else {
            throw JournalError.database("Backup SQLite bloccato (\(phase)): \(url.lastPathComponent), lstat=\(rc), errno=\(code)")
        }
    }

    /// VACUUM INTO produces a consistent, compact standalone snapshot,
    /// including committed WAL data. The source is NOT vacuumed in place.
    /// MacSync uses explicit IDs for operational records; implicit rowids
    /// are not used as identifiers. Never replace an existing backup.
    public static func backup(_ source: URL, to target: URL) throws {
        try verify(source)
        guard source.isFileURL, target.isFileURL,
              source.standardizedFileURL != target.standardizedFileURL else {
            throw JournalError.database("Percorso backup non valido")
        }
        let suffixes = ["-wal","-shm","-journal"]
        try requireAbsent(target,phase:"destinazione iniziale")
        for suffix in suffixes { try requireAbsent(URL(fileURLWithPath:target.path+suffix),phase:"destinazione iniziale") }

        // Own a private staging directory on the same filesystem as the
        // final backup. SQLite may create/delete its own sidecars here.
        let stage = target.deletingLastPathComponent()
            .appendingPathComponent(".backup-"+UUID().uuidString,isDirectory:true)
        guard stage.path.withCString({ mkdir($0,mode_t(0o700)) }) == 0 else {
            throw JournalError.database("Cartella temporanea backup non creata (errno \(errno))")
        }
        let tmp = stage.appendingPathComponent("snapshot.sqlite")
        // POSIX cleanup is non-throwing and touches only known private
        // paths. ENOENT is expected after SQLite removes a journal or
        // exclusive publication moves the main file. Never clean the source.
        defer {
            for suffix in [""] + suffixes {
                _ = (tmp.path+suffix).withCString { Darwin.unlink($0) }
            }
            _ = stage.path.withCString { Darwin.rmdir($0) }
        }
        // Let SQLite create the snapshot itself. Some macOS SQLite builds
        // reject a pre-created empty output file. The exclusive mode-0700
        // staging directory protects the previously absent path; the final
        // file is restricted to mode 0600 before publication.
        try requireAbsent(tmp,phase:"prima di VACUUM INTO")
        for suffix in suffixes { try requireAbsent(URL(fileURLWithPath:tmp.path+suffix),phase:"prima di VACUUM INTO") }
        // Bind its path instead of interpolating SQL.
        do {
            let src = try open(source,flags:SQLITE_OPEN_READWRITE)
            var openConnection = true
            defer { if openConnection { sqlite3_close(src) } }
            do {
                var statement: OpaquePointer?
                let prepare = sqlite3_prepare_v2(src,"VACUUM main INTO ?;",-1,&statement,nil)
                guard prepare == SQLITE_OK, let statement else {
                    if let statement { sqlite3_finalize(statement) }
                    throw JournalError.database("Preparazione VACUUM INTO non riuscita (codice \(prepare)): " + String(cString:sqlite3_errmsg(src)))
                }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
                let bind = tmp.path.withCString { sqlite3_bind_text(statement,1,$0,-1,transient) }
                guard bind == SQLITE_OK else {
                    throw JournalError.database("Percorso VACUUM INTO non associato (codice \(bind))")
                }
                let step = sqlite3_step(statement)
                guard step == SQLITE_DONE else {
                    throw JournalError.database("VACUUM INTO non riuscito (codice \(step)): " + String(cString:sqlite3_errmsg(src)))
                }
            }
            let closed = sqlite3_close(src)
            guard closed == SQLITE_OK else {
                throw JournalError.database("Chiusura connessione backup non riuscita (codice \(closed))")
            }
            openConnection = false
        }
        // Validate the closed SQLite file, not a snapshot that still
        // depends on private sidecars. Recheck after read-only verification.
        for suffix in suffixes { try requireAbsent(URL(fileURLWithPath:tmp.path+suffix),phase:"snapshot chiuso") }
        try verify(tmp,readOnly:true)
        for suffix in suffixes { try requireAbsent(URL(fileURLWithPath:tmp.path+suffix),phase:"snapshot verificato") }
        let header = try FileHandle(forReadingFrom:tmp)
        let bytes: Data
        do {
            defer { try? header.close() }
            bytes = try header.read(upToCount:100) ?? Data()
        }
        guard bytes.count >= 100, bytes[18] == 1, bytes[19] == 1 else {
            throw JournalError.database("Il backup SQLite non è autonomo")
        }

        // Explicitly request a flush of the finished standalone file
        // before exposing it. Do not modify or delete source sidecars.
        let flushFD = tmp.path.withCString { Darwin.open($0,O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        guard flushFD >= 0 else {
            throw JournalError.database("Snapshot non accessibile per flush (errno \(errno))")
        }
        // SQLite creates the file using its own default permissions.
        // Restrict the verified regular file while still in private staging.
        var snapshotStat = stat()
        guard fstat(flushFD,&snapshotStat) == 0,
              snapshotStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fchmod(flushFD,mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(flushFD)
            throw JournalError.database("Permessi snapshot non impostati (errno \(code))")
        }
        let flushResult = fsync(flushFD)
        let flushError = errno
        Darwin.close(flushFD)
        guard flushResult == 0 else {
            throw JournalError.database("Flush snapshot non riuscito (errno \(flushError))")
        }

        // Do not use FileManager.moveItem/removeItem for SQLite artifacts:
        // publish exactly the verified main file via exclusive native rename.
        // No copy fallback, no overwrite, no deletion of other backups.
        try requireAbsent(target,phase:"prima della pubblicazione")
        for suffix in suffixes { try requireAbsent(URL(fileURLWithPath:target.path+suffix),phase:"prima della pubblicazione") }
        let rc = tmp.path.withCString { old in
            target.path.withCString { new in
                renameatx_np(AT_FDCWD,old,AT_FDCWD,new,UInt32(RENAME_EXCL))
            }
        }
        guard rc == 0 else {
            throw JournalError.database("Pubblicazione esclusiva backup non riuscita (errno \(errno))")
        }
        try verify(target,readOnly:true)
        for suffix in suffixes { try requireAbsent(URL(fileURLWithPath:target.path+suffix),phase:"backup pubblicato") }
    }
}
