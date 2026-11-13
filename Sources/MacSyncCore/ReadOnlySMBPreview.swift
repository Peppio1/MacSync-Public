import Foundation
import Darwin

/// Read-only, explicitly invoked baseline inspection. Unlike normal incremental
/// sync, this does a ONE-OFF recursive REMOTE listing for the selected test root.
/// It NEVER changes files or SQLite records.
public enum ReadOnlySMBPreview {
    public static func inspect(
        localRoot: URL,
        remoteRoot: String,
        rcloneExecutable: URL,
        environment: [String: String],
        maximumListingBytes: Int = 64 * 1024 * 1024
    ) throws -> BootstrapPreview {
        guard maximumListingBytes > 0 else {
            throw JournalError.database("Invalid listing limit")
        }
        // Validate remote mapping before making even a read-only network request.
        _ = try SMBUploadMapping(
            rootID: "preview", localRoot: localRoot, remoteRoot: remoteRoot
        )
        let local = try LocalScanner.scan(root: localRoot)
        let listing = try readRemoteJSON(
            rcloneExecutable: rcloneExecutable,
            remoteRoot: remoteRoot,
            environment: environment,
            maximumBytes: maximumListingBytes
        )
        let remote = try BootstrapPlanner.decodeRcloneJSON(listing)
        return try BootstrapPlanner.preview(local: local, remote: remote)
    }

    private static func readRemoteJSON(
        rcloneExecutable: URL,
        remoteRoot: String,
        environment: [String: String],
        maximumBytes: Int
    ) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: rcloneExecutable.path) else {
            throw UploadError.noRcloneBinary
        }
        let command = Process()
        command.executableURL = rcloneExecutable
        command.arguments = [
            "lsjson", remoteRoot, "--recursive",
            "--files-only", "--no-mimetype", "--quiet"
        ]
        command.environment = ProcessInfo.processInfo.environment.merging(
            environment, uniquingKeysWith: { _, override in override }
        )
        let output = Pipe()
        command.standardOutput = output
        command.standardInput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        try command.run()
        output.fileHandleForWriting.closeFile()

        var data = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536),
                  !chunk.isEmpty {
                guard data.count + chunk.count <= maximumBytes else {
                    if command.isRunning { command.terminate() }
                    command.waitUntilExit()
                    throw JournalError.database(
                        "Remote baseline listing exceeded configured memory budget"
                    )
                }
                data.append(chunk)
            }
        } catch {
            if command.isRunning { command.terminate() }
            command.waitUntilExit()
            throw error
        }
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw UploadError.commandFailed(command.terminationStatus)
        }
        return data
    }
}
