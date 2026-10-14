import Foundation

public enum ScheduleMode: String, Codable, CaseIterable, Sendable {
    case always, scheduled, off
}

/// A window on chosen weekdays, e.g. Mon–Fri 08:00–18:00. When `endMinute` is
/// earlier than `startMinute` the window runs past midnight into the next day;
/// when they're equal it covers the whole day.
public struct ScheduleRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    /// Minutes after midnight, 0..<1440.
    public var startMinute: Int
    public var endMinute: Int

    public init(id: UUID = UUID(), weekdays: Set<Int>, startMinute: Int, endMinute: Int) {
        self.id = id
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public static let everyDay: Set<Int> = Set(1...7)
    public static let weekdaysOnly: Set<Int> = Set(2...6)

    func contains(weekday: Int, minute: Int) -> Bool {
        if startMinute == endMinute {
            return weekdays.contains(weekday)
        }
        if startMinute < endMinute {
            return weekdays.contains(weekday) && minute >= startMinute && minute < endMinute
        }
        // Crosses midnight: the late part of a chosen day, or the early part of
        // the day after one.
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        return (weekdays.contains(weekday) && minute >= startMinute)
            || (weekdays.contains(previousWeekday) && minute < endMinute)
    }
}

public struct Schedule: Codable, Hashable, Sendable {
    public var mode: ScheduleMode
    public var rules: [ScheduleRule]

    public init(mode: ScheduleMode, rules: [ScheduleRule]) {
        self.mode = mode
        self.rules = rules
    }

    public static let `default` = Schedule(
        mode: .scheduled,
        rules: [ScheduleRule(weekdays: ScheduleRule.everyDay, startMinute: 8 * 60, endMinute: 22 * 60)]
    )

    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        switch mode {
        case .always: return true
        case .off: return false
        case .scheduled:
            let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
            guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
            let minuteOfDay = hour * 60 + minute
            return rules.contains { $0.contains(weekday: weekday, minute: minuteOfDay) }
        }
    }

    /// The next moment after `date` when `isActive` changes, or nil if it never
    /// does (always/off mode, or no rules).
    public func nextTransition(after date: Date, calendar: Calendar = .current) -> Date? {
        guard mode == .scheduled, !rules.isEmpty else { return nil }
        let current = isActive(at: date, calendar: calendar)
        let today = calendar.startOfDay(for: date)
        var candidates: [Date] = []
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            candidates.append(day)
            for rule in rules {
                for minute in [rule.startMinute, rule.endMinute] {
                    if let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) {
                        candidates.append(time)
                    }
                }
            }
        }
        return candidates
            .filter { $0 > date }
            .sorted()
            .first { isActive(at: $0, calendar: calendar) != current }
    }
}

/// A temporary manual override from the menu.
public enum ActivityOverride: Codable, Hashable, Sendable {
    case keepAwake(until: Date)
    case pause(until: Date)

    public var until: Date {
        switch self {
        case .keepAwake(let until), .pause(let until): until
        }
    }

    public var forcesActive: Bool {
        if case .keepAwake = self { return true }
        return false
    }
}

public struct ActivityDecision: Equatable, Sendable {
    public var isActive: Bool
    /// The override still in effect, if any.
    public var override: ActivityOverride?
    /// When the decision may next change, for display.
    public var changesAt: Date?
}

public enum ActivityPolicy {
    public static func decide(schedule: Schedule, override: ActivityOverride?, now: Date, calendar: Calendar = .current) -> ActivityDecision {
        if let override, override.until > now {
            return ActivityDecision(isActive: override.forcesActive, override: override, changesAt: override.until)
        }
        return ActivityDecision(
            isActive: schedule.isActive(at: now, calendar: calendar),
            override: nil,
            changesAt: schedule.nextTransition(after: now, calendar: calendar)
        )
    }
}
