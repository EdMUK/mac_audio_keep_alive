import Foundation
import Testing
@testable import KeepAliveCore

private let london: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
}()

/// A London local time. 2026-10-12 is a Monday.
private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    london.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite struct ScheduleTests {
    let weekdays9to5 = Schedule(mode: .scheduled, rules: [
        ScheduleRule(weekdays: ScheduleRule.weekdaysOnly, startMinute: 9 * 60, endMinute: 17 * 60),
    ])

    @Test func alwaysAndOffIgnoreRules() {
        var schedule = weekdays9to5
        schedule.mode = .always
        #expect(schedule.isActive(at: date(2026, 10, 18, 3), calendar: london))
        #expect(schedule.nextTransition(after: date(2026, 10, 18, 3), calendar: london) == nil)
        schedule.mode = .off
        #expect(!schedule.isActive(at: date(2026, 10, 12, 12), calendar: london))
    }

    @Test func weekdayWindow() {
        #expect(!weekdays9to5.isActive(at: date(2026, 10, 12, 8, 59), calendar: london))
        #expect(weekdays9to5.isActive(at: date(2026, 10, 12, 9), calendar: london))
        #expect(weekdays9to5.isActive(at: date(2026, 10, 12, 16, 59), calendar: london))
        #expect(!weekdays9to5.isActive(at: date(2026, 10, 12, 17), calendar: london))
        // Saturday
        #expect(!weekdays9to5.isActive(at: date(2026, 10, 17, 12), calendar: london))
    }

    @Test func windowCrossingMidnight() {
        // Fridays 20:00 – 02:00
        let schedule = Schedule(mode: .scheduled, rules: [ScheduleRule(weekdays: [6], startMinute: 20 * 60, endMinute: 2 * 60)])
        #expect(schedule.isActive(at: date(2026, 10, 16, 23), calendar: london))
        #expect(schedule.isActive(at: date(2026, 10, 17, 1, 30), calendar: london))
        #expect(!schedule.isActive(at: date(2026, 10, 17, 2), calendar: london))
        // Early Friday morning belongs to Thursday, which isn't selected.
        #expect(!schedule.isActive(at: date(2026, 10, 16, 1), calendar: london))
        #expect(schedule.nextTransition(after: date(2026, 10, 16, 23), calendar: london) == date(2026, 10, 17, 2))
    }

    @Test func saturdayNightWrapsToSunday() {
        let schedule = Schedule(mode: .scheduled, rules: [ScheduleRule(weekdays: [7], startMinute: 22 * 60, endMinute: 60)])
        #expect(schedule.isActive(at: date(2026, 10, 18, 0, 30), calendar: london))
    }

    @Test func equalStartAndEndMeansAllDay() {
        let schedule = Schedule(mode: .scheduled, rules: [ScheduleRule(weekdays: [1], startMinute: 0, endMinute: 0)])
        #expect(schedule.isActive(at: date(2026, 10, 18, 0), calendar: london))
        #expect(schedule.isActive(at: date(2026, 10, 18, 23, 59), calendar: london))
        #expect(!schedule.isActive(at: date(2026, 10, 19, 0), calendar: london))
        #expect(schedule.nextTransition(after: date(2026, 10, 18, 12), calendar: london) == date(2026, 10, 19, 0))
    }

    @Test func nextTransitionSkipsWeekend() {
        // Friday 17:00 end -> next start Monday 09:00
        #expect(weekdays9to5.nextTransition(after: date(2026, 10, 16, 12), calendar: london) == date(2026, 10, 16, 17))
        #expect(weekdays9to5.nextTransition(after: date(2026, 10, 16, 17), calendar: london) == date(2026, 10, 19, 9))
    }

    @Test func overlappingRulesMerge() {
        let schedule = Schedule(mode: .scheduled, rules: [
            ScheduleRule(weekdays: ScheduleRule.everyDay, startMinute: 9 * 60, endMinute: 12 * 60),
            ScheduleRule(weekdays: ScheduleRule.everyDay, startMinute: 11 * 60, endMinute: 14 * 60),
        ])
        // 12:00 is the end of one rule but inside the other, so not a transition.
        #expect(schedule.nextTransition(after: date(2026, 10, 12, 10), calendar: london) == date(2026, 10, 12, 14))
    }

    @Test func noRulesNeverActive() {
        let schedule = Schedule(mode: .scheduled, rules: [])
        #expect(!schedule.isActive(at: date(2026, 10, 12, 12), calendar: london))
        #expect(schedule.nextTransition(after: date(2026, 10, 12, 12), calendar: london) == nil)
    }

    @Test func clocksGoingBack() {
        // UK clocks go back at 02:00 BST on 2026-10-25, so 01:00–02:00 happens twice.
        let schedule = Schedule(mode: .scheduled, rules: [ScheduleRule(weekdays: ScheduleRule.everyDay, startMinute: 8 * 60, endMinute: 22 * 60)])
        let saturdayNight = date(2026, 10, 24, 23)
        let next = schedule.nextTransition(after: saturdayNight, calendar: london)
        #expect(next == date(2026, 10, 25, 8))
        #expect(next!.timeIntervalSince(saturdayNight) == 10 * 3600)
    }

    @Test func clocksGoingForward() {
        // UK clocks go forward at 01:00 GMT on 2026-03-29; 01:30 doesn't exist.
        let schedule = Schedule(mode: .scheduled, rules: [ScheduleRule(weekdays: ScheduleRule.everyDay, startMinute: 90, endMinute: 6 * 60)])
        let next = schedule.nextTransition(after: date(2026, 3, 29, 0), calendar: london)
        #expect(next != nil)
        #expect(schedule.isActive(at: next!, calendar: london))
        #expect(next! < date(2026, 3, 29, 6))
    }

    @Test func overrideWinsUntilExpiry() {
        let now = date(2026, 10, 12, 23)
        let keepAwake = ActivityOverride.keepAwake(until: date(2026, 10, 13, 0))
        let decision = ActivityPolicy.decide(schedule: weekdays9to5, override: keepAwake, now: now, calendar: london)
        #expect(decision.isActive)
        #expect(decision.override == keepAwake)
        #expect(decision.changesAt == date(2026, 10, 13, 0))

        let expired = ActivityPolicy.decide(schedule: weekdays9to5, override: keepAwake, now: date(2026, 10, 13, 0, 1), calendar: london)
        #expect(!expired.isActive)
        #expect(expired.override == nil)
        #expect(expired.changesAt == date(2026, 10, 13, 9))
    }

    @Test func pauseOverride() {
        let pause = ActivityOverride.pause(until: date(2026, 10, 12, 17))
        let decision = ActivityPolicy.decide(schedule: weekdays9to5, override: pause, now: date(2026, 10, 12, 12), calendar: london)
        #expect(!decision.isActive)
    }

    @Test func scheduleRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(weekdays9to5)
        #expect(try JSONDecoder().decode(Schedule.self, from: data) == weekdays9to5)
    }
}
