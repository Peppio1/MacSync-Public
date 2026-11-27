import Foundation

/// A pure eligibility calculation for a future offline compaction. This
/// does not acquire a lock, open SQLite, create backups or replace files.
/// Callers must still prove exclusive access and verify a recovery copy.
public enum DatabaseCompactionPolicy {
    public enum Decision: Equatable, Sendable {
        case insufficientEvidence, insufficientReclaim, insufficientSpace, sizeLimit, backupLimit, preparationFailed, eligible
    }

    public static let maximumAutomaticBytes: Int64 = 512 * 1024 * 1024
    public static let maximumRetainedBackups = 3

    /// Conservative initial thresholds, independent of WAL size. WAL bytes
    /// are included only in the scratch-space estimate, not the reclaim estimate.
    public static func evaluate(pageSize: Int64?, pageCount: Int64?, freePages: Int64?,
                                walBytes: Int64?, availableBytes: Int64?) -> Decision {
        guard let pageSize, let pageCount, let freePages, let walBytes, let availableBytes,
              pageSize >= 512, pageSize <= 65536, pageSize.nonzeroBitCount == 1,
              pageCount > 0, freePages >= 0, freePages < pageCount,
              walBytes >= 0, availableBytes >= 0 else { return .insufficientEvidence }
        let (size, sizeOverflow) = pageSize.multipliedReportingOverflow(by: pageCount)
        let (free, freeOverflow) = pageSize.multipliedReportingOverflow(by: freePages)
        guard !sizeOverflow, !freeOverflow else { return .insufficientEvidence }
        let minimumReclaim: Int64 = 64 * 1024 * 1024
        // At least 25% and 64 MiB free, avoiding floating point rounding.
        let quarter = pageCount / 4 + (pageCount % 4 == 0 ? 0 : 1)
        guard free >= minimumReclaim, freePages >= quarter else { return .insufficientReclaim }
        let (total, totalOverflow) = size.addingReportingOverflow(walBytes)
        let (scratch, scratchOverflow) = total.multipliedReportingOverflow(by: 3)
        let (required, requiredOverflow) = scratch.addingReportingOverflow(minimumReclaim)
        guard !totalOverflow, !scratchOverflow, !requiredOverflow else { return .insufficientEvidence }
        guard total <= maximumAutomaticBytes else { return .sizeLimit }
        return availableBytes >= required ? .eligible : .insufficientSpace
    }
}
