import Foundation

/// All scheduling uses the current macOS user's local calendar/time zone.
/// Daily/weekly selections refer to wall-clock time, not elapsed seconds.
public struct SyncSchedule: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case minutes, hours, daily, weekly
    }

    public var frequency: Frequency
    /// Minutes: 1...45; hours: 1...12. Ignored for daily/weekly.
    public var interval: Int
    /// Local wall-clock hour: 0...23.
    public var hour: Int
    /// Local wall-clock minute: 0...59.
    public var minute: Int
    /// Gregorian Calendar weekday: Sunday=1, Monday=2, ... Saturday=7.
    public var weekday: Int

    public static let standard = SyncSchedule(
        frequency: .minutes, interval: 5, hour: 9, minute: 0, weekday: 2
    )

    public init(frequency: Frequency, interval: Int, hour: Int,
                minute: Int, weekday: Int) {
        self.frequency = frequency
        self.interval = interval
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
    }

    public var isValid: Bool {
        guard (0...23).contains(hour), (0...59).contains(minute),
              (1...7).contains(weekday) else { return false }
        switch frequency {
        case .minutes: return (1...45).contains(interval)
        case .hours: return (1...12).contains(interval)
        case .daily, .weekly: return true
        }
    }

    /// Next strictly future scheduled run. If a computer sleeps through a
    /// scheduled point, skip missed occurrences rather than issuing a burst
    /// of backups/copies when it wakes.
    public func next(after now: Date, calendar: Calendar = .current) -> Date? {
        guard isValid else { return nil }
        switch frequency {
        case .minutes:
            return now.addingTimeInterval(TimeInterval(interval) * 60)
        case .hours:
            return now.addingTimeInterval(TimeInterval(interval) * 3_600)
        case .daily:
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: minute, second: 0),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                direction: .forward
            )
        case .weekly:
            return calendar.nextDate(
                after: now,
                matching: DateComponents(
                    hour: hour, minute: minute, second: 0, weekday: weekday
                ),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                direction: .forward
            )
        }
    }

    public var summary: String {
        switch frequency {
        case .minutes: return "Ogni \(interval) minuti"
        case .hours: return "Ogni \(interval) ore"
        case .daily: return "Ogni giorno alle \(clock)"
        case .weekly: return "Ogni \(weekdayName) alle \(clock)"
        }
    }

    public var clock: String { String(format: "%02d:%02d", hour, minute) }

    public var weekdayName: String {
        switch weekday {
        case 1: return "domenica"
        case 2: return "lunedì"
        case 3: return "martedì"
        case 4: return "mercoledì"
        case 5: return "giovedì"
        case 6: return "venerdì"
        default: return "sabato"
        }
    }
}

/// Observable, persisted preferences are implemented in the application
/// module; pure schedule validation can be tested without a macOS UI.
public struct ConnectionAlertPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var afterHours: Int

    public init(enabled: Bool = false, afterHours: Int = 2) {
        self.enabled = enabled
        self.afterHours = afterHours
    }

    public var isValid: Bool { (1...168).contains(afterHours) }
}
