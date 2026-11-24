import Foundation
import Darwin

/// Never serialize NSError.userInfo, URLs or credentials. Report the OS domain,
/// numeric code and the known cause, rather than guessing the remote fault.
public enum SyncDiagnostic {
    public static func clean(_ text:String,limit:Int = 3000) -> String {
        String(text.replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\0",with:" ").prefix(limit))
    }
    public static func describe(_ error: Error) -> String {
        if let smb = error as? SMBNameRectificationError {
            return "SMBNameRectificationError: " + smb.localizedDescription
        }
        if let check = error as? NameRectificationCheckError {
            return "NameRectificationCheckError: " + check.localizedDescription
        }
        if let copy = error as? MountedCopyError {
            if case .copyFailed(let code) = copy {
                return "MountedCopyError.copyFailed; POSIX \(code): " + String(cString:strerror(Int32(clamping:code))) + "; coda preservata"
            }
            return "MountedCopyError: " + copy.localizedDescription
        }
        if let journal=error as? JournalError {
            let message=journal.localizedDescription
            let allowed=["Source root is unavailable or not a directory","Scan path is outside the source root","Source root is not a regular accessible directory","Source root changed during scan","Source scan path inaccessible (filesystem code ","Metadati non disponibili durante la verifica completa","File changed during inventory scan","Cannot enumerate source directory","Riparazioni non accodate: inventario non pronto durante la finalizzazione","Unexpected path outside root","database is locked","database is busy","database disk image is malformed","disk I/O error","database or disk is full"]
            if allowed.contains(where:{message == $0 || ($0.hasSuffix("code ") && message.hasPrefix($0))}) { return "JournalError: " + clean(message) }
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
