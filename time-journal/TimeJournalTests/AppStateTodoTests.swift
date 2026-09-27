import Testing
import Foundation
@testable import TimeJournal

@MainActor
private func makeState(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000_000) }) -> AppState {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
    return AppState(storage: Storage(url: dir.appendingPathComponent("store.json")),
                    now: now,
                    calendar: .current)
}

/// A state with a preferences domain of its own — for the tests that assert on pane folds.
///
/// `AppState`'s `defaults` parameter defaults to `UserDefaults.standard`, which is the *test host's*
/// real domain. `expandSectionIsIdempotent` failed exactly because of that: it persisted an empty
/// fold set into the host on one run and read it back on the next. A fresh suite per call also keeps
/// the developer's own pane state out of the test.
@MainActor
private func makeStateWithOwnDefaults() throws -> AppState {
    let defaults = try #require(UserDefaults(suiteName: "TimeJournalTests-\(UUID().uuidString)"))
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
    return AppState(storage: Storage(url: dir.appendingPathComponent("store.json")),
                    calendar: .current,
                    defaults: defaults)
}

/// A temp store.json already holding `legacyStoreJSON` — the pre-tasks on-disk shape — so a test
/// can drive `AppState.init` down the path that would quarantine a real file.
private func legacyStorage() throws -> Storage {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
    let storage = Storage(url: dir.appendingPathComponent("store.json"))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(legacyStoreJSON.utf8).write(to: storage.url)
    return storage
}

@MainActor
struct AppStateTodoTests {

    // MARK: - Creating and grouping

    @Test func addingATaskPutsItInTheSelectedProjectInCreationOrder() {
        let state = makeState()
        let project = state.addProject(name: "Thesis")
        state.addTodo(title: "Read the paper")
        state.addTodo(title: "Draft slides")

        #expect(state.todos.map(\.title) == ["Read the paper", "Draft slides"])
        #expect(state.todos.allSatisfy { $0.projectID == project.id })
        #expect(state.openTodos.count == 2)
    }

    /// A blank task is a row nobody can act on, and a blank rename is not an erasure — it would
    /// silently destroy the only description the task has.
    @Test func titlesAreTrimmedAndBlankOnesRefused() throws {
        let state = makeState()
        state.addProject(name: "Thesis")

        #expect(state.addTodo(title: "   ") == nil)
        #expect(state.addTodo(title: "\n\t") == nil)
        #expect(state.store.todos.isEmpty)

        _ = try #require(state.addTodo(title: "  Read the paper  "))
        let todo = try #require(state.todos.first)
        #expect(todo.title == "Read the paper")

        state.renameTodo(todo.id, title: "   ")
        #expect(state.todo(todo.id)?.title == "Read the paper")

        state.renameTodo(todo.id, title: " Read it properly ")
        #expect(state.todo(todo.id)?.title == "Read it properly")
    }

    @Test func withoutAProjectThereIsNowhereToPutATask() {
        let state = makeState()
        #expect(state.addTodo(title: "Read the paper") == nil)
        #expect(state.store.todos.isEmpty)
    }

    @Test func tasksFollowTheSelectedProject() throws {
        let state = makeState()
        let essays = state.addProject(name: "Essays")
        _ = try #require(state.addTodo(title: "Task for Essays"))
        let reading = state.addProject(name: "Reading")   // adding selects it

        #expect(state.todos.isEmpty)
        #expect(state.openTodos.isEmpty)
        #expect(state.todoCount(for: reading.id) == 0)

        state.select(essays.id)
        #expect(state.todos.map(\.title) == ["Task for Essays"])
        #expect(state.todoCount(for: essays.id) == 1)
    }

    @Test func statusGroupsAndDoneIsOrderedByWhenItWasFinished() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        state.addProject(name: "Thesis")
        let pausedTask = try #require(state.addTodo(title: "Started thing"))
        let doneEarlier = try #require(state.addTodo(title: "Finished first"))
        let doneLater = try #require(state.addTodo(title: "Finished second"))

        state.setTodoStatus(pausedTask.id, .paused)
        clock = Date(timeIntervalSince1970: 1_001_000)
        state.setTodoStatus(doneEarlier.id, .done)
        clock = Date(timeIntervalSince1970: 1_002_000)
        state.setTodoStatus(doneLater.id, .done)

        #expect(state.openTodos.isEmpty)
        #expect(state.inProgressTodos.map(\.title) == ["Started thing"])
        // Most recently finished first — completion is the one ordering that answers a question.
        #expect(state.doneTodos.map(\.title) == ["Finished second", "Finished first"])
        #expect(state.todos.map(\.title) == ["Started thing", "Finished first", "Finished second"])
    }

    @Test func reopeningClearsTheCompletionTime() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))

        state.setTodoStatus(todo.id, .done)
        #expect(state.todo(todo.id)?.completedAt == Date(timeIntervalSince1970: 1_000_000))

        clock = Date(timeIntervalSince1970: 1_002_000)
        state.setTodoStatus(todo.id, .open)
        #expect(state.todo(todo.id)?.completedAt == nil)   // never claims a finish that didn't happen
    }

    // MARK: - Starting a session from a task

    @Test func startingATaskRunsAgainstItsProjectAndTheSessionCarriesTheTitle() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let paper = state.addProject(name: "Paper")
        let other = state.addProject(name: "Other")
        state.select(paper.id)
        let todo = try #require(state.addTodo(title: "Read the paper"))
        state.select(other.id)   // look away before starting the task

        state.start(todoID: todo.id)

        #expect(state.store.running?.projectID == paper.id)     // the project follows the task
        #expect(state.store.selectedProjectID == paper.id)      // so both panels describe it
        #expect(state.store.running?.todoID == todo.id)
        #expect(state.runningTodo?.title == "Read the paper")

        clock = Date(timeIntervalSince1970: 1_003_600)
        state.stop()

        let session = try #require(state.store.sessions.first)
        #expect(session.note == "Read the paper")           // the description defaults to the title
        #expect(session.todoID == todo.id)
        #expect(session.projectID == paper.id)
        #expect(session.duration == 3600)
        #expect(state.runningTodo == nil)
        #expect(state.focusSessionID == session.id)         // and it opens for annotation
    }

    @Test func aPlainStartAttachesNoTask() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")
        _ = try #require(state.addTodo(title: "Read the paper"))

        state.start(projectID: project.id)
        #expect(state.store.running?.todoID == nil)
        #expect(state.runningTodo == nil)

        clock = Date(timeIntervalSince1970: 1_003_600)
        state.stop()
        let session = try #require(state.store.sessions.first)
        #expect(session.note == "")       // empty, exactly as before: nothing pre-filled it
        #expect(session.todoID == nil)
    }

    /// Time must never accrue against something that claims to be finished; a paused task, by
    /// contrast, is already in progress and starting it again says nothing new.
    @Test func startingAFinishedTaskReopensItAndAPausedOneStaysPaused() throws {
        let state = makeState()
        state.addProject(name: "Thesis")
        let done = try #require(state.addTodo(title: "Finished thing"))
        let paused = try #require(state.addTodo(title: "Started thing"))
        state.setTodoStatus(done.id, .done)
        state.setTodoStatus(paused.id, .paused)

        state.start(todoID: done.id)
        #expect(state.todo(done.id)?.status == .open)
        #expect(state.todo(done.id)?.completedAt == nil)
        state.stop()

        state.start(todoID: paused.id)
        #expect(state.todo(paused.id)?.status == .paused)
    }

    @Test func startingAnUnknownTaskStartsNothing() {
        let state = makeState()
        state.addProject(name: "Thesis")
        state.start(todoID: UUID())
        #expect(state.store.running == nil)
    }

    @Test func startingATaskStopsWhateverWasRunning() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))

        state.start(projectID: project.id)
        clock = Date(timeIntervalSince1970: 1_001_800)
        state.start(todoID: todo.id)

        // The plain session was committed, and only one clock runs — the task's.
        #expect(state.store.sessions.count == 1)
        #expect(state.store.sessions.first?.todoID == nil)
        #expect(state.store.running?.todoID == todo.id)
    }

    @Test func aSubSecondTaskSessionIsStillDiscarded() throws {
        let state = makeState()   // the clock never moves
        state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))

        state.start(todoID: todo.id)
        state.stop()

        #expect(state.store.sessions.isEmpty)
        #expect(state.focusSessionID == nil)
    }

    /// Whichever control stops the clock — the main button, a task row's own button, or the menu bar —
    /// the session it commits has to end up in view. Otherwise its row never renders, the annotate
    /// popover has nothing to attach to, and stop-then-annotate dead-ends.
    @Test func stoppingBringsTheSessionItCommitsIntoView() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let paper = state.addProject(name: "Paper")
        let other = state.addProject(name: "Other")
        state.select(paper.id)
        let todo = try #require(state.addTodo(title: "Read the paper"))
        state.start(todoID: todo.id)
        clock = Date(timeIntervalSince1970: 1_003_600)

        // Look away in both dimensions before stopping: another project, and a week with none of
        // this work in it.
        state.select(other.id)
        state.goToWeek(offset: -1)

        state.stopAndReveal()

        #expect(state.store.selectedProjectID == paper.id)
        #expect(state.isCurrentWeek)
        #expect(state.weekSessions.count == 1)
        #expect(state.focusSessionID == state.store.sessions.first?.id)
        #expect(state.store.sessions.first?.note == "Read the paper")
    }

    // MARK: - The sessions behind a task

    @Test func aTasksSessionsAndTotalIgnoreEveryOtherSession() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))

        state.start(todoID: todo.id)
        clock = Date(timeIntervalSince1970: 1_001_800)   // 30m
        state.stop()
        state.start(todoID: todo.id)
        clock = Date(timeIntervalSince1970: 1_003_600)   // 30m more
        state.stop()

        // A manual session using the same words is not the task's: words are not an identity, and
        // guessing by title would silently fold unrelated hours into the task's total.
        state.addSession(projectID: project.id,
                         start: clock, end: clock.addingTimeInterval(600),
                         note: "Read the paper")

        let linked = state.sessions(forTodo: todo.id)
        #expect(linked.count == 2)
        #expect(linked.map(\.start) == linked.map(\.start).sorted(by: >))   // newest first
        #expect(state.total(forTodo: todo.id) == 3600)
        #expect(state.store.sessions.count == 3)
    }

    /// Logging an hour by hand against a task links it the same way a stopped session is linked:
    /// it counts toward the task's total, and it is still an ordinary session in the notes list.
    @Test func aManuallyLoggedSessionLinksToItsTask() throws {
        let state = makeState()
        let project = state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))

        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = state.addSession(projectID: project.id,
                                       start: start, end: start.addingTimeInterval(1800),
                                       note: "Read ch. 3", todoID: todo.id)

        #expect(session.todoID == todo.id)
        #expect(session.note == "Read ch. 3")           // typed words are not overwritten
        #expect(state.sessions(forTodo: todo.id).map(\.id) == [session.id])
        #expect(state.total(forTodo: todo.id) == 1800)
        // It is an ordinary session too — the notes list draws it like any other.
        #expect(state.weekSessions.map(\.id) == [session.id])
    }

    /// The same default `stop()` applies: a manual session left blank is described by its task, so
    /// the task's history never shows a nameless row that only the clock could have written.
    @Test func aManuallyLoggedSessionTakesTheTaskTitleWhenTheNoteIsBlank() throws {
        let state = makeState()
        let project = state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))

        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = state.addSession(projectID: project.id,
                                       start: start, end: start.addingTimeInterval(900),
                                       todoID: todo.id)

        #expect(session.note == "Read the paper")
        #expect(session.todoID == todo.id)
    }

    /// The task is looked up as the session is written, not trusted from the popover that was open
    /// when it was started: a task deleted in the meantime leaves no dangling link and no title.
    @Test func loggingAgainstADeletedTaskLeavesAnOrdinarySession() throws {
        let state = makeState()
        let project = state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))
        state.deleteTodo(todo.id)

        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = state.addSession(projectID: project.id,
                                       start: start, end: start.addingTimeInterval(600),
                                       todoID: todo.id)

        #expect(session.todoID == nil)
        #expect(session.note == "")
        #expect(state.store.sessions.count == 1)   // the time was really spent
    }

    /// Tagging an existing session is an edit like any other: the notes list's editor rewrites the
    /// times, the note and the link in one save, and clearing the link is allowed — a session can be
    /// a mix of work that doesn't belong to any one task.
    @Test func anExistingSessionCanBeTaggedToATaskAndUntagged() throws {
        let state = makeState()
        let project = state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))

        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = state.addSession(projectID: project.id,
                                       start: start, end: start.addingTimeInterval(1200),
                                       note: "Mixed morning")

        // What `SessionEditor`'s Save does: the picker's value is written onto the whole record.
        var edited = session
        edited.todoID = todo.id
        state.updateSession(edited)

        #expect(state.sessions(forTodo: todo.id).map(\.id) == [session.id])
        #expect(state.total(forTodo: todo.id) == 1200)
        // Editing the link does not rewrite the note: words typed for this session are kept.
        #expect(state.store.sessions.first?.note == "Mixed morning")

        edited.todoID = nil
        state.updateSession(edited)
        #expect(state.sessions(forTodo: todo.id).isEmpty)
        #expect(state.store.sessions.first?.todoID == nil)
        #expect(state.store.sessions.first?.note == "Mixed morning")   // untagging keeps the words
    }

    /// The session editor's task menu names the tasks of the session's own project, not the project
    /// the pane happens to be showing — and every status is offered, because a session can belong to
    /// work that has since been finished.
    @Test func theEditorsTaskListIsScopedToTheSessionsProjectAndIncludesFinishedTasks() throws {
        let state = makeState()
        let thesis = state.addProject(name: "Thesis")
        let paper = try #require(state.addTodo(title: "Read the paper"))
        state.addTodo(title: "Draft slides")
        state.setTodoStatus(paper.id, .done)

        let garden = state.addProject(name: "Garden")
        state.addTodo(title: "Prune the roses")

        // Creation order, finished work included — the menu is a label, not a to-do list.
        #expect(state.todos(for: thesis.id).map(\.title) == ["Read the paper", "Draft slides"])
        #expect(state.todos(for: garden.id).map(\.title) == ["Prune the roses"])
        #expect(state.todos(for: UUID()).isEmpty)
    }

    /// A task outlives a week, so its total is deliberately not week-scoped — that is the one thing
    /// separating the disclosure from the notes list above it.
    @Test func aTasksTotalIsNotScopedToTheDisplayedWeek() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))

        state.start(todoID: todo.id)
        clock = clock.addingTimeInterval(3600)
        state.stop()

        state.goToWeek(offset: -1)   // a week none of this happened in
        #expect(state.weekSessions.isEmpty)
        #expect(state.sessions(forTodo: todo.id).count == 1)
        #expect(state.total(forTodo: todo.id) == 3600)
    }

    // MARK: - Deleting

    @Test func deletingATaskKeepsItsSessions() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))
        state.start(todoID: todo.id)
        clock = Date(timeIntervalSince1970: 1_003_600)
        state.stop()

        state.deleteTodo(todo.id)

        #expect(state.store.todos.isEmpty)
        #expect(state.store.sessions.count == 1)   // the hour was really spent
    }

    /// Deleting the task is not a statement about the clock: the timer keeps running, and simply
    /// stops being able to name a task it no longer has.
    @Test func deletingTheRunningTaskLeavesTheClockAlone() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let project = state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))
        state.start(todoID: todo.id)

        state.deleteTodo(todo.id)

        #expect(state.store.running?.projectID == project.id)
        #expect(state.store.running?.todoID == nil)
        #expect(state.runningTodo == nil)

        clock = Date(timeIntervalSince1970: 1_003_600)
        state.stop()
        let session = try #require(state.store.sessions.first)
        #expect(session.note == "")        // nothing left to name it with
        #expect(session.todoID == nil)
    }

    @Test func deletingAProjectTakesItsTasksWithIt() throws {
        let state = makeState()
        let essays = state.addProject(name: "Essays")
        _ = try #require(state.addTodo(title: "Task for Essays"))
        let reading = state.addProject(name: "Reading")
        _ = try #require(state.addTodo(title: "Task for Reading"))

        state.deleteProject(essays.id)

        #expect(state.store.todos.map(\.title) == ["Task for Reading"])
        #expect(state.store.todos.allSatisfy { $0.projectID == reading.id })
    }

    // MARK: - Persistence

    @Test func tasksSurviveARelaunch() throws {
        let state = makeState()
        let project = state.addProject(name: "Thesis")
        let todo = try #require(state.addTodo(title: "Read the paper"))
        state.setTodoStatus(todo.id, .paused)

        let loaded = try state.storage.load()

        #expect(loaded.todos.count == 1)
        #expect(loaded.todos.first?.title == "Read the paper")
        #expect(loaded.todos.first?.status == .paused)
        #expect(loaded.todos.first?.projectID == project.id)
    }

    /// The end-to-end version of `StorageTests.legacyStoreWithoutTodosDecodes`: this drives the
    /// actual `AppState.init`, where a decode failure would move the real file aside and come up
    /// empty. If this fails, the user's history is one launch away from being quarantined.
    @Test func aStoreFromBeforeTasksExistedIsNotQuarantined() throws {
        let storage = try legacyStorage()
        let state = AppState(storage: storage,
                             now: { Date(timeIntervalSince1970: 1_000_000) },
                             calendar: .current)

        #expect(state.loadError == nil)
        #expect(state.store.projects.map(\.name) == ["Thesis"])
        #expect(state.store.sessions.count == 1)
        #expect(state.store.sessions.first?.note == "fixed ch.3")
        #expect(state.store.todos.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: storage.url.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.contains("corrupt") })
        #expect(siblings.contains("store.json"))
    }

    /// And once it *has* tasks, opening it again with an older-shaped reader must not matter —
    /// but it must stop being quarantined, which the round trip above it covers.
    @Test func theFirstSaveAfterLoadingAnOldStoreKeepsEverythingAndAddsTheKey() throws {
        let storage = try legacyStorage()
        let state = AppState(storage: storage,
                             now: { Date(timeIntervalSince1970: 1_000_000) },
                             calendar: .current)

        _ = try #require(state.addTodo(title: "Read the paper"))   // forces a save

        let reloaded = try storage.load()
        #expect(reloaded.sessions.count == 1)                  // nothing was dropped by the rewrite
        #expect(reloaded.projects.count == 1)
        #expect(reloaded.running?.projectID == reloaded.selectedProjectID)
        #expect(reloaded.todos.map(\.title) == ["Read the paper"])

        let text = try String(contentsOf: storage.url, encoding: .utf8)
        #expect(text.contains("\"todos\""))
    }

    @Test func foldedSectionsStartWithDoneFoldedAndOutliveTheWindow() throws {
        let suite = "TimeJournalTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
        let storage = Storage(url: dir.appendingPathComponent("store.json"))

        let first = AppState(storage: storage, calendar: .current, defaults: defaults)
        #expect(first.collapsedSections == [.done])     // the receipt starts folded
        #expect(first.isCollapsed(.done))
        #expect(!first.isCollapsed(.tasks))

        first.toggleSection(.done)
        first.toggleSection(.sessions)
        #expect(first.collapsedSections == [.sessions])

        let second = AppState(storage: storage, calendar: .current, defaults: defaults)
        #expect(second.collapsedSections == [.sessions])
        #expect(!second.isCollapsed(.done))             // and unfurling Done sticks too
    }

    @Test func expandSectionIsIdempotent() throws {
        let state = try makeStateWithOwnDefaults()
        #expect(state.collapsedSections == [.done])
        state.expandSection(.sessions)
        state.expandSection(.sessions)
        #expect(state.collapsedSections == [.done])
        state.expandSection(.done)
        #expect(state.collapsedSections.isEmpty)
    }
}
