import Foundation

/// Counts only events that completed during a sync cycle. A queued or
/// retried operation is NOT shown as a successful copy or deletion.
/// UI displays last cycle and cumulative totals for the current test session.
public struct SyncDashboardStats: Equatable, Sendable {
    public var newFiles: Int
    public var updatedFiles: Int
    public var permanentlyDeleted: Int
    public var movedToRecovery: Int
    public var failed: Int
    public var deferred: Int
    public var createdDirectories: Int
    public var removedDirectories: Int
    public var expiredRecovery: Int
    public var bytesTransferred: Int64
    public var deletionsBlocked: Bool

    public init(
        newFiles: Int = 0,
        updatedFiles: Int = 0,
        permanentlyDeleted: Int = 0,
        movedToRecovery: Int = 0,
        failed: Int = 0,
        deferred: Int = 0,
        createdDirectories: Int = 0,
        removedDirectories: Int = 0,
        expiredRecovery: Int = 0,
        bytesTransferred: Int64 = 0,
        deletionsBlocked: Bool = false
    ) {
        self.newFiles = newFiles
        self.updatedFiles = updatedFiles
        self.permanentlyDeleted = permanentlyDeleted
        self.movedToRecovery = movedToRecovery
        self.failed = failed
        self.deferred = deferred
        self.createdDirectories = createdDirectories
        self.removedDirectories = removedDirectories
        self.expiredRecovery = expiredRecovery
        self.bytesTransferred = bytesTransferred
        self.deletionsBlocked = deletionsBlocked
    }

    public init(copy: MountedCopySummary, mirror: MirrorDeletionSummary, expiredRecovery: Int) {
        self.init(
            newFiles: copy.created,
            updatedFiles: copy.updated,
            permanentlyDeleted: mirror.removed,
            movedToRecovery: mirror.recovered,
            failed: copy.failed,
            deferred: copy.deferred + mirror.deferred,
            createdDirectories: copy.directoriesCreated,
            removedDirectories: mirror.directories,
            expiredRecovery: expiredRecovery,
            bytesTransferred: copy.bytes,
            deletionsBlocked: mirror.blocked
        )
    }

    public mutating func accumulate(_ other: SyncDashboardStats) {
        newFiles += other.newFiles
        updatedFiles += other.updatedFiles
        permanentlyDeleted += other.permanentlyDeleted
        movedToRecovery += other.movedToRecovery
        failed += other.failed
        deferred += other.deferred
        createdDirectories += other.createdDirectories
        removedDirectories += other.removedDirectories
        expiredRecovery += other.expiredRecovery
        bytesTransferred = bytesTransferred.addingReportingOverflow(other.bytesTransferred).overflow
            ? Int64.max
            : bytesTransferred + other.bytesTransferred
        deletionsBlocked = deletionsBlocked || other.deletionsBlocked
    }
}
