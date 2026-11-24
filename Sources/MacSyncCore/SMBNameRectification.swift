import Darwin
import Foundation
import Security

enum SMBNameRectificationError: LocalizedError {
    case mountUnavailable
    case credentialUnavailable
    case credentialLookupFailed(OSStatus)
    case credentialAmbiguous
    case credentialReadFailed(OSStatus)
    case helperFailed
    case notAttempted
    case timedOut

    var errorDescription: String? {
        switch self {
        case .mountUnavailable: return "Destinazione SMB non identificabile per la rettifica"
        case .credentialUnavailable: return "Nessuna credenziale SMB compatibile nel Portachiavi"
        case .credentialLookupFailed(let status): return "Ricerca credenziale SMB non riuscita (Portachiavi: \(status))"
        case .credentialAmbiguous: return "Più credenziali SMB compatibili nel Portachiavi; selezione non sicura"
        case .credentialReadFailed(let status): return "Lettura credenziale SMB non riuscita (Portachiavi: \(status))"
        case .helperFailed: return "Rclone SMB non ha confermato la rinomina protetta"
        case .notAttempted: return "Rclone SMB ha rifiutato il controllo prima di tentare la rinomina"
        case .timedOut: return "Tempo scaduto durante la rinomina rclone SMB"
        }
    }
}

struct SMBNameRectificationTarget {
    let host: String
    let port: Int
    let share: String
    let mountedAccount: String?
    private let basePath: [String]

    init(volume: VolumeFingerprint, parent: URL) throws {
        guard volume.fileSystem.lowercased() == "smbfs",
              let source = volume.mountSource, source.hasPrefix("//"),
              let parts = URLComponents(string: "smb:" + source),
              let host = parts.host, !host.isEmpty,
              parts.password == nil, parts.query == nil, parts.fragment == nil,
              let share = String(parts.percentEncodedPath.dropFirst()).removingPercentEncoding,
              Self.validComponent(share) else {
            throw SMBNameRectificationError.mountUnavailable
        }

        let mount = URL(fileURLWithPath: volume.mountPath).pathComponents
        let components = parent.pathComponents
        let port = parts.port ?? 445
        guard (1...65535).contains(port), components.starts(with: mount),
              components.dropFirst(mount.count).allSatisfy(Self.validComponent) else {
            throw SMBNameRectificationError.mountUnavailable
        }
        self.host = host
        self.port = port
        self.share = share
        self.mountedAccount = parts.user
        self.basePath = Array(components.dropFirst(mount.count))
    }

    func path(for name: String) throws -> String {
        guard Self.validComponent(name) else { throw MountedCopyError.unsafeFile }
        return (basePath + [name]).joined(separator: "/")
    }

    private static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}

enum SMBNameRectification {
    private struct Account: Equatable {
        let user: String
        let domain: String

        init(_ raw: String) {
            let parts = raw.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == "\\" || $0 == ";" }
            if parts.count == 2 {
                domain = String(parts[0])
                user = String(parts[1])
            } else {
                domain = ""
                user = raw
            }
        }

        func matches(_ other: Account) -> Bool {
            user.caseInsensitiveCompare(other.user) == .orderedSame &&
                (domain.isEmpty || other.domain.isEmpty || domain.caseInsensitiveCompare(other.domain) == .orderedSame)
        }
    }

    private struct Request: Encodable {
        let host: String
        let port: String
        let share: String
        let user: String
        let domain: String
        let password: String
        let oldPath: String
        let newPath: String
        let fileID: UInt64
        let createdSeconds: Int64
        let createdNanos: Int64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let isDirectory: Bool
        let verifyOnly: Bool
    }

    private static func credential(for target: SMBNameRectificationTarget) throws -> (Account, String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecAttrServer as String: target.host,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true
        ]
        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if lookupStatus == errSecItemNotFound { throw SMBNameRectificationError.credentialUnavailable }
        guard lookupStatus == errSecSuccess, let rows = result as? [[String: Any]] else {
            throw SMBNameRectificationError.credentialLookupFailed(lookupStatus)
        }

        let mountedAccount = target.mountedAccount.map(Account.init)
        var candidates: [(account: Account, ref: Data, exactShare: Bool)] = []
        for row in rows {
            guard let user = row[kSecAttrAccount as String] as? String, !user.isEmpty,
                  let ref = row[kSecValuePersistentRef as String] as? Data else { continue }
            let port = (row[kSecAttrPort as String] as? NSNumber)?.intValue ?? 0
            guard port == target.port || (port == 0 && target.port == 445) else { continue }
            let path = (row[kSecAttrPath as String] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
            // Finder can store an internet password for a subdirectory of the
            // mounted share. Accept only the same share, never another server
            // or account. Keep ambiguous credentials fail-closed.
            let firstComponent = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).first.map(String.init) ?? ""
            let exactShare = (firstComponent.removingPercentEncoding ?? firstComponent).caseInsensitiveCompare(target.share) == .orderedSame
            guard path.isEmpty || exactShare else { continue }
            var account = Account(user)
            if let hint = mountedAccount {
                guard hint.matches(account) else { continue }
                if account.domain.isEmpty && !hint.domain.isEmpty { account = hint }
            }
            candidates.append((account, ref, exactShare))
        }

        let shareMatches = candidates.filter { $0.exactShare }
        let matches = shareMatches.isEmpty ? candidates : shareMatches
        guard !matches.isEmpty else { throw SMBNameRectificationError.credentialUnavailable }
        guard matches.count == 1, let selected = matches.first else {
            throw SMBNameRectificationError.credentialAmbiguous
        }

        let passwordQuery: [String: Any] = [
            kSecValuePersistentRef as String: selected.ref,
            kSecReturnData as String: true
        ]
        result = nil
        let readStatus = SecItemCopyMatching(passwordQuery as CFDictionary, &result)
        guard readStatus == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw SMBNameRectificationError.credentialReadFailed(readStatus)
        }
        return (selected.account, password)
    }

    static func preflight(volume: VolumeFingerprint, parent: URL) throws {
        let target = try SMBNameRectificationTarget(volume: volume, parent: parent)
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone-smb-rename")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MountedCopyError.rcloneUnavailable }
        _ = try credential(for: target)
    }

    static func rename(volume: VolumeFingerprint, parent: URL, oldName: String, newName: String,
                       original: stat, verifyOnly: Bool = false, shouldContinue: () -> Bool) throws {
        let target = try SMBNameRectificationTarget(volume: volume, parent: parent)
        let oldPath = try target.path(for: oldName)
        let newPath = try target.path(for: newName)
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone-smb-rename")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MountedCopyError.rcloneUnavailable }
        let (account, password) = try credential(for: target)
        guard shouldContinue() else { throw SeedVerificationError.cancelled }

        let request = Request(host: target.host, port: String(target.port), share: target.share,
            user: account.user, domain: account.domain, password: password, oldPath: oldPath, newPath: newPath,
            fileID: UInt64(original.st_ino), createdSeconds: Int64(original.st_birthtimespec.tv_sec),
            createdNanos: Int64(original.st_birthtimespec.tv_nsec), size: original.st_size,
            modifiedSeconds: Int64(original.st_mtimespec.tv_sec), modifiedNanos: Int64(original.st_mtimespec.tv_nsec),
            isDirectory: original.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), verifyOnly: verifyOnly)
        let payload = try JSONEncoder().encode(request)
        guard payload.count <= 65_536 else { throw SMBNameRectificationError.helperFailed }

        let process = Process()
        let input = Pipe()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        do {
            try process.run()
        } catch {
            throw MountedCopyError.rcloneLaunchFailed
        }
        let writer = input.fileHandleForWriting
        defer {
            try? writer.close()
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        do {
            try writer.write(contentsOf: payload)
            try writer.close()
        } catch {
            throw SMBNameRectificationError.helperFailed
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while process.isRunning {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SMBNameRectificationError.timedOut }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.terminationReason == .exit && process.terminationStatus == 3 {
            throw SMBNameRectificationError.notAttempted
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SMBNameRectificationError.helperFailed
        }
    }
}
