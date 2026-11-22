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
    func testFastDiagnosticProducerIsBackpressuredWithoutDroppingItems() throws {
        let lane=InventoryReadLane()
        let count=50_000
        var received=0, largestBatch=0, lastIndex = -1
        let start=ProcessInfo.processInfo.systemUptime
        let completed=try lane.read(maxPendingUpdates:512,shouldContinue:{ true },
            onUpdate:{ (updates: [Int]) in
                largestBatch=max(largestBatch,updates.count)
                for index in updates {
                    XCTAssertEqual(index,lastIndex+1,"Diagnostic item ordering changed")
                    lastIndex=index
                    received+=1
                }
            },work:{ active,report in
                for i in 0..<count {
                    guard active() else { return -1 }
                    report(i)
                }
                return count
            })
        XCTAssertEqual(completed,count)
        XCTAssertEqual(received,count)
        XCTAssertEqual(lastIndex,count-1)
        XCTAssertLessThanOrEqual(largestBatch,512)
        print(String(format:"InventoryRead 50k ordered updates: %.3fs, max batch %d",
                     ProcessInfo.processInfo.systemUptime-start,largestBatch))
    }

    func testCancellationWakesBackpressuredDiagnosticWorker() throws {
        let lane=InventoryReadLane()
        let cancel=SeedVerificationCancellation()
        let started=ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try lane.read(maxPendingUpdates:32,
            shouldContinue:{ !cancel.isCancelled },
            onUpdate:{ (updates: [Int]) in
                if !updates.isEmpty { cancel.cancel() }
            },work:{ active,report in
                for i in 0..<20_000 {
                    guard active() else { return -1 }
                    report(i)
                }
                return 20_000
            })) { error in
                guard case .cancelled? = error as? SeedVerificationError else {
                    return XCTFail("Expected cancelled scan, got \(error)")
                }
            }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,3.0)
    }

    func testHalfMillionDiagnosticUpdatesStressOptIn() throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_PERF_STRESS"] == "1" else {
            throw XCTSkip("Enable MACSYNC_PERF_STRESS for extended synthetic stress")
        }
        let lane=InventoryReadLane()
        let total=500_000
        var delivered=0, maxBatch=0
        let begin=ProcessInfo.processInfo.systemUptime
        let result=try lane.read(maxPendingUpdates:2048,shouldContinue:{ true },
            onUpdate:{ (updates: [Int]) in
                delivered+=updates.count
                maxBatch=max(maxBatch,updates.count)
            },work:{ active,report in
                for i in 0..<total {
                    guard active() else { return -1 }
                    report(i)
                }
                return total
            })
        XCTAssertEqual(result,total)
        XCTAssertEqual(delivered,total)
        XCTAssertLessThanOrEqual(maxBatch,2048)
        let duration=ProcessInfo.processInfo.systemUptime-begin
        print(String(format:"MacSync stress synthetic: %d updates in %.3fs (%.0f/s), max buffered batch %d",
                     total,duration,Double(total)/max(0.001,duration),maxBatch))
    }

}
