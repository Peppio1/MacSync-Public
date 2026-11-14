import Foundation
import XCTest
@testable import MacSyncCore

final class SyncScheduleTests: XCTestCase {
    private var rome: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        return cal
    }
    private func local(_ year: Int, _ month: Int, _ day: Int,
                       _ hour: Int, _ minute: Int) -> Date {
        rome.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute
        ))!
    }
    private func schedule(_ mode: SyncSchedule.Frequency, _ interval: Int = 5,
                          _ h: Int = 9, _ m: Int = 0, _ weekday: Int = 2) -> SyncSchedule {
        SyncSchedule(
            frequency: mode, interval: interval, hour: h, minute: m,
            weekday: weekday
        )
    }
    func testMinuteAndHourBoundaries() {
        XCTAssertTrue(schedule(.minutes, 1).isValid)
        XCTAssertTrue(schedule(.minutes, 45).isValid)
        XCTAssertFalse(schedule(.minutes, 0).isValid)
        XCTAssertFalse(schedule(.minutes, 46).isValid)
        XCTAssertTrue(schedule(.hours, 1).isValid)
        XCTAssertTrue(schedule(.hours, 12).isValid)
        XCTAssertFalse(schedule(.hours, 13).isValid)
        XCTAssertFalse(schedule(.hours, 0).isValid)
        let now = local(2026, 11, 14, 10, 15)
        XCTAssertEqual(schedule(.minutes, 5).next(after: now), now.addingTimeInterval(300))
        XCTAssertEqual(schedule(.hours, 12).next(after: now), now.addingTimeInterval(12*3600))
    }

    func testDailyFiresAtNextLocalTimeAndWeeklyAtSelectedDay() {
        let now = local(2026, 11, 14, 10, 15) // Saturday
        XCTAssertEqual(schedule(.daily, 1, 9, 30).next(after: now, calendar: rome),
                       local(2026, 11, 15, 9, 30))
        XCTAssertEqual(schedule(.daily, 1, 11, 30).next(after: now, calendar: rome),
                       local(2026, 11, 14, 11, 30))
        XCTAssertEqual(schedule(.weekly, 1, 8, 15, 2).next(after: now, calendar: rome),
                       local(2026, 11, 16, 8, 15)) // Monday
        XCTAssertEqual(schedule(.weekly, 1, 11, 30, 7).next(after: now, calendar: rome),
                       local(2026, 11, 14, 11, 30)) // Saturday
    }

    func testWeeklyDoesNotRepeatWhenTimePassedToday() {
        let now = local(2026, 11, 16, 10, 00) // Monday
        XCTAssertEqual(schedule(.weekly, 5, 9, 00, 2).next(after: now, calendar: rome),
                       local(2026, 11, 23, 9, 00))
    }

    func testBadTimeValuesNeverSchedule() {
        XCTAssertFalse(schedule(.daily, 1, 24, 0).isValid)
        XCTAssertFalse(schedule(.weekly, 1, 9, 60).isValid)
        XCTAssertFalse(schedule(.weekly, 1, 9, 0, 0).isValid)
        XCTAssertNil(schedule(.weekly, 1, 9, 0, 8).next(after: Date()))
    }

    func testDSTStillUsesLocalClock() {
        // European winter/summer time transition, with a normal 09:00 choice
        let before = local(2027, 3, 27, 10, 0)
        XCTAssertEqual(schedule(.daily, 1, 9, 0).next(after: before, calendar: rome),
                       local(2027, 3, 28, 9, 0))
        let expectedAfter = local(2027, 3, 29, 9, 0)
        let next = schedule(.daily, 1, 9, 0)
            .next(after: local(2027, 3, 28, 9, 1), calendar: rome)
        XCTAssertEqual(next, expectedAfter)
    }

    func testEncodingAndDescription() throws {
        let original = schedule(.weekly, 1, 8, 15, 2)
        XCTAssertEqual(try JSONDecoder().decode(
            SyncSchedule.self, from: JSONEncoder().encode(original)
        ), original)
        XCTAssertEqual(original.summary, "Ogni lunedì alle 08:15")
        XCTAssertTrue(ConnectionAlertPolicy(enabled: true, afterHours: 168).isValid)
        XCTAssertFalse(ConnectionAlertPolicy(enabled: true, afterHours: 0).isValid)
    }
}

final class ConnectionOutageTrackerTests: XCTestCase {
    func testNotBeforeThresholdAndOnlyOnce() {
        var tracker = ConnectionOutageTracker()
        let policy = ConnectionAlertPolicy(enabled: true, afterHours: 2)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(tracker.record(["photos": .unavailable], at: t0, policy: policy), [])
        XCTAssertEqual(tracker.record(
            ["photos": .unavailable], at: t0.addingTimeInterval(7199),
            policy: policy
        ), [])
        XCTAssertEqual(tracker.record(
            ["photos": .unavailable], at: t0.addingTimeInterval(7200),
            policy: policy
        ), ["photos"])
        XCTAssertEqual(tracker.record(
            ["photos": .unavailable], at: t0.addingTimeInterval(36000),
            policy: policy
        ), [])
        XCTAssertEqual(tracker.record(
            ["photos": .ready], at: t0.addingTimeInterval(36001),
            policy: policy
        ), [])
        XCTAssertEqual(tracker.record(
            ["photos": .unavailable], at: t0.addingTimeInterval(36002),
            policy: policy
        ), [])
    }

    func testIndependentDestinationsAndDisabledAlerts() throws {
        let p = ConnectionAlertPolicy(enabled: true, afterHours: 1)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        var tracker = ConnectionOutageTracker()
        _ = tracker.record(["A": .unavailable, "B": .ready], at: t, policy: p)
        _ = tracker.record(
            ["A": .unavailable, "B": .unavailable],
            at: t.addingTimeInterval(1800), policy: p
        )
        XCTAssertEqual(tracker.record(
            ["A": .unavailable, "B": .unavailable],
            at: t.addingTimeInterval(3700), policy: p
        ), ["A"])
        XCTAssertEqual(tracker.record(
            ["A": .unavailable, "B": .unavailable],
            at: t.addingTimeInterval(5400), policy: p
        ), ["B"])
        let data = try JSONEncoder().encode(tracker)
        var recovered = try JSONDecoder().decode(ConnectionOutageTracker.self, from: data)
        XCTAssertEqual(recovered.record(
            ["A": .unavailable, "B": .unavailable],
            at: t.addingTimeInterval(10800), policy: p
        ), [])
        XCTAssertEqual(recovered.record(
            ["A": .unavailable], at: t.addingTimeInterval(10860),
            policy: ConnectionAlertPolicy(enabled: false, afterHours: 1)
        ), [])
        XCTAssertNil(recovered.firstObserved(for: "A"))
    }

    func testNoAlertForUnconfiguredOrUnverifiedFolders() {
        var tracker = ConnectionOutageTracker()
        let p = ConnectionAlertPolicy(enabled: true, afterHours: 1)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        _ = tracker.record(["A": .notConfigured, "B": .unverified],
                           at: t, policy: p)
        XCTAssertTrue(tracker.record(["A": .notConfigured, "B": .unverified],
                         at: t.addingTimeInterval(7200), policy: p).isEmpty)
        XCTAssertTrue(tracker.outages.isEmpty)
    }
}
