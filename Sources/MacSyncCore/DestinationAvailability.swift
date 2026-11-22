import Foundation
import Darwin

/// Lightweight per-destination check. It never opens an SMB connection,
/// mounts a share, writes files, scans children or changes the sync journal.
public enum DestinationAvailability: Equatable, Sendable {
    case notConfigured
    case unverified
    case unavailable
    case differentVolume
    case ready

    public var isReady: Bool {
        self == .ready
    }

    public var description: String {
        switch self {
        case .notConfigured: return "Non configurata"
        case .unverified: return "Volume non verificato: riseleziona la cartella"
        case .unavailable: return "Cartella non accessibile: attendo il volume"
        case .differentVolume: return "Volume diverso da quello configurato: operazioni bloccate"
        case .ready: return "Cartella pronta"
        }
    }
}

public enum DestinationProbe {
    /// Use the originally saved volume fingerprint; otherwise a missing
    /// network mount could be mistaken for a local directory at /Volumes.
    public static func inspect(
        path: String,
        expectedVolume: VolumeFingerprint?
    ) -> DestinationAvailability {
        guard !path.isEmpty else { return .notConfigured }
        guard let expectedVolume else { return .unverified }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        let status = target.path.withCString { lstat($0, &info) }
        guard status == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            return .unavailable
        }
        guard let actual = try? VolumeFingerprint.read(at: target) else {
            return .unavailable
        }
        return actual == expectedVolume ? .ready : .differentVolume
    }
}


/// Finder can remount the same SMB share under /Volumes/Share-1 after login.
/// Only recover an *existing* and uniquely identified mount; never mount it,
/// guess an SMB hostname, store credentials or approve any write.
public enum SMBRemountLocator {
    /// Lexical projection only; callers must subsequently verify the mounted
    /// directory and the persistent directory bindings before accepting it.
    public static func candidatePath(savedPath: String,
                                     expected: VolumeFingerprint,
                                     mounted: [VolumeFingerprint]) -> String? {
        guard expected.fileSystem.lowercased() == "smbfs",
              expected.isStrongIdentity, !expected.mountPath.isEmpty,
              savedPath == expected.mountPath ||
                savedPath.hasPrefix(expected.mountPath + "/") else { return nil }

        let matches = mounted.filter {
            $0.fileSystem.lowercased() == "smbfs" &&
            $0.mountSource == expected.mountSource &&
            $0.mountPath != expected.mountPath &&
            !$0.mountPath.isEmpty
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        let suffix = String(savedPath.dropFirst(expected.mountPath.count))
        return URL(fileURLWithPath: match.mountPath + suffix).standardizedFileURL.path
    }

    public static func verifiedCandidate(savedPath: String,
                                         expected: VolumeFingerprint) -> (path: String, volume: VolumeFingerprint)? {
        let mounted = VolumeFingerprint.mountedVolumes()
        guard let candidate = candidatePath(savedPath: savedPath,
                                            expected: expected, mounted: mounted),
              let match = mounted.first(where: { volume in
                  volume.fileSystem.lowercased() == "smbfs" &&
                  volume.mountSource == expected.mountSource &&
                  (candidate == volume.mountPath ||
                   candidate.hasPrefix(volume.mountPath + "/"))
              }) else {
            // Keep mount discovery separate from filesystem verification;
            // never accept a missing or ambiguous candidate.
            return nil
        }
        let url = URL(fileURLWithPath: candidate)
        var entry = stat()
        guard candidate.withCString({ lstat($0, &entry) }) == 0,
              (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              url.resolvingSymlinksInPath().path == candidate,
              (try? VolumeFingerprint.read(at: url)) == match else { return nil }
        return (candidate, match)
    }
}
