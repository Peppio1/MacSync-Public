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
        }
    }
}

public struct VolumeFingerprint: Equatable, Codable, Sendable {
    public let fileSystem: String
    public let mountPath: String

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
        return VolumeFingerprint(fileSystem: fs, mountPath: mount)
    }

    public var isNetworkVolume: Bool {
        let fs = fileSystem.lowercased()
        return fs == "smbfs" || fs == "webdav" || fs == "nfs"
    }
}

/// Each selected target is used as-is. The prototype requires an explicit
/// per-session opt-in, and it NEVER performs remote deletions.
public struct MountedFolderMapping: Sendable {
    public let rootID: String
    public let source: URL
    public let target: URL
    public let targetVolume: VolumeFingerprint

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
    }

    public func verify() throws {
        guard FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: target.path) else {
            throw MountedCopyError.rootUnavailable
        }
        let current = try VolumeFingerprint.read(at: target)
        guard current == targetVolume else { throw MountedCopyError.volumeChanged }
    }

    public func fileURL(relativePath: String, destination: Bool) throws -> URL {
        let root = destination ? target : source
        let comps = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !comps.isEmpty,
              comps.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0")
              }) else { throw MountedCopyError.unsafeFile }
        return root.appendingPathComponent(relativePath)
    }
}

public struct MountedCopySummary: Equatable {
    public var copied = 0
    public var deferred = 0
    public var failed = 0
    public var bytes: Int64 = 0
    public var disabled = false
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

    public func runOnce(enabled: Bool = false, maxJobs: Int = 50) throws -> MountedCopySummary {
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
        for job in jobs {
            nextAfterID = job.id
            let started = Date()
            guard let mapping = mappings[job.rootID] else {
                summary.failed += 1
                continue
            }
            do {
                let bytes = try transfer(job, mapping: mapping)
                try journal.markCompleted(id: job.id)
                summary.copied += 1
                summary.bytes += bytes
                try log.record(
                    level: .success, rootID: job.rootID, action: "copy",
                    relativePath: job.relativePath, bytes: bytes,
                    durationSeconds: Date().timeIntervalSince(started),
                    message: "Trasferimento completato"
                )
            } catch let error as MountedCopyError {
                switch error {
                case .sourceChanging, .sourceMissing, .volumeChanged,
                     .rootUnavailable, .insufficientSpace:
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
        return summary
    }

    private func transfer(_ job: QueuedChange, mapping: MountedFolderMapping) throws -> Int64 {
        try mapping.verify()
        let src = try mapping.fileURL(relativePath: job.relativePath, destination: false)
        let dst = try mapping.fileURL(relativePath: job.relativePath, destination: true)
        try ensureSafeParents(src, under: mapping.source, create: false)
        let snapshot = try readSnapshot(src)
        guard snapshot.kind == .directory || snapshot.kind == .file else {
            throw MountedCopyError.unsafeFile
        }

        if snapshot.kind == .directory {
            try ensureSafeParents(dst, under: mapping.target, create: true)
            if fm.fileExists(atPath: dst.path) {
                let existing = try readSnapshot(dst)
                guard existing.kind == .directory else { throw MountedCopyError.destinationConflict }
            } else {
                try fm.createDirectory(at: dst, withIntermediateDirectories: false)
            }
            try mapping.verify()
            return 0
        }

        guard now().timeIntervalSince1970 - snapshot.mtime >= minimumStableAge else {
            throw MountedCopyError.sourceChanging
        }
        try ensureSafeParents(dst, under: mapping.target, create: true)
        // Check capacity before creating staging or safety backups. An
        // overwrite temporarily needs space for both old and new copies.
        var existingBytes: Int64 = 0
        if fm.fileExists(atPath: dst.path) {
            let targetSnapshot = try readSnapshot(dst)
            guard targetSnapshot.kind == .file else { throw MountedCopyError.destinationConflict }
            existingBytes = targetSnapshot.size
        }
        try TransferPreflight.requireCapacity(
            available: try availableCapacity(mapping.target),
            incoming: snapshot.size, existing: existingBytes
        )
        let stageFolder = mapping.target.appendingPathComponent(".macsync-staging", isDirectory: true)
        try createSafeDirectory(stageFolder, parent: mapping.target)
        let staging = stageFolder.appendingPathComponent(UUID().uuidString + ".partial")
        try log.record(
            level: .info, rootID: job.rootID, action: "start",
            relativePath: job.relativePath, bytes: snapshot.size,
            message: "Inizio copia in staging"
        )
        // FileManager.copyItem streams data without buffering full PSD/DNG in
        // app RAM. Failure leaves journal pending and may leave a .partial file.
        do {
            try fm.copyItem(at: src, to: staging)
            // Inspect the transferred staging file before publication.
            let staged = try readSnapshot(staging)
            guard staged.kind == .file, staged.size == snapshot.size else {
                throw MountedCopyError.stagingIncomplete
            }
            guard try readSnapshot(src) == snapshot else {
                throw MountedCopyError.sourceChanging
            }
            try mapping.verify()
            if fm.fileExists(atPath: dst.path) {
                // Explicitly preserve the prior target BEFORE any overwrite.
                // Foundation.replaceItemAt's backupItemName is not dependable
                // across every filesystem; copy to a unique backup path first.
                // This preview never purges backups or staging objects.
                let existing = try readSnapshot(dst)
                guard existing.kind == .file else { throw MountedCopyError.destinationConflict }
                let backupURL = dst.deletingLastPathComponent()
                    .appendingPathComponent(".macsync-backup-" + UUID().uuidString)
                try fm.copyItem(at: dst, to: backupURL)
                // The old content remains in the backup even if publishing fails.
                _ = try fm.replaceItemAt(dst, withItemAt: staging,
                                         backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: staging, to: dst)
            }
            guard try readSnapshot(src) == snapshot else {
                throw MountedCopyError.sourceChanging
            }
            return snapshot.size
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
    }

    private func readSnapshot(_ url: URL) throws -> Snapshot {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            throw MountedCopyError.sourceMissing
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
            inode: UInt64(info.st_ino)
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
            if fm.fileExists(atPath: current.path) {
                guard try readSnapshot(current).kind == .directory else {
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
        if fm.fileExists(atPath: directory.path) {
            guard try readSnapshot(directory).kind == .directory else {
                throw MountedCopyError.unsafeFile
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }
}
