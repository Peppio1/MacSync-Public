import Foundation

/// Runs read-only filesystem work in isolation. A kernel SMB call may return
/// late. Its result is discarded and the lane does not start a second reader
/// until that call has actually returned.
public final class InventoryReadLane: @unchecked Sendable {
    public static let names = InventoryReadLane()
    public static let archive = InventoryReadLane()

    public enum Failure: LocalizedError {
        case stalled
        case previousReadPending

        public var errorDescription: String? {
            switch self {
            case .stalled: return "Nessuna risposta dal filesystem durante la scansione"
            case .previousReadPending: return "Il filesystem sta ancora completando una lettura precedente"
            }
        }
    }

    private final class State<Value, Update>: @unchecked Sendable {
        private let condition = NSCondition()
        private let wakeReader = DispatchSemaphore(value: 0)
        private let limit: Int
        private var active = true
        private var lastActivity = ProcessInfo.processInfo.systemUptime
        private var result: Result<Value, Error>?
        private var updates: [Update] = []

        init(limit: Int) { self.limit = max(1, min(16_384, limit)) }

        func shouldContinue() -> Bool {
            condition.lock(); defer { condition.unlock() }
            return active
        }

        func report(_ update: Update) {
            condition.lock(); defer { condition.unlock() }
            // All .item events in an archive scan count toward diagnostics.
            // Never discard them; backpressure only the isolated scan worker
            // if its consumer cannot keep up. Stop wakes a blocked producer.
            while active && updates.count >= limit { condition.wait() }
            guard active else { return }
            lastActivity = ProcessInfo.processInfo.systemUptime
            updates.append(update)
            if updates.count == min(limit, 512) { wakeReader.signal() }
        }

        func finish(_ value: Result<Value, Error>) {
            condition.lock()
            if active { result = value }
            condition.broadcast()
            condition.unlock()
            wakeReader.signal()
        }

        func waitForUpdate() {
            _ = wakeReader.wait(timeout: .now() + .milliseconds(200))
        }

        func poll() -> (Result<Value, Error>?, [Update], Double) {
            condition.lock(); defer { condition.unlock() }
            let pending = updates
            updates = []
            if !pending.isEmpty {
                // Pending progress is evidence of an active scan; waiting for
                // its consumer is not a filesystem inactivity timeout.
                lastActivity = ProcessInfo.processInfo.systemUptime
                condition.broadcast()
            }
            return (result, pending, lastActivity)
        }

        func stop() {
            condition.lock()
            active = false
            updates = []
            condition.broadcast()
            condition.unlock()
            wakeReader.signal()
        }
    }

    private let slot = DispatchSemaphore(value: 1)

    public func read<Value: Sendable, Update: Sendable>(
        idleLimit: TimeInterval = 90,
        maxPendingUpdates: Int = 4096,
        shouldContinue: () -> Bool,
        onUpdate: ([Update]) -> Void,
        work: @escaping @Sendable (() -> Bool, (Update) -> Void) throws -> Value
    ) throws -> Value {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        guard slot.wait(timeout: .now()) == .success else { throw Failure.previousReadPending }
        let state = State<Value, Update>(limit: maxPendingUpdates)
        defer { state.stop() }
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try work(state.shouldContinue, state.report) }
            state.finish(result)
            // A cancelled or stalled read keeps the lane occupied until its
            // original worker actually returns; never overlap SMB scans.
            self.slot.signal()
        }
        while true {
            state.waitForUpdate()
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            let (result, updates, lastActivity) = state.poll()
            if !updates.isEmpty { onUpdate(updates) }
            if let result { return try result.get() }
            if ProcessInfo.processInfo.systemUptime - lastActivity >= idleLimit { throw Failure.stalled }
        }
    }
}
