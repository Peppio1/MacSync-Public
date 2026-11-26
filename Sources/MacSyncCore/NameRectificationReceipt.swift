import Foundation

/// Historical evidence of a verified *local* rename, not evidence of
/// destination absence or permission to delete or acknowledge a queue job.
/// The mapping stamp is the stored target binding, not a fresh remote probe.
struct NameRectificationContext: Codable, Equatable, Sendable {
    let plannedAt:Date
    let queueSequence:Int64
    let targetBinding:DirectoryBinding?
}

struct NameRectificationReceipt: Codable, Equatable, Sendable {
    let rootID:String
    let oldPath:String
    let newPath:String
    let isDirectory:Bool
    let sourceRoot:String
    let sourceBinding:DirectoryBinding
    let inode:UInt64
    let birthSeconds:Int64
    let birthNanos:Int64
    let context:NameRectificationContext
    let completedAt:Date
}
