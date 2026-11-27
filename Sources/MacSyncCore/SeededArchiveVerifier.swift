import Foundation
import CryptoKit
import Darwin

public enum SeedVerificationError: Error, LocalizedError {
    case cancelled
    case unsafeEntry
    case changedDuringRead
    case sourceMissing

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Verifica annullata: nessun job marcato come completato"
        case .unsafeEntry: return "Collegamento simbolico o percorso non sicuro"
        case .changedDuringRead: return "File cambiato durante la verifica"
        case .sourceMissing: return "File non più disponibile"
        }
    }
}

// All mutable state is protected by the private NSLock.
public final class SeedVerificationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let shouldContinue: () -> Bool
    private let commitAllowed: () -> Bool

    public init(shouldContinue: @escaping () -> Bool = { true }, commitAllowed: @escaping () -> Bool = { true }) {
        self.shouldContinue = shouldContinue
        self.commitAllowed = commitAllowed
    }
    public var wasExplicitlyCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    public var mayCommit: Bool { !isCancelled && commitAllowed() }

    /// A monitor reconciliation temporarily closes the commit gate without
    /// cancelling the already-authorized read-only archive snapshot. Wait on
    /// the worker thread OUTSIDE any SQLite transaction, so FSEvents can
    /// finish persisting the newer changes before audit UPSERTs are committed.
    /// Permanent gate invalidation and explicit Stop still cancel immediately.
    public func awaitCommitWindow(maxSeconds: Double = 120,
                                  onWaiting: () -> Void = {}) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0,maxSeconds)
        var announced = false
        while !isCancelled {
            if mayCommit { return true }
            if !announced { announced = true; onWaiting() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    public var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value || !shouldContinue()
    }
}

/// A conservative lstat fingerprint; a successful hash is valid only while
/// both files retain these attributes. mtime + ctime protect against edits
/// that preserve size and modification time.
public struct SeedFileFingerprint: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let mtimeSeconds: Int64
    public let mtimeNanos: Int64
    public let ctimeSeconds: Int64
    public let ctimeNanos: Int64

    public var modifiedAt: Double {
        Double(mtimeSeconds) + Double(mtimeNanos) / 1_000_000_000
    }
}

// Keep the synthesized memberwise initializer available to existing code.
extension SeedFileFingerprint {
    /// Retains the exact stat already obtained during a complete inventory.
    /// Never use this snapshot as the sole authority for a queue commit.
    init(fileStat info: stat) {
        self.init(
            device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeSeconds: Int64(info.st_mtimespec.tv_sec),
            mtimeNanos: Int64(info.st_mtimespec.tv_nsec),
            ctimeSeconds: Int64(info.st_ctimespec.tv_sec),
            ctimeNanos: Int64(info.st_ctimespec.tv_nsec)
        )
    }

}

public struct SeedVerifiedMatch: Sendable {
    public let jobID: Int64
    public let rootID: String
    public let relativePath: String
    public let source: SeedFileFingerprint
    public let target: SeedFileFingerprint
    public let verifiedBytes: Int64
    public var objectKind: String = "file"
}

public struct SeedVerificationProgress: Sendable {
    public let inspected: Int
    public let verified: Int
    public let missingOrDifferent: Int
    public let deferred: Int
    public let bytesRead: Int64
    public let planned: Int
    public let currentPath: String
}

public struct SeedVerificationReport: Sendable {
    public let matches: [SeedVerifiedMatch]
    public let inspected: Int
    public let missingOrDifferent: Int
    public let deferred: Int
    public let bytesRead: Int64

    public var verifiedCount: Int { matches.count }
}

/// Read-only directory descriptor pinned to an actual directory inode.
/// A symlink substituted into a parent path cannot redirect fstatat() outside
/// the selected archive. The parent is re-opened by name before committing.
private enum ApprovalReadError: Error { case unsupported }

private func approvalReadError(_ code: Int32) -> Error {
    // Some Finder-mounted SMB implementations reject directory descriptors.
    // Only unsupported read-only calls may fall back to the PREEXISTING
    // exact-path validation; never fall back on I/O, identity or access errors.
    if code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS || code == EINVAL {
        return ApprovalReadError.unsupported
    }
    return SeedVerificationError.unsafeEntry
}

private final class ApprovalParentReader {
    private let rootPath: String
    private let parentPath: String
    private let directoryDescriptor: Int32
    private let device: UInt64
    private let inode: UInt64

    init(rootPath: String, relativeParent: String) throws {
        self.rootPath = rootPath
        self.parentPath = relativeParent
        var descriptor = rootPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw approvalReadError(errno) }
        do {
            if !relativeParent.isEmpty {
                for component in relativeParent.split(separator: "/", omittingEmptySubsequences: false) {
                    guard !component.isEmpty, component != ".", component != ".." else {
                        throw SeedVerificationError.unsafeEntry
                    }
                    let next = String(component).withCString {
                        openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard next >= 0 else { throw approvalReadError(errno) }
                    _ = Darwin.close(descriptor)
                    descriptor = next
                }
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw approvalReadError(errno) }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw SeedVerificationError.unsafeEntry
            }
            self.device = UInt64(bitPattern: Int64(info.st_dev))
            self.inode = UInt64(info.st_ino)
            self.directoryDescriptor = descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    deinit { _ = Darwin.close(directoryDescriptor) }

    func fingerprint(leaf: String, directory: Bool) throws -> SeedFileFingerprint {
        guard !leaf.isEmpty, leaf != ".", leaf != "..",
              !leaf.contains("/"), !leaf.contains("\0") else {
            throw SeedVerificationError.unsafeEntry
        }
        var info = stat()
        guard leaf.withCString({ fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw approvalReadError(errno)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG) else {
            throw SeedVerificationError.unsafeEntry
        }
        return SeedFileFingerprint(fileStat: info)
    }

    func isStillAtPath() -> Bool {
        guard let current = try? ApprovalParentReader(rootPath: rootPath, relativeParent: parentPath) else {
            return false
        }
        return current.device == device && current.inode == inode
    }
}

/// Only pending UPSERT files are checked; directory and DELETE records are
/// never acknowledged here. Does NOT enumerate the entire server directory.
/// Each comparison reads bytes from *both* files and hashes SHA-256 in 1 MiB
/// chunks. SMB reads count as VPN traffic even when no uploads are needed.
public final class SeededArchiveVerifier {
    private let journal: ChangeJournal
    private let mappings: [String: MountedFolderMapping]

    public init(journal: ChangeJournal, mappings: [MountedFolderMapping]) throws {
        guard !mappings.isEmpty,
              Set(mappings.map(\.rootID)).count == mappings.count else {
            throw MountedCopyError.invalidMapping
        }
        self.journal = journal
        self.mappings = Dictionary(uniqueKeysWithValues: mappings.map { ($0.rootID, $0) })
    }

    public func verify(
        cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
        progress: ((SeedVerificationProgress) -> Void)? = nil
    ) throws -> SeedVerificationReport {
        var matches: [SeedVerifiedMatch] = []
        var cursor: Int64 = 0
        var inspected = 0
        var differences = 0
        var deferred = 0
        var bytesRead: Int64 = 0
        var lastProgress: Double = 0
        let upper = try journal.pendingUploadUpperBound() ?? 0
        let planned = try journal.plannedUploadCount(throughID:upper)
        var currentPath = ""
        func publish(force:Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now-lastProgress >= 1 else { return }
            lastProgress = now
            progress?(SeedVerificationProgress(inspected:inspected,verified:matches.count,
                missingOrDifferent:differences,deferred:deferred,bytesRead:bytesRead,
                planned:planned,currentPath:currentPath))
        }
        publish(force:true)
        while true {
            if cancellation.isCancelled { throw SeedVerificationError.cancelled }
            let jobs = try journal.pendingUploads(limit: 250, afterID: cursor, throughID: upper)
            if jobs.isEmpty { break }
            for job in jobs {
                if cancellation.isCancelled { throw SeedVerificationError.cancelled }
                cursor = job.id
                currentPath = job.rootID + " / " + job.relativePath
                publish()
                guard let mapping = mappings[job.rootID] else {
                    deferred += 1
                    inspected += 1
                    publish()
                    continue
                }
                do {
                    let verified = try verifyOne(
                        job, mapping: mapping, cancellation: cancellation,
                        onBytesRead: { chunkSize in
                            let (sum, overflow) = bytesRead.addingReportingOverflow(chunkSize)
                            bytesRead = overflow ? Int64.max : sum
                            publish()
                        }
                    )
                    if let verified { matches.append(verified) }
                    else { differences += 1 }
                } catch SeedVerificationError.cancelled {
                    throw SeedVerificationError.cancelled
                } catch {
                    // Missing, inaccessible, changing or unsupported files
                    // remain pending for later copy/review. Never mark them
                    // as synced on the basis of metadata alone.
                    deferred += 1
                }
                inspected += 1
                publish()
            }
        }
        currentPath = ""
        publish(force:true)
        return SeedVerificationReport(
            matches: matches, inspected: inspected,
            missingOrDifferent: differences, deferred: deferred,
            bytesRead: bytesRead
        )
    }

    /// User must explicitly approve. We recheck both file fingerprints and
    /// the volume mapping, then conditionally acknowledge all eligible jobs in
    /// ONE SQLite transaction. No file or remote content is modified.
    public func approve(
        report: SeedVerificationReport,
        cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
        progress: ((Int, Int) -> Void)? = nil,
        onCommit: () -> Void = {},
        onCounts: (Int, Int) -> Void = { _,_ in }
    ) throws -> Int {
        var stillValid: [SeedVerifiedMatch] = []
        var lastProgress = ProcessInfo.processInfo.systemUptime
        var unsupportedReadOnlyRoots = Set<String>()
        progress?(0,report.matches.count)
        // Bounded groups avoid hundreds of thousands of repeated SMB root and
        // parent checks. Parent directories remain anchored by file descriptor,
        // and every candidate is still live-fingerprinted on BOTH sides.
        // Limit concurrently open source/target parent FDs even when every
        // candidate is in a different directory (macOS soft limit may be 256).
        let approvalBatchSize = 32
        for base in stride(from: 0, to: report.matches.count, by: approvalBatchSize) {
            if cancellation.isCancelled { throw SeedVerificationError.cancelled }
            let upper = min(report.matches.count, base + approvalBatchSize)
            var roots: [String: MountedFolderMapping] = [:]
            var parents: [String: ApprovalParentReader] = [:]
            var validInBatch: [SeedVerifiedMatch] = []
            for index in base..<upper {
                defer {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now-lastProgress >= 1 || index+1 == report.matches.count {
                        lastProgress = now
                        progress?(index+1,report.matches.count)
                    }
                }
                if cancellation.isCancelled { throw SeedVerificationError.cancelled }
                let match = report.matches[index]
                guard let mapping = mappings[match.rootID],
                      match.objectKind == "file" || match.objectKind == "directory" else { continue }
                do {
                    if roots[match.rootID] == nil {
                        try mapping.verify()
                        roots[match.rootID] = mapping
                    }
                    var sourceFingerprint: SeedFileFingerprint?
                    var targetFingerprint: SeedFileFingerprint?
                    if WindowsPathSafety.validRelativePath(match.relativePath),
                       !unsupportedReadOnlyRoots.contains(match.rootID) {
                        do {
                            let components = match.relativePath.split(separator: "/").map(String.init)
                            guard let leaf = components.last else { continue }
                            let parent = components.dropLast().joined(separator: "/")
                            let sourceKey = match.rootID + "\0s\0" + parent
                            let targetKey = match.rootID + "\0t\0" + parent
                            if parents[sourceKey] == nil {
                                parents[sourceKey] = try ApprovalParentReader(rootPath: mapping.source.path, relativeParent: parent)
                            }
                            if parents[targetKey] == nil {
                                parents[targetKey] = try ApprovalParentReader(rootPath: mapping.target.path, relativeParent: parent)
                            }
                            sourceFingerprint = try parents[sourceKey]!.fingerprint(leaf: leaf, directory: match.objectKind == "directory")
                            targetFingerprint = try parents[targetKey]!.fingerprint(leaf: leaf, directory: match.objectKind == "directory")
                        } catch ApprovalReadError.unsupported {
                            unsupportedReadOnlyRoots.insert(match.rootID)
                        }
                    }
                    if sourceFingerprint == nil || targetFingerprint == nil {
                        // Read-only compatibility fallback ONLY when openat or
                        // fstatat is unavailable; this is not a transfer-engine
                        // fallback and retains all original path checks.
                        let src = try safePath(match.relativePath, mapping: mapping, destination: false)
                        let dst = try safePath(match.relativePath, mapping: mapping, destination: true)
                        sourceFingerprint = try Self.fingerprint(src,directory:match.objectKind == "directory")
                        targetFingerprint = try Self.fingerprint(dst,directory:match.objectKind == "directory")
                    }
                    if let sourceFingerprint, let targetFingerprint,
                       sourceFingerprint == match.source && targetFingerprint == match.target {
                        validInBatch.append(match)
                    }
                } catch {
                    // Missing, changed, inaccessible, symlinked or ambiguous
                    // entries remain pending and are never blindly acknowledged.
                    continue
                }
            }
            if cancellation.isCancelled { throw SeedVerificationError.cancelled }
            // If any parent was replaced during the group, discard the WHOLE
            // batch. A changed root or SMB mount is a hard stop, not success.
            guard parents.values.allSatisfy({ $0.isStillAtPath() }) else {
                continue
            }
            for mapping in roots.values { try mapping.verify() }
            stillValid.append(contentsOf: validInBatch)
        }
        if !cancellation.mayCommit { throw SeedVerificationError.cancelled }
        onCommit()
        let sources = mappings.mapValues { $0.source.path }
        let bindings = stillValid.isEmpty ? [:] : try journal.lineageCopyBindings(Array(mappings.values))
        let changed = try journal.acknowledgeVerifiedFiles(
            stillValid, sourceRoots: sources, shouldContinue: { cancellation.mayCommit }, onCounts:onCounts,
            lineageBindings:bindings
        )
        progress?(report.matches.count, report.matches.count)
        return changed
    }

    func verifyOne(
        _ job: QueuedChange, mapping: MountedFolderMapping,
        cancellation: SeedVerificationCancellation,
        onBytesRead: (Int64) -> Void
    ) throws -> SeedVerifiedMatch? {
        try mapping.verify()
        let src = try safePath(job.relativePath, mapping: mapping, destination: false)
        let dst = try safePath(job.relativePath, mapping: mapping, destination: true)
        let beforeSource = try Self.fingerprint(src)
        let beforeTarget = try Self.fingerprint(dst)
        // A size match is a cheap prefilter only; it is NEVER evidence of
        // equality until SHA-256 of BOTH complete files agrees.
        guard beforeSource.size == beforeTarget.size else { return nil }
        let sourceDigest = try Self.sha256(
            src, cancellation: cancellation, onBytesRead: onBytesRead
        )
        let targetDigest = try Self.sha256(
            dst, cancellation: cancellation, onBytesRead: onBytesRead
        )
        guard try Self.fingerprint(src) == beforeSource,
              try Self.fingerprint(dst) == beforeTarget else {
            throw SeedVerificationError.changedDuringRead
        }
        try mapping.verify()
        guard sourceDigest == targetDigest else { return nil }
        return SeedVerifiedMatch(
            jobID: job.id, rootID: job.rootID, relativePath: job.relativePath,
            source: beforeSource, target: beforeTarget,
            verifiedBytes: beforeSource.size
        )
    }

    private func safePath(
        _ relativePath: String, mapping: MountedFolderMapping, destination: Bool
    ) throws -> URL {
        let root = destination ? mapping.target : mapping.source
        let url = try mapping.verificationURL(relativePath: relativePath, destination: destination)
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else {
            throw SeedVerificationError.unsafeEntry
        }
        var current = root
        let relativeParent = String(parent.path.dropFirst(root.path.count))
        for component in relativeParent.split(separator: "/") {
            current.appendPathComponent(String(component))
            var st = stat()
            guard current.path.withCString({ lstat($0, &st) }) == 0,
                  (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw SeedVerificationError.unsafeEntry
            }
        }
        return url
    }

    public static func fingerprint(_ url: URL, directory: Bool = false) throws -> SeedFileFingerprint {
        var st = stat()
        guard url.path.withCString({ lstat($0, &st) }) == 0 else {
            throw SeedVerificationError.sourceMissing
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG) else {
            throw SeedVerificationError.unsafeEntry
        }
        return SeedFileFingerprint(
            device: UInt64(bitPattern:Int64(st.st_dev)), inode: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
            mtimeNanos: Int64(st.st_mtimespec.tv_nsec),
            ctimeSeconds: Int64(st.st_ctimespec.tv_sec),
            ctimeNanos: Int64(st.st_ctimespec.tv_nsec)
        )
    }

    private static func sha256(
        _ file: URL,
        cancellation: SeedVerificationCancellation,
        onBytesRead: (Int64) -> Void
    ) throws -> Data {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var hash = SHA256()
        while true {
            if cancellation.isCancelled { throw SeedVerificationError.cancelled }
            guard let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            hash.update(data: chunk)
            onBytesRead(Int64(chunk.count))
        }
        return Data(hash.finalize())
    }
}


/// Immutable handoff. The verifier and its SQLite connection live only inside
/// each synchronous worker operation, never in the UI.
public struct SeededArchiveSession: Sendable {
    private let database: URL
    private let mappings: [MountedFolderMapping]
    private let databaseID: String
    private let device: UInt64
    private let inode: UInt64

    public init(database: URL, mappings: [MountedFolderMapping]) throws {
        let identity = try Self.fileIdentity(database)
        let journal = try ChangeJournal(path: database.path)
        let id = try journal.databaseIdentity()
        let after = try Self.fileIdentity(database)
        guard identity == after else { throw Self.changedDatabase() }
        self.database = database
        self.mappings = mappings
        self.databaseID = id
        self.device = identity.device
        self.inode = identity.inode
    }

    private static func changedDatabase() -> JournalError {
        .database("Database di sincronizzazione cambiato: ripetere la verifica SHA-256")
    }

    private static func fileIdentity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw changedDatabase()
        }
        return (UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino))
    }

    private func checkFileIdentity() throws {
        let current = try Self.fileIdentity(database)
        guard current.device == device, current.inode == inode else {
            throw Self.changedDatabase()
        }
    }

    private func openJournal() throws -> ChangeJournal {
        try checkFileIdentity()
        let journal = try ChangeJournal(path: database.path)
        guard try journal.databaseIdentity() == databaseID else {
            throw Self.changedDatabase()
        }
        try checkFileIdentity()
        return journal
    }

    public func verify(
        cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
        progress: ((SeedVerificationProgress) -> Void)? = nil
    ) throws -> SeedVerificationReport {
        let journal = try openJournal()
        let verifier = try SeededArchiveVerifier(journal: journal, mappings: mappings)
        let report = try verifier.verify(cancellation: cancellation, progress: progress)
        try checkFileIdentity()
        return report
    }

    /// QUICK/INTELLIGENT operational audit: one metadata inventory per side,
    /// then local SQLite reconciliation. Only proven INITIAL inventory jobs
    /// may be completed from corresponding metadata; monitor, audit, rebind
    /// and legacy-unknown jobs are NEVER acknowledged. A newer FSEvents event
    /// replaces the initial job and takes precedence during the SQLite commit.
    /// INTELLIGENT keeps its selective SHA-256 checks; neither mode starts
    /// the old mass SMB approval/revalidation phase.
    public func auditPreservingQueuedChanges(
        mode: ArchiveAuditMode,
        repair: Bool = true,
        cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
        diagnostic: (ArchiveAuditProgress) -> Void = { _ in },
        progress: (ArchiveAuditProgress) -> Void = { _ in },
        deletionCandidates: Set<String> = [],
        queueMirrorExtras: Bool = false,
        reconcileOrdinaryJobs: Bool = false
    ) throws -> ArchiveAuditReport {
        let journal = try openJournal()
        var pending:[String:QueuedChange]=[:]
        var ambiguous=Set<String>()
        var pendingDeletes:[QueuedChange]=[]
        let operational = repair && reconcileOrdinaryJobs
        if operational {
            let cutoff=try journal.queueSequence()
            let upper=cutoff
            var cursor:Int64=0
            while true {
                guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                let page=try journal.pendingUploads(limit:250,afterID:cursor,throughID:upper)
                if page.isEmpty { break }
                for job in page {
                    cursor=job.id
                    let key=job.rootID+"\0"+job.relativePath
                    if pending.updateValue(job,forKey:key) != nil { ambiguous.insert(key) }
                }
            }
            var length=Int64.max
            cursor=0
            while true {
                guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                let page=try journal.pendingDeletePage(afterID:0,throughID:cutoff,
                    previousLength:length,previousID:cursor,limit:250)
                guard let last=page.last else { break }
                pendingDeletes.append(contentsOf:page)
                length=Int64(last.relativePath.unicodeScalars.count);cursor=last.id
            }
        }
        var matches:[SeedVerifiedMatch]=[]
        func collect(_ root:String,_ path:String,_ source:SeedFileFingerprint,_ target:SeedFileFingerprint,_ kind:String) {
            let key=root+"\0"+path
            guard operational,!ambiguous.contains(key),let job=pending[key] else { return }
            matches.append(SeedVerifiedMatch(jobID:job.id,rootID:root,relativePath:path,
                source:source,target:target,verifiedBytes:kind=="file" ? source.size : 0,objectKind:kind))
        }
        var result = try ArchiveAudit(journal: journal, mappings: mappings).run(
            mode: mode, repair: repair, cancellation: cancellation,
            collectMetadataMatches:operational,shouldCollectMetadataMatch:{root,path in
                let key=root+"\0"+path
                return pending[key] != nil && !ambiguous.contains(key)
            },deletionCandidates: deletionCandidates, queueMirrorExtras: queueMirrorExtras,
            onVerifiedFile:{collect($0,$1,$2,$3,"file")},
            onVerifiedDirectory:{collect($0,$1,$2,$3,"directory")},
            diagnostic: diagnostic, progress: progress
        )
        try checkFileIdentity()
        var auditTargetMissingPrefixes:[Int64:String]=[:]
        if repair {
            if operational {
                // Do not build an archive-sized index when there are no
                // corresponding pending jobs. Index only relevant candidates.
                if !matches.isEmpty {
                    let wanted=Set(matches.map{$0.rootID+"\0"+$0.relativePath})
                    let matching=Set(result.findings.lazy.filter{$0.kind == .matching && wanted.contains($0.id)}.map(\.id))
                    matches.removeAll{!matching.contains($0.rootID+"\0"+$0.relativePath)}
                }
                if !pendingDeletes.isEmpty {
                    let wanted=Set(pendingDeletes.map{$0.rootID+"\0"+$0.relativePath})
                    let observed=Set(result.findings.lazy.filter{wanted.contains($0.id)}.map(\.id))
                    pendingDeletes.removeAll{observed.contains($0.rootID+"\0"+$0.relativePath)}
                    // Reuse the already acquired inventory, but retain only
                    // ancestors of Windows-compatible pending delete paths.
                    var relevant:[String:Set<Data>]=[:]
                    for job in pendingDeletes {
                        guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                        guard WindowsPathSafety.validRelativePath(job.relativePath) else { continue }
                        var prefix=""
                        for part in job.relativePath.split(separator:"/") {
                            prefix=prefix.isEmpty ? String(part) : prefix+"/"+part
                            relevant[job.rootID,default:[]].insert(Data(prefix.utf8))
                        }
                    }
                    var present:[String:Set<Data>]=[:]
                    if !relevant.isEmpty {
                        for finding in result.findings {
                            guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                            guard finding.targetObjectKind != nil,let candidates=relevant[finding.rootID] else { continue }
                            let key=Data(finding.relativePath.utf8)
                            if candidates.contains(key) { present[finding.rootID,default:[]].insert(key) }
                        }
                    }
                    for job in pendingDeletes {
                        guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                        guard WindowsPathSafety.validRelativePath(job.relativePath) else { continue }
                        let known=present[job.rootID] ?? []
                        var prefix=""
                        for part in job.relativePath.split(separator:"/") {
                            prefix=prefix.isEmpty ? String(part) : prefix+"/"+part
                            if !known.contains(Data(prefix.utf8)) {
                                auditTargetMissingPrefixes[job.id]=prefix
                                break
                            }
                        }
                    }
                }
            }
            // No second complete destination scan during reconciliation.
            // Missing-delete candidates still require targeted live checks.
            // An FSEvents
            // cycle can briefly set ready=false after the expensive audit;
            // do not discard its snapshot simply because the commit gate
            // temporarily closes. Never wait while holding a SQLite lock.
            var retries=0
            while true {
                guard cancellation.awaitCommitWindow(onWaiting:{
                    var p=ArchiveAuditProgress(started:result.started)
                    p.phase="Attesa completamento inventario locale"
                    progress(p)
                }) else { throw SeedVerificationError.cancelled }
                var lastLocalProgress=ProcessInfo.processInfo.systemUptime
                do {
                    if operational {
                        var snapshot=ArchiveAuditProgress(started:result.started)
                        snapshot.phase="Riconciliazione copie pendenti"
                        snapshot.source=result.sourceMetrics ?? AuditSideMetrics()
                        snapshot.destination=result.destinationMetrics ?? AuditSideMetrics()
                        progress(snapshot)
                        let counts=try journal.acknowledgeOperationalAuditMatches(matches,mappings:mappings,
                            shouldContinue:{cancellation.mayCommit})
                        result.recognizedFiles=(result.recognizedFiles ?? 0)+counts.files
                        result.recognizedDirectories=(result.recognizedDirectories ?? 0)+counts.directories
                        var deleteProgress=snapshot
                        deleteProgress.phase="Verifica cancellazioni già soddisfatte"
                        progress(deleteProgress)
                        let deletes=try journal.acknowledgeAbsentAuditDeletes(pendingDeletes,mappings:mappings,
                            auditTargetMissingPrefixes:auditTargetMissingPrefixes,
                            shouldContinue:{cancellation.mayCommit})
                        result.recognizedAbsentDeletes=deletes
                        break
                    }
                    let counts = try journal.acknowledgeInitialInventoryMatches(
                        result.findings,
                        shouldContinue:{ cancellation.mayCommit },
                        onProgress:{ completed,total in
                            let now=ProcessInfo.processInfo.systemUptime
                            guard completed == 0 || completed == total || now-lastLocalProgress >= 0.5 else { return }
                            lastLocalProgress=now
                            var snapshot=ArchiveAuditProgress(started:result.started)
                            snapshot.phase="Riconciliazione coda iniziale · \(completed)/\(total)"
                            snapshot.source=result.sourceMetrics ?? AuditSideMetrics()
                            snapshot.destination=result.destinationMetrics ?? AuditSideMetrics()
                            snapshot.compared=completed; snapshot.total=total
                            progress(snapshot)
                        }
                    )
                    result.recognizedFiles = counts.files
                    result.recognizedDirectories = counts.directories
                    break
                } catch SeedVerificationError.cancelled {
                    // acknowledgeInitialInventoryMatches has already rolled
                    // back. Retry locally only if the SAME audit token is
                    // still valid (no Stop, failure or root reconfiguration).
                    guard !cancellation.isCancelled, retries < 3 else { throw SeedVerificationError.cancelled }
                    retries += 1
                }
            }
        }
        return result
    }

    /// Use one complete archive scan and reuse its verified fingerprints.
    /// Only job IDs captured before the scan can become approval candidates.
    /// No queue acknowledgement happens until a guarded commit is requested.
    public func auditAndRecognize(
        mode: ArchiveAuditMode = .deep,
        repair: Bool = false,
        cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
        diagnostic: (ArchiveAuditProgress) -> Void = { _ in },
        progress: (ArchiveAuditProgress) -> Void = { _ in },
        deletionCandidates: Set<String> = []
    ) throws -> (audit: ArchiveAuditReport, recognition: SeedVerificationReport) {
        let journal = try openJournal()
        let upper = try journal.pendingUploadUpperBound() ?? 0
        var cursor: Int64 = 0
        var pending: [String: QueuedChange] = [:]
        var ambiguous: Set<String> = []
        var inspected = 0
        while true {
            guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
            let page = try journal.pendingUploads(limit:250,afterID:cursor,throughID:upper)
            if page.isEmpty { break }
            for job in page {
                guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                cursor = job.id
                inspected += 1
                let key = job.rootID + "\0" + job.relativePath
                if pending[key] != nil { ambiguous.insert(key) }
                pending[key] = job
            }
        }
        var matches: [SeedVerifiedMatch] = []
        let report = try ArchiveAudit(journal:journal,mappings:mappings).run(
            mode:mode,repair:repair,cancellation:cancellation,collectMetadataMatches:true,
            shouldCollectMetadataMatch:{ root,path in
                let key = root + "\0" + path
                return pending[key] != nil && !ambiguous.contains(key)
            },deletionCandidates:deletionCandidates,
            onVerifiedFile: { root,path,source,target in
                let key = root + "\0" + path
                guard !ambiguous.contains(key), let job = pending[key] else { return }
                matches.append(SeedVerifiedMatch(jobID:job.id,rootID:root,relativePath:path,source:source,target:target,verifiedBytes:source.size))
            },onVerifiedDirectory: { root,path,source,target in
                let key = root + "\0" + path
                guard !ambiguous.contains(key), let job = pending[key] else { return }
                matches.append(SeedVerifiedMatch(jobID:job.id,rootID:root,relativePath:path,source:source,target:target,verifiedBytes:0,objectKind:"directory"))
            },diagnostic:diagnostic,progress:progress)
        try checkFileIdentity()
        guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
        // Report remaining jobs conservatively: directories, conflicts, files
        // changed during scanning and unmatched jobs remain in the queue.
        let differenceCount = report.findings.filter {
            ($0.kind == .missing || $0.kind == .different) && pending[$0.rootID + "\0" + $0.relativePath] != nil
        }.count
        return (report,SeedVerificationReport(matches:matches,inspected:inspected,
            missingOrDifferent:differenceCount,deferred:max(0,inspected-matches.count-differenceCount),
            bytesRead:report.bytesRead))
    }

    public func approve(
        report: SeedVerificationReport,
        cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
        progress: ((Int, Int) -> Void)? = nil,
        onCommit: () -> Void = {},
        onCounts: (Int, Int) -> Void = { _,_ in }
    ) throws -> Int {
        let journal = try openJournal()
        let verifier = try SeededArchiveVerifier(journal: journal, mappings: mappings)
        return try verifier.approve(report: report, cancellation: cancellation, progress:progress,onCommit:onCommit,onCounts:onCounts)
    }
}
