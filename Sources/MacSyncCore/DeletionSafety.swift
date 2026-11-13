import Foundation

public struct DeletionDecision: Equatable, Sendable {
    public let allowed: Bool
    public let reason: String?

    public init(allowed: Bool, reason: String? = nil) {
        self.allowed = allowed
        self.reason = reason
    }
}

/// Conservative gate for *future* mirror deletion jobs.
/// No deletion implementation is included in the first prototype.
public enum DeletionSafety {
    public static func evaluate(
        sourceAvailable: Bool,
        serverAvailable: Bool,
        baselineVerified: Bool,
        trackedFileCount: Int,
        pendingDeleteCount: Int,
        minimumBulkCount: Int = 25,
        maximumBulkFraction: Double = 0.10,
        absoluteMaximum: Int = 250
    ) -> DeletionDecision {
        guard sourceAvailable else {
            return .init(allowed: false, reason: "Source folder is unavailable")
        }
        guard serverAvailable else {
            return .init(allowed: false, reason: "Server is unavailable")
        }
        guard baselineVerified, trackedFileCount > 0 else {
            return .init(allowed: false, reason: "No verified source inventory")
        }
        guard pendingDeleteCount >= 0 else {
            return .init(allowed: false, reason: "Invalid deletion count")
        }
        guard pendingDeleteCount < absoluteMaximum else {
            return .init(allowed: false, reason: "Absolute mass deletion threshold")
        }
        if pendingDeleteCount >= minimumBulkCount,
           Double(pendingDeleteCount) / Double(trackedFileCount) >= maximumBulkFraction {
            return .init(allowed: false, reason: "Bulk deletion fraction threshold")
        }
        return .init(allowed: true)
    }
}
