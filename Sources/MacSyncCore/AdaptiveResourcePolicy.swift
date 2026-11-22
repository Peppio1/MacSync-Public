import Foundation

/// Regulates *presentation* only. Never slows, skips or reorders file
/// operations, journal commits, safety checks or cancellation tokens.
public struct AdaptiveResourceProfile: Equatable, Sendable {
    public enum Thermal: Equatable, Sendable {
        case nominal, fair, serious, critical
    }

    public let thermal: Thermal
    public let lowPower: Bool

    public init(thermal: Thermal, lowPower: Bool) {
        self.thermal = thermal
        self.lowPower = lowPower
    }

    /// Interval between UI progress snapshots, not between filesystem jobs.
    public var progressInterval: TimeInterval {
        let base: TimeInterval
        switch thermal {
        case .nominal: base = 0.2
        case .fair: base = 0.35
        case .serious: base = 0.6
        case .critical: base = 0.9
        }
        return max(base, lowPower ? 0.45 : 0.2)
    }

    public var nameStatusInterval: TimeInterval {
        switch thermal {
        case .nominal: return lowPower ? 1.2 : 0.8
        case .fair: return 1.2
        case .serious: return 1.8
        case .critical: return 2.5
        }
    }

    public static func sample() -> Self {
        let process = ProcessInfo.processInfo
        let thermal: Thermal
        switch process.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .fair
        }
        return Self(thermal: thermal, lowPower: process.isLowPowerModeEnabled)
    }
}

/// Adapts the progress presentation rate to observed main-queue delivery
/// delays. Thread-safe because the worker asks for intervals while the
/// main queue reports delivery. Metrics are monotonic delivery times,
/// not a claim to measure frame rendering or network throughput.
public final class AdaptiveProgressCadence: @unchecked Sendable {
    private let lock = NSLock()
    private var delayInterval: TimeInterval = 0.2
    private var largestDeliveryDelay: TimeInterval = 0

    public init() {}

    public func interval(profile: AdaptiveResourceProfile) -> TimeInterval {
        lock.lock()
        let interval = delayInterval
        lock.unlock()
        return max(profile.progressInterval, interval)
    }

    public func observeDeliveryDelay(_ delay: TimeInterval) {
        guard delay.isFinite, delay >= 0 else { return }
        lock.lock()
        largestDeliveryDelay = max(largestDeliveryDelay, delay)
        if delay >= 0.25 {
            delayInterval = min(1.0, delayInterval * 1.5)
        } else if delay <= 0.08 {
            delayInterval = max(0.2, delayInterval - 0.04)
        }
        lock.unlock()
    }

    public var maximumDeliveryDelay: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return largestDeliveryDelay
    }
}
