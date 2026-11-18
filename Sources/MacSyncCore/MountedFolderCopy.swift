import Foundation
import Darwin

public enum MountedCopyError: Error, LocalizedError, Equatable {
    case invalidMapping
    case rootUnavailable
    case volumeChanged
    case unsafeFile
    case sourceChanging
    case destinationConflict
    case sourceMissing
    case copyFailed(Int)
    case insufficientSpace(required: Int64, available: Int64)
    case stagingIncomplete
    case destinationChanging
    case sourceRootChanged

    public var errorDescription: String? {
        switch self {
        case .invalidMapping: return "Origine e destinazione devono essere cartelle separate"
        case .rootUnavailable: return "Cartella origine/destinazione non accessibile"
        case .volumeChanged: return "Volume destinazione non montato o diverso da quello configurato"
        case .unsafeFile: return "Percorso o collegamento simbolico non sicuro"
        case .sourceChanging: return "File ancora in modifica, trasferimento rimandato"
        case .destinationConflict: return "Destinazione incompatibile: elemento già esistente"
        case .sourceMissing: return "File sorgente mancante: copia rimandata"
        case .copyFailed(let code): return "Copia non riuscita (codice filesystem: \(code)); operazione mantenuta in coda"
        case .insufficientSpace(let required, let available): return "Spazio insufficiente: richiesti \(required) byte, disponibili \(available) byte"
        case .stagingIncomplete: return "File temporaneo incompleto; operazione mantenuta in coda"
        case .destinationChanging: return "Destinazione modificata durante la copia; operazione rimandata"
        case .sourceRootChanged: return "Identità della cartella sorgente cambiata; operazioni bloccate"
        }
    }
}

public struct VolumeFingerprint: Equatable, Codable, Sendable {
    public let fileSystem: String
    public let mountPath: String
    /// SMB mount source, e.g. //server/share, as reported by statfs.
    /// Never write this value to activity logs. Nil denotes an old profile
    /// and must not be trusted for unattended background copying.
    public let mountSource: String?

    public init(fileSystem: String, mountPath: String, mountSource: String? = nil) {
        self.fileSystem = fileSystem
        self.mountPath = mountPath
        self.mountSource = mountSource
    }

    public var isStrongIdentity: Bool { mountSource?.isEmpty == false }

    public static func read(at url: URL) throws -> VolumeFingerprint {
        var info = statfs()
        let result = url.path.withCString { statfs($0, &info) }
        guard result == 0 else { throw MountedCopyError.rootUnavailable }
        return fingerprint(from: &info)
    }

    public static func read(directoryDescriptor: Int32) throws -> VolumeFingerprint {
        var info = statfs()
        guard fstatfs(directoryDescriptor,&info) == 0 else { throw MountedCopyError.rootUnavailable }
        return fingerprint(from:&info)
    }

    private static func fingerprint(from info: inout statfs) -> VolumeFingerprint {
        let fs = withUnsafePointer(to: &info.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        let mount = withUnsafePointer(to: &info.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        let from = withUnsafePointer(to: &info.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return VolumeFingerprint(fileSystem: fs, mountPath: mount,
                                 mountSource: from.isEmpty ? nil : from)
    }

    public var isNetworkVolume: Bool {
        let fs = fileSystem.lowercased()
        return fs == "smbfs" || fs == "webdav" || fs == "nfs"
    }
}

/// Directory identity, excluding timestamps changed by ordinary file creation.
fileprivate struct CopyDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func read(_ url: URL) throws -> CopyDirectoryIdentity {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              url.resolvingSymlinksInPath().path == url.path else {
            throw MountedCopyError.rootUnavailable
        }
        return CopyDirectoryIdentity(device: UInt64(bitPattern: Int64(info.st_dev)),
                                     inode: UInt64(info.st_ino))
    }
}

/// Each selected target is used as-is. Deletion actions are handled only
/// by the separately confirmed MirrorDeletionWorker.
public struct MountedFolderMapping: Sendable {
    public let rootID: String
    public let source: URL
    public let target: URL
    public let targetVolume: VolumeFingerprint
    private let sourceIdentity: CopyDirectoryIdentity
    private let targetIdentity: CopyDirectoryIdentity

    public init(
        rootID: String, source: URL, target: URL,
        expectedTargetVolume: VolumeFingerprint? = nil
    ) throws {
        let src = source.standardizedFileURL.resolvingSymlinksInPath()
        let dst = target.standardizedFileURL.resolvingSymlinksInPath()
        guard !rootID.isEmpty, src.isFileURL, dst.isFileURL,
              src.path != dst.path,
              !src.path.hasPrefix(dst.path + "/"),
              !dst.path.hasPrefix(src.path + "/"),
              !src.path.hasPrefix(dst.path + "/"),
              FileManager.default.fileExists(atPath: src.path),
              FileManager.default.fileExists(atPath: dst.path)
        else { throw MountedCopyError.invalidMapping }
        let sourceValue = try src.resourceValues(forKeys: [.isDirectoryKey])
        let targetValue = try dst.resourceValues(forKeys: [.isDirectoryKey])
        guard sourceValue.isDirectory == true, targetValue.isDirectory == true else {
            throw MountedCopyError.rootUnavailable
        }
        let found = try VolumeFingerprint.read(at: dst)
        if let expectedTargetVolume, expectedTargetVolume != found {
            throw MountedCopyError.volumeChanged
        }
        self.rootID = rootID
        self.source = src
        self.target = dst
        self.targetVolume = found
        self.sourceIdentity = try CopyDirectoryIdentity.read(src)
        self.targetIdentity = try CopyDirectoryIdentity.read(dst)
    }

    public func verify() throws {
        guard FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: target.path) else {
            throw MountedCopyError.rootUnavailable
        }
        guard try CopyDirectoryIdentity.read(source) == sourceIdentity else {
            throw MountedCopyError.sourceRootChanged
        }
        guard try CopyDirectoryIdentity.read(target) == targetIdentity else { throw MountedCopyError.volumeChanged }
        let current = try VolumeFingerprint.read(at: target)
        guard current == targetVolume else { throw MountedCopyError.volumeChanged }
    }

    /// Only for read-only verification of an already enumerated object.
    /// Special names must exist exactly as listed, without ambiguous
    /// Win32 aliases, traversal, alternate separators or symlinks.
    /// Write and deletion paths continue to use the strict fileURL.
    public func verificationURL(relativePath: String, destination: Bool) throws -> URL {
        if WindowsPathSafety.validRelativePath(relativePath) {
            return try fileURL(relativePath:relativePath,destination:destination)
        }
        let comps = relativePath.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard !comps.isEmpty, comps.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") &&
            !$0.contains("\0") && !$0.lowercased().hasPrefix(".macsync-")
        }) else { throw MountedCopyError.unsafeFile }
        var current = destination ? target : source
        for (index,part) in comps.enumerated() {
            let names = try FileManager.default.contentsOfDirectory(atPath:current.path)
            let aliases = names.filter { WindowsPathSafety.comparisonFold($0) == WindowsPathSafety.comparisonFold(part) }
            guard aliases.count == 1, let actual = aliases.first,
                  Array(actual.utf8) == Array(part.utf8) else { throw MountedCopyError.destinationConflict }
            current.appendPathComponent(actual)
            var st = stat()
            guard current.path.withCString({ lstat($0,&st) }) == 0 else { throw MountedCopyError.rootUnavailable }
            let kind = st.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFDIR) || (index == comps.count-1 && kind == mode_t(S_IFREG)) else {
                throw MountedCopyError.unsafeFile
            }
        }
        return current
    }

    public func fileURL(relativePath: String, destination: Bool) throws -> URL {
        let root = destination ? target : source
        let comps = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard WindowsPathSafety.validRelativePath(relativePath), !comps.isEmpty,
              comps.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0") &&
                  !$0.lowercased().hasPrefix(".macsync-")
              }) else { throw MountedCopyError.unsafeFile }
        return root.appendingPathComponent(relativePath)
    }
}

public struct MountedCopySummary: Equatable {
    public var created = 0
    public var updated = 0
    public var directoriesCreated = 0
    public var copied = 0
    public var reconciled = 0
    public var deferred = 0
    public var failed = 0
    public var bytes: Int64 = 0
    public var disabled = false
    public var interrupted = false
    public init() {}
}

/// Uses Foundation only: no separate SMB credentials, no rclone binary.
/// macOS supplies authentication for already-mounted Finder shares.
/// Call only on one serial work queue (SQLite connection is not thread-safe).
public final class MountedFolderCopyWorker {
    private let journal: ChangeJournal
    private let log: SyncActivityLog
    private let mappings: [String: MountedFolderMapping]
    private let fm = FileManager.default
    private let minimumStableAge: TimeInterval
    private let now: () -> Date
    private let availableCapacity: (URL) throws -> Int64?
    private var nextAfterID: Int64 = 0
    public var onEvent: ((SyncCycleEvent) -> Void)?
    public var onJobStarted: ((QueuedChange) -> Void)?
    public var onPlan: ((Int) -> Void)?
    public var onPhase: ((String) -> Void)?
    public var operationAllowed: () -> Bool = { true }
    private func emit(_ kind: SyncEventKind, job: QueuedChange, mapping: MountedFolderMapping?,
                      bytes: Int64? = nil, seconds: Double = 0, detail: String = "") {
        onEvent?(SyncCycleEvent(kind:kind,job:job,mapping:mapping,bytes:bytes,seconds:seconds,detail:detail))
    }

    // Internal fault injection for deterministic core tests, never configured
    // by the application or exposed to users.
    enum Checkpoint: Equatable { case beforeStageCopy, afterStageCopy, afterBackup, afterPublish, beforeBackupCleanup, beforeFailedStageCleanup }
    var checkpoint: ((Checkpoint, URL) throws -> Void)?

    public init(
        journal: ChangeJournal, log: SyncActivityLog,
        mappings: [MountedFolderMapping],
        minimumStableAge: TimeInterval = 20,
        now: @escaping () -> Date = Date.init,
        availableCapacity: @escaping (URL) throws -> Int64? = TransferPreflight.availableBytes
    ) throws {
        guard !mappings.isEmpty,
              Dictionary(grouping: mappings, by: \.rootID).allSatisfy({ $0.value.count == 1 })
        else { throw MountedCopyError.invalidMapping }
        self.journal = journal
        self.log = log
        self.mappings = Dictionary(uniqueKeysWithValues: mappings.map { ($0.rootID, $0) })
        self.minimumStableAge = max(0, minimumStableAge)
        self.now = now
        self.availableCapacity = availableCapacity
    }

    public func runOnce(enabled: Bool = false, maxJobs: Int = 50,
                        shouldContinue: () -> Bool = { true }) throws -> MountedCopySummary {
        var summary = MountedCopySummary()
        guard enabled else {
            summary.disabled = true
            return summary
        }
        guard try journal.queueRebuildToken() == nil else { summary.interrupted=true; return summary }
        var jobs = try journal.pendingUploads(limit: maxJobs, afterID: nextAfterID)
        if jobs.isEmpty && nextAfterID != 0 {
            nextAfterID = 0
            jobs = try journal.pendingUploads(limit: maxJobs)
        }
        _ = try process(jobs, summary: &summary, shouldContinue: shouldContinue)
        return summary
    }

    /// Process every eligible job present at the beginning of the cycle,
    /// with bounded memory. A failing job is tried at most once per cycle;
    /// new events wait for the next scheduled run.
    public func runCycle(enabled: Bool = false, pageSize: Int = 100,
                         throughID: Int64? = nil,
                         shouldContinue: () -> Bool = { true },
                         onProgress: (MountedCopySummary) -> Void = { _ in }) throws -> MountedCopySummary {
        var summary = MountedCopySummary()
        guard enabled else {
            summary.disabled = true
            return summary
        }
        guard try journal.queueRebuildToken() == nil else { summary.interrupted=true; return summary }
        guard let pendingUpper = try journal.pendingUploadUpperBound() else { onPlan?(0); return summary }
        let upper = min(pendingUpper, throughID ?? Int64.max)
        onPlan?(try journal.plannedUploadCount(throughID: upper))
        let size = max(1, min(pageSize, 1000))
        nextAfterID = 0
        while shouldContinue() {
            let page = try journal.pendingUploads(
                limit: size, afterID: nextAfterID, throughID: upper
            )
            guard !page.isEmpty else { return summary }
            let completedPage = try process(page, summary: &summary,
                                            shouldContinue: shouldContinue)
            onProgress(summary)
            guard completedPage else { return summary }
        }
        summary.interrupted = true
        return summary
    }

    /// Serial batch processing; returns false if transfers should stop.
    private func process(_ jobs: [QueuedChange], summary: inout MountedCopySummary,
                         shouldContinue: () -> Bool) throws -> Bool {
        for job in jobs {
            guard shouldContinue(), operationAllowed() else {
                summary.interrupted = true
                return false
            }
            nextAfterID = job.id
            let started = Date()
            onJobStarted?(job)
            guard let mapping = mappings[job.rootID] else {
                summary.failed += 1
                emit(.failed,job:job,mapping:nil,detail:"Coppia non configurata")
                continue
            }
            do {
                guard try journal.uploadIsCurrent(job) else {
                    summary.deferred += 1
                    emit(.deferred,job:job,mapping:mapping,detail:"Evento non più corrente")
                    continue
                }
                // Only an interrupted publication pays the cost of a full
                // content comparison. Never infer completion from size alone.
                if try journal.hasPublicationIntent(job), try reconcilePublished(job,mapping:mapping) {
                    summary.reconciled += 1
                    emit(.noChange,job:job,mapping:mapping,detail:"Pubblicazione precedente verificata SHA-256")
                    try? log.record(level:.success,rootID:job.rootID,action:"reconciled",relativePath:job.relativePath,message:"Pubblicazione precedente verificata; nessuna nuova copia")
                    continue
                }
                let outcome = try transfer(job, mapping: mapping)
                guard try journal.acknowledgeUpload(job) else {
                    // The published version may have been superseded while
                    // completing the job. Keep its backup for manual recovery.
                    summary.deferred += 1
                    emit(.deferred,job:job,mapping:mapping,detail:"Conferma non acquisita")
                    try? log.record(level: .warning, rootID: job.rootID, action: "retry",
                        relativePath: job.relativePath,
                        message: "Conferma non acquisita; eventuale backup conservato")
                    continue
                }
                try? journal.clearPublicationIntent(job)
                // Cleanup is strictly post-acknowledgment, never part of the
                // replacement transaction. Failure cannot turn a confirmed
                // copy into another upload or authorize a second cleanup.
                if let backup = outcome.backup {
                    cleanupConfirmedBackup(backup, mapping: mapping, job: job)
                }
                summary.copied += 1
                let (totalBytes, overflow) = summary.bytes.addingReportingOverflow(outcome.bytes)
                summary.bytes = overflow ? Int64.max : totalBytes
                switch outcome.kind {
                case .created: summary.created += 1
                case .updated: summary.updated += 1
                case .directoryCreated: summary.directoriesCreated += 1
                case .directoryExisting: break
                }
                let eventKind: SyncEventKind
                switch outcome.kind {
                case .created: eventKind = .newFile
                case .updated: eventKind = .updatedFile
                case .directoryCreated: eventKind = .directoryCreated
                case .directoryExisting: eventKind = .noChange
                }
                emit(eventKind,job:job,mapping:mapping,bytes:outcome.bytes,seconds:Date().timeIntervalSince(started))
                let detail: String
                switch outcome.kind {
                case .created: detail = "Nuovo file copiato"
                case .updated: detail = "File aggiornato"
                case .directoryCreated: detail = "Cartella creata"
                case .directoryExisting: detail = "Cartella già presente"
                }
                try? log.record(
                    level: .success, rootID: job.rootID, action: "copy",
                    relativePath: job.relativePath, bytes: outcome.bytes,
                    durationSeconds: Date().timeIntervalSince(started),
                    message: detail
                )
            } catch SeedVerificationError.cancelled {
                summary.interrupted = true; return false
            } catch let error as MountedCopyError {
                let eventKind: SyncEventKind
                switch error {
                case .sourceChanging, .sourceMissing, .volumeChanged,
                     .rootUnavailable, .insufficientSpace, .destinationChanging,
                     .sourceRootChanged:
                    summary.deferred += 1; eventKind = .deferred
                default:
                    summary.failed += 1; eventKind = .failed
                }
                emit(eventKind,job:job,mapping:mapping,seconds:Date().timeIntervalSince(started),detail:error.localizedDescription)
                try log.record(
                    level: .warning, rootID: job.rootID, action: "retry",
                    relativePath: job.relativePath,
                    durationSeconds: Date().timeIntervalSince(started),
                    message: SyncDiagnostic.describe(error)
                )
                // A lost mount or changed root is not a per-file failure.
                // Stop the cycle rather than attempting thousands of jobs
                // against the same unavailable destination.
                switch error {
                case .volumeChanged, .rootUnavailable, .sourceRootChanged:
                    summary.interrupted = true
                    return false
                case .copyFailed(let code):
                    // An unsupported operation cannot be fixed by repeated
                    // transfers. Preserve remaining jobs and stop the cycle.
                    if code == Int(ENOTSUP) {
                        summary.interrupted = true
                        return false
                    }
                    // A network failure may be reported as a generic
                    // Foundation copy error. Revalidate only on failure,
                    // not on a separate timer or a recursive remote scan.
                    do { try mapping.verify() }
                    catch {
                        summary.interrupted = true
                        return false
                    }
                default: break
                }
            } catch {
                summary.failed += 1
                emit(.failed,job:job,mapping:mapping,seconds:Date().timeIntervalSince(started),detail:SyncDiagnostic.describe(error))
                try log.record(
                    level: .error, rootID: job.rootID, action: "retry",
                    relativePath: job.relativePath,
                    durationSeconds: Date().timeIntervalSince(started),
                    message: SyncDiagnostic.describe(error) + "; operazione conservata in coda"
                )
            }
        }
        return true
    }

    private func reconcilePublished(_ job: QueuedChange,mapping:MountedFolderMapping) throws -> Bool {
        let token = SeedVerificationCancellation(shouldContinue:operationAllowed)
        let verifier = try SeededArchiveVerifier(journal:journal,mappings:[mapping])
        do {
            try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.source)
            try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.target)
            guard let match = try verifier.verifyOne(job,mapping:mapping,cancellation:token,onBytesRead:{_ in}) else { return false }
            let report = SeedVerificationReport(matches:[match],inspected:1,missingOrDifferent:0,deferred:0,bytesRead:0)
            guard try verifier.approve(report:report,cancellation:token) == 1 else { return false }
            try? journal.clearPublicationIntent(job)
            return true
        } catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
        catch { try mapping.verify(); return false }
    }

    private enum TransferKind { case created, updated, directoryCreated, directoryExisting }
    private struct TransferOutcome {
        let bytes: Int64
        let kind: TransferKind
        let backup: ConfirmedBackup?

        init(bytes: Int64, kind: TransferKind, backup: ConfirmedBackup? = nil) {
            self.bytes = bytes
            self.kind = kind
            self.backup = backup
        }
    }

    // A capability scoped to this successful transfer only. Never find
    // backups by filename pattern or automatically clean older artifacts.
    private struct ConfirmedBackup {
        let url: URL
        let snapshot: Snapshot
        let targetRoot: CopyDirectoryIdentity
        let parent: CopyDirectoryIdentity
        let sourceURL: URL
        let sourceSnapshot: Snapshot
        let publishedURL: URL
        let publishedSnapshot: Snapshot
    }

    private func cleanupConfirmedBackup(_ backup: ConfirmedBackup,
                                        mapping: MountedFolderMapping,
                                        job: QueuedChange) {
        do {
            try checkpoint?(.beforeBackupCleanup, backup.url)
            try mapping.verify()
            guard try CopyDirectoryIdentity.read(mapping.target) == backup.targetRoot else {
                throw MountedCopyError.volumeChanged
            }
            try ensureSafeParents(backup.url, under: mapping.target, create: false)
            try ensureSafeParents(backup.sourceURL, under: mapping.source, create: false)
            guard backup.url.deletingLastPathComponent() == backup.publishedURL.deletingLastPathComponent(),
                  try CopyDirectoryIdentity.read(backup.url.deletingLastPathComponent()) == backup.parent,
                  try readSnapshot(backup.sourceURL) == backup.sourceSnapshot,
                  try readSnapshot(backup.publishedURL) == backup.publishedSnapshot,
                  try readSnapshot(backup.url) == backup.snapshot else {
                throw MountedCopyError.destinationChanging
            }
            // unlink refuses directories and does not follow leaf symlinks.
            // There is no recursive removal or directory enumeration.
            let anchor = try AnchoredDirectory(backup.url.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
            let stat = try anchor.leaf(backup.url.lastPathComponent)
            guard UInt64(stat.st_ino) == backup.snapshot.inode, Int64(stat.st_ctimespec.tv_sec) == backup.snapshot.ctimeSeconds,
                  Int64(stat.st_ctimespec.tv_nsec) == backup.snapshot.ctimeNanoseconds else { throw MountedCopyError.destinationChanging }
            try anchor.remove(backup.url.lastPathComponent,matching:stat)
            try? log.record(level: .success, rootID: job.rootID, action: "backup_cleanup",
                relativePath: job.relativePath, message: "Backup temporaneo eliminato dopo conferma")
        } catch {
            // No automatic retry: a disconnect, identity change or crash
            // leaves a backup for manual inspection, never a blind deletion.
            try? log.record(level: .warning, rootID: job.rootID, action: "backup_retained",
                relativePath: job.relativePath,
                message: "Pulizia backup non confermata; verificare manualmente: " + backup.url.lastPathComponent)
        }
    }

    private func transfer(_ job: QueuedChange, mapping: MountedFolderMapping) throws -> TransferOutcome {
        guard operationAllowed() else { throw SeedVerificationError.cancelled }
        try mapping.verify()
        let targetIdentity = try CopyDirectoryIdentity.read(mapping.target)
        func verifyRoots() throws {
            try mapping.verify()
            guard try CopyDirectoryIdentity.read(mapping.target) == targetIdentity else {
                throw MountedCopyError.volumeChanged
            }
        }
        let src = try mapping.fileURL(relativePath: job.relativePath, destination: false)
        let dst = try mapping.fileURL(relativePath: job.relativePath, destination: true)
        try ensureSafeParents(src, under: mapping.source, create: false)
        try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.source)
        try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.target)
        let snapshot = try readSnapshot(src)
        guard snapshot.kind == .directory || snapshot.kind == .file else {
            throw MountedCopyError.unsafeFile
        }

        if snapshot.kind == .directory {
            guard operationAllowed() else { throw SeedVerificationError.cancelled }
            try verifyRoots()
            try ensureSafeParents(dst, under: mapping.target, create: true, expectedVolume:mapping.targetVolume)
            try verifyRoots()
            guard try journal.uploadIsCurrent(job) else { throw MountedCopyError.sourceChanging }
            let alreadyPresent = try optionalSnapshot(dst) != nil
            if alreadyPresent {
                let existing = try readSnapshot(dst)
                guard existing.kind == .directory else { throw MountedCopyError.destinationConflict }
            } else {
                let parent = try AnchoredDirectory(dst.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
                try verifyRoots()
                try parent.ensureDirectory(dst.lastPathComponent,shouldContinue:operationAllowed)
            }
            try verifyRoots()
            return TransferOutcome(bytes: 0,
                kind: alreadyPresent ? .directoryExisting : .directoryCreated)
        }

        guard now().timeIntervalSince1970 - snapshot.mtime >= minimumStableAge else {
            throw MountedCopyError.sourceChanging
        }
        try verifyRoots()
        try ensureSafeParents(dst, under: mapping.target, create: true, expectedVolume:mapping.targetVolume)
        try verifyRoots()
        // Check capacity before creating staging or safety backups. An
        // overwrite temporarily needs space for both old and new copies.
        let originalTarget = try optionalSnapshot(dst)
        let targetExisted = originalTarget != nil
        if let originalTarget, originalTarget.kind != .file {
            throw MountedCopyError.destinationConflict
        }
        let existingBytes = originalTarget?.size ?? 0
        try TransferPreflight.requireCapacity(
            available: try availableCapacity(mapping.target),
            incoming: snapshot.size, existing: existingBytes
        )
        try verifyRoots()
        let stageFolder = mapping.target.appendingPathComponent(".macsync-staging", isDirectory: true)
        try createSafeDirectory(stageFolder, parent: mapping.target, expectedVolume:mapping.targetVolume)
        let stageIdentity = try CopyDirectoryIdentity.read(stageFolder)
        let staging = stageFolder.appendingPathComponent(UUID().uuidString + ".partial")
        try log.record(
            level: .info, rootID: job.rootID, action: "start",
            relativePath: job.relativePath, bytes: snapshot.size,
            message: "Inizio copia in staging"
        )
        // Each attempt owns a fresh UUID path; never reuse a previous partial.
        // Only discard an identifiable pre-publication temporary. When the
        // share is offline or publication may have run, retain recovery data.
        var stageAttempted = false
        var publicationAttempted = false
        var observedStage: Snapshot?
        do {
            try verifyRoots()
            guard try CopyDirectoryIdentity.read(stageFolder) == stageIdentity,
                  try optionalSnapshot(staging) == nil else {
                throw MountedCopyError.unsafeFile
            }
            stageAttempted = true
            try checkpoint?(.beforeStageCopy, staging)
            onPhase?("Trasferimento")
            let transferStart = ProcessInfo.processInfo.systemUptime
            try fm.copyItem(at: src, to: staging)
            onPhase?("Verifica del trasferimento")
            observedStage = try readSnapshot(staging)
            if let observedStage, observedStage.kind == .file {
                emit(.stageCopy,job:job,mapping:mapping,bytes:observedStage.size,
                     seconds:ProcessInfo.processInfo.systemUptime-transferStart)
            }
            try checkpoint?(.afterStageCopy, staging)
            try verifyRoots()
            guard try CopyDirectoryIdentity.read(stageFolder) == stageIdentity else {
                throw MountedCopyError.unsafeFile
            }
            // Inspect the transferred staging file before publication.
            let staged = try readSnapshot(staging)
            let stageAnchor = try AnchoredDirectory(stageFolder,expectedVolume:mapping.targetVolume)
            let destAnchor = try AnchoredDirectory(dst.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
            let stagedStat = try stageAnchor.leaf(staging.lastPathComponent)
            guard UInt64(stagedStat.st_ino) == staged.inode, Int64(stagedStat.st_size) == staged.size else { throw MountedCopyError.stagingIncomplete }
            guard staged.kind == .file, staged.size == snapshot.size,
                  staged == observedStage else {
                throw MountedCopyError.stagingIncomplete
            }
            guard try readSnapshot(src) == snapshot else {
                throw MountedCopyError.sourceChanging
            }
            func verifyPublication() throws {
                guard operationAllowed() else { throw SeedVerificationError.cancelled }
                try verifyRoots()
                guard try journal.uploadIsCurrent(job) else { throw MountedCopyError.sourceChanging }
                try ensureSafeParents(src, under: mapping.source, create: false)
                try ensureSafeParents(dst, under: mapping.target, create: false)
                guard try CopyDirectoryIdentity.read(stageFolder) == stageIdentity,
                      try readSnapshot(staging) == staged else {
                    throw MountedCopyError.stagingIncomplete
                }
                guard try readSnapshot(src) == snapshot else {
                    throw MountedCopyError.sourceChanging
                }
                guard try optionalSnapshot(dst) == originalTarget else {
                    throw MountedCopyError.destinationChanging
                }
            }
            try verifyPublication()
            var backupForCleanup: (url: URL, snapshot: Snapshot, parent: CopyDirectoryIdentity)?
            if let originalTarget {
                // Preserve the exact previous target before publishing. If
                // another client modifies it during backup, do not overwrite.
                let backupURL = dst.deletingLastPathComponent()
                    .appendingPathComponent(".macsync-backup-" + UUID().uuidString)
                let parent = try CopyDirectoryIdentity.read(dst.deletingLastPathComponent())
                // Record the opaque backup name with the original relative
                // path before creating it, so interrupted copies can be
                // identified in the activity log without scanning the share.
                try log.record(level: .info, rootID: job.rootID, action: "backup_start",
                    relativePath: job.relativePath, bytes: originalTarget.size,
                    message: "Backup temporaneo: " + backupURL.lastPathComponent)
                onPhase?("Backup di sicurezza")
                let backupStart = ProcessInfo.processInfo.systemUptime
                try fm.copyItem(at: dst, to: backupURL)
                onPhase?("Verifica e pubblicazione")
                let backup = try readSnapshot(backupURL)
                if backup.kind == .file {
                    emit(.backupCopy,job:job,mapping:mapping,bytes:backup.size,
                         seconds:ProcessInfo.processInfo.systemUptime-backupStart)
                }
                try checkpoint?(.afterBackup, backupURL)
                try verifyPublication()
                guard backup.kind == .file, backup.size == originalTarget.size,
                      try readSnapshot(backupURL) == backup,
                      try CopyDirectoryIdentity.read(dst.deletingLastPathComponent()) == parent else {
                    throw MountedCopyError.stagingIncomplete
                }
                let originalStat = try destAnchor.leaf(dst.lastPathComponent)
                guard UInt64(originalStat.st_ino) == originalTarget.inode,
                      Int64(originalStat.st_ctimespec.tv_sec) == originalTarget.ctimeSeconds,
                      Int64(originalStat.st_ctimespec.tv_nsec) == originalTarget.ctimeNanoseconds else { throw MountedCopyError.destinationChanging }
                try journal.recordPublicationIntent(job)
                publicationAttempted = true
                try stageAnchor.publish(staging.lastPathComponent,matching:stagedStat,to:destAnchor,
                    as:dst.lastPathComponent,replacing:originalStat,shouldContinue:operationAllowed,onMethod: { method in
                        try? self.log.record(level:.info,rootID:job.rootID,action:"publish_method",relativePath:job.relativePath,message:method)
                    })
                backupForCleanup = (backupURL, backup, parent)
            } else {
                // moveItem refuses an existing target; never overwrite a
                // newly arrived file after an initially absent destination.
                try journal.recordPublicationIntent(job)
                publicationAttempted = true
                try stageAnchor.publish(staging.lastPathComponent,matching:stagedStat,to:destAnchor,
                    as:dst.lastPathComponent,replacing:nil,shouldContinue:operationAllowed,onMethod: { method in
                        try? self.log.record(level:.info,rootID:job.rootID,action:"publish_method",relativePath:job.relativePath,message:method)
                    })
            }
            try checkpoint?(.afterPublish, dst)
            try verifyRoots()
            try ensureSafeParents(dst, under: mapping.target, create: false)
            let published = try readSnapshot(dst)
            guard published.kind == .file, published.size == snapshot.size,
                  published.device == staged.device, published.inode == staged.inode else {
                throw MountedCopyError.stagingIncomplete
            }
            guard try readSnapshot(src) == snapshot else {
                throw MountedCopyError.sourceChanging
            }
            let confirmedBackup = backupForCleanup.map {
                ConfirmedBackup(url: $0.url, snapshot: $0.snapshot,
                    targetRoot: targetIdentity, parent: $0.parent,
                    sourceURL: src, sourceSnapshot: snapshot,
                    publishedURL: dst, publishedSnapshot: published)
            }
            return TransferOutcome(bytes: snapshot.size,
                kind: targetExisted ? .updated : .created, backup: confirmedBackup)
        } catch {
            // Never touch destination photos or backups on failure. Only
            // the current attempt's unpublished UUID partial can be removed.
            if stageAttempted && !publicationAttempted {
                do {
                    try verifyRoots()
                    guard try CopyDirectoryIdentity.read(stageFolder) == stageIdentity else {
                        throw MountedCopyError.unsafeFile
                    }
                    if let failedStage = try optionalSnapshot(staging) {
                        guard failedStage.kind == .file,
                              observedStage == nil || observedStage == failedStage else {
                            throw MountedCopyError.unsafeFile
                        }
                        try checkpoint?(.beforeFailedStageCleanup, staging)
                        try verifyRoots()
                        try ensureSafeParents(src, under: mapping.source, create: false)
                        guard try readSnapshot(src) == snapshot,
                              try CopyDirectoryIdentity.read(stageFolder) == stageIdentity,
                              try optionalSnapshot(staging) == failedStage else {
                            throw MountedCopyError.destinationChanging
                        }
                        let anchor = try AnchoredDirectory(stageFolder,expectedVolume:mapping.targetVolume)
                        let stat = try anchor.leaf(staging.lastPathComponent)
                        guard UInt64(stat.st_ino) == failedStage.inode, Int64(stat.st_ctimespec.tv_sec) == failedStage.ctimeSeconds,
                              Int64(stat.st_ctimespec.tv_nsec) == failedStage.ctimeNanoseconds else { throw MountedCopyError.destinationChanging }
                        try anchor.remove(staging.lastPathComponent,matching:stat)
                        try? log.record(level: .info, rootID: job.rootID, action: "staging_cleanup",
                            relativePath: job.relativePath,
                            message: "Temporaneo del tentativo fallito eliminato; nuovo tentativo da zero")
                    }
                } catch {
                    try? log.record(level: .warning, rootID: job.rootID, action: "staging_retained",
                        relativePath: job.relativePath,
                        message: "Temporaneo non verificabile; controllare manualmente: " + staging.lastPathComponent)
                }
            } else if publicationAttempted {
                try? log.record(level: .warning, rootID: job.rootID, action: "staging_retained",
                    relativePath: job.relativePath,
                    message: "Esito pubblicazione incerto; eventuale temporaneo non rimosso: " + staging.lastPathComponent)
            }
            if let m = error as? MountedCopyError { throw m }
            if let e = error as? SeedVerificationError { throw e }
            throw MountedCopyError.copyFailed((error as NSError).code)
        }
    }

    private enum FileKind { case file, directory, other }
    private struct Snapshot: Equatable {
        let kind: FileKind
        let size: Int64
        let mtime: TimeInterval
        let inode: UInt64
        let device: UInt64
        let ctimeSeconds: Int64
        let ctimeNanoseconds: Int64
    }

    private func readSnapshot(_ url: URL) throws -> Snapshot {
        guard let value = try optionalSnapshot(url) else {
            throw MountedCopyError.sourceMissing
        }
        return value
    }

    /// Only ENOENT means absent. Permission/network errors and dangling
    /// symlinks must not be mistaken for an empty destination.
    private func optionalSnapshot(_ url: URL) throws -> Snapshot? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            if errno == ENOENT { return nil }
            throw MountedCopyError.rootUnavailable
        }
        let type = info.st_mode & mode_t(S_IFMT)
        let kind: FileKind
        if type == mode_t(S_IFREG) { kind = .file }
        else if type == mode_t(S_IFDIR) { kind = .directory }
        else { kind = .other }
        return Snapshot(
            kind: kind, size: Int64(info.st_size),
            mtime: Double(info.st_mtimespec.tv_sec) +
                Double(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            inode: UInt64(info.st_ino),
            device: UInt64(bitPattern: Int64(info.st_dev)),
            ctimeSeconds: Int64(info.st_ctimespec.tv_sec),
            ctimeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private func ensureSafeParents(_ item: URL, under root: URL, create: Bool, expectedVolume: VolumeFingerprint? = nil) throws {
        let parent = item.deletingLastPathComponent().standardizedFileURL
        guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else {
            throw MountedCopyError.unsafeFile
        }
        let rel = String(parent.path.dropFirst(root.path.count))
            .split(separator: "/")
        var current = root
        for component in rel {
            current.appendPathComponent(String(component))
            if let existing = try optionalSnapshot(current) {
                guard existing.kind == .directory else {
                    throw MountedCopyError.unsafeFile
                }
            } else if create {
                guard let expectedVolume else { throw MountedCopyError.invalidMapping }
                let parent = try AnchoredDirectory(current.deletingLastPathComponent(),expectedVolume:expectedVolume)
                try parent.ensureDirectory(current.lastPathComponent,shouldContinue:operationAllowed)
            } else {
                throw MountedCopyError.sourceMissing
            }
        }
    }

    private func createSafeDirectory(_ directory: URL, parent: URL, expectedVolume: VolumeFingerprint) throws {
        guard directory.deletingLastPathComponent().standardizedFileURL == parent else {
            throw MountedCopyError.unsafeFile
        }
        if let existing = try optionalSnapshot(directory) {
            guard existing.kind == .directory else {
                throw MountedCopyError.unsafeFile
            }
        } else {
            let anchor = try AnchoredDirectory(parent,expectedVolume:expectedVolume)
            try anchor.ensureDirectory(directory.lastPathComponent,managed:true,shouldContinue:operationAllowed)
        }
    }
}
