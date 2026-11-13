import Foundation
import Darwin

/// Non-secret connection settings; password is stored independently in
/// SMBSecretStore (Keychain). The remote is synthesized in the child process
/// environment rather than written to a persistent rclone.conf file.
public struct SMBSecureProfile: Equatable {
    public let host: String
    public let username: String
    public let domain: String
    public let share: String

    public init(host: String, username: String, domain: String = "WORKGROUP", share: String) throws {
        guard !host.isEmpty, !host.contains(where: { $0.isNewline || $0.isWhitespace || $0 == "/" || $0 == "\\" }),
              !username.isEmpty, !username.contains(where: { $0.isNewline || $0 == "\0" }),
              !domain.contains(where: { $0.isNewline || $0 == "\0" }),
              !share.isEmpty, share != ".", share != "..",
              !share.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0.isNewline || $0 == "\0" }),
              share.trimmingCharacters(in: .whitespacesAndNewlines) == share
        else {
            throw UploadError.invalidMapping("Invalid SMB host, user, domain or share")
        }
        self.host = host
        self.username = username
        self.domain = domain
        self.share = share
    }

    public var remoteParent: String {
        "macsync_smb:" + share
    }

    public func environment(obscuredPassword: String) throws -> [String: String] {
        guard !obscuredPassword.isEmpty,
              !obscuredPassword.contains("\n"),
              !obscuredPassword.contains("\r") else {
            throw KeychainSecretError.invalidSecret
        }
        return [
            "RCLONE_CONFIG_MACSYNC_SMB_TYPE": "smb",
            "RCLONE_CONFIG_MACSYNC_SMB_HOST": host,
            "RCLONE_CONFIG_MACSYNC_SMB_USER": username,
            "RCLONE_CONFIG_MACSYNC_SMB_DOMAIN": domain,
            "RCLONE_CONFIG_MACSYNC_SMB_PASS": obscuredPassword,
            "RCLONE_CONFIG": "/dev/null"
        ]
    }
}

/// Rclone requires SMB passwords in its reversible 'obscured' format.
/// Feed the plaintext password via STDIN (never as CLI argument).
/// Obscuring is NOT a security boundary: the original secret belongs in Keychain.
public enum RclonePasswordObscurer {
    public static func obscure(password: String, executable: URL) throws -> String {
        guard !password.isEmpty, !password.contains("\n"),
              !password.contains("\r") else { throw KeychainSecretError.invalidSecret }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UploadError.noRcloneBinary
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["obscure", "-"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForReading.closeFile()

        let secret = Data((password + "\n").utf8)
        input.fileHandleForWriting.write(secret)
        input.fileHandleForWriting.closeFile()

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        if terminated.wait(timeout: .now() + 10) == .timedOut {
            if process.isRunning { process.terminate() }
            throw UploadError.commandTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw UploadError.commandFailed(process.terminationStatus)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count < 10_000,
              let text = String(data: data, encoding: .utf8) else {
            throw KeychainSecretError.invalidSecret
        }
        let obscured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !obscured.isEmpty else { throw KeychainSecretError.invalidSecret }
        return obscured
    }
}
