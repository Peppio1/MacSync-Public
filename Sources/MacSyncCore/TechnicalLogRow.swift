import Foundation

public struct TechnicalLogRow: Identifiable, Equatable, Sendable {
    public var id: Int64 { entry.id }
    public let entry: SyncLogEntry
    public let cycleID: String?
    public let jobID: Int64?

    public var component: String {
        let action=entry.action
        if action.hasPrefix("rclone") { return "RCLONE" }
        if action.hasPrefix("smb") || action.hasPrefix("connection") { return "SMB" }
        if action.hasPrefix("mirror") { return "MIRROR" }
        if action.hasPrefix("queue") || action.hasPrefix("retry") { return "CODA" }
        if action.hasPrefix("monitor") || action.hasPrefix("fsevent") { return "FSEVENTS" }
        if action.hasPrefix("sqlite") || action.hasPrefix("database") { return "SQLITE" }
        return "MACSYNC"
    }
    public static func tsv(_ rows:[TechnicalLogRow]) -> String {
        let iso=ISO8601DateFormatter()
        iso.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        var lines=["timestamp\tlevel\troot\taction\trelative_path\tbytes\tseconds\tmessage\tcycle_id\tjob_id\tcomponent"]
        for row in rows.sorted(by:{$0.id<$1.id}) {
            let e=row.entry
            let values=[iso.string(from:e.timestamp),e.level,e.rootID,e.action,e.relativePath,String(e.bytes),
                        String(format:"%.3f",e.durationSeconds),e.message,row.cycleID ?? "",row.jobID.map { String($0) } ?? "",row.component]
            lines.append(values.map { $0.replacingOccurrences(of:"\t",with:" ").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ") }.joined(separator:"\t"))
        }
        return lines.joined(separator:"\n")+"\n"
    }
}

public enum TechnicalLogVerbosity:String,CaseIterable,Sendable {
    case normal, detailed, debug
    public static let preferenceKey="MacSync.technicalLogVerbosity"
    public static var current:Self { Self(rawValue:UserDefaults.standard.string(forKey:preferenceKey) ?? "") ?? .normal }
}
