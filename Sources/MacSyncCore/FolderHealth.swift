import Foundation
import Darwin

/// Presentation-only checks. Never write, enumerate children, mount a
/// volume, or grant operational consent. Workers retain all safety checks.
public enum FolderHealth: Equatable, Sendable {
    case checking, ready, missing, denied, invalidType, unavailable(Int32), unverified, differentVolume
    public var isReady: Bool { self == .ready }
    public var isError: Bool { self != .ready && self != .checking }
    public var description: String {
        switch self {
        case .checking: return "Controllo in corso…"
        case .ready: return "Disponibile"
        case .missing: return "Cartella non trovata"
        case .denied: return "Accesso negato o permessi insufficienti"
        case .invalidType: return "Percorso non valido o collegamento simbolico"
        case .unavailable(let code): return "Non accessibile (POSIX \(code): \(String(cString:strerror(code))))"
        case .unverified: return "Volume non verificato; riseleziona la destinazione"
        case .differentVolume: return "Volume diverso da quello configurato"
        }
    }
    public static func inspect(path:String, expected:VolumeFingerprint? = nil, destination:Bool = false) -> Self {
        guard !path.isEmpty else { return .checking }
        var info = stat()
        if path.withCString({ lstat($0,&info) }) != 0 { return classify(errno) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return .invalidType }
        if destination {
            guard let expected, expected.isStrongIdentity else { return .unverified }
            do {
                guard try VolumeFingerprint.read(at:URL(fileURLWithPath:path)) == expected else { return .differentVolume }
            } catch { return .unverified }
        }
        let mask = destination ? (R_OK | W_OK | X_OK) : (R_OK | X_OK)
        if path.withCString({ Darwin.access($0,mask) }) != 0 { return classify(errno) }
        return .ready
    }
    public static func classify(_ code:Int32) -> Self {
        switch code {
        case ENOENT, ENOTDIR: return .missing
        case EACCES, EPERM, EROFS: return .denied
        default: return .unavailable(code)
        }
    }
}
