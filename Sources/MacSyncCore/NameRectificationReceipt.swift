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

extension NameRectificationReceipt {
    // Shared by the local inventory and journal, including startup order.
    static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS name_rectification_receipts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,root_id TEXT NOT NULL,
            old_path TEXT NOT NULL,new_path TEXT NOT NULL,receipt TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_rectification_receipts_root ON name_rectification_receipts(root_id,id DESC);
        CREATE INDEX IF NOT EXISTS idx_rectification_receipts_old ON name_rectification_receipts(root_id,old_path,id DESC);
        CREATE TABLE IF NOT EXISTS name_rectification_monitor_links(
            job_id INTEGER PRIMARY KEY,receipt_id INTEGER NOT NULL
        );
        CREATE TRIGGER IF NOT EXISTS rectification_monitor_link_cleanup
        AFTER DELETE ON change_queue BEGIN
            DELETE FROM name_rectification_monitor_links WHERE job_id=OLD.id;
        END;
        """
}
