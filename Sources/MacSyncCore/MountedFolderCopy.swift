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
        _ = try CopyDirectoryIdentity.read(dst)
    }

    public func verify() throws {
        guard FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: target.path) else {
            throw MountedCopyError.rootUnavailable
        }
        guard try CopyDirectoryIdentity.read(source) == sourceIdentity else {
            throw MountedCopyError.sourceRootChanged
        }
        _ = try CopyDirectoryIdentity.read(target)
        let current = try VolumeFingerprint.read(at: target)
        guard current == targetVolume else { throw MountedCopyError.volumeChanged }
    }

    public func fileURL(relativePath: String, destination: Bool) throws -> URL {
        let root = destination ? target : source
        let comps = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !comps.isEmpty,
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

    // Internal fault injection for deterministic core tests, never configured
    // by the application or exposed to users.
    enum Checkpoint: Equatable { case beforeStageCopy, afterStageCopy, afterBackup, afterPublish }
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
                         shouldContinue: () -> Bool = { true },
                         onProgress: (MountedCopySummary) -> Void = { _ in }) throws -> MountedCopySummary {
        var summary = MountedCopySummary()
        guard enabled else {
            summary.disabled = true
            return summary
        }
        guard let upper = try journal.pendingUploadUpperBound() else { return summary }
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
            guard shouldContinue() else {
                summary.interrupted = true
                return false
            }
            nextAfterID = job.id
            let started = Date()
            guard let mapping = mappings[job.rootID] else {
                summary.failed += 1
                continue
            }
            do {
                guard try journal.uploadIsCurrent(job) else {
                    summary.deferred += 1
                    continue
                }
                let outcome = try transfer(job, mapping: mapping)
                try journal.markCompleted(id: job.id)
                summary.copied += 1
                let (totalBytes, overflow) = summary.bytes.addingReportingOverflow(outcome.bytes)
                summary.bytes = overflow ? Int64.max : totalBytes
                switch outcome.kind {
                case .created: summary.created += 1
                case .updated: summary.updated += 1
                case .directoryCreated: summary.directoriesCreated += 1
                case .directoryExisting: break
                }
                let detail: String
                switch outcome.kind {
                case .created: detail = "Nuovo file copiato"
                case .updated: detail = "File aggiornato"
                case .directoryCreated: detail = "Cartella creata"
                case .directoryExisting: detail = "Cartella già presente"
                }
                try log.record(
                    level: .success, rootID: job.rootID, action: "copy",
                    relativePath: job.relativePath, bytes: outcome.bytes,
                    durationSeconds: Date().timeIntervalSince(started),
                    message: detail
                )
            } catch let error as MountedCopyError {
                switch error {
                case .sourceChanging, .sourceMissing, .volumeChanged,
                     .rootUnavailable, .insufficientSpace, .destinationChanging,
                     .sourceRootChanged:
                    summary.deferred += 1
                default:
                    summary.failed += 1
                }
                try log.record(
                    level: .warning, rootID: job.rootID, action: "retry",
                    relativePath: job.relativePath,
                    durationSeconds: Date().timeIntervalSince(started),
                    message: error.localizedDescription
                )
                // A lost mount or changed root is not a per-file failure.
                // Stop the cycle rather than attempting thousands of jobs
                // against the same unavailable destination.
                switch error {
                case .volumeChanged, .rootUnavailable, .sourceRootChanged:
                    summary.interrupted = true
                    return false
                case .copyFailed:
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
                try log.record(
                    level: .error, rootID: job.rootID, action: "retry",
                    relativePath: job.relativePath,
                    durationSeconds: Date().timeIntervalSince(started),
                    message: "Errore trasferimento; operazione conservata in coda"
                )
            }
        }
        return true
    }

    private enum TransferKind { case created, updated, directoryCreated, directoryExisting }
    private struct TransferOutcome {
        let bytes: Int64
        let kind: TransferKind
    }

    private func transfer(_ job: QueuedChange, mapping: MountedFolderMapping) throws -> TransferOutcome {
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
        let snapshot = try readSnapshot(src)
        guard snapshot.kind == .directory || snapshot.kind == .file else {
            throw MountedCopyError.unsafeFile
        }

        if snapshot.kind == .directory {
            try verifyRoots()
            try ensureSafeParents(dst, under: mapping.target, create: true)
            try verifyRoots()
            guard try journal.uploadIsCurrent(job) else { throw MountedCopyError.sourceChanging }
            let alreadyPresent = try optionalSnapshot(dst) != nil
            if alreadyPresent {
                let existing = try readSnapshot(dst)
                guard existing.kind == .directory else { throw MountedCopyError.destinationConflict }
            } else {
                try fm.createDirectory(at: dst, withIntermediateDirectories: false)
            }
            try verifyRoots()
            return TransferOutcome(bytes: 0,
                kind: alreadyPresent ? .directoryExisting : .directoryCreated)
        }

        guard now().timeIntervalSince1970 - snapshot.mtime >= minimumStableAge else {
            throw MountedCopyError.sourceChanging
        }
        try verifyRoots()
        try ensureSafeParents(dst, under: mapping.target, create: true)
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
        try createSafeDirectory(stageFolder, parent: mapping.target)
        let stageIdentity = try CopyDirectoryIdentity.read(stageFolder)
        let staging = stageFolder.appendingPathComponent(UUID().uuidString + ".partial")
        try log.record(
            level: .info, rootID: job.rootID, action: "start",
            relativePath: job.relativePath, bytes: snapshot.size,
            message: "Inizio copia in staging"
        )
        // FileManager.copyItem streams data without buffering full PSD/DNG in
        // app RAM. Failure leaves journal pending and may leave a .partial file.
        do {
            try checkpoint?(.beforeStageCopy, staging)
            try verifyRoots()
            try fm.copyItem(at: src, to: staging)
            try checkpoint?(.afterStageCopy, staging)
            try verifyRoots()
            guard try CopyDirectoryIdentity.read(stageFolder) == stageIdentity else {
                throw MountedCopyError.unsafeFile
            }
            // Inspect the transferred staging file before publication.
            let staged = try readSnapshot(staging)
            guard staged.kind == .file, staged.size == snapshot.size else {
                throw MountedCopyError.stagingIncomplete
            }
            guard try readSnapshot(src) == snapshot else {
                throw MountedCopyError.sourceChanging
            }
            func verifyPublication() throws {
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
            if let originalTarget {
                // Preserve the exact previous target before publishing. If
                // another client modifies it during backup, do not overwrite.
                let backupURL = dst.deletingLastPathComponent()
                    .appendingPathComponent(".macsync-backup-" + UUID().uuidString)
                try fm.copyItem(at: dst, to: backupURL)
                try checkpoint?(.afterBackup, backupURL)
                try verifyPublication()
                let backup = try readSnapshot(backupURL)
                guard backup.kind == .file, backup.size == originalTarget.size else {
                    throw MountedCopyError.stagingIncomplete
                }
                _ = try fm.replaceItemAt(dst, withItemAt: staging,
                                         backupItemName: nil, options: [])
            } else {
                // moveItem refuses an existing target; never overwrite a
                // newly arrived file after an initially absent destination.
                try fm.moveItem(at: staging, to: dst)
            }
            try checkpoint?(.afterPublish, dst)
            try verifyRoots()
            try ensureSafeParents(dst, under: mapping.target, create: false)
            let published = try readSnapshot(dst)
            guard published.kind == .file, published.size == snapshot.size else {
                throw MountedCopyError.stagingIncomplete
            }
            guard try readSnapshot(src) == snapshot else {
                throw MountedCopyError.sourceChanging
            }
            return TransferOutcome(bytes: snapshot.size,
                kind: targetExisted ? .updated : .created)
        } catch {
            // NEVER delete anything in the shared destination on failure;
            // interrupted stage objects remain for future safe GC.
            if let m = error as? MountedCopyError { throw m }
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

    private func ensureSafeParents(_ item: URL, under root: URL, create: Bool) throws {
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
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            } else {
                throw MountedCopyError.sourceMissing
            }
        }
    }

    private func createSafeDirectory(_ directory: URL, parent: URL) throws {
        guard directory.deletingLastPathComponent().standardizedFileURL == parent else {
            throw MountedCopyError.unsafeFile
        }
        if let existing = try optionalSnapshot(directory) {
            guard existing.kind == .directory else {
                throw MountedCopyError.unsafeFile
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }
}
