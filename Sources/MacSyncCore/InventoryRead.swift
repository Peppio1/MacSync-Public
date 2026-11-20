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
        private let lock = NSLock()
        private var active = true
        private var lastActivity = ProcessInfo.processInfo.systemUptime
        private var result: Result<Value, Error>?
        private var updates: [Update] = []

        func shouldContinue() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return active
        }

        func report(_ update: Update) {
            lock.lock(); defer { lock.unlock() }
            guard active else { return }
            lastActivity = ProcessInfo.processInfo.systemUptime
            updates.append(update)
        }

        func finish(_ value: Result<Value, Error>) {
            lock.lock(); defer { lock.unlock() }
            if active { result = value }
        }

        func poll() -> (Result<Value, Error>?, [Update], Double) {
            lock.lock(); defer { lock.unlock() }
            let pending = updates
            updates = []
            return (result, pending, lastActivity)
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            active = false
            updates = []
        }
    }

    private let slot = DispatchSemaphore(value: 1)

    public func read<Value: Sendable, Update: Sendable>(
        idleLimit: TimeInterval = 90,
        shouldContinue: () -> Bool,
        onUpdate: ([Update]) -> Void,
        work: @escaping @Sendable (() -> Bool, (Update) -> Void) throws -> Value
    ) throws -> Value {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        guard slot.wait(timeout: .now()) == .success else { throw Failure.previousReadPending }
        let state = State<Value, Update>()
        defer { state.stop() }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try work(state.shouldContinue, state.report) }
            self.slot.signal()
            state.finish(result)
            finished.signal()
        }
        while true {
            _ = finished.wait(timeout: .now() + .milliseconds(200))
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            let (result, updates, lastActivity) = state.poll()
            if !updates.isEmpty { onUpdate(updates) }
            if let result { return try result.get() }
            if ProcessInfo.processInfo.systemUptime - lastActivity >= idleLimit { throw Failure.stalled }
        }
    }
}
