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

/// The fraction of a day a wall-clock time sits at — the same arithmetic the layout does.
private func fraction(_ hour: Int, _ minute: Int = 0) -> Double {
    Double(hour * 3600 + minute * 60) / 86_400
}

@Suite struct DayLayoutTests {
    private let project = UUID()
    /// Monday 2 Feb 2026.
    private var weekStart: Date { at(2026, 2, 2, 0, 0, testCalendar()) }

    @Test func positionsASessionByTheWallClock() throws {
        let cal = testCalendar()
        let session = Session(projectID: project,
                              start: at(2026, 2, 2, 9, 30, cal),
                              end: at(2026, 2, 2, 10, 42, cal))

        let blocks = DayLayout.blocks(sessions: [session], weekStart: weekStart, calendar: cal)

        let block = try #require(blocks.first)
        #expect(blocks.count == 1)
        #expect(block.dayIndex == 0)
        #expect(block.start == fraction(9, 30))
        #expect(block.end == fraction(10, 42))
        #expect(block.lane == 0)
        #expect(block.laneCount == 1)
        #expect(!block.isContinuation)
    }

    @Test func placesEachDayInItsOwnColumn() {
        let cal = testCalendar()
        let sessions = [
            Session(projectID: project, start: at(2026, 2, 2, 9, 0, cal), end: at(2026, 2, 2, 10, 0, cal)),
            Session(projectID: project, start: at(2026, 2, 8, 9, 0, cal), end: at(2026, 2, 8, 10, 0, cal)),
        ]
        let blocks = DayLayout.blocks(sessions: sessions, weekStart: weekStart, calendar: cal)
        #expect(blocks.map(\.dayIndex) == [0, 6])   // Monday and Sunday
    }

    /// The bars attribute an overnight session wholly to its start day; the calendar has to
    /// draw it where it actually happened, which is both days.
    @Test func splitsAnOvernightSessionAtMidnight() {
        let cal = testCalendar()
        let session = Session(projectID: project,
                              start: at(2026, 2, 3, 23, 30, cal),
                              end: at(2026, 2, 4, 0, 30, cal))

        let blocks = DayLayout.blocks(sessions: [session], weekStart: weekStart, calendar: cal)

        #expect(blocks.count == 2)
        #expect(blocks[0].dayIndex == 1)
        #expect(blocks[0].start == fraction(23, 30))
        #expect(blocks[0].end == 1)             // runs to the bottom of Tuesday
        #expect(!blocks[0].isContinuation)
        #expect(blocks[1].dayIndex == 2)
        #expect(blocks[1].start == 0)           // and resumes at the top of Wednesday
        #expect(blocks[1].end == fraction(0, 30))
        #expect(blocks[1].isContinuation)
        // Two blocks of one session still need distinct identities.
        #expect(blocks[0].id != blocks[1].id)
    }

    @Test func clipsTheTailThatFallsOutsideTheWeek() {
        let cal = testCalendar()
        let session = Session(projectID: project,
                              start: at(2026, 2, 8, 23, 0, cal),   // Sunday night
                              end: at(2026, 2, 9, 1, 0, cal))      // into the next week

        let blocks = DayLayout.blocks(sessions: [session], weekStart: weekStart, calendar: cal)

        #expect(blocks.count == 1)
        #expect(blocks[0].dayIndex == 6)
        #expect(blocks[0].end == 1)
    }

    @Test func overlappingSessionsShareTheColumn() {
        let cal = testCalendar()
        let sessions = [
            Session(projectID: project, start: at(2026, 2, 2, 9, 0, cal), end: at(2026, 2, 2, 11, 0, cal)),
            Session(projectID: project, start: at(2026, 2, 2, 10, 0, cal), end: at(2026, 2, 2, 12, 0, cal)),
        ]
        let blocks = DayLayout.blocks(sessions: sessions, weekStart: weekStart, calendar: cal)

        #expect(blocks.count == 2)
        #expect(blocks.map(\.lane) == [0, 1])
        #expect(blocks.allSatisfy { $0.laneCount == 2 })
    }

    /// Width is shared only within a run of overlapping blocks: a double-booked morning must
    /// not halve an unrelated block that afternoon.
    @Test func separateClustersKeepTheFullWidth() {
        let cal = testCalendar()
        let sessions = [
            Session(projectID: project, start: at(2026, 2, 2, 9, 0, cal), end: at(2026, 2, 2, 11, 0, cal)),
            Session(projectID: project, start: at(2026, 2, 2, 10, 0, cal), end: at(2026, 2, 2, 12, 0, cal)),
            Session(projectID: project, start: at(2026, 2, 2, 15, 0, cal), end: at(2026, 2, 2, 16, 0, cal)),
        ]
        let blocks = DayLayout.blocks(sessions: sessions, weekStart: weekStart, calendar: cal)

        #expect(blocks.count == 3)
        #expect(blocks[2].lane == 0)
        #expect(blocks[2].laneCount == 1)
    }

    /// Back-to-back is not overlapping: 9–10 and 10–11 belong in the same lane, full width.
    @Test func touchingSessionsDoNotCountAsOverlap() {
        let cal = testCalendar()
        let sessions = [
            Session(projectID: project, start: at(2026, 2, 2, 9, 0, cal), end: at(2026, 2, 2, 10, 0, cal)),
            Session(projectID: project, start: at(2026, 2, 2, 10, 0, cal), end: at(2026, 2, 2, 11, 0, cal)),
        ]
        let blocks = DayLayout.blocks(sessions: sessions, weekStart: weekStart, calendar: cal)
        #expect(blocks.allSatisfy { $0.laneCount == 1 && $0.lane == 0 })
    }

    /// 2026-03-08 is the US spring-forward Sunday: 2 AM never happens. Positions are read off
    /// the wall clock, so blocks stay lined up with the hour labels beside them.
    @Test func positionsFollowTheWallClockThroughDaylightSaving() throws {
        let cal = testCalendar()
        let session = Session(projectID: project,
                              start: at(2026, 3, 8, 1, 30, cal),
                              end: at(2026, 3, 8, 3, 30, cal))   // one hour of real time

        let blocks = DayLayout.blocks(sessions: [session],
                                      weekStart: at(2026, 3, 2, 0, 0, cal),
                                      calendar: cal)

        let block = try #require(blocks.first)
        #expect(block.dayIndex == 6)
        #expect(block.start == fraction(1, 30))
        #expect(block.end == fraction(3, 30))
    }

    @Test func anEmptyWeekHasNoBlocks() {
        #expect(DayLayout.blocks(sessions: [], weekStart: weekStart, calendar: testCalendar()).isEmpty)
    }
}
