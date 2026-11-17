import Foundation
import Darwin

/// Never serialize NSError.userInfo, URLs or credentials. Report the OS domain,
/// numeric code and the known cause, rather than guessing the remote fault.
public enum SyncDiagnostic {
    public static func describe(_ error: Error) -> String {
        if let copy = error as? MountedCopyError {
            if case .copyFailed(let code) = copy {
                return "MountedCopyError.copyFailed; POSIX \(code): " + String(cString:strerror(Int32(clamping:code))) + "; coda preservata"
            }
            return "MountedCopyError: " + copy.localizedDescription
        }
        let e = error as NSError
        var parts = ["\(e.domain) [\(e.code)]"]
        if e.domain == NSPOSIXErrorDomain {
            parts.append(String(cString:strerror(Int32(clamping:e.code))))
        } else if e.domain == NSCocoaErrorDomain {
            switch e.code {
            case 4,260: parts.append("File o percorso non trovato")
            case 257,513: parts.append("Permessi insufficienti")
            case 640: parts.append("Spazio disponibile insufficiente")
            default: parts.append("Errore filesystem Cocoa; consultare il codice")
            }
        } else if let known = error as? SeedVerificationError {
            parts.append(known.localizedDescription)
        } else {
            parts.append("Causa specifica non disponibile")
        }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("Sottostante: \(underlying.domain) [\(underlying.code)]")
            if underlying.domain == NSPOSIXErrorDomain { parts.append(String(cString:strerror(Int32(clamping:underlying.code)))) }
        }
        return String(parts.joined(separator:" — ").prefix(3000))
    }
}
