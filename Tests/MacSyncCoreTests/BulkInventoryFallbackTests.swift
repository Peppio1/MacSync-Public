import XCTest
@testable import MacSyncCore

final class BulkInventoryFallbackTests: XCTestCase {
    private enum Fault: Error, Equatable { case io, changed }
    func testCompleteUsesBulkOnlyAndRevalidates() throws {
        var checks = 0, legacy = 0
        let result = try BulkInventoryFallback.scan(shouldContinue: { true },
            verifyBinding: { checks += 1 }, bulk: { .complete(["a", "b"]) },
            posix: { legacy += 1; return ["legacy"] })
        XCTAssertEqual(result.value, ["a", "b"])
        XCTAssertEqual(result.method, .bulk)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(legacy, 0)
    }
    func testUnsupportedRestartsFromScratchWithKnownMethod() throws {
        var checks = 0, legacy = 0
        let result = try BulkInventoryFallback.scan(shouldContinue: { true },
            verifyBinding: { checks += 1 }, bulk: { .unsupported },
            posix: { legacy += 1; return ["complete", "legacy"] })
        XCTAssertEqual(result.value, ["complete", "legacy"])
        XCTAssertEqual(result.method, .posix)
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(legacy, 1)
    }
    func testIOErrorNeverTriggersFallback() {
        var legacy = 0
        XCTAssertThrowsError(try BulkInventoryFallback.scan(shouldContinue: { true },
            verifyBinding: {}, bulk: { throw Fault.io },
            posix: { legacy += 1; return ["legacy"] })) { error in
                XCTAssertEqual(error as? Fault, .io)
            }
        XCTAssertEqual(legacy, 0)
    }
    func testChangedBindingPreventsFallbackOrReturningBulk() {
        for unsupported in [true, false] {
            var checks = 0, legacy = 0
            XCTAssertThrowsError(try BulkInventoryFallback.scan(shouldContinue: { true },
                verifyBinding: { checks += 1; if checks == 2 { throw Fault.changed } },
                bulk: { unsupported ? .unsupported : .complete(["bulk"]) },
                posix: { legacy += 1; return ["legacy"] })) { error in
                    XCTAssertEqual(error as? Fault, .changed)
                }
            XCTAssertEqual(legacy, 0)
        }
    }
    func testCancellationNeverRestartsOrAcceptsLateResult() {
        for unsupported in [true, false] {
            var active = true, legacy = 0
            XCTAssertThrowsError(try BulkInventoryFallback.scan(shouldContinue: { active },
                verifyBinding: {}, bulk: { active = false; return unsupported ? .unsupported : .complete(["bulk"]) },
                posix: { legacy += 1; return ["legacy"] }))
            XCTAssertEqual(legacy, 0)
        }
    }
    func testFallbackResultRejectedIfBindingChanges() {
        var checks = 0, legacy = 0
        XCTAssertThrowsError(try BulkInventoryFallback.scan(shouldContinue: { true },
            verifyBinding: { checks += 1; if checks == 3 { throw Fault.changed } },
            bulk: { .unsupported }, posix: { legacy += 1; return ["legacy"] }))
        XCTAssertEqual(legacy, 1)
    }
}
