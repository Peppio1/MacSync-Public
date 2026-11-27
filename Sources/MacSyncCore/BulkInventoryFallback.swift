import Foundation

/// Experimental selection policy, not wired to the operational scanner.
/// The bulk reader must return only a complete inventory. Unsupported
/// capabilities may restart with the known reader, but I/O and consistency
/// failures must abort; never turn an incomplete listing into absence.
enum BulkInventoryFallback {
    enum Attempt<Value> {
        case complete(Value)
        case unsupported
    }
    enum Method: Equatable { case bulk, posix }
    static func scan<Value>(
        shouldContinue: () -> Bool,
        verifyBinding: () throws -> Void,
        bulk: () throws -> Attempt<Value>,
        posix: () throws -> Value
    ) throws -> (value: Value, method: Method) {
        func check() throws {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            try verifyBinding()
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
        }
        try check()
        let attempt = try bulk()
        try check()
        switch attempt {
        case .complete(let value):
            return (value, .bulk)
        case .unsupported:
            // No result, queue update or progress callbacks from an
            // abandoned attempt may be used for reconciliation.
            // Called synchronously: the previous reader has returned.
            let value = try posix()
            try check()
            return (value, .posix)
        }
    }
}
