import Testing
import Foundation
@testable import TimeJournal

private func weekTestCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    cal.locale = Locale(identifier: "en_US")
    return cal
}

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    weekTestCalendar().date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

@MainActor
private func makeState(now: @escaping () -> Date) -> AppState {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
    return AppState(storage: Storage(url: dir.appendingPathComponent("store.json")),
                    now: now,
                    calendar: weekTestCalendar())
}

@MainActor
struct AppStateSessionEditTests {
    @Test func updateReplacesTheSessionInPlace() throws {
        var clock = at(2026, 2, 4, 9, 0)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")
        state.start(projectID: project.id)
        clock = at(2026, 2, 4, 21, 0)      // "left it running all day"
        state.stop()

        var session = try #require(state.store.sessions.first)
        session.end = at(2026, 2, 4, 11, 0)
        session.note = "fixed ch.3"
        state.updateSession(session)

        #expect(state.store.sessions.count == 1)
        // `as TimeInterval` is load-bearing: inside #expect, an optional-chained Double
        // compared against compound integer-literal arithmetic gets the right side boxed
        // as Int rather than promoted to Double, and the expectation fails on a correct
        // value. A bare literal (== 7200) or a non-optional receiver would be fine.
        #expect(state.store.sessions.first?.duration == 2 * 3600 as TimeInterval)
        #expect(state.store.sessions.first?.note == "fixed ch.3")
        #expect(try state.storage.load().sessions.first?.note == "fixed ch.3")
    }

    @Test func deleteRemovesOnlyThatSession() {
        var clock = at(2026, 2, 2, 9, 0)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")
        state.start(projectID: project.id)
        clock = at(2026, 2, 2, 10, 0)
        state.stop()
        state.start(projectID: project.id)
        clock = at(2026, 2, 2, 12, 0)
        state.stop()

        let first = state.store.sessions[0].id
        state.deleteSession(first)

        #expect(state.store.sessions.count == 1)
        #expect(state.store.sessions.first?.id != first)
    }
}

@MainActor
struct AppStateWeekNavigationTests {
    @Test func opensOnTheCurrentWeek() {
        let state = makeState(now: { at(2026, 2, 4, 15, 0) })   // a Wednesday
        #expect(state.displayedWeekStart == at(2026, 2, 2))
        #expect(state.isCurrentWeek)
        #expect(state.weekLabel == "Feb 2 – 8")
    }

    @Test func pagingMovesByWholeWeeks() {
        let state = makeState(now: { at(2026, 2, 4, 15, 0) })

        state.goToWeek(offset: -1)
        #expect(state.displayedWeekStart == at(2026, 1, 26))
        #expect(!state.isCurrentWeek)

        state.goToWeek(offset: 1)
        #expect(state.displayedWeekStart == at(2026, 2, 2))
        #expect(state.isCurrentWeek)

        state.goToWeek(offset: -3)
        state.goToCurrentWeek()
        #expect(state.displayedWeekStart == at(2026, 2, 2))
    }

    @Test func derivedTotalsFollowTheDisplayedWeek() {
        var clock = at(2026, 2, 3, 9, 0)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")

        // One hour on Tue Feb 3 (current week).
        state.start(projectID: project.id)
        clock = at(2026, 2, 3, 10, 0)
        state.stop()

        // Two hours on Tue Jan 27 (previous week).
        clock = at(2026, 1, 27, 9, 0)
        state.start(projectID: project.id)
        clock = at(2026, 1, 27, 11, 0)
        state.stop()

        clock = at(2026, 2, 3, 12, 0)
        #expect(state.weekTotal == 3600)
        #expect(state.dayTotals.count == 7)
        #expect(state.dayTotals[1].seconds == 3600)
        #expect(state.weekSessions.count == 1)

        state.goToWeek(offset: -1)
        #expect(state.weekTotal == 2 * 3600)
        #expect(state.dayTotals[1].seconds == 2 * 3600)
        #expect(state.weekSessions.count == 1)
    }

    @Test func weekSessionsAreNewestFirst() {
        var clock = at(2026, 2, 2, 9, 0)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")
        state.start(projectID: project.id)
        clock = at(2026, 2, 2, 10, 0)
        state.stop()
        clock = at(2026, 2, 5, 9, 0)
        state.start(projectID: project.id)
        clock = at(2026, 2, 5, 10, 0)
        state.stop()

        #expect(state.weekSessions.map(\.start) == [at(2026, 2, 5, 9, 0), at(2026, 2, 2, 9, 0)])
    }

    @Test func derivedValuesAreEmptyWithNoProjectSelected() {
        let state = makeState(now: { at(2026, 2, 4, 15, 0) })
        #expect(state.weekTotal == 0)
        #expect(state.weekSessions.isEmpty)
        #expect(state.dayTotals.count == 7)
        #expect(state.dayTotals.allSatisfy { $0.seconds == 0 })
    }
}
