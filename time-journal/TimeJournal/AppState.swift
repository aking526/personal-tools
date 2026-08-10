import Foundation
import Observation

/// The two ways the left pane can draw the same week: totals per day, or where the work
/// actually sat in the day.
nonisolated enum WeekViewMode: String, CaseIterable {
    case bars, calendar
}

/// The single mutable object and the single writer. Views read it and call its methods;
/// no view touches Storage directly.
@Observable
@MainActor
final class AppState {
    private(set) var store: Store
    var loadError: String?

    /// Bumped once a second while a timer runs, purely to drive re-renders.
    var tickNow: Date
    /// Set whenever a session lands in the notes list — by `stop()` or by `addSession` —
    /// so the list can put the cursor in its note.
    var focusSessionID: UUID?
    /// Monday 00:00 of the week both panels are showing.
    var displayedWeekStart: Date
    /// Which drawing of the week the left pane shows. A view preference, not user data —
    /// it lives in UserDefaults deliberately. Adding a field to `Store` would make every
    /// store.json written before this feature fail to decode, and `init` below treats a
    /// decode failure as corruption.
    var viewMode: WeekViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Self.viewModeKey) }
    }

    @ObservationIgnored let storage: Storage
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var ticker: Timer?
    /// The week that was current the last time the day changed under us. It's what lets
    /// `followDayChange()` tell "still parked on the current week" apart from "deliberately
    /// paged back to the week that happens to have been current".
    @ObservationIgnored private var lastCurrentWeekStart: Date

    private static let viewModeKey = "weekViewMode"

    init(storage: Storage = .appSupport(),
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         defaults: UserDefaults = .standard) {
        self.storage = storage
        self.now = now
        self.calendar = calendar
        self.defaults = defaults
        self.tickNow = now()
        self.viewMode = WeekViewMode(rawValue: defaults.string(forKey: Self.viewModeKey) ?? "") ?? .bars
        do {
            self.store = try storage.load()
        } catch {
            // Move the unreadable file aside BEFORE anything can overwrite it. Without this,
            // the next mutation the user makes — creating a project, starting a timer — saves
            // an empty store straight over a file that may still hold years of history.
            self.store = Store()
            // A UUID rather than a timestamp: two failures in the same second would collide,
            // and a collision makes moveItem throw. `kept` reflects whether THIS move actually
            // succeeded — checking that the destination merely exists would report success
            // while the corrupt file sat at the original path waiting to be overwritten.
            let backup = storage.url.appendingPathExtension("corrupt-\(UUID().uuidString)")
            let kept = (try? FileManager.default.moveItem(at: storage.url, to: backup)) != nil
            self.loadError = "Could not read your saved time log at \(storage.url.path).\n\n\(error.localizedDescription)"
                + (kept
                   ? "\n\nThe unreadable file has been kept at \(backup.path)."
                   : "\n\nIt could NOT be moved aside — back it up by hand before making any changes.")
        }
        let currentWeek = Week.start(of: now(), calendar: calendar)
        self.displayedWeekStart = currentWeek
        self.lastCurrentWeekStart = currentWeek
        if store.running != nil { startTicking() }
    }

    // MARK: - Derived

    /// The wall clock the app runs on. Views that need the date rather than an elapsed count —
    /// the timeline opens on today — read it here instead of calling `Date()`, so a test that
    /// injects a clock still describes the whole app.
    var currentDate: Date { now() }

    var selectedProject: Project? {
        store.projects.first { $0.id == store.selectedProjectID }
    }

    var elapsed: TimeInterval {
        guard let running = store.running else { return 0 }
        return max(0, tickNow.timeIntervalSince(running.start))
    }

    var isRunning: Bool { store.running != nil }

    // MARK: - Projects

    @discardableResult
    func addProject(name: String) -> Project {
        let project = Project(name: name, createdAt: now())
        store.projects.append(project)
        store.selectedProjectID = project.id
        save()
        return project
    }

    func select(_ id: UUID) {
        store.selectedProjectID = id
        save()
    }

    /// For views that hold a session's `projectID` rather than the selection — the session
    /// editor names the project it is about to write to.
    func project(_ id: UUID) -> Project? {
        store.projects.first { $0.id == id }
    }

    func sessionCount(for id: UUID) -> Int {
        store.sessions.count { $0.projectID == id }
    }

    /// Destructive and irreversible — callers must confirm first.
    func deleteProject(_ id: UUID) {
        if store.running?.projectID == id {
            store.running = nil
            stopTicking()
        }
        store.sessions.removeAll { $0.projectID == id }
        store.projects.removeAll { $0.id == id }
        if store.selectedProjectID == id {
            store.selectedProjectID = store.projects.first?.id
        }
        save()
    }

    // MARK: - Timer

    func start(projectID: UUID) {
        if store.running != nil { stop() }
        store.selectedProjectID = projectID   // both panels must describe the same project
        store.running = Running(projectID: projectID, start: now())
        tickNow = now()
        startTicking()
        save()
    }

    func stop() {
        guard let running = store.running else { return }
        let ended = now()
        store.running = nil
        stopTicking()

        if ended.timeIntervalSince(running.start) >= 1 {
            let session = Session(projectID: running.projectID, start: running.start, end: ended)
            store.sessions.append(session)
            focusSessionID = session.id
        } else {
            focusSessionID = nil
        }
        save()
    }

    // MARK: - Sessions

    /// What a manually added session should default to: the hour before now, or the hour
    /// before midday when browsing another week — defaulting to today would file the entry
    /// into a week the user isn't looking at.
    var newSessionSpan: (start: Date, end: Date) {
        let end = isCurrentWeek
            ? now()
            : calendar.date(bySettingHour: 13, minute: 0, second: 0, of: displayedWeekStart) ?? displayedWeekStart
        return (end.addingTimeInterval(-3600), end)
    }

    /// Logs time after the fact. The displayed week follows the new session, so an entry
    /// dated outside the week on screen doesn't vanish the moment it's saved.
    @discardableResult
    func addSession(projectID: UUID, start: Date, end: Date, note: String = "") -> Session {
        let session = Session(projectID: projectID, start: start, end: end, note: note)
        store.sessions.append(session)
        store.selectedProjectID = projectID
        displayedWeekStart = Week.start(of: start, calendar: calendar)
        focusSessionID = session.id
        save()
        return session
    }

    func updateSession(_ session: Session) {
        guard let index = store.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        store.sessions[index] = session
        save()
    }

    func deleteSession(_ id: UUID) {
        store.sessions.removeAll { $0.id == id }
        save()
    }

    // MARK: - Week navigation

    var isCurrentWeek: Bool {
        displayedWeekStart == Week.start(of: now(), calendar: calendar)
    }

    var weekLabel: String {
        Week.label(weekStart: displayedWeekStart, calendar: calendar)
    }

    func goToWeek(offset: Int) {
        displayedWeekStart = Week.shift(displayedWeekStart, byWeeks: offset, calendar: calendar)
    }

    func goToCurrentWeek() {
        displayedWeekStart = Week.start(of: now(), calendar: calendar)
        lastCurrentWeekStart = displayedWeekStart
    }

    /// Midnight has passed with the app still open. A window sitting on the current week
    /// follows the clock into the new one; a window paged back to an older week stays where
    /// the user left it, because moving that would lose their place mid-review.
    func followDayChange() {
        let currentWeek = Week.start(of: now(), calendar: calendar)
        guard currentWeek != lastCurrentWeekStart else { return }
        if displayedWeekStart == lastCurrentWeekStart {
            displayedWeekStart = currentWeek
        }
        lastCurrentWeekStart = currentWeek
    }

    /// Always seven entries, zero-filled — and all zeroes when no project is selected.
    var dayTotals: [DayTotal] {
        guard let projectID = store.selectedProjectID else {
            return Week.days(from: displayedWeekStart, calendar: calendar)
                .map { DayTotal(date: $0, seconds: 0) }
        }
        return Stats.dayTotals(sessions: store.sessions,
                               projectID: projectID,
                               weekStart: displayedWeekStart,
                               calendar: calendar)
    }

    var weekTotal: TimeInterval {
        dayTotals.reduce(0) { $0 + $1.seconds }
    }

    /// Sessions of the selected project in the displayed week, newest first.
    var weekSessions: [Session] {
        guard let projectID = store.selectedProjectID else { return [] }
        let weekEnd = Week.shift(displayedWeekStart, byWeeks: 1, calendar: calendar)
        return store.sessions
            .filter { $0.projectID == projectID && $0.start >= displayedWeekStart && $0.start < weekEnd }
            .sorted { $0.start > $1.start }
    }

    // MARK: - Persistence

    /// Saving is best-effort at the UI layer: a failed write is surfaced, never swallowed,
    /// but it must not prevent the in-memory state from advancing.
    private func save() {
        do {
            try storage.save(store)
        } catch {
            loadError = "Could not save your time log.\n\n\(error.localizedDescription)"
        }
    }

    // MARK: - Ticking

    private func startTicking() {
        stopTicking()
        // The Timer callback is nonisolated, but RunLoop.main guarantees it fires on the
        // main thread. `assumeIsolated` states that without hopping through a Task —
        // wrapping the body in `Task { @MainActor in ... }` instead captures `self`
        // across a concurrency boundary and is an error in the Swift 6 language mode.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tickNow = self.now() }
        }
        RunLoop.main.add(timer, forMode: .common)   // .common keeps it ticking during menu tracking
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}
