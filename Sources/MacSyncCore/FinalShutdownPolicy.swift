import Foundation

/// Independent of the ordinary copy cadence. Never schedules a past slot.
public struct FinalShutdownPolicy: Codable, Equatable, Sendable {
    public var enabled = false
    public var hour = 19
    public var minute = 0
    public var weekdays: Set<Int> = [2,3,4,5,6]
    public init() {}
    public var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute) &&
        !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) }
    }
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, isValid else { return nil }
        return weekdays.compactMap { day in
            calendar.nextDate(after:date,
                matching:DateComponents(hour:hour,minute:minute,second:0,weekday:day),
                matchingPolicy:.nextTime,repeatedTimePolicy:.first,direction:.forward)
        }.min()
    }
    /// Reject an old, interrupted, partial or unrecorded cycle and any pending work.
    public static func mayRequestShutdown(slot: Date, cycleStarted: Date, cycleState: String,
                                          errors: Int, deferred: Int, queueEmpty: Bool,
                                          monitorReady: Bool) -> Bool {
        cycleStarted >= slot && cycleState == "completed" && errors == 0 && deferred == 0 &&
        queueEmpty && monitorReady
    }
}
