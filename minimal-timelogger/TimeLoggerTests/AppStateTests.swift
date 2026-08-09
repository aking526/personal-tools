import Testing
import Foundation
@testable import TimeLogger

@MainActor
private func makeState(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000_000) }) -> AppState {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeLoggerTests-\(UUID().uuidString)")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return AppState(storage: Storage(url: dir.appendingPathComponent("store.json")),
                    now: now,
                    calendar: cal)
}

@MainActor
struct AppStateTimerTests {
    @Test func startRecordsRunningTimerAndPersists() throws {
        let state = makeState()
        let project = state.addProject(name: "Thesis")

        state.start(projectID: project.id)

        #expect(state.store.running?.projectID == project.id)
        #expect(state.store.running?.start == Date(timeIntervalSince1970: 1_000_000))
        // Persisted immediately, so a crash cannot lose the in-flight session.
        #expect(try state.storage.load().running?.projectID == project.id)
    }

    @Test func stopConvertsRunningIntoASession() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")

        state.start(projectID: project.id)
        clock = Date(timeIntervalSince1970: 1_003_600)
        state.stop()

        #expect(state.store.running == nil)
        #expect(state.store.sessions.count == 1)
        let session = try! #require(state.store.sessions.first)
        #expect(session.projectID == project.id)
        #expect(session.duration == 3600)
        #expect(session.note == "")
        #expect(state.focusSessionID == session.id)
    }

    @Test func startingAnotherProjectStopsTheCurrentOne() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let a = state.addProject(name: "A")
        let b = state.addProject(name: "B")

        state.start(projectID: a.id)
        clock = Date(timeIntervalSince1970: 1_001_800)
        state.start(projectID: b.id)

        #expect(state.store.sessions.count == 1)
        #expect(state.store.sessions.first?.projectID == a.id)
        #expect(state.store.sessions.first?.duration == 1800)
        #expect(state.store.running?.projectID == b.id)
    }

    /// A mis-click should not litter the notes list with 0:00 entries.
    @Test func stopDiscardsSubSecondSessions() {
        let state = makeState()
        let project = state.addProject(name: "Thesis")

        state.start(projectID: project.id)
        state.stop()   // clock never advanced

        #expect(state.store.sessions.isEmpty)
        #expect(state.store.running == nil)
        #expect(state.focusSessionID == nil)
    }

    /// A discarded mis-click must not leave the PREVIOUS session's id behind.
    @Test func discardedSessionClearsTheLastStoppedID() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")

        state.start(projectID: project.id)
        clock = Date(timeIntervalSince1970: 1_003_600)
        state.stop()
        #expect(state.focusSessionID != nil)

        state.start(projectID: project.id)   // clock does not advance — mis-click
        state.stop()

        #expect(state.store.sessions.count == 1)
        #expect(state.focusSessionID == nil)
    }

    @Test func stopWithNoTimerIsANoOp() {
        let state = makeState()
        state.stop()
        #expect(state.store.sessions.isEmpty)
    }

    @Test func elapsedIsZeroWhenIdle() {
        let state = makeState()
        #expect(state.elapsed == 0)
    }

    @Test func stateReloadsFromDisk() throws {
        let state = makeState()
        let project = state.addProject(name: "Thesis")
        state.start(projectID: project.id)

        let reopened = AppState(storage: state.storage,
                                now: { Date(timeIntervalSince1970: 1_003_600) },
                                calendar: .current)

        #expect(reopened.store.projects.map(\.name) == ["Thesis"])
        #expect(reopened.store.running?.projectID == project.id)
        #expect(reopened.elapsed == 3600)   // still ticking from the original start
    }

    @Test func corruptStoreSurfacesAnError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TimeLoggerTests-\(UUID().uuidString)")
        let storage = Storage(url: dir.appendingPathComponent("store.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storage.url)

        let state = AppState(storage: storage, now: Date.init, calendar: .current)
        #expect(state.loadError != nil)
    }

    /// A corrupt store must survive the next mutation. Loading empty and then saving over the
    /// original file would destroy every session the user ever recorded.
    @Test func corruptStoreIsMovedAsideNotOverwritten() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TimeLoggerTests-\(UUID().uuidString)")
        let storage = Storage(url: dir.appendingPathComponent("store.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storage.url)

        let state = AppState(storage: storage,
                             now: { Date(timeIntervalSince1970: 1_000_000) },
                             calendar: .current)
        #expect(state.loadError != nil)

        state.addProject(name: "Thesis")   // any mutation triggers save()

        // The original bytes must still exist somewhere in the directory.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let preserved = names.contains { name in
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))?
                .contains("not json") == true
        }
        #expect(preserved)
    }
}

@MainActor
struct AppStateViewModeTests {
    /// A scratch domain: `.standard` here is the real app's preferences, and a test has no
    /// business changing which view the user left the app in.
    private func scratchDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "TimeLoggerTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeState(storage: Storage, defaults: UserDefaults) -> AppState {
        AppState(storage: storage,
                 now: { Date(timeIntervalSince1970: 1_000_000) },
                 calendar: .current,
                 defaults: defaults)
    }

    private func scratchStorage() -> Storage {
        Storage(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TimeLoggerTests-\(UUID().uuidString)/store.json"))
    }

    @Test func defaultsToTheDayBars() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(makeState(storage: scratchStorage(), defaults: defaults).viewMode == .bars)
    }

    /// The chosen view is a preference, so it has to outlive the window — but it is kept out
    /// of store.json, where a new key would make every store written before this feature
    /// fail to decode and be quarantined as corrupt.
    @Test func chosenViewSurvivesRelaunch() throws {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = scratchStorage()

        let state = makeState(storage: storage, defaults: defaults)
        state.addProject(name: "Thesis")
        state.viewMode = .calendar

        let reopened = makeState(storage: storage, defaults: defaults)
        #expect(reopened.viewMode == .calendar)
        #expect(reopened.store.projects.map(\.name) == ["Thesis"])
        #expect(reopened.loadError == nil)
    }
}

@MainActor
struct AppStateManualEntryTests {
    /// The whole point of manual entry is logging something you forgot — the entry has to
    /// be visible afterwards, whatever week the user happened to be browsing when they added it.
    @Test func addSessionRecordsTimeAndFollowsItToItsWeek() throws {
        let state = makeState()
        let project = state.addProject(name: "Thesis")
        state.goToWeek(offset: -3)

        let start = Date(timeIntervalSince1970: 1_000_000)
        state.addSession(projectID: project.id, start: start, end: start.addingTimeInterval(5400))

        let session = try #require(state.store.sessions.first)
        #expect(state.store.sessions.count == 1)
        #expect(session.projectID == project.id)
        #expect(session.duration == 5400)
        #expect(state.focusSessionID == session.id)   // cursor lands in the new note
        #expect(state.isCurrentWeek)                  // pulled back from three weeks ago
        #expect(state.weekSessions.map(\.id) == [session.id])
        #expect(try state.storage.load().sessions.count == 1)
    }

    /// Defaults must land inside the week on screen, or adding while browsing the past
    /// files the entry under today and it disappears.
    @Test func defaultSpanLandsInTheDisplayedWeek() {
        let state = makeState()
        state.goToWeek(offset: -1)

        let span = state.newSessionSpan

        #expect(span.end.timeIntervalSince(span.start) == 3600)
        #expect(span.start >= state.displayedWeekStart)
        #expect(span.end < Week.shift(state.displayedWeekStart, byWeeks: 1, calendar: state.calendar))
    }
}
