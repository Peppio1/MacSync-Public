import Foundation

/// Same stable ordering keys used by the worker's SQLite page selectors.
enum QueueExecutionOrder {
    static let idSQL = "id"
    static let deleteLengthSQL = "length(relative_path)"
    static let deleteSQL = deleteLengthSQL + " DESC, " + idSQL
}

/// Advisory snapshot of the serial worker. Never an authorization to mutate.
public struct QueueExecutionCursor: Equatable, Sendable {
    public enum Phase: String, Sendable { case uploads, deletes, finished }
    public let upperID: Int64
    public let mirrorCutoff: Int64?
    public var phase: Phase = .uploads
    public var currentID: Int64?
    public var uploadCursor: Int64 = 0
    public var deleteLength: Int64 = Int64.max
    public var deleteCursor: Int64 = 0
    public init(upperID:Int64,mirrorCutoff:Int64?) {
        self.upperID=upperID;self.mirrorCutoff=mirrorCutoff
    }
    public mutating func consider(_ job:QueuedChange) {
        currentID=job.id
        if job.kind == .upsert { uploadCursor=job.id }
        else { deleteLength=Int64(job.relativePath.unicodeScalars.count);deleteCursor=job.id }
    }
}
public enum QueuePreviewStatus:String, Sendable {
    case current, planned, waitingCopies, retry, nameBlocked, mirrorOff, beforeConsent, laterCycle, hold
    public var label:String {
        switch self {
        case .current: return "In esame / esecuzione"
        case .planned: return "Da esaminare"
        case .waitingCopies: return "Dopo completamento copie"
        case .retry: return "Riprova non ancora disponibile"
        case .nameBlocked: return "Nome bloccato nell’ultimo tentativo"
        case .mirrorOff: return "Mirror disattivato o non autorizzato"
        case .beforeConsent: return "Prima del limite di autorizzazione mirror"
        case .laterCycle: return "Da riesaminare al prossimo ciclo"
        case .hold: return "Pianificazione sospesa"
        }
    }
    public var isPlanned:Bool { self == .current || self == .planned || self == .waitingCopies }
}
public struct QueuePreviewRow: Identifiable, Sendable, Equatable {
    public let job:QueuedChange
    public let origin:String
    public let objectKind:String
    public let status:QueuePreviewStatus
    public var id:Int64 { job.id }
}
public struct QueuePreviewPage: Sendable {
    public let rows:[QueuePreviewRow]
    public let hasMore:Bool
    public init(rows:[QueuePreviewRow],hasMore:Bool) { self.rows=rows;self.hasMore=hasMore }
}
