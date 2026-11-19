import Foundation

/// Local bounded diagnostics, independent of SQLite. No raw child-process
/// output, file names, remote URLs or credentials. Best effort, never fatal.
public enum TechnicalFallbackLog {
    private static let lock=NSLock()
    private static let limit:UInt64=512*1024
    private static func url(_ databasePath:String) -> URL {
        URL(fileURLWithPath:databasePath).deletingLastPathComponent().appendingPathComponent("technical-fallback.log")
    }
    public static func record(databasePath:String,cycleID:String? = nil,action:String,message:String) {
        lock.lock(); defer { lock.unlock() }
        let file=url(databasePath), previous=file.appendingPathExtension("previous"), fm=FileManager.default
        do {
            let size=(try? fm.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if size>=limit {
                if fm.fileExists(atPath:previous.path) { try fm.removeItem(at:previous) }
                try fm.moveItem(at:file,to:previous)
            }
            if !fm.fileExists(atPath:file.path) {
                guard fm.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else { return }
            }
            let iso=ISO8601DateFormatter()
            iso.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            let line=[iso.string(from:Date()),cycleID ?? "-",SyncDiagnostic.clean(action,limit:100),SyncDiagnostic.clean(message,limit:500)].joined(separator:" | ")+"\n"
            let handle=try FileHandle(forWritingTo:file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf:Data(line.utf8))
        } catch { /* A full/unavailable local disk can also prevent fallback. */ }
    }
    public static func recent(databasePath:String,limit:Int=100) -> String {
        lock.lock(); defer { lock.unlock() }
        let file=url(databasePath)
        let files=[file.appendingPathExtension("previous"),file]
        let lines=files.flatMap { source in
            ((try? String(contentsOf:source,encoding:.utf8)) ?? "").split(separator:"\n").map(String.init)
        }
        return lines.suffix(max(1,min(limit,1000))).joined(separator:"\n")
    }
}
