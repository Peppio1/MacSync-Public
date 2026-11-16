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

    public init() {}
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// A conservative lstat fingerprint; a successful hash is valid only while
/// both files retain these attributes. mtime + ctime protect against edits
/// that preserve size and modification time.
public struct SeedFileFingerprint: Equatable, Sendable {
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

public struct SeedVerifiedMatch: Sendable {
    public let jobID: Int64
    public let rootID: String
    public let relativePath: String
    public let source: SeedFileFingerprint
    public let target: SeedFileFingerprint
    public let verifiedBytes: Int64
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
            guard force || now-lastProgress >= 0.25 else { return }
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
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Int {
        var stillValid: [SeedVerifiedMatch] = []
        for (index, match) in report.matches.enumerated() {
            if cancellation.isCancelled { throw SeedVerificationError.cancelled }
            guard let mapping = mappings[match.rootID] else { continue }
            do {
                try mapping.verify()
                let src = try safePath(match.relativePath, mapping: mapping, destination: false)
                let dst = try safePath(match.relativePath, mapping: mapping, destination: true)
                guard try Self.fingerprint(src) == match.source,
                      try Self.fingerprint(dst) == match.target else { continue }
                try mapping.verify()
                stillValid.append(match)
            } catch {
                // A file changed or disappeared AFTER the initial preview.
                // We do not mark it complete and never silently overwrite it.
                continue
            }
            if (index + 1) % 25 == 0 {
                progress?(index + 1, report.matches.count)
            }
        }
        if cancellation.isCancelled { throw SeedVerificationError.cancelled }
        let sources = mappings.mapValues { $0.source.path }
        let changed = try journal.acknowledgeVerifiedFiles(
            stillValid, sourceRoots: sources, shouldContinue: { !cancellation.isCancelled }
        )
        progress?(report.matches.count, report.matches.count)
        return changed
    }

    private func verifyOne(
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
        let url = try mapping.fileURL(relativePath: relativePath, destination: destination)
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

    public static func fingerprint(_ url: URL) throws -> SeedFileFingerprint {
        var st = stat()
        guard url.path.withCString({ lstat($0, &st) }) == 0 else {
            throw SeedVerificationError.sourceMissing
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
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

    /// Use one complete archive scan and reuse its verified fingerprints.
    /// Only job IDs captured before the scan can become approval candidates.
    /// No queue acknowledgement happens without a subsequent explicit approval.
    public func auditAndRecognize(
        repair: Bool = false,
        cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
        progress: (ArchiveAuditProgress) -> Void = { _ in }
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
            mode:.deep,repair:repair,cancellation:cancellation,
            onVerifiedFile: { root,path,source,target in
                let key = root + "\0" + path
                guard !ambiguous.contains(key), let job = pending[key] else { return }
                matches.append(SeedVerifiedMatch(jobID:job.id,rootID:root,relativePath:path,source:source,target:target,verifiedBytes:source.size))
            },progress:progress)
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
        cancellation: SeedVerificationCancellation = SeedVerificationCancellation()
    ) throws -> Int {
        let journal = try openJournal()
        let verifier = try SeededArchiveVerifier(journal: journal, mappings: mappings)
        return try verifier.approve(report: report, cancellation: cancellation)
    }
}
