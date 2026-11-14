import Foundation

/// First observation of an unavailable destination starts the timer.
/// Alerting happens ONLY on a scheduled synchronization attempt; there are
/// no additional background connection probes or repeated notifications.
public struct ConnectionOutageTracker: Codable, Equatable, Sendable {
    public struct Outage: Codable, Equatable, Sendable {
        public var firstObserved: Date
        public var alertSent: Bool
        public init(firstObserved: Date, alertSent: Bool = false) {
            self.firstObserved = firstObserved
            self.alertSent = alertSent
        }
    }

    public private(set) var outages: [String: Outage] = [:]
    public init() {}

    /// Returns destinations due for an alert. A failed delivery stays due,
    /// and is retried only on a subsequent scheduled check. Mark acceptance
    /// separately, only when the operating system accepts the notification.
    public mutating func record(
        _ checked: [String: DestinationAvailability],
        at now: Date, policy: ConnectionAlertPolicy
    ) -> [String] {
        guard policy.isValid else { return [] }
        guard policy.enabled else {
            outages.removeAll()
            return []
        }
        var newlyDue: [String] = []
        for (id, state) in checked {
            switch state {
            case .ready, .notConfigured, .unverified:
                outages.removeValue(forKey: id)
            case .unavailable, .differentVolume:
                var outage = outages[id] ?? Outage(firstObserved: now)
                if outage.firstObserved > now {
                    outage = Outage(firstObserved: now)
                }
                let elapsed = now.timeIntervalSince(outage.firstObserved)
                if !outage.alertSent &&
                    elapsed >= TimeInterval(policy.afterHours) * 3_600 {
                    newlyDue.append(id)
                }
                outages[id] = outage
            }
        }
        // Remove old entries if an entire destination was unconfigured.
        // Do not assume missing readings mean the network has recovered.
        return newlyDue.sorted()
    }

    /// A delayed callback must not acknowledge a different outage.
    @discardableResult
    public mutating func markAccepted(for id: String, firstObserved: Date) -> Bool {
        guard var outage = outages[id], outage.firstObserved == firstObserved,
              !outage.alertSent else { return false }
        outage.alertSent = true
        outages[id] = outage
        return true
    }

    public func firstObserved(for id: String) -> Date? {
        outages[id]?.firstObserved
    }
}
