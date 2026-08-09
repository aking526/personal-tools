# Minimal Time Logger — Design

**Date:** 2026-08-08
**Status:** Approved for planning

## Goal

A minimalist macOS app for tracking time against personal projects. Start a stopwatch,
stop it, jot what you did, and see where the week went. Personal tool, single user,
single machine.

Success means: starting a timer takes one click, stopping and annotating takes one click
plus a sentence, and the week's shape is legible at a glance without interacting with
anything.

## Constraints

- **macOS only, personal use.** No installer, no code signing beyond local development,
  no cross-platform story.
- **Minimum total work.** Every feature is weighed against not building it.
- **Must look good.** The app is used daily and voluntarily; ugly means abandoned.

## Stack

**SwiftUI, in the Xcode project already created at the repo root. Zero third-party
dependencies.**

Rejected alternatives:

- **Tauri / Electron + React.** Full CSS control and a cross-platform future, at the cost
  of a second toolchain, an npm dependency tree, and an IPC boundary. Neither benefit was
  wanted here.
- **Browser PWA.** Effectively zero packaging work, but cannot provide a menu bar timer,
  which is a required feature.
- **SwiftPM package with a hand-rolled `.app` bundle.** Avoids the Xcode wizard, but
  forfeits SwiftUI Previews, hand-writes `Info.plist`, and makes later additions
  (app icon, launch at login) into plist archaeology. The wizard costs 30 seconds once.

Native SwiftUI also makes two requirements nearly free that cost real work elsewhere:
`MenuBarExtra` for the menu bar timer, and system-native appearance (window chrome, dark
mode, SF Symbols, system accent color) for the aesthetic requirement.

### Verified project baseline

The Xcode project is created and confirmed working:

- `xcodebuild -scheme TimeLogger -configuration Debug -derivedDataPath build build` → **BUILD SUCCEEDED**
- `xcodebuild test -scheme TimeLogger -derivedDataPath build -only-testing:TimeLoggerTests` → **TEST SUCCEEDED**
- Test target uses **Swift Testing** (`import Testing`), bundled with the toolchain — no dependency.
- Source folders are **file-system synchronized groups**, so adding a `.swift` file to the
  directory adds it to the build. No `project.pbxproj` edits are ever required.
- `MACOSX_DEPLOYMENT_TARGET = 26.5`. Single-machine app, so no availability guards needed.
- `ENABLE_APP_SANDBOX = YES` (Xcode 26 default, left on).
- Bundle identifier: `com.alistair.TimeLogger`.

## Layout

Two panels with a project switcher above them.

```
┌────────────────────────────────────────────────────┐
│  ⌄ Thesis                                    + New │
├──────────────────────────┬─────────────────────────┤
│  WEEK · Feb 3–9      ‹ › │  THIS WEEK              │
│                          │   9h 10m                │
│  Mon ███████       2:10  │                         │
│  Tue █████         1:40  │   04:12:33              │
│  Wed ██████████    3:05  │  ┌───────────────────┐  │
│  Thu ███           0:55  │  │     ▶  START      │  │
│  Fri ████          1:20  │  └───────────────────┘  │
│  Sat                 —   │                         │
│  Sun                 —   │  NOTES                  │
│                          │  · fixed ch.3    1:12   │
│  Total            9:10   │  · lit review    0:48   │
└──────────────────────────┴─────────────────────────┘
```

Both panels always describe **the same project and the same week**. Paging the left panel
to a past week changes the right panel's total and notes list with it, and the right
panel's heading changes from `THIS WEEK` to the date range. There is never ambiguity
about what the large number refers to.

## Data model

Four `Codable` structs. Everything displayed — day totals, week totals, the stopwatch
reading — is **derived from `start`/`end` at render time**. No aggregate is ever stored,
so no cache can go stale and the dashboard cannot disagree with the sessions behind it.

```swift
struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
}

struct Session: Codable, Identifiable, Hashable {
    let id: UUID
    var projectID: UUID
    var start: Date
    var end: Date
    var note: String        // may be empty; a blank note is valid
}

struct Running: Codable, Hashable {
    var projectID: UUID
    var start: Date
}

struct Store: Codable {
    var projects: [Project] = []
    var sessions: [Session] = []
    var running: Running?
    var selectedProjectID: UUID?
}
```

### Persistence

A single JSON file, loaded once at launch and written on every mutation.

**Path:** `~/Library/Containers/com.alistair.TimeLogger/Data/Library/Application Support/TimeLogger/store.json`

Resolved via `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask)`.
The container prefix is a consequence of the app sandbox; it is where the file to back up
lives.

Five years of heavy use is on the order of 5,000 sessions — a few hundred KB. SQLite would
be machinery for a problem that never arrives.

**Writes are atomic** (`Data.write(to:options:.atomic)`), so an interrupted write cannot
truncate the file and lose the history.

**`running` is persisted the instant Start is pressed.** A crash, a force quit, or a
reboot cannot silently swallow hours of work — on next launch the timer is still running
from its original start time. This is the one place the design deliberately refuses to be
minimal.

Load failure (missing file) yields an empty store — that is a first launch, not an error.

Load failure (corrupt JSON) surfaces an error **and quarantines the unreadable file**: it is
renamed to `store.json.corrupt-<uuid>` alongside the original before anything else runs, and
the error names the path it was kept at. Surfacing the error alone is not enough. The app
loads an empty store to stay usable, and the very next thing the user does — creating a
project, starting a timer — calls `save()`, which would atomically write that empty store
straight over a file still holding years of history. Moving it aside first is what makes the
error message true rather than an epitaph.

## Architecture

`AppState` is the single writer and the only mutable object. Views read from it and call
its methods; **no view touches storage directly.** That one rule is the whole architecture.

| File | Responsibility |
|---|---|
| `Model.swift` | The four structs. Pure data, no behavior. |
| `Storage.swift` | Load/save JSON, atomic write, path resolution. Knows nothing about UI. |
| `AppState.swift` | `@Observable`. Owns the `Store`, the tick, and every mutation: `start`, `stop`, `addProject`, `deleteProject`, `select`, `updateSession`, `deleteSession`. |
| `Format.swift` | Duration formatting and week math. Pure functions. |
| `ProjectBar.swift` | Top switcher and `+ New`. |
| `WeekView.swift` | Left panel: week header, seven day rows, total. |
| `TimerPanel.swift` | Right panel: week total, stopwatch, Start/Stop, notes list. |
| `SessionEditor.swift` | Popover for editing or deleting one session. |
| `TimeLoggerApp.swift` | `@main`, `WindowGroup`, `MenuBarExtra`. (Already exists.) |
| `ContentView.swift` | Assembles `ProjectBar` + `HSplitView`. (Already exists, will be replaced.) |

Each view file reads from `AppState` and renders; each is independently previewable in the
Xcode canvas.

## Behavior

### Timer

**One running timer at a time, globally.** Starting a timer on another project stops the
current one first, committing that session. There is no way to have two clocks running.

The stopwatch ticks via a 1-second `Timer` publisher that exists **only while a timer is
running**, so an idle app does no per-second work.

### Stop → note

Pressing Stop does **not** open a modal. The finished session drops into the top of the
notes list with the text cursor already in it. Type and press Enter, or press Escape and
leave it blank. Stopping the clock is never blocked by anything.

### Projects

`+ New` creates a project and selects it. A context menu on each row of the switcher
offers **Delete**.

Deletion is destructive and irreversible, so it is the one action in the app that asks
first: a confirmation dialog naming the project and the number of sessions that will be
destroyed with it. On confirm, `deleteProject` removes the project and all of its
sessions, and additionally:

- If that project's timer was running, the running timer is discarded.
- If it was the selected project, selection moves to the first remaining project, or to
  `nil` when none are left.

### Week view

- Week runs **Monday to Sunday**, hardcoded, matching the layout above (not
  `Calendar.firstWeekday`, which would give Sunday-first in this locale).
- `‹ ›` page backward and forward. When displaying any week other than the current one,
  the week header becomes a button that jumps back to the current week; on the current
  week it is plain text.
- Bars scale to the **busiest day of the displayed week**, so a light week is still
  legible rather than seven flat slivers.
- Today's row is subtly emphasized when the current week is displayed.
- Days with no time show `—`, not `0:00`.
- All week arithmetic goes through `Calendar`, never through `86400`.

### Notes list

Shows every session in the **displayed week**, newest first, under small day headers. Each
row shows the note and the session's duration. Clicking a row opens `SessionEditor`.

### Editing sessions

`SessionEditor` is a popover with start time, end time, and Delete. Duration is derived
and shown live as the times change; Save is disabled unless the end is after the start.
This exists to repair the inevitable "left it running overnight" — without it, a single
mistake permanently poisons the statistics.

### Manual entry

A **Log Time** button in the notes header opens the same editor with no session behind
it, for work you did without starting the clock. It defaults to the hour before now, or
the hour before midday when a past week is on screen. Nothing is written until Add;
Cancel discards.

On Add, the displayed week follows the new session, so an entry dated outside the week
being browsed doesn't vanish the moment it's saved, and the cursor lands in its note —
the same landing the stopwatch gives you.

This was originally out of scope. It came back because the alternative to a forgotten
hour is a wrong week total, which is the one thing the app exists to get right.

### Menu bar

`MenuBarExtra` showing the elapsed time when a timer runs, a static icon when idle.
Clicking it opens a small popover:

- **Running:** project name, elapsed time, Stop.
- **Idle:** the project list; clicking one starts its timer.

### Empty states

- **No projects:** the window prompts to create the first one; the switcher shows `+ New` only.
- **A project with no sessions:** the week renders with seven `—` rows and a `0:00` total,
  not a special-cased empty view.

## Visual design

- System font throughout; system accent color, so the app matches the user's macOS setting
  rather than imposing a brand.
- The stopwatch uses `.monospacedDigit()`. Without it the digits reflow every tick, and
  that single detail reads as cheap immediately.
- Hairline dividers, generous whitespace, restrained use of color — color carries meaning
  (running, today, accent) and is otherwise absent.
- Light and dark both supported, which is free by using semantic colors
  (`.primary`, `.secondary`, `.background`) rather than literal ones.

## Testing

One test file, `TimeLoggerTests.swift`, using Swift Testing. It covers only where bugs
actually hide — the date math and the state transition — not the views:

1. Sessions bucket into the correct days of a week.
2. A session on a week boundary lands in exactly one week.
3. **Week totals are correct across a daylight-saving transition.** A "day" is not always
   24 hours; this is the one genuine trap in the app.
4. Duration formatting: zero, sub-minute, multi-hour.
5. `stop()` converts `running` into a `Session` with the correct span and clears `running`.
6. `deleteProject()` removes the project's sessions, leaves other projects' sessions
   untouched, discards a running timer belonging to it, and moves selection.

Views are not tested. SwiftUI Previews cover that need at far lower cost.

## Explicitly out of scope

Not building, and not designing for: idle detection,
a month or calendar grid view, project renaming and archiving, tags or subtasks,
billing rates, CSV export, iCloud sync, reports beyond the current week, a custom app icon,
notifications, global hotkeys, concurrent timers, and any non-macOS platform.

Project *deletion* was added to scope during review (see **Projects** above); renaming was
not. Manual entry was added after the first build (see **Manual entry** above).

## Build and run

```bash
./run.sh                                          # build and launch
xcodebuild test -scheme TimeLogger -derivedDataPath build -only-testing:TimeLoggerTests
build/Build/Products/Debug/TimeLogger.app/Contents/MacOS/TimeLogger   # run with stdout in terminal
```

`run.sh` (to be written):

```bash
#!/bin/bash
set -e
xcodebuild -scheme TimeLogger -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/TimeLogger.app
```
