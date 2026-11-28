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
    case rcloneUnavailable
    case rcloneLaunchFailed
    case rcloneFailed(Int32)
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
        case .rcloneUnavailable: return "Helper di trasferimento non disponibile; operazione mantenuta in coda"
        case .rcloneLaunchFailed: return "Avvio del motore di trasferimento non riuscito; operazione mantenuta in coda"
        case .rcloneFailed(let code): return "Motore Rclone: codice uscita \(code); operazione mantenuta in coda"
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

    /// Read only the mount table; never mount a share or contact the network.
    /// The exact SMB mount source is used as a strict recovery identifier.
    public static func mountedVolumes() -> [VolumeFingerprint] {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, Int32(MNT_NOWAIT))
        guard count > 0, let entries else { return [] }
        return (0..<Int(count)).map { index in
            var entry = entries[index]
            return fingerprint(from: &entry)
        }
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
        try verificationURL(relativePath:relativePath,destination:destination,listingCache:nil)
    }

    // Internal overload used only by the read-only comparison phase.
    func verificationURL(relativePath: String, destination: Bool, listingCache: AuditDirectoryListingCache?) throws -> URL {
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
            let aliases: [String]
            if let listingCache {
                aliases = try listingCache.aliases(for:part,in:current)
            } else {
                let names = try FileManager.default.contentsOfDirectory(atPath:current.path)
                let key = WindowsPathSafety.comparisonFold(part)
                aliases = names.filter { WindowsPathSafety.comparisonFold($0) == key }
            }
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
    private let stageEngine: StageTransferEngine
    private let minimumStableAge: TimeInterval
    private let now: () -> Date
    private let availableCapacity: (URL) throws -> Int64?
    private var nextAfterID: Int64 = 0
    private var rectificationScopes: [String: [String]] = [:]
    private var pendingNameProtection = NameRectification.PendingProtection(relations: [])
    private var pendingLocalNamePaths:[String:Set<String>] = [:]
    private var transferDiagnostics: [String: DiagnosticTiming] = [:]
    private var lineageBindings: [String:[String:String]] = [:]

    private func recordDuration(_ action: String, since started: Double) {
        transferDiagnostics[action, default: DiagnosticTiming()].observe(ProcessInfo.processInfo.systemUptime - started)
    }
    private var publicationMethods: [String:ExclusivePublicationMethod] = [:]
    private var unsupportedNewPublicationRoots=Set<String>()
    private enum NewPublicationUnsupported: Error { case unavailable }
    public var onEvent: ((SyncCycleEvent) -> Void)?
    public var onJobStarted: ((QueuedChange) -> Void)?
    public var onPlan: ((Int) -> Void)?
    public var onPhase: ((String) -> Void)?
    public var onTransferProgress: ((Int64, Double) -> Void)?
    public var operationAllowed: () -> Bool = { true }
    private func emit(_ kind: SyncEventKind, job: QueuedChange, mapping: MountedFolderMapping?,
                      bytes: Int64? = nil, seconds: Double = 0, detail: String = "") {
        onEvent?(SyncCycleEvent(kind:kind,job:job,mapping:mapping,bytes:bytes,seconds:seconds,detail:detail))
    }

    // Internal fault injection for deterministic core tests, never configured
    // by the application or exposed to users.
    enum Checkpoint: Equatable { case beforeStageCopy, afterStageCopy, afterBackup, beforePublish, afterPublish, beforeBackupCleanup, beforeFailedStageCleanup }
    var checkpoint: ((Checkpoint, URL) throws -> Void)?

    public init(
        journal: ChangeJournal, log: SyncActivityLog,
        mappings: [MountedFolderMapping],
        minimumStableAge: TimeInterval = 20,
        now: @escaping () -> Date = Date.init,
        availableCapacity: @escaping (URL) throws -> Int64? = TransferPreflight.availableBytes,
        stageEngine: StageTransferEngine = .native
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
        self.stageEngine = stageEngine
    }

    public func runOnce(enabled: Bool = false, maxJobs: Int = 50,
                        shouldContinue: () -> Bool = { true }) throws -> MountedCopySummary {
        var summary = MountedCopySummary()
        guard enabled else {
            summary.disabled = true
            return summary
        }
        guard try prepareCycle() else { summary.interrupted = true; return summary }
        defer { flushTransferDiagnostics() }
        _ = try journal.retireExcludedJobs()
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
        guard try prepareCycle() else { summary.interrupted = true; return summary }
        defer { flushTransferDiagnostics() }
        _ = try journal.retireExcludedJobs()
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

    private func prepareCycle() throws -> Bool {
        guard try journal.queueRebuildToken() == nil else { return false }
        // Read the approved, durable plan; only its exact old/new paths and
        // dependent ancestors/descendants are held. All unrelated uploads
        // continue. Bad journal data throws and still stops the entire cycle.
        pendingNameProtection = try NameRectification.pendingProtection(journal: journal)
        pendingLocalNamePaths = Dictionary(grouping:try journal.pendingLocalNameRectifications(),by: \.rootID)
            .mapValues { Set($0.map(\.relativePath)) }
        rectificationScopes = try journal.nameRectificationScopes()
        transferDiagnostics = [:]
        lineageBindings = try journal.lineageCopyBindings(Array(mappings.values))
        return true
    }

    private func flushTransferDiagnostics() {
        guard stageEngine.isDirect, log.cycleID != nil else { return }
        for (action, timing) in transferDiagnostics.sorted(by: { $0.key < $1.key }) {
            try? log.record(level: .info, rootID: "app", action: action, durationSeconds: timing.totalSeconds,
                message: "Tempo cumulativo del ciclo")
            if DiagnosticCollectionLevel.current != .standard,let encoded=try? JSONEncoder().encode(timing) {
                try? log.record(level:.info,rootID:"app",action:DiagnosticTiming.prefix+action,
                    durationSeconds:timing.totalSeconds,message:String(decoding:encoded,as:UTF8.self))
            }
        }
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
            let jobTick=ProcessInfo.processInfo.systemUptime
            defer { recordDuration("metric_job_wall",since:jobTick) }
            onJobStarted?(job)
            guard let mapping = mappings[job.rootID] else {
                summary.failed += 1
                emit(.failed,job:job,mapping:nil,detail:"Coppia non configurata")
                continue
            }
            do {
                if pendingNameProtection.protects(rootID: job.rootID, path: job.relativePath) {
                    summary.deferred += 1
                    emit(.deferred, job: job, mapping: mapping,
                         detail: "Rettifica nomi pendente: percorso protetto, nessuna copia")
                    continue
                }
                let blockedNames=pendingLocalNamePaths[job.rootID] ?? []
                var prefix=""
                let blockedByName=job.relativePath.split(separator:"/").contains { part in
                    prefix=prefix.isEmpty ? String(part) : prefix+"/"+part
                    return blockedNames.contains(prefix)
                }
                if blockedByName || !WindowsPathSafety.validRelativePath(job.relativePath) {
                    summary.deferred += 1
                    emit(.deferred,job:job,mapping:mapping,detail:"Nome incompatibile: in attesa di rettifica locale")
                    if try journal.noteBlockedName(job) {
                        try? log.record(level:.warning,rootID:job.rootID,action:"name_blocked",relativePath:job.relativePath,message:"Nome incompatibile: operazione mantenuta in coda; nessuna copia tentata")
                    }
                    continue
                }
                if try journal.retryBlocked(job,now:now()) {
                    summary.deferred += 1
                    emit(.deferred,job:job,mapping:mapping,detail:"Riprova programmata dopo errore precedente")
                    if summary.deferred == 1 { try? log.record(level:.info,rootID:job.rootID,action:"retry_wait",relativePath:job.relativePath,message:"Attesa riprova; coda mantenuta") }
                    continue
                }
                guard try journal.uploadIsCurrent(job) else {
                    summary.deferred += 1
                    emit(.deferred,job:job,mapping:mapping,detail:"Evento non più corrente")
                    continue
                }
                // Only an interrupted publication pays the cost of a full
                // content comparison. Never infer completion from size alone.
                try journal.adoptRetiredPublication(job)
                let previousPublication = try journal.hasPublicationIntent(job)
                if !previousPublication,try reconcileSelectiveRestoration(job,mapping:mapping,shouldContinue:shouldContinue) {
                    summary.reconciled += 1
                    emit(.noChange,job:job,mapping:mapping,detail:"Ripristino nome verificato: nessuna nuova copia")
                    try? log.record(level:.success,rootID:job.rootID,action:"selective_restore_avoided",
                        relativePath:job.relativePath,message:"Identità e metadati verificati; nessuna lettura del contenuto")
                    continue
                }
                // Only hash an ordinary existing queued file if its size and
                // mtime look equal. A same-size/same-date edit still copies
                // if the actual bytes differ.
                let rectified = rectificationScopes[job.rootID]?.contains {
                    job.relativePath == $0 || job.relativePath.hasPrefix($0 + "/")
                } == true
                let mayAlreadyMatch = previousPublication || rectified || ((try? metadataMayMatch(job,mapping:mapping)) == true)
                let reconcileTick=ProcessInfo.processInfo.systemUptime
                let verifiedMatch:Int64?
                if mayAlreadyMatch {
                    defer { recordDuration("metric_job_reconciliation",since:reconcileTick) }
                    verifiedMatch=try reconcilePublished(job,mapping:mapping)
                } else { verifiedMatch=nil }
                if let verifiedBytes=verifiedMatch {
                    recoverConfirmedStage(job,mapping:mapping)
                    try? journal.clearRetry(job)
                    summary.reconciled += 1
                    let message=previousPublication ? "Pubblicazione precedente verificata SHA-256" : "File già corrispondente SHA-256"
                    emit(.noChange,job:job,mapping:mapping,detail:message)
                    try? log.record(level:.success,rootID:job.rootID,action:rectified ? "name_rectification_copy_avoided" : "reconciled",
                        relativePath:job.relativePath,bytes:rectified ? verifiedBytes : 0,message:message+"; nessuna nuova copia")
                    continue
                }
                let retryTick=ProcessInfo.processInfo.systemUptime
                do {
                    defer { recordDuration("metric_job_retry_preparation",since:retryTick) }
                    try prepareRetry(job,mapping:mapping,publicationUncertain:previousPublication)
                }
                let lineage = try journal.beginLineageTransfer(job,mapping:mapping,
                    bindings:lineageBindings[job.rootID] ?? [:])
                let outcome = try transfer(job, mapping: mapping)
                let acknowledgeStarted = ProcessInfo.processInfo.systemUptime
                let acknowledged = try journal.acknowledgeLineageTransfer(job,token:lineage)
                if stageEngine.isDirect { recordDuration("metric_queue_acknowledgment", since: acknowledgeStarted) }
                guard acknowledged else {
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
                try? journal.clearRetry(job)
                try? journal.clearTransferRecovery(job)
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
            } catch NewPublicationUnsupported.unavailable {
                summary.deferred += 1
                emit(.deferred,job:job,mapping:mapping,detail:"SMB: pubblicazione esclusiva indisponibile; nuovo file conservato in coda")
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
                switch error {
                case .rcloneFailed:
                    try journal.recordRetry(job,rootWide:false,reason:SyncDiagnostic.describe(error),now:now(),initial:30)
                case .unsafeFile,.destinationConflict:
                    try journal.recordRetry(job,rootWide:false,reason:SyncDiagnostic.describe(error),now:now(),initial:300)
                case .copyFailed(let code) where code == Int(ENOTSUP):
                    publicationMethods.removeValue(forKey:job.rootID)
                    try journal.recordRetry(job,rootWide:true,reason:SyncDiagnostic.describe(error),now:now(),initial:300)
                case .copyFailed(let code) where [Int(EACCES),Int(EPERM),Int(EBUSY),Int(EIO),Int(ENOSPC)].contains(code):
                    try journal.recordRetry(job,rootWide:false,reason:SyncDiagnostic.describe(error),now:now(),initial:30)
                default: break
                }
                // A lost mount or changed root is not a per-file failure.
                // Stop the cycle rather than attempting thousands of jobs
                // against the same unavailable destination.
                switch error {
                case .rcloneUnavailable, .rcloneLaunchFailed, .volumeChanged, .rootUnavailable, .sourceRootChanged:
                    summary.interrupted = true
                    return false
                case .rcloneFailed:
                    do { try mapping.verify() }
                    catch { summary.interrupted = true; return false }
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

    private func reconcileSelectiveRestoration(_ job:QueuedChange,mapping:MountedFolderMapping,
                                               shouldContinue:()->Bool)throws->Bool {
        guard try journal.selectiveRestoredCandidate(job,mapping:mapping) else { return false }
        try mapping.verify()
        let sourceBinding=try DirectoryBinding.encoded(mapping.source)
        let targetBinding=try DirectoryBinding.encoded(mapping.target)
        let src=try mapping.fileURL(relativePath:job.relativePath,destination:false)
        let dst=try mapping.fileURL(relativePath:job.relativePath,destination:true)
        do {
            try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.source)
            try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.target)
            try ensureSafeParents(src,under:mapping.source,create:false)
            try ensureSafeParents(dst,under:mapping.target,create:false)
            var local=stat(),remote=stat()
            guard src.resolvingSymlinksInPath().path==src.path,
                  src.path.withCString({lstat($0,&local)})==0,
                  dst.path.withCString({lstat($0,&remote)})==0,
                  let id=SourceNameLineage.Identity(stat:local) else { return false }
            let localKind=local.st_mode & mode_t(S_IFMT),remoteKind=remote.st_mode & mode_t(S_IFMT)
            guard localKind==remoteKind,localKind==mode_t(S_IFREG) || localKind==mode_t(S_IFDIR) else { return false }
            let first=SeedFileFingerprint(fileStat:local),other=SeedFileFingerprint(fileStat:remote)
            guard localKind==mode_t(S_IFDIR) || (first.size==other.size && abs(first.modifiedAt-other.modifiedAt)<=2) else { return false }
            try mapping.verify()
            guard try DirectoryBinding.encoded(mapping.source)==sourceBinding,
                  try DirectoryBinding.encoded(mapping.target)==targetBinding,
                  try SeededArchiveVerifier.fingerprint(dst,directory:localKind==mode_t(S_IFDIR))==other,
                  shouldContinue(),operationAllowed() else { return false }
            return try journal.acknowledgeSelectiveRestoration(job,mapping:mapping,sourceURL:src,
                sourceFingerprint:first,sourceIdentity:id,sourceBinding:sourceBinding,targetBinding:targetBinding,
                shouldContinue:{shouldContinue() && self.operationAllowed()})
        } catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
        catch {
            // Fall back to the existing protected transfer/reconciliation
            // path, never infer success from an unavailable target.
            try mapping.verify();return false
        }
    }

    private func metadataMayMatch(_ job:QueuedChange,mapping:MountedFolderMapping) throws -> Bool {
        try mapping.verify()
        let src=try mapping.fileURL(relativePath:job.relativePath,destination:false)
        let dst=try mapping.fileURL(relativePath:job.relativePath,destination:true)
        try ensureSafeParents(src,under:mapping.source,create:false)
        try ensureSafeParents(dst,under:mapping.target,create:false)
        guard let a=try optionalSnapshot(src), let b=try optionalSnapshot(dst),
              a.kind == .file, b.kind == .file, a.size == b.size else { return false }
        return abs(a.mtime-b.mtime)<=2
    }

    private func reconcilePublished(_ job: QueuedChange,mapping:MountedFolderMapping) throws -> Int64? {
        let token = SeedVerificationCancellation(shouldContinue:operationAllowed)
        let verifier = try SeededArchiveVerifier(journal:journal,mappings:[mapping])
        do {
            try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.source)
            try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.target)
            guard let match = try verifier.verifyOne(job,mapping:mapping,cancellation:token,onBytesRead:{_ in}) else { return nil }
            let report = SeedVerificationReport(matches:[match],inspected:1,missingOrDifferent:0,deferred:0,bytesRead:0)
            guard try verifier.approve(report:report,cancellation:token) == 1 else { return nil }
            try? journal.clearPublicationIntent(job)
            return match.verifiedBytes
        } catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
        catch { try mapping.verify(); return nil }
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

    private struct DirectRecoveryRecord: Codable {
        let root: DirectoryBinding
        let originalTarget: Snapshot?
    }
    private let directRecordPrefix = "rclone-direct-v1:"

    private func directRecovery(_ job: QueuedChange) throws -> DirectRecoveryRecord? {
        guard let record = try journal.transferRecovery(job), record.hasPrefix(directRecordPrefix) else { return nil }
        return try JSONDecoder().decode(DirectRecoveryRecord.self,from:Data(record.dropFirst(directRecordPrefix.count).utf8))
    }

    private struct RecoveryRecord: Codable {
        let name:String
        let root:DirectoryBinding
        let stageFolder:DirectoryBinding
        let stage:Snapshot
        let originalTarget:Snapshot?
        let source:Snapshot
    }

    private func recoveryRecord(_ job:QueuedChange) throws -> RecoveryRecord? {
        guard let json=try journal.transferRecovery(job) else { return nil }
        return try JSONDecoder().decode(RecoveryRecord.self,from:Data(json.utf8))
    }

    private func verifyRecovery(_ record:RecoveryRecord,mapping:MountedFolderMapping) throws -> URL {
        try mapping.verify()
        let folder=mapping.target.appendingPathComponent(".macsync-staging",isDirectory:true)
        guard record.name.hasSuffix(".partial"),
              UUID(uuidString:String(record.name.dropLast(8))) != nil,
              try DirectoryBinding.read(mapping.target)==record.root,
              try DirectoryBinding.read(folder)==record.stageFolder else { throw MountedCopyError.destinationChanging }
        return folder.appendingPathComponent(record.name)
    }

    private func discardVerifiedStage(_ record:RecoveryRecord,mapping:MountedFolderMapping,confirmedTarget:URL? = nil) throws {
        let url=try verifyRecovery(record,mapping:mapping)
        guard let actual=try optionalSnapshot(url) else { return }
        guard actual.kind == .file else { throw MountedCopyError.destinationChanging }
        if actual != record.stage {
            // A completed hard link changes ctime. Only remove the staging
            // name when it is still the same inode AND the already verified
            // definitive file is another link to that very object.
            guard let confirmedTarget, actual.device==record.stage.device,actual.inode==record.stage.inode,
                  actual.size==record.stage.size,actual.mtime==record.stage.mtime,
                  try readSnapshot(confirmedTarget)==actual else { throw MountedCopyError.destinationChanging }
        }
        let anchor=try AnchoredDirectory(url.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
        let s=try anchor.leaf(record.name)
        guard UInt64(s.st_ino)==actual.inode,Int64(s.st_size)==actual.size,
              Int64(s.st_ctimespec.tv_sec)==actual.ctimeSeconds,
              Int64(s.st_ctimespec.tv_nsec)==actual.ctimeNanoseconds,
              try readSnapshot(url)==actual else { throw MountedCopyError.destinationChanging }
        if actual != record.stage {
            guard let confirmedTarget, s.st_nlink>=2,
                  try readSnapshot(confirmedTarget)==actual else { throw MountedCopyError.destinationChanging }
        }
        try anchor.remove(record.name,matching:s,shouldContinue:operationAllowed)
    }

    private func recoverConfirmedStage(_ job:QueuedChange,mapping:MountedFolderMapping) {
        do {
            if try directRecovery(job) != nil { try journal.clearTransferRecovery(job); return }
            guard let record=try recoveryRecord(job) else { return }
            let dst=try mapping.fileURL(relativePath:job.relativePath,destination:true)
            try ensureSafeParents(dst,under:mapping.target,create:false)
            try discardVerifiedStage(record,mapping:mapping,confirmedTarget:dst)
            try journal.clearTransferRecovery(job)
        } catch {
            try? log.record(level:.warning,rootID:job.rootID,action:"staging_retained",relativePath:job.relativePath,message:"Temporaneo di recupero non verificabile; conservato")
        }
    }

    private func prepareRetry(_ job:QueuedChange,mapping:MountedFolderMapping,publicationUncertain:Bool) throws {
        if let direct = try directRecovery(job) {
            try mapping.verify()
            let dst = try mapping.fileURL(relativePath:job.relativePath,destination:true)
            guard try DirectoryBinding.read(mapping.target) == direct.root,
                  try optionalSnapshot(dst) == direct.originalTarget else { throw MountedCopyError.destinationChanging }
            // The old destination is still intact. A new attempt is safe.
            try journal.clearPublicationIntent(job)
            try journal.clearTransferRecovery(job)
            return
        }
        guard let record=try recoveryRecord(job) else {
            // Old builds did not record the previous target. Never overwrite
            // a newly arrived destination in an ambiguous legacy attempt.
            if publicationUncertain {
                let dst=try mapping.fileURL(relativePath:job.relativePath,destination:true)
                try ensureSafeParents(dst,under:mapping.target,create:false)
                guard try optionalSnapshot(dst)==nil else { throw MountedCopyError.destinationChanging }
            }
            return
        }
        _ = try verifyRecovery(record,mapping:mapping)
        let dst=try mapping.fileURL(relativePath:job.relativePath,destination:true)
        try ensureSafeParents(dst,under:mapping.target,create:false)
        let src=try mapping.fileURL(relativePath:job.relativePath,destination:false)
        try ensureSafeParents(src,under:mapping.source,create:false)
        let currentSource=try readSnapshot(src)
        guard currentSource.kind == .file else { throw MountedCopyError.sourceMissing }
        if publicationUncertain {
            let current=try optionalSnapshot(dst)
            // Permit retry ONLY against the same old target (or its still
            // absent name). If the completed publication is ours, allow the
            // ordinary byte comparison / update of that same object, never
            // an independently created file. The source must still exist.
            if current != record.originalTarget {
                guard let current, current.kind == .file,
                      current.device==record.stage.device,current.inode==record.stage.inode,
                      current.size==record.stage.size,current.mtime==record.stage.mtime,
                      currentSource==record.source else {
                    throw MountedCopyError.destinationChanging
                }
                // An inode match alone is not evidence that the bytes are
                // ours: another writer can preserve length and mtime.
                try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.source)
                try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.target)
                let token=SeedVerificationCancellation(shouldContinue:operationAllowed)
                let verifier=try SeededArchiveVerifier(journal:journal,mappings:[mapping])
                guard try verifier.verifyOne(job,mapping:mapping,cancellation:token,onBytesRead:{_ in}) != nil,
                      try readSnapshot(src)==currentSource,try optionalSnapshot(dst)==current else {
                    throw MountedCopyError.destinationChanging
                }
            }
        }
        try discardVerifiedStage(record,mapping:mapping)
        try journal.clearTransferRecovery(job)
        try journal.clearPublicationIntent(job)
    }

    private func recordRcloneDiagnostic(_ level:SyncLogLevel,_ message:String,job:QueuedChange) {
        try? log.record(level:level,rootID:job.rootID,action:"rclone_diagnostic",relativePath:job.relativePath,message:message)
    }

    private func transferDirect(_ job: QueuedChange, mapping: MountedFolderMapping) throws -> TransferOutcome {
        let checksStarted = ProcessInfo.processInfo.systemUptime
        guard operationAllowed() else { throw SeedVerificationError.cancelled }
        try mapping.verify()
        let src = try mapping.fileURL(relativePath:job.relativePath,destination:false)
        let dst = try mapping.fileURL(relativePath:job.relativePath,destination:true)
        try ensureSafeParents(src,under:mapping.source,create:false)
        try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.source)
        try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.target)
        let source = try readSnapshot(src)
        guard source.kind == .file || source.kind == .directory else { throw MountedCopyError.unsafeFile }
        try validateExistingParents(dst, under:mapping.target)
        let original = try optionalSnapshot(dst)
        guard original == nil || original?.kind == source.kind else { throw MountedCopyError.destinationConflict }
        if source.kind == .file {
            guard now().timeIntervalSince1970-source.mtime >= minimumStableAge else { throw MountedCopyError.sourceChanging }
            try TransferPreflight.requireCapacity(available:try availableCapacity(mapping.target),incoming:source.size,existing:0)
        }
        try mapping.verify()
        guard try journal.uploadIsCurrent(job), try readSnapshot(src)==source,
              try optionalSnapshot(dst)==original else { throw MountedCopyError.sourceChanging }
        guard operationAllowed() else { throw SeedVerificationError.cancelled }
        if source.kind == .directory {
            if original == nil {
                try? log.record(level:.info,rootID:job.rootID,action:"rclone_mkdir",relativePath:job.relativePath,message:"Rclone: creazione cartella")
                let mkdirTick=ProcessInfo.processInfo.systemUptime
                defer { recordDuration("metric_rclone_mkdir",since:mkdirTick) }
                try stageEngine.pathOperation("mkdir",url:dst,shouldContinue:operationAllowed,diagnostic:{ self.recordRcloneDiagnostic($0,$1,job:job) })
            }
            try mapping.verify()
            try ensureSafeParents(dst,under:mapping.target,create:false)
            guard try readSnapshot(dst).kind == .directory, try readSnapshot(src)==source else { throw MountedCopyError.destinationChanging }
            return TransferOutcome(bytes:0,kind:original == nil ? .directoryCreated : .directoryExisting)
        }
        let recovery = DirectRecoveryRecord(root:try DirectoryBinding.read(mapping.target),originalTarget:original)
        try journal.saveTransferRecovery(job,record:directRecordPrefix+String(decoding:try JSONEncoder().encode(recovery),as:UTF8.self))
        try journal.recordPublicationIntent(job)
        try mapping.verify()
        try validateExistingParents(dst,under:mapping.target)
        guard try journal.uploadIsCurrent(job),try readSnapshot(src)==source,try optionalSnapshot(dst)==original else { throw MountedCopyError.destinationChanging }
        try log.record(level:.info,rootID:job.rootID,action:"rclone_start",relativePath:job.relativePath,bytes:source.size,message:"Rclone copyto: pubblicazione diretta con temporaneo nativo")
        onPhase?("Trasferimento")
        let started = ProcessInfo.processInfo.systemUptime
        recordDuration("metric_copy_preflight", since: checksStarted)
        do {
        defer { recordDuration("metric_rclone_total_process", since: started) }
        try stageEngine.copyDirect(source:src,destination:dst,newFile:original == nil,shouldContinue:operationAllowed,
            diagnostic:{ self.recordRcloneDiagnostic($0,$1,job:job) },
            launched:{ self.recordDuration("metric_rclone_process_launch", since: started) },
            progress:{ [weak self] bytes, seconds in self?.onTransferProgress?(bytes,seconds) })
        }
        let verification = ProcessInfo.processInfo.systemUptime
        defer { recordDuration("metric_copy_postflight", since: verification) }
        onPhase?("Verifica del trasferimento")
        try mapping.verify()
        try ensureSafeParents(dst,under:mapping.target,create:false)
        let published = try readSnapshot(dst)
        guard published.kind == .file, published.size == source.size,try readSnapshot(src)==source else { throw MountedCopyError.sourceChanging }
        emit(.stageCopy,job:job,mapping:mapping,bytes:source.size,seconds:ProcessInfo.processInfo.systemUptime-started)
        return TransferOutcome(bytes:source.size,kind:original == nil ? .created : .updated)
    }

    private func validateExistingParents(_ item: URL, under root: URL) throws {
        let parent = item.deletingLastPathComponent().standardizedFileURL
        guard parent.path == root.path || parent.path.hasPrefix(root.path+"/") else { throw MountedCopyError.unsafeFile }
        var current = root
        for component in parent.path.dropFirst(root.path.count).split(separator:"/") {
            current.appendPathComponent(String(component))
            guard let existing = try optionalSnapshot(current) else { return }
            guard existing.kind == .directory else { throw MountedCopyError.unsafeFile }
        }
    }

    private func transfer(_ job: QueuedChange, mapping: MountedFolderMapping) throws -> TransferOutcome {
        if stageEngine.isDirect { return try transferDirect(job,mapping:mapping) }
        guard operationAllowed() else { throw SeedVerificationError.cancelled }
        try mapping.verify()
        let targetIdentity = try CopyDirectoryIdentity.read(mapping.target)
        func verifyRoots() throws {
            // mapping.verify already compares the immutable target identity,
            // source identity and mounted volume. Avoid a duplicate SMB stat.
            try mapping.verify()
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
        if originalTarget == nil && unsupportedNewPublicationRoots.contains(job.rootID) {
            throw NewPublicationUnsupported.unavailable
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
        var method: ExclusivePublicationMethod?
        if originalTarget == nil && mapping.targetVolume.fileSystem.lowercased()=="smbfs" {
            guard !unsupportedNewPublicationRoots.contains(job.rootID) else { throw NewPublicationUnsupported.unavailable }
            if let cached=publicationMethods[job.rootID] { method=cached }
            else {
                let probe=try AnchoredDirectory(stageFolder,expectedVolume:mapping.targetVolume)
                do {
                    let selected=try probe.probeExclusivePublication(shouldContinue:operationAllowed,onDiagnostic:{ message in
                        try? self.log.record(level:.info,rootID:job.rootID,action:"smb_probe_step",message:message)
                    })
                    publicationMethods[job.rootID]=selected
                    method=selected
                    try? log.record(level:.info,rootID:job.rootID,action:"smb_probe",message:"Metodo esclusivo verificato in staging: "+selected.rawValue)
                } catch MountedCopyError.copyFailed(let code) where [Int(ENOTSUP),Int(ENOSYS),Int(EINVAL)].contains(code) {
                    try verifyRoots()
                    unsupportedNewPublicationRoots.insert(job.rootID)
                    try? log.record(level:.warning,rootID:job.rootID,action:"smb_probe_blocked",message:"Pubblicazione esclusiva non disponibile (POSIX \(code)); nessuna copia diretta, nuovi file in coda")
                    throw NewPublicationUnsupported.unavailable
                } catch MountedCopyError.destinationChanging {
                    try verifyRoots()
                    unsupportedNewPublicationRoots.insert(job.rootID)
                    try? log.record(level:.warning,rootID:job.rootID,action:"smb_probe_blocked",message:"Identità o contenuto dei file di prova incerti; nessun nuovo tentativo nel ciclo")
                    throw NewPublicationUnsupported.unavailable
                }
            }
        }
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
            do {
                try stageEngine.copy(source:src, staging:staging, shouldContinue:operationAllowed,
                                     progress:{ [weak self] bytes, seconds in self?.onTransferProgress?(bytes, seconds) })
            }
            catch {
                try? log.record(level:.warning,rootID:job.rootID,action:"stage_copy_failed",relativePath:job.relativePath,message:SyncDiagnostic.describe(error))
                throw error
            }
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
                try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.source)
                try WindowsPathSafety.checkNames(relativePath:job.relativePath,under:mapping.target)
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
            let recovery=RecoveryRecord(name:staging.lastPathComponent,root:try DirectoryBinding.read(mapping.target),
                stageFolder:try DirectoryBinding.read(stageFolder),stage:staged,originalTarget:originalTarget,source:snapshot)
            try journal.saveTransferRecovery(job,record:String(decoding:try JSONEncoder().encode(recovery),as:UTF8.self))
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
                try checkpoint?(.beforePublish, staging)
                try verifyPublication()
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
                try checkpoint?(.beforePublish, staging)
                try verifyPublication()
                try stageAnchor.publish(staging.lastPathComponent,matching:stagedStat,to:destAnchor,
                    as:dst.lastPathComponent,replacing:nil,shouldContinue:operationAllowed,preferredMethod:method,onMethod: { method in
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
                        try? journal.clearTransferRecovery(job)
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

    private enum FileKind: String, Codable { case file, directory, other }
    private struct Snapshot: Codable, Equatable {
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
