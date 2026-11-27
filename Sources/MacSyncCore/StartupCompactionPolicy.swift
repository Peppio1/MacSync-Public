import Foundation

/// A conservative startup-only policy. No timers run in the live runtime.
public enum StartupCompactionPolicy {
    public static let interval: TimeInterval = 7 * 24 * 60 * 60
    public static func shouldCheck(existing: Bool, stableIdentity: Bool, migrationNeeded: Bool,
                                   resetCompleted: Bool, updatePending: Bool,
                                   lastCheck: Date?, now: Date) -> Bool {
        guard existing, stableIdentity, !migrationNeeded, !resetCompleted, !updatePending,
              now.timeIntervalSinceReferenceDate.isFinite else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed.isFinite && elapsed >= interval
    }
}
