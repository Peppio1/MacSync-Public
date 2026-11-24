import Foundation

/// Single-use decision, independent of the GUI's run loop. A late click
/// cannot authorize mutation after the monotonic 60-second deadline.
public final class NamePromptDecision: @unchecked Sendable {
    private let lock=NSLock()
    private let deadline:Double
    private var value:Bool?
    public init(started:Double=ProcessInfo.processInfo.systemUptime,timeout:Double=60) {
        deadline=started+timeout
    }
    public func answer(at now:Double) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        if value == nil && now >= deadline { value=false }
        return value
    }
    public var answer:Bool? { answer(at:ProcessInfo.processInfo.systemUptime) }
    public func confirm(at now:Double=ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return }
        value=now < deadline
    }
    public func skip() {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value=false }
    }
    public var remaining:Int {
        max(0,Int(ceil(deadline-ProcessInfo.processInfo.systemUptime)))
    }
}
