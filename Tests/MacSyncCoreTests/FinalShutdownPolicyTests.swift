import Foundation
import XCTest
@testable import MacSyncCore

final class FinalShutdownPolicyTests: XCTestCase {
    func testDisabledAndInvalidScheduleNeverFires() {
        var policy = FinalShutdownPolicy()
        XCTAssertNil(policy.next(after:Date()))
        policy.enabled = true; policy.weekdays = []
        XCTAssertNil(policy.next(after:Date()))
    }
    func testNextSlotIsFutureAndSelectedWeekday() throws {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier:"Europe/Rome"))
        var policy = FinalShutdownPolicy()
        policy.enabled = true; policy.weekdays = [2]
        let monday = try XCTUnwrap(calendar.date(from:DateComponents(year:2026,month:11,day:16,hour:20)))
        let next = try XCTUnwrap(policy.next(after:monday,calendar:calendar))
        XCTAssertGreaterThan(next,monday)
        XCTAssertEqual(calendar.component(.weekday,from:next),2)
        XCTAssertEqual(calendar.component(.hour,from:next),19)
        XCTAssertEqual(calendar.component(.day,from:next),23)
    }
    func testShutdownRequiresCurrentSuccessfulCycleAndEmptyQueue() {
        let slot = Date()
        func permitted(start:Date,state:String="completed",errors:Int=0,deferred:Int=0,empty:Bool=true,ready:Bool=true) -> Bool {
            FinalShutdownPolicy.mayRequestShutdown(slot:slot,cycleStarted:start,cycleState:state,
                errors:errors,deferred:deferred,queueEmpty:empty,monitorReady:ready)
        }
        XCTAssertTrue(permitted(start:slot))
        XCTAssertFalse(permitted(start:slot.addingTimeInterval(-1)))
        XCTAssertFalse(permitted(start:slot,state:"suspended"))
        XCTAssertFalse(permitted(start:slot,state:"completed_history_incomplete"))
        XCTAssertFalse(permitted(start:slot,errors:1))
        XCTAssertFalse(permitted(start:slot,deferred:1))
        XCTAssertFalse(permitted(start:slot,empty:false))
        XCTAssertFalse(permitted(start:slot,ready:false))
    }
}
