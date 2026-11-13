import Foundation
import Darwin

/// MacSync uses rclone's SMB backend as a CLIENT. Nothing runs on Windows.
/// IMPORTANT: rclone copyto is called with a *single local file* as source.
/// A directory source would make copyto recurse, which this worker forbids.
public struct SMBUploadMapping: Equatable {
    public let rootID: String
    public let localRoot: URL
    public let remoteRoot: String

    public init(rootID: String, localRoot: URL, remoteRoot: String) throws {
        guard !rootID.isEmpty else { throw UploadError.invalidMapping("Empty root identifier") }
        let local = localRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard local.isFileURL else { throw UploadError.invalidMapping("Source must be a local directory") }
        try Self.validateRemote(remoteRoot)
        self.rootID = rootID
        self.localRoot = local
        self.remoteRoot = remoteRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The first component after the colon MUST be the SMB share name.
    /// Example: macsync_smb:Condivisione_SMB/Cartella_1
    private static func validateRemote(_ remote: String) throws {
        let segments = remote.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.count == 2,
              let name = segments.first, !name.isEmpty,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              let part = segments.last, !part.isEmpty,
              !part.hasPrefix("/"), !part.contains("\\"),
              !part.contains("\n"), !part.contains("\r"), !part.contains("\0") else {
            throw UploadError.invalidMapping("Expected remote:share/subfolder (no credentials)")
        }
        let path = part.split(separator: "/", omittingEmptySubsequences: false)
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw UploadError.invalidMapping("Unsafe SMB destination path")
        }
    }

    public func destination(for relativePath: String) throws -> String {
        // Remote SMB targets Windows Server; prevent filesystem ambiguity and
        // rclone command-line traversal. Spaces and unicode remain supported.
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0") &&
                  !$0.contains("*") && !$0.contains("?") &&
                  !$0.contains("\"") && !$0.contains("<") &&
                  !$0.contains(">") && !$0.contains("|") }) else {
            throw UploadError.unsafePath
        }
        return remoteRoot + "/" + relativePath
    }
}

public enum UploadError: Error, Equatable, LocalizedError {
    case invalidMapping(String)
    case unsafePath
    case sourceNotAvailable
    case sourceChanged
    case unsupportedSource
    case noRcloneBinary
    case commandFailed(Int32)
    case commandTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidMapping(let text): return text
        case .unsafePath: return "Invalid destination-relative path"
        case .sourceNotAvailable: return "Source is missing or unavailable; upload paused"
        case .sourceChanged: return "Source is still changing; retry later"
        case .unsupportedSource: return "Symlink or unsupported source entry; upload refused"
        case .noRcloneBinary: return "rclone executable missing"
        case .commandFailed(let code): return "rclone exited unsuccessfully (code \(code))"
        case .commandTimedOut: return "rclone did not complete before the timeout"
        }
    }
}

public protocol RcloneCommandExecuting {
    func run(arguments: [String], timeout: TimeInterval) throws
}

/// No shell involved; credentials are never included in command arguments.
/// Configure a *local* SMB remote with rclone config on the Mac; keep its
/// credentials outside the project/repository. Keychain UI is a later phase.
public final class ProcessRcloneExecutor: RcloneCommandExecuting {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public func run(arguments: [String], timeout: TimeInterval) throws {
        let path = executable.standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw UploadError.noRcloneBinary
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice // Never leak SMB data/paths
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + max(1, timeout)) == .timedOut {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 4) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 4)
                }
            }
            throw UploadError.commandTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw UploadError.commandFailed(process.terminationStatus)
        }
    }
}

public struct UploadBatchResult: Equatable {
    public var succeeded = 0
    public var deferred = 0
    public var failed = 0
    public var ignoredDeletes = 0
    public var disabled = false

    public init() {}
}

/// Explicit opt-in and copy-only policy. No delete or move command exists.
/// Serialize this worker per DB. The database acknowledges a queue row ONLY
/// after the rclone command returns success and the source snapshot is stable.
public final class SelectiveSMBCopyWorker {
    private let journal: ChangeJournal
    private let runner: RcloneCommandExecuting
    private let mappings: [String: SMBUploadMapping]
    private let minimumStableAge: TimeInterval
    private let now: () -> Date

    public init(
        journal: ChangeJournal,
        runner: RcloneCommandExecuting,
        mappings: [SMBUploadMapping],
        minimumStableAge: TimeInterval = 20,
        now: @escaping () -> Date = Date.init
    ) throws {
        guard !mappings.isEmpty,
              Dictionary(grouping: mappings, by: \.rootID).allSatisfy({ $0.value.count == 1 }) else {
            throw UploadError.invalidMapping("Missing or duplicate source mappings")
        }
        self.journal = journal
        self.runner = runner
        self.mappings = Dictionary(uniqueKeysWithValues: mappings.map { ($0.rootID, $0) })
        self.minimumStableAge = max(0, minimumStableAge)
        self.now = now
    }

    /// This is an opt-in worker: callers must explicitly enable writes.
    /// Pending delete jobs are NEVER executed or acknowledged.
    public func runOnce(enabled: Bool = false, maxJobs: Int = 25) throws -> UploadBatchResult {
        var summary = UploadBatchResult()
        guard enabled else {
            summary.disabled = true
            return summary
        }
        let pending = try journal.pendingUploads(limit: maxJobs)
        for job in pending {
            guard let mapping = mappings[job.rootID] else {
                summary.failed += 1
                continue
            }
            do {
                try transfer(job, via: mapping)
                try journal.markCompleted(id: job.id)
                summary.succeeded += 1
            } catch UploadError.sourceChanged {
                summary.deferred += 1
            } catch UploadError.sourceNotAvailable {
                summary.deferred += 1
            } catch {
                // Leave the pending job intact for retry. There is deliberately
                // no remote DELETE fallback, even if the local path vanished.
                summary.failed += 1
            }
        }
        return summary
    }

    private func transfer(_ job: QueuedChange, via mapping: SMBUploadMapping) throws {
        let destination = try mapping.destination(for: job.relativePath)
        let root = mapping.localRoot
        let rootAttributes = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootAttributes?.isDirectory == true,
              rootAttributes?.isSymbolicLink != true else {
            throw UploadError.sourceNotAvailable
        }

        let source = root.appendingPathComponent(job.relativePath)
        let actual = source.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(source.lastPathComponent).standardizedFileURL
        guard actual.path.hasPrefix(root.path + "/") else { throw UploadError.unsafePath }

        let snapshot = try attributes(of: actual)
        if snapshot.isDirectory {
            // mkdir targets the SINGLE configured folder; no recursive scan.
            try runner.run(arguments: ["mkdir", destination, "--retries", "1", "--quiet"], timeout: 300)
            return
        }
        guard snapshot.isFile else { throw UploadError.unsupportedSource }
        guard now().timeIntervalSince1970 - snapshot.mtime >= minimumStableAge else {
            throw UploadError.sourceChanged
        }

        try runner.run(
            arguments: [
                "copyto", actual.path, destination,
                "--retries", "1", "--low-level-retries", "1",
                "--stats", "0", "--quiet"
            ],
            timeout: 7_200
        )
        guard try attributes(of: actual) == snapshot else {
            // Queue stays pending for a safe retry when a source file changed
            // mid-upload (e.g. an active PSD project).
            throw UploadError.sourceChanged
        }
    }

    private struct Snapshot: Equatable {
        let isFile: Bool
        let isDirectory: Bool
        let size: Int64
        let mtime: TimeInterval
        let inode: UInt64
    }

    private func attributes(of file: URL) throws -> Snapshot {
        // URLResourceValues can cache metadata for a URL instance. Use lstat
        // for a fresh source snapshot so active PSD files are NOT acknowledged.
        var info = stat()
        let rc = file.path.withCString { lstat($0, &info) }
        guard rc == 0 else { throw UploadError.sourceNotAvailable }
        let kind = info.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else {
            // In particular, never follow or upload a symbolic link.
            throw UploadError.unsupportedSource
        }
        return Snapshot(
            isFile: kind == mode_t(S_IFREG),
            isDirectory: kind == mode_t(S_IFDIR),
            size: Int64(info.st_size),
            mtime: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            inode: UInt64(info.st_ino)
        )
    }

}
