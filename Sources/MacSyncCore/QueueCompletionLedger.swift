import Foundation

/// Local retention bookkeeping only. Does not authorize, acknowledge or
/// remove jobs. A separate table preserves the predecessor's queue layout.
/// No migration of legacy completion dates from recorded_at (enqueue time).
enum QueueCompletionLedger {
    static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS queue_completion_ledger(
            job_id INTEGER PRIMARY KEY,
            completed_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_queue_completion_time
            ON queue_completion_ledger(completed_at,job_id);
        CREATE TRIGGER IF NOT EXISTS queue_completion_insert
        AFTER INSERT ON change_queue
        WHEN NEW.completed=1 BEGIN
            INSERT OR REPLACE INTO queue_completion_ledger(job_id,completed_at)
                VALUES(NEW.id,(julianday('now')-2440587.5)*86400.0);
        END;
        CREATE TRIGGER IF NOT EXISTS queue_completion_transition
        AFTER UPDATE OF completed ON change_queue
        WHEN OLD.completed<>1 AND NEW.completed=1 BEGIN
            INSERT OR REPLACE INTO queue_completion_ledger(job_id,completed_at)
                VALUES(NEW.id,(julianday('now')-2440587.5)*86400.0);
        END;
        CREATE TRIGGER IF NOT EXISTS queue_completion_reopen
        AFTER UPDATE OF completed ON change_queue
        WHEN NEW.completed<>1 BEGIN
            DELETE FROM queue_completion_ledger WHERE job_id=NEW.id;
        END;
        CREATE TRIGGER IF NOT EXISTS queue_completion_delete
        AFTER DELETE ON change_queue BEGIN
            DELETE FROM queue_completion_ledger WHERE job_id=OLD.id;
        END;
        """
}
