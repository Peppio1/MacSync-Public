import Foundation
import XCTest
@testable import MacSyncCore

final class InventoryReadTests: XCTestCase {
    func testCancellationReturnsWhileFilesystemReadIsStillPending() throws {
        let lane = InventoryReadLane()
        let request = SeedVerificationCancellation()
        let blocked = DispatchSemaphore(value: 0)
        defer { blocked.signal() }
        XCTAssertThrowsError(try lane.read(shouldContinue: { !request.isCancelled },
            onUpdate: { (_: [Int]) in request.cancel() },
            work: { _, report in
                report(1)
                _ = blocked.wait(timeout: .now() + 10)
                return 42
            })) { error in
            guard case .cancelled? = error as? SeedVerificationError else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
        XCTAssertThrowsError(try lane.read(shouldContinue: { true }, onUpdate: { (_: [Int]) in },
            work: { _, _ in 7 })) { error in
            guard case .previousReadPending? = error as? InventoryReadLane.Failure else {
                return XCTFail("Expected an occupied lane, got \(error)")
            }
        }
    }

    func testUnresponsiveReadTimesOutWithoutPublishingResult() throws {
        let lane = InventoryReadLane()
        let blocked = DispatchSemaphore(value: 0)
        defer { blocked.signal() }
        XCTAssertThrowsError(try lane.read(idleLimit: 0.05, shouldContinue: { true },
            onUpdate: { (_: [Int]) in }, work: { _, _ in
                _ = blocked.wait(timeout: .now() + 10)
                return 42
            })) { error in
            guard case .stalled? = error as? InventoryReadLane.Failure else {
                return XCTFail("Expected inactivity timeout, got \(error)")
            }
        }
    }

    func testSuccessfulReadDeliversProgressAndResult() throws {
        let lane = InventoryReadLane()
        var updates: [Int] = []
        let result = try lane.read(shouldContinue: { true }, onUpdate: { updates += $0 },
            work: { _, report in report(1); report(2); return 42 })
        XCTAssertEqual(updates, [1, 2])
        XCTAssertEqual(result, 42)
    }
}
