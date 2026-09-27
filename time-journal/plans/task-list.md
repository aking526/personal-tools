# Task list and task-driven sessions

**Status:** ready for review
**Files:** `TimeJournal/` (SwiftUI, macOS 26.5), `TimeJournalTests/`
**Spec lineage:** extends `docs/superpowers/specs/2026-08-08-time-journal-design.md`

## Context

Today the app is a stopwatch plus notes: pick a project, press Start, work, press Stop, type a
note. There is no way to record something you intend to do later, and therefore no way to decide
what to work on from inside the app.

This adds a task list. A task is a thing to do later. From the list you start a session on a
task, and that session's description defaults to the task's title — still editable afterwards
like any other note. While a task session runs, the timer says so, rather than looking like a
plain Start.

## Hard constraint: your existing data must survive

Your live store is
`~/Library/Containers/com.alistair.TimeJournal/Data/Library/Application Support/TimeJournal/store.json`
— **1 project, 102 sessions, 27 KB**. Past sessions are not migrated into tasks; the task list
starts empty.

I checked the two facts this depends on with scratch Swift programs:

1. **Swift's synthesized `Decodable` throws `keyNotFound` for a missing key even when the
   property has a default value.** So a naive `var todos: [Todo] = []` on `Store` would fail to
   decode your file. `AppState.init` treats a decode failure as corruption: it moves the file
   aside to `store.json.corrupt-<uuid>` and starts from an empty store. The history would be
   quarantined, and the app would come up empty.
2. **Optional properties decode fine when their key is absent** (`nil`), including a persisted
   `running` object from an old build. This is what makes adding `Session.todoID` and
   `Running.todoID` safe.

So the rules for this change, both enforced by tests:

- `Store` gets a hand-written `init(from:)` using `decodeIfPresent` plus an explicit
  `CodingKeys` that documents the on-disk schema. Every field is absent-safe, not just `todos`.
- New per-record fields (`Session.todoID`, `Running.todoID`) are `UUID?`.
- A test decodes a hand-written **old-format** JSON literal (no `todos` key, no `todoID`
  anywhere) and asserts projects and sessions survive. This is the regression test for exactly
  the failure above.
- Nothing in the existing corrupt/quarantine path in `AppState.init` and `Storage.load` is
  touched, and no test writes to the real `store.json` (tests already use temp directories via
  `makeState(now:)` and `tempStorage()`).
- `Todo` is new, so its own shape has no legacy to honour; still, it is only ever *added* to,
  never reshaped in place.

## Approach

Right pane gains two collapsible sections — TASKS above NOTES — and the running clock gains a
task chip. Tasks belong to the selected project, so switching projects swaps the list. Starting
a task starts a normal session that carries the task's id; `stop()` seeds the session's note with
the task title, and the existing notes-list popover opens on it with the caret at the end, so
typing extends the title rather than wiping it.

```text
┌────────────────────────────────────────────────────┐
│ THIS WEEK  9h 10m  │  TODAY  1:20                  │
├────────────────────────────────────────────────────┤
│ 04:12:33                                           │
│ ▣ Write the report          ← task session chip    │
│ ┌────────────────────────────────────────────────┐ │
│ │                   ■ STOP                       │ │
│ └────────────────────────────────────────────────┘ │
├────────────────────────────────────────────────────┤
│ ⌄ TASKS                                       + New│
│    ▸ Write the report          2:40   ✓   ‖        │
│    ▸ Read the paper            0:20   ✓   ‖        │
│    ⌄ IN PROGRESS (1)                               │
│      ▸ Draft slides                   ✓   ‖        │
│        ⌄ Wed · Draft slides   9:30–10:15 AM  0:45  │
│          Mon · Draft slides  11:00–11:30 AM  0:30  │
│          2 sessions · 1:15                         │
│    ⌄ DONE (3)                                      │
│      ✓ Fix the build sheet                         │
├────────────────────────────────────────────────────┤
│ ⌄ NOTES                            Wrap    + Log   │
│    Wed · fixed ch.3    9:30–10:42 AM        1:12   │
└────────────────────────────────────────────────────┘
```

Reading the sketch: `▸` is the ▶ start button, `✓` completes, `‖` pauses, `⌄` is a disclosure
chevron. A task that has linked sessions gets a chevron; expanding it lists those sessions
(all-time, newest first) with a total, reusing the existing `SessionRow` so clicking one still
opens the normal session editor. The row of the task whose session is running is highlighted and
shows the live clock in place of its total.

Both TASKS and NOTES get a collapse chevron in their headers, as asked. Collapse state is a view
preference and lives in `UserDefaults` beside `viewMode`, not in `Store` — the design doc already
explains why: a new field in `Store` is a decode hazard, and a pane's fold state isn't user data.
Each section's header keeps a count (for DONE/IN PROGRESS) so a collapsed section still tells you
something is inside it.

## Decisions taken from your answers

| Question | Answer |
| --- | --- |
| Where the list lives | Right pane, TASKS section above NOTES; both collapsible |
| Do tasks belong to a project | Yes — created against the selected project, list follows selection |
| Complete / pause | Per-row `✓` (done) and `‖` (paused) buttons; paused tasks group into IN PROGRESS |
| Per-task sessions | Disclosure under the task; all sessions ever linked, newest first, with a total |
| Finished tasks | DONE group, collapsible, collapsed by default |
| Menu bar | Running task's title shown in the popover while running |
| Ordering | Creation order (store order); DONE sorted by completion, newest first |

### Judgment calls worth a look

1. **Starting a DONE task reopens it** (status → open, `completedAt` → nil). Starting a PAUSED
   task leaves it paused — it's already visible in IN PROGRESS. Starting never *sets* done.
2. **Deleting a task keeps its sessions** (they keep a now-dangling `todoID`, invisible) and
   leaves a running timer running, just clearing the chip's link. Deleting a project still
   removes its tasks and discards its running timer, as it does today.
3. **`+ New` opens an alert with a `TextField`**, copying `ProjectBar`'s New Project alert rather
   than inventing a popover. Rename reuses the same alert shape.
4. **A sub-second session is still discarded** (`stop()`'s existing rule), and it takes the
   prefilled task note with it — nothing lands, so `focusSessionID` is nil, exactly as today.
5. **Collapsing NOTES while a stop is in flight** would strand the annotate popover: the existing
   code has a comment about precisely this dead-end, so a landing session auto-expands NOTES.
6. **Type is named `Todo`, label is "TASKS"** — `Task` is Swift Concurrency's type and declaring
   our own at module scope would shadow it ([`AppState.swift:287`](TimeJournal/AppState.swift)).
7. **No new file format.** Tasks ride in the same `store.json`, written atomically by the same
   single writer. After the first save the file gains a `todos` key and new sessions gain
   `todoID`; existing keys are untouched.

## Data model

`TimeJournal/Model.swift`:

```swift
/// A thing to do later. `Todo`, not `Task`: `Task` is Swift Concurrency's type, and declaring
/// our own at module scope would shadow it everywhere in the module.
nonisolated struct Todo: Codable, Identifiable, Hashable {
    nonisolated enum Status: String, Codable { case open, paused, done }

    let id: UUID
    var projectID: UUID
    var title: String
    var createdAt: Date
    var status: Status
    var completedAt: Date?      // set when status becomes .done, for DONE ordering
}
```

`Session` and `Running` each gain an optional link — absent in every record on disk today, and
absent-safe because Swift decodes optionals with `decodeIfPresent`:

```swift
struct Session { ...; var todoID: UUID? }   // was this started from a task?
struct Running { ...; var todoID: UUID? }
```

`Store` gains `todos` plus the hand-written decoder, keeping `Store()` working for the tests:

```swift
nonisolated struct Store: Codable {
    var projects: [Project]
    var sessions: [Session]
    var todos: [Todo]
    var running: Running?
    var selectedProjectID: UUID?

    private enum CodingKeys: String, CodingKey {
        case projects, sessions, todos, running, selectedProjectID
    }

    init(projects: [Project] = [], sessions: [Session] = [], todos: [Todo] = [],
         running: Running? = nil, selectedProjectID: UUID? = nil) { ... }

    /// Hand-written because the synthesized decoder throws keyNotFound for a missing key even
    /// when the property has a default — which is every store.json written before tasks existed.
    /// AppState treats a decode failure as corruption, so that would quarantine real history.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects          = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions          = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        todos             = try c.decodeIfPresent([Todo].self, forKey: .todos) ?? []
        running           = try c.decodeIfPresent(Running.self, forKey: .running)
        selectedProjectID = try c.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
    }
}
```

## AppState surface

Reads (all derived at render time — nothing aggregated is stored, per the existing rule):

- `var todos: [Todo]` → filtered by `store.selectedProjectID`; `openTodos`, `inProgressTodos`,
  `doneTodos` grouped by status, in store order (`doneTodos` by `completedAt` descending).
- `var runningTodo: Todo?` — drives the chip and the highlighted row.
- `func sessions(forTodo:) -> [Session]` (newest first) and `func total(forTodo:) -> TimeInterval`.
- `func todoCount(for projectID:)` — for the delete-project dialog.

Mutations: `addTodo(title:)`, `renameTodo(_:title:)`, `setTodoStatus(_:_:)`, `deleteTodo(_:)`,
`start(todoID:)`.

Wiring into what exists:

- `start(projectID:)` becomes a thin call into a private `start(projectID:todoID:)`, so the
  existing one-click Start keeps its exact behaviour (clears `todoID`, commits a running session
  first) and there is one place that starts timers.
- `stop()` looks up `running.todoID` and seeds `note: todo?.title ?? ""`, `todoID: todo?.id`.
  A task deleted mid-session therefore yields an empty note rather than a stale title.
- `deleteProject(_:)` also drops that project's tasks.
- `deleteTodo(_:)` clears `store.running?.todoID` when it pointed at the deleted task.

## Files to modify

| File | Change |
| --- | --- |
| `TimeJournal/Model.swift` | `Todo` + `Status`; `Session.todoID`, `Running.todoID`; `Store.todos` + hand-written decoder |
| `TimeJournal/AppState.swift` | task CRUD, groupings, `runningTodo`, `start(todoID:)`, `stop()` note seeding, project-delete cascade, collapse state |
| `TimeJournal/TaskList.swift` *(new)* | `SectionHeader`, `TasksSection`, `TaskRow`, per-task session disclosure |
| `TimeJournal/TimerPanel.swift` | extract `NotesSection`, add `TasksSection` + task chip, auto-expand NOTES on a landing session |
| `TimeJournal/ProjectBar.swift` | delete dialog counts tasks |
| `TimeJournal/MenuBarPanel.swift` | running task's title under the project name |
| `TimeJournalTests/AppStateTodoTests.swift` *(new)* | task behaviour |
| `TimeJournalTests/StorageTests.swift` | legacy-store decode + todos round-trip |
| `plans/task-list.md` | this plan |

Source folders are file-system synchronized groups, so new `.swift` files join the build with no
`project.pbxproj` edits.

## Reuse

| Existing thing | Used for |
| --- | --- |
| `Storage` + `AppState.save()` ([`Storage.swift`](TimeJournal/Storage.swift), [`AppState.swift`](TimeJournal/AppState.swift)) | Tasks persist through the same atomic whole-file write; no new file, no new writer |
| `AppState.start(projectID:)` / `stop()` / `focusSessionID` | Session mechanics and the stop-then-annotate flow, unchanged |
| `SessionEditor` + `SessionRow` ([`TimerPanel.swift`](TimeJournal/TimerPanel.swift)) | Task-linked session rows are the same rows; click to edit times/note as usual |
| `SessionEditor`'s `placeCaretAtEndOfNote()` | The prefilled task title opens editable instead of pre-selected |
| `Format.short` / `Format.clock` ([`Format.swift`](TimeJournal/Format.swift)) | Per-task totals and the live clock; no new formatter |
| `ProjectBar`'s New Project alert with `TextField` | New/rename task dialogs, same shape |
| `viewMode`'s `UserDefaults` pattern ([`AppState.swift:30`](TimeJournal/AppState.swift)) | Where collapse state lives, and why it isn't in `Store` |
| `MenuBarPanel`'s project-name row | Place to put the running task title |
| `makeState(now:)`, `tempStorage()` test helpers | New tests, same injected clock and temp store |

## Steps

- [x] **1. Data-safety test first.** Add a hand-written old-format JSON literal (no `todos`, no
      `todoID`) to `StorageTests.swift` asserting it decodes with `projects`/`sessions` intact and
      empty `todos`; extend `roundTripsThroughDisk` with a `Todo`. Watch it fail to compile, then
      implement the model.
- [x] **2. `Model.swift`.** Add `Todo`/`Status`; add the optional `todoID` links to `Session` and
      `Running` with defaulted inits; add `Store.todos` with `CodingKeys`, the explicit init and
      the `decodeIfPresent` decoder.
- [x] **3. `AppState.swift` — task state.** Groupings, `runningTodo`, `sessions(forTodo:)`,
      `total(forTodo:)`, `todoCount(for:)`; `addTodo`/`renameTodo`/`setTodoStatus`/`deleteTodo`
      (trims titles, ignores empty, reopens a started DONE task, clears a dangling running link,
      keeps sessions). `deleteProject` cascades to tasks.
- [x] **4. `AppState.swift` — task sessions.** Private `start(projectID:todoID:)`, public
      `start(todoID:)` that selects the task's project, and `stop()` seeding `note`/`todoID`.
- [x] **5. `AppState.swift` — collapse preference.** `collapsedSections: Set<String>` persisted to
      `UserDefaults` (`"collapsedPaneSections"`), defaulting to `["done"]` when unset.
- [x] **6. `AppStateTodoTests.swift`.** New file using the existing `makeState(now:)` helper:
      start-from-task seeds note/title/link and selects the project; plain start attaches nothing;
      starting a DONE task reopens it; per-task sessions and total (and a same-noted unlinked
      session is excluded); delete project cascades; delete task keeps sessions and clears the
      running link; status round-trips through `storage.load()`.
- [x] **7. `TaskList.swift`.** `SectionHeader` (chevron + caption header matching the existing
      `NOTES` styling), `TasksSection` (TASKS header with `+ New`, open rows, IN PROGRESS and DONE
      subgroups, empty state "No tasks yet."), `TaskRow` (▶ / ✓ / ‖, per-row total or live clock
      when running, context menu Rename…/Delete Task, disclosure of linked sessions + total), and
      the new/rename alerts.
- [x] **8. `TimerPanel.swift`.** Extract the notes block into `NotesSection` with its own collapse
      chevron; mount `TasksSection` above it; add the task chip under the clock when
      `app.runningTodo != nil`; auto-expand NOTES in the `focusSessionID` `onChange`. Both expanded
      sections take `maxHeight: .infinity` so a collapsed one hands its space to the other.
- [x] **9. `ProjectBar.swift`.** Delete dialog names the task count alongside the session count.
- [x] **10. `MenuBarPanel.swift`.** Running state shows the task title (secondary, under the
      project name) when there is one; idle list unchanged.
- [x] **11. Build clean, then verify by hand** (below). Warnings count: the project builds in
      Swift 5 mode with default `MainActor` isolation, so keep new domain types `nonisolated` and
      check the *test* build for `#expect` warnings too.

## Verification

Automated:

```bash
xcodebuild test -scheme TimeJournal -configuration Debug -only-testing:TimeJournalTests
```

The one that matters most is the legacy-store decode test: it is the standing guard that your
102 sessions still load. Everything else is task behaviour.

Manual, against your real data:

1. **Quit the running TimeJournal first.** There is no file locking — two builds writing one
   `store.json` is a real way to lose data, and that's true today, not because of this change.
2. Back up: `cp "$HOME/Library/Containers/com.alistair.TimeJournal/Data/Library/Application Support/TimeJournal/store.json" /tmp/store.json.bak`
3. `./run.sh`.
4. No error alert on launch. Week total and the 102 notes rows are exactly as before.
5. `+ New` a task in TASKS. It appears in creation order. Press ▶: the chip under the clock reads
   the task title, the row is highlighted with the live clock, and the project is the task's.
6. Stop. The note is prefilled with the task title, caret at the end — typing extends it, and the
   linked session shows under the task's disclosure with a total.
7. `‖` pause → the task moves to IN PROGRESS; `✓` complete → it moves to DONE (collapsed by
   default). Relaunch: all of that is still true, and TASKS/NOTES folded state persists.
8. `python3 -m json.tool` on `store.json` — a `todos` array is present, old sessions are untouched
   apart from a `todoID` on the new one, `projects` and `sessions` counts are 1 and 103.
9. Regression check: start a plain session with no task and confirm there's no chip, no link, and
   the note comes up empty exactly as before.

## Out of scope

Due dates, reminders/notifications, priorities, tags, subtasks, estimates, drag-to-reorder,
a cross-project task list, starting tasks from the menu bar, and any migration of past sessions
into tasks. Also unchanged: project renaming, idle detection, and everything else the design doc
already lists as excluded.
