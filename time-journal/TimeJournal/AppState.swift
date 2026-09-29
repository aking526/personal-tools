import Foundation
import Observation

/// The two ways the left pane can draw the same week: totals per day, or where the work
/// actually sat in the day.
nonisolated enum WeekViewMode: String, CaseIterable {
    case bars, calendar
}

/// The folds in the right pane. A view preference for the same reason `viewMode` is one: how the
/// pane is arranged is not part of the time log, and `Store` is the time log.
///
/// `sessions` was `notes` before the section was renamed: the raw value is what is persisted, so an
/// older fold set naming `notes` simply no longer decodes and that section comes back expanded. A
/// view preference is allowed to be forgotten; the log is not, which is why only `Store` has a
/// migration story.
nonisolated enum PaneSection: String, CaseIterable {
    case tasks, inProgress, done, sessions
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
    /// Set whenever a session lands in the sessions list — by `stop()` or by `addSession` —
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
    /// Which sections of the right pane the user has folded away. Held as a set of the collapsed
    /// ones rather than a flag per section so that "add another section" can't forget to default
    /// one of them, and so the stored value stays a short list of exceptions.
    var collapsedSections: Set<PaneSection> {
        didSet {
            defaults.set(collapsedSections.map(\.rawValue).sorted(),
                         forKey: Self.collapsedSectionsKey)
        }
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
    private static let collapsedSectionsKey = "collapsedPaneSections"

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
        // DONE starts folded: a list of finished work is mostly a receipt, and it would otherwise
        // push the tasks still to do — the reason the section exists — off the bottom. An empty
        // stored array means "everything expanded", which is why this checks for the key being
        // absent (`stringArray` returns nil) rather than for the set being empty.
        self.collapsedSections = defaults.stringArray(forKey: Self.collapsedSectionsKey)
            .map { Set($0.compactMap(PaneSection.init(rawValue:))) } ?? [.done]
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

    // MARK: - Pane sections

    func isCollapsed(_ section: PaneSection) -> Bool { collapsedSections.contains(section) }

    func toggleSection(_ section: PaneSection) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
    }

    /// For something landing that the user has to be able to see. Without this, a stopped session
    /// would open its note in a popover attached to a row inside a folded section: no row is
    /// drawn, so nothing opens, and the dead-end is the one `toggle()` already warns about.
    func expandSection(_ section: PaneSection) {
        collapsedSections.remove(section)
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
        store.todos.removeAll { $0.projectID == id }   // a task without its project has no project to run against
        store.projects.removeAll { $0.id == id }
        if store.selectedProjectID == id {
            store.selectedProjectID = store.projects.first?.id
        }
        save()
    }

    // MARK: - Tasks

    /// The selected project's tasks, in creation order — which is the store's own order, because
    /// tasks are only ever appended. Nothing is sorted, so no sort key can drift from what was
    /// typed, and a new task can't jump the queue.
    var todos: [Todo] {
        guard let projectID = store.selectedProjectID else { return [] }
        return store.todos.filter { $0.projectID == projectID }
    }

    /// Still to do. This is the list the section is for.
    var openTodos: [Todo] { todos.filter { $0.status == .open } }

    /// Started and set down — the IN PROGRESS group. A paused task is the one the disclosure
    /// below it is worth expanding: it is work already begun, so its sessions are the point.
    var inProgressTodos: [Todo] { todos.filter { $0.status == .paused } }

    /// Finished, most recently finished first. Completion order is the only ordering in the app
    /// that isn't creation order, because it is the only one that answers a question (what did I
    /// just get done). `createdAt` is the fallback for a task finished before it had a stamp.
    var doneTodos: [Todo] {
        todos.filter { $0.status == .done }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    /// The task the running session was started from, if it was — what the chip under the clock
    /// and the highlighted row are drawn from. Looked up across all projects rather than the
    /// selection: it describes the timer, not the pane.
    var runningTodo: Todo? {
        guard let id = store.running?.todoID else { return nil }
        return todo(id)
    }

    func todo(_ id: UUID) -> Todo? {
        store.todos.first { $0.id == id }
    }

    func todoCount(for projectID: UUID) -> Int {
        store.todos.count { $0.projectID == projectID }
    }

    /// Any project's tasks, in creation order — for the session editor, which names the tasks of the
    /// session's own project rather than the one the pane happens to be showing. Every status is
    /// listed, because a session can belong to work that has since been finished.
    func todos(for projectID: UUID) -> [Todo] {
        store.todos.filter { $0.projectID == projectID }
    }

    /// Every session ever run against this task, newest first. Derived by scan like every other
    /// figure here — and deliberately not week-scoped, because a task outlives a week: "what did
    /// this thing cost me" is the question the disclosure is asked.
    func sessions(forTodo id: UUID) -> [Session] {
        store.sessions.filter { $0.todoID == id }.sorted { $0.start > $1.start }
    }

    func total(forTodo id: UUID) -> TimeInterval {
        store.sessions.reduce(0) { total, session in
            session.todoID == id ? total + session.duration : total
        }
    }

    /// New tasks land in the selected project. An empty title is refused rather than stored as a
    /// nameless row — `nil` tells the caller it was refused, which is what the dialog's Create
    /// button checks before dismissing.
    @discardableResult
    func addTodo(title: String) -> Todo? {
        guard let projectID = store.selectedProjectID else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let todo = Todo(projectID: projectID, title: trimmed, createdAt: now())
        store.todos.append(todo)
        save()
        return todo
    }

    func renameTodo(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = store.todos.firstIndex(where: { $0.id == id }) else { return }
        store.todos[index].title = trimmed
        save()
    }

    /// Completing stamps the moment, because that is what orders the DONE group; reopening clears
    /// it, so a reopened task never claims to have been finished at a time it wasn't.
    func setTodoStatus(_ id: UUID, _ status: Todo.Status) {
        guard let index = store.todos.firstIndex(where: { $0.id == id }) else { return }
        store.todos[index].status = status
        store.todos[index].completedAt = (status == .done) ? now() : nil
        save()
    }

    /// Deleting a task keeps its sessions — the time really was spent, and erasing it would
    /// falsify the week — and leaves a timer it started running, because deleting the task says
    /// nothing about the clock. Only the dangling link goes, so nothing draws a task that is gone.
    func deleteTodo(_ id: UUID) {
        if store.running?.todoID == id { store.running?.todoID = nil }
        store.todos.removeAll { $0.id == id }
        save()
    }

    // MARK: - Timer

    func start(projectID: UUID) {
        start(projectID: projectID, todoID: nil)
    }

    /// Starts a session on a task. The project follows the task, and the running timer remembers
    /// where it came from so `stop()` can describe the session with the task's title.
    func start(todoID: UUID) {
        guard let todo = todo(todoID) else { return }
        // Starting something already finished reopens it: otherwise time would accrue against a
        // task that claims to be done, and the DONE group would quietly be a lie. A paused task is
        // left alone — it is in progress, which is exactly what starting it again means.
        // Mutated here without a save because the `start` below writes the whole store anyway.
        if let index = store.todos.firstIndex(where: { $0.id == todoID }),
           store.todos[index].status == .done {
            store.todos[index].status = .open
            store.todos[index].completedAt = nil
        }
        start(projectID: todo.projectID, todoID: todo.id)
    }

    private func start(projectID: UUID, todoID: UUID?) {
        if store.running != nil { stop() }
        store.selectedProjectID = projectID   // both panels must describe the same project
        store.running = Running(projectID: projectID, start: now(), todoID: todoID)
        tickNow = now()
        startTicking()
        save()
    }

    @discardableResult
    func stop(focusNote: Bool = true) -> Session? {
        guard let running = store.running else { return nil }
        let ended = now()
        store.running = nil
        stopTicking()

        var stoppedSession: Session?
        if ended.timeIntervalSince(running.start) >= 1 {
            // A session started from a task is described by that task for free: its title becomes
            // the note. That is only a default — the popover that opens on this session edits the
            // note like any other, and `focusNoteOnOpen` puts the caret at the end of the title so
            // typing extends it instead of wiping it. A task deleted mid-session contributes
            // nothing, which is why the lookup is by id here rather than trusted from the timer.
            let todo = running.todoID.flatMap { id in store.todos.first { $0.id == id } }
            let session = Session(projectID: running.projectID, start: running.start, end: ended,
                                  note: todo?.title ?? "", todoID: todo?.id)
            store.sessions.append(session)
            stoppedSession = session
            focusSessionID = focusNote ? session.id : nil
        } else {
            focusSessionID = nil
        }
        save()
        return stoppedSession
    }

    /// Stops the clock with the session it is about to commit already in view — its project, and the
    /// week it sits in.
    ///
    /// Nothing stops you switching project or paging weeks while a timer runs. Stop while looking
    /// elsewhere and the new session isn't in `weekSessions`: its row never renders, the annotate
    /// popover has nothing to attach to, and stop-then-annotate dead-ends. Correcting state first
    /// means the row exists by the time `focusSessionID` changes and the popover opens.
    ///
    /// It lives here rather than in the control that calls it because three controls now stop the
    /// clock — the main button, a task row's own button, and the menu bar — and all three need that
    /// same ordering to be right.
    @discardableResult
    func stopAndReveal(focusNote: Bool = true) -> Session? {
        guard let running = store.running else { return nil }
        if store.selectedProjectID != running.projectID { select(running.projectID) }
        if !isCurrentWeek { goToCurrentWeek() }
        return stop(focusNote: focusNote)
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

    /// Logs time after the fact, optionally against a task. The displayed week follows the new
    /// session, so an entry dated outside the week on screen doesn't vanish the moment it's saved.
    ///
    /// A session logged against a task is described by that task for free, exactly as a stopped one
    /// is — see `stop()`. That rule lives here rather than in the popover that usually calls it, so
    /// every caller inherits it and the two paths can't drift on what a blank note means. The task is
    /// looked up rather than trusted: one deleted while the popover was open leaves no dangling link.
    @discardableResult
    func addSession(projectID: UUID, start: Date, end: Date, note: String = "",
                    todoID: UUID? = nil) -> Session {
        let todo = todoID.flatMap { id in store.todos.first { $0.id == id } }
        let session = Session(projectID: projectID, start: start, end: end,
                              note: note.isEmpty ? (todo?.title ?? "") : note,
                              todoID: todo?.id)
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

    /// One day's total for the selected project, independent of the week on screen — paging back
    /// through history doesn't change what today came to. Stored sessions only, like `weekTotal`:
    /// a timer still running is the stopwatch's business, not the day's tally.
    ///
    /// The day is passed in rather than read from the clock here, because a view can't observe
    /// `now()` — the panel holds the day in state so it can re-ask after midnight.
    func dayTotal(for date: Date) -> TimeInterval {
        guard let projectID = store.selectedProjectID else { return 0 }
        return Stats.dayTotal(sessions: store.sessions,
                              projectID: projectID,
                              day: date,
                              calendar: calendar)
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
