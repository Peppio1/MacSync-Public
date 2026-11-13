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
