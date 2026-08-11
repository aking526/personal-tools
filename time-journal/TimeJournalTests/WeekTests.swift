import Testing
import Foundation
@testable import TimeJournal

/// Pinned to a fixed zone so results never depend on the machine running the tests.
private func testCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    cal.locale = Locale(identifier: "en_US")
    return cal
}

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

struct WeekTests {
    @Test func weekStartsOnMonday() {
        let cal = testCalendar()
        let monday = at(2026, 2, 2, 0, 0, cal)
        // Every day Mon–Sun resolves to the same Monday.
        for day in 2...8 {
            #expect(Week.start(of: at(2026, 2, day, 13, 30, cal), calendar: cal) == monday)
        }
        // The next Monday belongs to the next week.
        #expect(Week.start(of: at(2026, 2, 9, 0, 0, cal), calendar: cal) == at(2026, 2, 9, 0, 0, cal))
    }

    @Test func daysReturnsSevenMidnights() {
        let cal = testCalendar()
        let days = Week.days(from: at(2026, 2, 2, 0, 0, cal), calendar: cal)
        #expect(days.count == 7)
        #expect(days.first == at(2026, 2, 2, 0, 0, cal))
        #expect(days.last == at(2026, 2, 8, 0, 0, cal))
    }

    /// 2026-03-08 is a Sunday and the US spring-forward date, so that day is 23 hours long.
    /// Any implementation that advances days by adding 86400 seconds fails this.
    @Test func dayMathSurvivesDaylightSaving() {
        let cal = testCalendar()
        let sunday = at(2026, 3, 8, 0, 0, cal)
        #expect(at(2026, 3, 9, 0, 0, cal).timeIntervalSince(sunday) == 23 * 3600)

        let weekStart = Week.start(of: sunday, calendar: cal)
        #expect(weekStart == at(2026, 3, 2, 0, 0, cal))

        let days = Week.days(from: weekStart, calendar: cal)
        #expect(days.last == sunday)
        #expect(days.allSatisfy { cal.component(.hour, from: $0) == 0 })
    }

    @Test func shiftMovesWholeWeeks() {
        let cal = testCalendar()
        let feb2 = at(2026, 2, 2, 0, 0, cal)
        #expect(Week.shift(feb2, byWeeks: -1, calendar: cal) == at(2026, 1, 26, 0, 0, cal))
        #expect(Week.shift(feb2, byWeeks: 1, calendar: cal) == at(2026, 2, 9, 0, 0, cal))
        // Crossing the DST boundary still lands on a midnight.
        let mar2 = at(2026, 3, 2, 0, 0, cal)
        #expect(Week.shift(mar2, byWeeks: 1, calendar: cal) == at(2026, 3, 9, 0, 0, cal))
    }

    @Test func labelCollapsesSharedMonth() {
        let cal = testCalendar()
        #expect(Week.label(weekStart: at(2026, 2, 2, 0, 0, cal), calendar: cal) == "Feb 2 – 8")
        #expect(Week.label(weekStart: at(2026, 1, 26, 0, 0, cal), calendar: cal) == "Jan 26 – Feb 1")
    }
}

struct StatsTests {
    private let projectA = UUID()
    private let projectB = UUID()

    @Test func bucketsSessionsIntoDays() {
        let cal = testCalendar()
        let weekStart = at(2026, 2, 2, 0, 0, cal)
        let sessions = [
            Session(projectID: projectA, start: at(2026, 2, 2, 9, 0, cal), end: at(2026, 2, 2, 11, 0, cal)),
            Session(projectID: projectA, start: at(2026, 2, 2, 14, 0, cal), end: at(2026, 2, 2, 14, 10, cal)),
            Session(projectID: projectA, start: at(2026, 2, 4, 9, 0, cal), end: at(2026, 2, 4, 12, 5, cal)),
        ]
        let totals = Stats.dayTotals(sessions: sessions, projectID: projectA, weekStart: weekStart, calendar: cal)

        #expect(totals.count == 7)
        #expect(totals[0].seconds == 2 * 3600 + 600)   // Monday: both sessions summed
        #expect(totals[1].seconds == 0)                 // Tuesday: empty days still appear
        #expect(totals[2].seconds == 3 * 3600 + 300)    // Wednesday
        #expect(Stats.weekTotal(sessions: sessions, projectID: projectA, weekStart: weekStart, calendar: cal)
                == 5 * 3600 + 900)
    }

    @Test func ignoresOtherProjectsAndOtherWeeks() {
        let cal = testCalendar()
        let weekStart = at(2026, 2, 2, 0, 0, cal)
        let sessions = [
            Session(projectID: projectA, start: at(2026, 2, 3, 9, 0, cal), end: at(2026, 2, 3, 10, 0, cal)),
            Session(projectID: projectB, start: at(2026, 2, 3, 9, 0, cal), end: at(2026, 2, 3, 15, 0, cal)),
            Session(projectID: projectA, start: at(2026, 1, 30, 9, 0, cal), end: at(2026, 1, 30, 15, 0, cal)),
            Session(projectID: projectA, start: at(2026, 2, 9, 9, 0, cal), end: at(2026, 2, 9, 15, 0, cal)),
        ]
        #expect(Stats.weekTotal(sessions: sessions, projectID: projectA, weekStart: weekStart, calendar: cal) == 3600)
    }

    /// A session is attributed entirely to the day it STARTED on. An overnight session
    /// counts against the earlier day rather than being split across two.
    @Test func overnightSessionCountsOnItsStartDay() {
        let cal = testCalendar()
        let weekStart = at(2026, 2, 2, 0, 0, cal)
        let sessions = [
            Session(projectID: projectA, start: at(2026, 2, 3, 23, 30, cal), end: at(2026, 2, 4, 0, 30, cal))
        ]
        let totals = Stats.dayTotals(sessions: sessions, projectID: projectA, weekStart: weekStart, calendar: cal)
        #expect(totals[1].seconds == 3600)   // Tuesday, the start day
        #expect(totals[2].seconds == 0)      // Wednesday untouched
    }

    @Test func dayTotalSumsOneDayOnly() {
        let cal = testCalendar()
        let sessions = [
            Session(projectID: projectA, start: at(2026, 2, 3, 9, 0, cal), end: at(2026, 2, 3, 10, 0, cal)),
            Session(projectID: projectA, start: at(2026, 2, 3, 14, 0, cal), end: at(2026, 2, 3, 14, 30, cal)),
            Session(projectID: projectB, start: at(2026, 2, 3, 8, 0, cal), end: at(2026, 2, 3, 12, 0, cal)),
            Session(projectID: projectA, start: at(2026, 2, 4, 9, 0, cal), end: at(2026, 2, 4, 17, 0, cal)),
            Session(projectID: projectA, start: at(2026, 2, 2, 9, 0, cal), end: at(2026, 2, 2, 17, 0, cal)),
        ]
        // The time of day asked about doesn't matter — the whole day is counted, including work
        // logged later in it.
        for hour in [0, 9, 23] {
            #expect(Stats.dayTotal(sessions: sessions,
                                   projectID: projectA,
                                   day: at(2026, 2, 3, hour, 0, cal),
                                   calendar: cal) == 3600 + 1800)
        }
        // A day with nothing on it is zero, not the neighbouring days bleeding in.
        #expect(Stats.dayTotal(sessions: sessions,
                               projectID: projectA,
                               day: at(2026, 2, 5, 12, 0, cal),
                               calendar: cal) == 0)
    }

    /// Same rule as the week: the day a session started on owns all of it.
    @Test func dayTotalCountsAnOvernightSessionOnItsStartDay() {
        let cal = testCalendar()
        let sessions = [
            Session(projectID: projectA, start: at(2026, 2, 3, 23, 30, cal), end: at(2026, 2, 4, 1, 30, cal))
        ]
        #expect(Stats.dayTotal(sessions: sessions, projectID: projectA,
                               day: at(2026, 2, 3, 12, 0, cal), calendar: cal) == 2 * 3600)
        #expect(Stats.dayTotal(sessions: sessions, projectID: projectA,
                               day: at(2026, 2, 4, 12, 0, cal), calendar: cal) == 0)
    }

    /// The 23-hour spring-forward day: adding a day beats adding 86,400 seconds, which would
    /// stretch the window an hour into the Monday after and pull its first session in.
    @Test func dayTotalSurvivesDaylightSaving() {
        let cal = testCalendar()
        let sessions = [
            Session(projectID: projectA, start: at(2026, 3, 8, 1, 30, cal), end: at(2026, 3, 8, 3, 30, cal)),
            Session(projectID: projectA, start: at(2026, 3, 9, 0, 15, cal), end: at(2026, 3, 9, 1, 15, cal)),
        ]
        #expect(Stats.dayTotal(sessions: sessions, projectID: projectA,
                               day: at(2026, 3, 8, 12, 0, cal), calendar: cal) == 3600)
    }

    @Test func weekTotalSurvivesDaylightSaving() {
        let cal = testCalendar()
        let weekStart = at(2026, 3, 2, 0, 0, cal)
        // Sunday 2026-03-08 is the 23-hour day; a session spanning the skipped hour
        // is one hour of wall time, not two.
        let sessions = [
            Session(projectID: projectA, start: at(2026, 3, 8, 1, 30, cal), end: at(2026, 3, 8, 3, 30, cal))
        ]
        let totals = Stats.dayTotals(sessions: sessions, projectID: projectA, weekStart: weekStart, calendar: cal)
        #expect(totals[6].seconds == 3600)
    }
}
