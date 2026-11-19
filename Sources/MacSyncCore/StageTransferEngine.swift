import Foundation
import Darwin

/// Copies only the current job to an unpublished UUID staging path.
/// The caller owns publication, journal acknowledgment and cleanup.
public enum StageTransferEngine {
    case native
    case rclone(URL)

    /// Internal rollback switch, intentionally not a user preference.
    public static func applicationDefault() -> StageTransferEngine {
        if ProcessInfo.processInfo.environment["MACSYNC_INTERNAL_TRANSFER_ENGINE"] == "native" {
            return .native
        }
        return .rclone(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone"))
    }

    static func arguments(source: URL, staging: URL) -> [String] {
        ["copyto", "--config", "/dev/null", "--inplace", "--no-traverse",
         "--ignore-times", "--retries", "1", "--low-level-retries", "1",
         "--multi-thread-streams", "0", "--local-no-clone", "--buffer-size", "16Mi",
         "--use-json-log", "--stats", "1s", "--stats-log-level", "INFO",
         "--log-level", "INFO", "--", source.path, staging.path]
    }

    func copy(source: URL, staging: URL, shouldContinue: () -> Bool,
              progress: (Int64, Double) -> Void) throws {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        switch self {
        case .native:
            try FileManager.default.copyItem(at: source, to: staging)
        case .rclone(let executable):
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw MountedCopyError.rcloneUnavailable
            }
            var sourceStat = stat()
            guard lstat(source.path, &sourceStat) == 0,
                  sourceStat.st_mode & S_IFMT == S_IFREG,
                  staging.deletingLastPathComponent().lastPathComponent == ".macsync-staging",
                  staging.pathExtension == "partial",
                  UUID(uuidString: staging.deletingPathExtension().lastPathComponent) != nil else {
                throw MountedCopyError.unsafeFile
            }
            var targetStat = stat()
            guard lstat(staging.path, &targetStat) != 0, errno == ENOENT else {
                throw MountedCopyError.unsafeFile
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = Self.arguments(source: source, staging: staging)
            // No inherited RCLONE_* settings, remotes, credentials or shell.
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            let output = Pipe()
            process.standardError = output
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { throw MountedCopyError.rcloneLaunchFailed }
            var pending = Data()
            var cancelled = false
            let reader = output.fileHandleForReading
            defer { try? reader.close() }
            // Drain stderr on the serial worker so callbacks cannot race SQLite
            // or the UI progress model. Raw output may contain absolute paths:
            // never persist it or print it. Only extract numeric stats.
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                if !shouldContinue(), !cancelled {
                    cancelled = true
                    if process.isRunning { process.terminate() }
                }
                pending.append(chunk)
                while let index = pending.firstIndex(of: 10) {
                    let line = Data(pending.prefix(upTo: index))
                    pending.removeSubrange(pending.startIndex...index)
                    if let sample = Self.parseStats(line) { progress(sample.0, sample.1) }
                }
                if pending.count > 262144 { pending.removeAll(keepingCapacity: false) }
            }
            process.waitUntilExit()
            if cancelled || !shouldContinue() { throw SeedVerificationError.cancelled }
            guard process.terminationStatus == 0 else {
                throw MountedCopyError.rcloneFailed(process.terminationStatus)
            }
        }
    }

    static func parseStats(_ data: Data) -> (Int64, Double)? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stats = message["stats"] as? [String: Any],
              let bytes = stats["bytes"] as? NSNumber,
              let elapsed = stats["elapsedTime"] as? NSNumber,
              bytes.int64Value >= 0, elapsed.doubleValue.isFinite, elapsed.doubleValue > 0 else { return nil }
        return (bytes.int64Value, elapsed.doubleValue)
    }
}
