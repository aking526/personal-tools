# Minimal Time Logger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A two-panel macOS menu-bar time logger: pick a project, run a stopwatch, annotate each stopped session, and read the week at a glance.

**Architecture:** A pure domain layer (`Model`, `Format`, `Week`, `Stats`) with no UI or I/O, a `Storage` struct that reads and writes one JSON file, and a single `@Observable AppState` that is the only mutable object and the only writer. Views read `AppState` from the SwiftUI environment and call its methods; no view touches storage. Every displayed number is derived from session `start`/`end` at render time — nothing aggregated is stored.

**Tech Stack:** Swift 6.3, SwiftUI, Observation (`@Observable`), Foundation `Calendar`/`JSONEncoder`, Swift Testing. Zero third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-08-08-time-journal-design.md`

## Global Constraints

- **Zero third-party dependencies.** No SPM packages, no CocoaPods, no Homebrew. Foundation and SwiftUI only.
- **Never edit `TimeJournal.xcodeproj/project.pbxproj`.** Source folders are file-system synchronized groups — creating a `.swift` file in `TimeJournal/` or `TimeJournalTests/` adds it to the build automatically.
- **All date arithmetic goes through `Calendar`.** Never `86400`, never `addingTimeInterval` for day or week offsets. A day is not always 24 hours.
- **Weeks run Monday→Sunday**, hardcoded via `calendar.firstWeekday = 2`. Do not use the locale default, which is Sunday-first here.
- **Every function touching dates takes an explicit `calendar: Calendar` parameter** so tests can pin the time zone. Never read `Calendar.current` inside domain code.
- **Writes are atomic:** `Data.write(to:options:.atomic)`.
- Deployment target is macOS 26.5 — no `@available` guards needed.
- The project builds in **Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**. Concurrency violations surface as *warnings* here, not errors — treat them as errors anyway (Task 14 enforces a warning-clean build).
- **The domain layer is `nonisolated`; only `AppState` and the views are main-actor.** Default actor isolation would otherwise make the pure types main-actor-isolated, which breaks two things: a main-actor-isolated `Storage.appSupport()` cannot be used as a default argument (evaluated in a nonisolated context), and main-actor-isolated `Equatable` conformances on the model structs cannot be used inside Swift Testing's `#expect` macro expansions. So `Project`, `Session`, `Running`, `Store`, `Storage`, `Format`, `Week`, `DayTotal`, and `Stats` are each declared `nonisolated`. Keep it that way — and check warnings under `xcodebuild test`, not just `xcodebuild build`: the `#expect` warnings only appear in the test build.
- Bundle identifier is `com.alistair.TimeLogger`; the app is sandboxed.
- Build: `xcodebuild -scheme TimeJournal -configuration Debug -derivedDataPath build build`
- Test: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests`

**Four deliberate refinements to the spec, already decided — implement as written here:**
1. The spec lists one `Format.swift` for "duration formatting and week math". This plan splits it into `Format.swift` (duration strings) and `Week.swift` (week math + bucketing), because they are separate responsibilities.
2. `stop()` discards sessions shorter than one second, so a mis-click cannot litter the notes list with `0:00` entries.
3. The spec puts notes "under small day headers". This plan puts the day label inline on each row instead (`Wed · fixed ch.3 · 1:12`) — same information, no grouping logic, and it keeps every row the same shape.
4. The spec puts the note field inside `SessionEditor`. This plan leaves the note editable inline in the notes row and keeps the editor to times and deletion, so the common case (write a note) needs no popover at all.

**One behavior the spec left open, decided here:** a session that crosses midnight counts entirely against the day it *started* on, rather than being split. Pinned by a test in Task 3.

---

### Task 1: Build script and domain types

**Files:**
- Create: `run.sh`
- Create: `TimeJournal/Model.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Project`, `Session`, `Running`, `Store` — all `Codable`. `Session.duration: TimeInterval`.

- [ ] **Step 1: Create the run script**

```bash
#!/bin/bash
set -e
xcodebuild -scheme TimeJournal -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/TimeJournal.app
```

- [ ] **Step 2: Make it executable and confirm it launches the template app**

Run: `chmod +x run.sh && ./run.sh`
Expected: `** BUILD SUCCEEDED **`, then a window appears showing the "Hello, world!" template. Quit the app.

- [ ] **Step 3: Create the domain types**

Create `TimeJournal/Model.swift`:

```swift
import Foundation

struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct Session: Codable, Identifiable, Hashable {
    let id: UUID
    var projectID: UUID
    var start: Date
    var end: Date
    var note: String

    init(id: UUID = UUID(), projectID: UUID, start: Date, end: Date, note: String = "") {
        self.id = id
        self.projectID = projectID
        self.start = start
        self.end = end
        self.note = note
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
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

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild -scheme TimeJournal -configuration Debug -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add run.sh TimeJournal/Model.swift
git commit -m "Add build script and domain types"
```

---

### Task 2: Duration formatting

**Files:**
- Create: `TimeJournal/Format.swift`
- Modify: `TimeJournalTests/TimeJournalTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Format.clock(_:) -> String` (`"04:12:33"`), `Format.short(_:) -> String` (`"1:12"`), `Format.total(_:) -> String` (`"9h 10m"`). All take `TimeInterval`, all clamp negatives to zero.

- [ ] **Step 1: Write the failing tests**

Replace the entire contents of `TimeJournalTests/TimeJournalTests.swift` with:

```swift
import Testing
import Foundation
@testable import TimeJournal

struct FormatTests {
    @Test func clockPadsToTwoDigits() {
        #expect(Format.clock(0) == "00:00:00")
        #expect(Format.clock(59) == "00:00:59")
        #expect(Format.clock(60) == "00:01:00")
        #expect(Format.clock(3600) == "01:00:00")
        #expect(Format.clock(15153) == "04:12:33")
    }

    @Test func clockClampsNegatives() {
        #expect(Format.clock(-10) == "00:00:00")
    }

    @Test func shortDropsSecondsAndLeadingZero() {
        #expect(Format.short(0) == "0:00")
        #expect(Format.short(4320) == "1:12")
        #expect(Format.short(4379) == "1:12")   // seconds truncate, never round up
        #expect(Format.short(37800) == "10:30")
    }

    @Test func totalReadsAsProse() {
        #expect(Format.total(0) == "0m")
        #expect(Format.total(600) == "10m")
        #expect(Format.total(3600) == "1h")
        #expect(Format.total(33000) == "9h 10m")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: compile failure — `cannot find 'Format' in scope`.

- [ ] **Step 3: Implement**

Create `TimeJournal/Format.swift`:

```swift
import Foundation

enum Format {
    /// "04:12:33" — for the running stopwatch. Always two-digit padded.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "1:12" — for a single session or a day total.
    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }

    /// "9h 10m" — for week totals, where prose reads better than a colon.
    static func total(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let (h, m) = (s / 3600, (s % 3600) / 60)
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add TimeJournal/Format.swift TimeJournalTests/TimeJournalTests.swift
git commit -m "Add duration formatting"
```

---

### Task 3: Week math and day bucketing

This is where the only genuinely tricky bugs in the app live. Take the DST test seriously — if it fails, the day arithmetic is wrong, not the test.

**Files:**
- Create: `TimeJournal/Week.swift`
- Create: `TimeJournalTests/WeekTests.swift`

**Interfaces:**
- Consumes: `Session` (Task 1).
- Produces:
  - `Week.start(of: Date, calendar: Calendar) -> Date` — Monday 00:00 of that date's week
  - `Week.days(from: Date, calendar: Calendar) -> [Date]` — seven day-start dates
  - `Week.shift(_ weekStart: Date, byWeeks: Int, calendar: Calendar) -> Date`
  - `Week.label(weekStart: Date, calendar: Calendar) -> String` — `"Feb 3 – 9"` / `"Jan 29 – Feb 4"`
  - `DayTotal { date: Date, seconds: TimeInterval, id: Date }`
  - `Stats.dayTotals(sessions:projectID:weekStart:calendar:) -> [DayTotal]` — always 7 entries
  - `Stats.weekTotal(sessions:projectID:weekStart:calendar:) -> TimeInterval`

- [ ] **Step 1: Write the failing tests**

Create `TimeJournalTests/WeekTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: compile failure — `cannot find 'Week' in scope`.

- [ ] **Step 3: Implement**

Create `TimeJournal/Week.swift`:

```swift
import Foundation

/// Monday-based week arithmetic. Every function takes an explicit calendar so
/// callers (and tests) control the time zone.
enum Week {
    /// Forces Monday-first regardless of locale.
    private static func mondayFirst(_ calendar: Calendar) -> Calendar {
        var cal = calendar
        cal.firstWeekday = 2
        return cal
    }

    static func start(of date: Date, calendar: Calendar) -> Date {
        let cal = mondayFirst(calendar)
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    static func days(from weekStart: Date, calendar: Calendar) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    static func shift(_ weekStart: Date, byWeeks weeks: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .weekOfYear, value: weeks, to: weekStart) ?? weekStart
    }

    /// "Feb 2 – 8" within one month, "Jan 26 – Feb 1" across a boundary.
    static func label(weekStart: Date, calendar: Calendar) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart

        let monthDay = DateFormatter()
        monthDay.calendar = calendar
        monthDay.timeZone = calendar.timeZone
        monthDay.locale = calendar.locale ?? Locale(identifier: "en_US")
        monthDay.dateFormat = "MMM d"

        let dayOnly = DateFormatter()
        dayOnly.calendar = calendar
        dayOnly.timeZone = calendar.timeZone
        dayOnly.locale = monthDay.locale
        dayOnly.dateFormat = "d"

        let sameMonth = calendar.isDate(weekStart, equalTo: end, toGranularity: .month)
        let tail = sameMonth ? dayOnly.string(from: end) : monthDay.string(from: end)
        return "\(monthDay.string(from: weekStart)) – \(tail)"
    }
}

struct DayTotal: Identifiable, Hashable {
    let date: Date
    let seconds: TimeInterval
    var id: Date { date }
}

enum Stats {
    /// Always returns exactly seven entries, one per day, zero-filled.
    /// A session belongs to the day it started on.
    static func dayTotals(sessions: [Session],
                          projectID: UUID,
                          weekStart: Date,
                          calendar: Calendar) -> [DayTotal] {
        let weekEnd = Week.shift(weekStart, byWeeks: 1, calendar: calendar)
        var sums: [Date: TimeInterval] = [:]
        for session in sessions
        where session.projectID == projectID && session.start >= weekStart && session.start < weekEnd {
            sums[calendar.startOfDay(for: session.start), default: 0] += session.duration
        }
        return Week.days(from: weekStart, calendar: calendar).map {
            DayTotal(date: $0, seconds: sums[$0] ?? 0)
        }
    }

    static func weekTotal(sessions: [Session],
                          projectID: UUID,
                          weekStart: Date,
                          calendar: Calendar) -> TimeInterval {
        dayTotals(sessions: sessions, projectID: projectID, weekStart: weekStart, calendar: calendar)
            .reduce(0) { $0 + $1.seconds }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

If `dayMathSurvivesDaylightSaving` fails, do not weaken the assertion — the implementation is using fixed-second arithmetic somewhere.

- [ ] **Step 5: Commit**

```bash
git add TimeJournal/Week.swift TimeJournalTests/WeekTests.swift
git commit -m "Add Monday-based week math and day bucketing"
```

---

### Task 4: JSON storage

**Files:**
- Create: `TimeJournal/Storage.swift`
- Create: `TimeJournalTests/StorageTests.swift`

**Interfaces:**
- Consumes: `Store` (Task 1).
- Produces: `Storage { let url: URL }`, `Storage.appSupport() -> Storage`, `load() throws -> Store`, `save(_ store: Store) throws`.

- [ ] **Step 1: Write the failing tests**

Create `TimeJournalTests/StorageTests.swift`:

```swift
import Testing
import Foundation
@testable import TimeJournal

private func tempStorage() -> Storage {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
    return Storage(url: dir.appendingPathComponent("store.json"))
}

struct StorageTests {
    @Test func missingFileLoadsEmptyStore() throws {
        let store = try tempStorage().load()
        #expect(store.projects.isEmpty)
        #expect(store.sessions.isEmpty)
        #expect(store.running == nil)
    }

    @Test func roundTripsThroughDisk() throws {
        let storage = tempStorage()
        let project = Project(name: "Thesis", createdAt: Date(timeIntervalSince1970: 1_000_000))
        var store = Store()
        store.projects = [project]
        store.sessions = [Session(projectID: project.id,
                                  start: Date(timeIntervalSince1970: 1_000_000),
                                  end: Date(timeIntervalSince1970: 1_003_600),
                                  note: "fixed ch.3")]
        store.running = Running(projectID: project.id, start: Date(timeIntervalSince1970: 1_010_000))
        store.selectedProjectID = project.id

        try storage.save(store)
        let loaded = try storage.load()

        #expect(loaded.projects == store.projects)
        #expect(loaded.sessions == store.sessions)
        #expect(loaded.running == store.running)
        #expect(loaded.selectedProjectID == project.id)
    }

    @Test func savingCreatesIntermediateDirectories() throws {
        let storage = tempStorage()
        try storage.save(Store())
        #expect(FileManager.default.fileExists(atPath: storage.url.path))
    }

    /// Corrupt data must surface, not silently reset — a silent empty store would be
    /// overwritten by the next save and take the history with it.
    @Test func corruptFileThrows() throws {
        let storage = tempStorage()
        try FileManager.default.createDirectory(at: storage.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: storage.url)
        #expect(throws: (any Error).self) { try storage.load() }
    }

    @Test func fileIsHumanReadable() throws {
        let storage = tempStorage()
        var store = Store()
        store.projects = [Project(name: "Thesis", createdAt: Date(timeIntervalSince1970: 0))]
        try storage.save(store)

        let text = try String(contentsOf: storage.url, encoding: .utf8)
        #expect(text.contains("Thesis"))
        #expect(text.contains("1970-01-01"))   // ISO-8601 dates, not float timestamps
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: compile failure — `cannot find 'Storage' in scope`.

- [ ] **Step 3: Implement**

Create `TimeJournal/Storage.swift`:

```swift
import Foundation

/// Reads and writes the whole store as one JSON file. The dataset is a few hundred KB
/// after years of use, so whole-file rewrites are cheaper than any alternative.
struct Storage {
    let url: URL

    /// Under the app sandbox this resolves inside
    /// ~/Library/Containers/com.alistair.TimeLogger/Data/...
    static func appSupport() -> Storage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Storage(url: base.appendingPathComponent("TimeLogger/store.json"))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A missing file is a first launch, not an error. Malformed contents ARE an error —
    /// returning an empty store would let the next save destroy the real history.
    func load() throws -> Store {
        guard FileManager.default.fileExists(atPath: url.path) else { return Store() }
        return try Self.decoder.decode(Store.self, from: Data(contentsOf: url))
    }

    func save(_ store: Store) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(store).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add TimeJournal/Storage.swift TimeJournalTests/StorageTests.swift
git commit -m "Add atomic JSON storage"
```

---

### Task 5: AppState — loading and the stopwatch

**Files:**
- Create: `TimeJournal/AppState.swift`
- Create: `TimeJournalTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `Store`, `Storage`, `Session`, `Running`, `Week`.
- Produces: `@Observable final class AppState` with
  - `init(storage: Storage = .appSupport(), now: @escaping () -> Date = Date.init, calendar: Calendar = .current)`
  - `var store: Store`, `var loadError: String?`, `var tickNow: Date`, `var lastStoppedSessionID: UUID?`
  - `var elapsed: TimeInterval`, `var selectedProject: Project?`
  - `func start(projectID: UUID)`, `func stop()`

- [ ] **Step 1: Write the failing tests**

Create `TimeJournalTests/AppStateTests.swift`:

```swift
import Testing
import Foundation
@testable import TimeJournal

@MainActor
private func makeState(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000_000) }) -> AppState {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
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
        #expect(state.lastStoppedSessionID == session.id)
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
        #expect(state.lastStoppedSessionID == nil)
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
            .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
        let storage = Storage(url: dir.appendingPathComponent("store.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storage.url)

        let state = AppState(storage: storage, now: Date.init, calendar: .current)
        #expect(state.loadError != nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: compile failure — `cannot find 'AppState' in scope`.

- [ ] **Step 3: Implement**

Create `TimeJournal/AppState.swift`. `addProject` is included here because the timer tests need projects to exist; Task 6 adds deletion.

```swift
import Foundation
import Observation

/// The single mutable object and the single writer. Views read it and call its methods;
/// no view touches Storage directly.
@Observable
@MainActor
final class AppState {
    private(set) var store: Store
    var loadError: String?

    /// Bumped once a second while a timer runs, purely to drive re-renders.
    var tickNow: Date
    /// Set by `stop()` so the notes list can focus the session that just landed.
    var lastStoppedSessionID: UUID?

    @ObservationIgnored let storage: Storage
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored private var ticker: Timer?

    init(storage: Storage = .appSupport(),
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.storage = storage
        self.now = now
        self.calendar = calendar
        self.tickNow = now()
        do {
            self.store = try storage.load()
        } catch {
            self.store = Store()
            self.loadError = "Could not read your saved time log at \(storage.url.path).\n\n\(error.localizedDescription)"
        }
        if store.running != nil { startTicking() }
    }

    // MARK: - Derived

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

    // MARK: - Timer

    func start(projectID: UUID) {
        if store.running != nil { stop() }
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
            lastStoppedSessionID = session.id
        }
        save()
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add TimeJournal/AppState.swift TimeJournalTests/AppStateTests.swift
git commit -m "Add AppState with stopwatch start/stop and crash-safe running timer"
```

---

### Task 6: AppState — project deletion

**Files:**
- Modify: `TimeJournal/AppState.swift`
- Create: `TimeJournalTests/AppStateProjectTests.swift`

**Interfaces:**
- Consumes: `AppState` (Task 5).
- Produces: `func deleteProject(_ id: UUID)`, `func select(_ id: UUID)`, `func sessionCount(for id: UUID) -> Int`.

- [ ] **Step 1: Write the failing tests**

Create `TimeJournalTests/AppStateProjectTests.swift`:

```swift
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

@MainActor
struct AppStateProjectTests {
    @Test func addingSelectsTheNewProject() {
        let state = makeState()
        let a = state.addProject(name: "A")
        #expect(state.store.selectedProjectID == a.id)
        let b = state.addProject(name: "B")
        #expect(state.store.selectedProjectID == b.id)
        #expect(state.selectedProject?.name == "B")
    }

    @Test func deleteRemovesTheProjectAndItsSessions() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let a = state.addProject(name: "A")
        let b = state.addProject(name: "B")

        state.start(projectID: a.id)
        clock = Date(timeIntervalSince1970: 1_003_600)
        state.stop()
        state.start(projectID: b.id)
        clock = Date(timeIntervalSince1970: 1_007_200)
        state.stop()

        state.deleteProject(a.id)

        #expect(state.store.projects.map(\.name) == ["B"])
        #expect(state.store.sessions.count == 1)
        #expect(state.store.sessions.first?.projectID == b.id)
    }

    @Test func deletingTheRunningProjectDiscardsItsTimer() {
        let state = makeState()
        let a = state.addProject(name: "A")
        state.start(projectID: a.id)

        state.deleteProject(a.id)

        #expect(state.store.running == nil)
        #expect(state.store.sessions.isEmpty)
    }

    @Test func deletingAnIdleProjectLeavesAnotherProjectsTimerRunning() {
        let state = makeState()
        let a = state.addProject(name: "A")
        let b = state.addProject(name: "B")
        state.start(projectID: b.id)

        state.deleteProject(a.id)

        #expect(state.store.running?.projectID == b.id)
    }

    @Test func deletingTheSelectedProjectMovesSelection() {
        let state = makeState()
        let a = state.addProject(name: "A")
        let b = state.addProject(name: "B")
        state.select(a.id)

        state.deleteProject(a.id)

        #expect(state.store.selectedProjectID == b.id)
    }

    @Test func deletingTheLastProjectClearsSelection() {
        let state = makeState()
        let a = state.addProject(name: "A")
        state.deleteProject(a.id)
        #expect(state.store.selectedProjectID == nil)
        #expect(state.selectedProject == nil)
    }

    @Test func deletionPersists() throws {
        let state = makeState()
        let a = state.addProject(name: "A")
        state.addProject(name: "B")
        state.deleteProject(a.id)
        #expect(try state.storage.load().projects.map(\.name) == ["B"])
    }

    @Test func sessionCountDrivesTheConfirmationCopy() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let state = makeState(now: { clock })
        let a = state.addProject(name: "A")
        for step in 1...3 {
            state.start(projectID: a.id)
            clock = Date(timeIntervalSince1970: 1_000_000 + Double(step) * 3600)
            state.stop()
        }
        #expect(state.sessionCount(for: a.id) == 3)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: compile failure — `value of type 'AppState' has no member 'deleteProject'`.

- [ ] **Step 3: Implement**

In `TimeJournal/AppState.swift`, add these methods to the `// MARK: - Projects` section, directly after `addProject`:

```swift
    func select(_ id: UUID) {
        store.selectedProjectID = id
        save()
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add TimeJournal/AppState.swift TimeJournalTests/AppStateProjectTests.swift
git commit -m "Add project deletion with session cascade"
```

---

### Task 7: AppState — session editing and week navigation

**Files:**
- Modify: `TimeJournal/AppState.swift`
- Create: `TimeJournalTests/AppStateWeekTests.swift`

**Interfaces:**
- Consumes: `AppState` (Tasks 5–6), `Week`, `Stats`, `DayTotal`.
- Produces:
  - `func updateSession(_ session: Session)`, `func deleteSession(_ id: UUID)`
  - `var displayedWeekStart: Date`, `var isCurrentWeek: Bool`, `var weekLabel: String`
  - `func goToWeek(offset: Int)`, `func goToCurrentWeek()`
  - `var dayTotals: [DayTotal]`, `var weekTotal: TimeInterval`, `var weekSessions: [Session]`

- [ ] **Step 1: Write the failing tests**

Create `TimeJournalTests/AppStateWeekTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: compile failure — `value of type 'AppState' has no member 'displayedWeekStart'`.

- [ ] **Step 3: Implement**

In `TimeJournal/AppState.swift`:

Add a stored property alongside `lastStoppedSessionID`:

```swift
    /// Monday 00:00 of the week both panels are showing.
    var displayedWeekStart: Date
```

Set it at the end of `init`, before the `if store.running != nil` line:

```swift
        self.displayedWeekStart = Week.start(of: now(), calendar: calendar)
```

Add a new section before `// MARK: - Persistence`:

```swift
    // MARK: - Sessions

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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add TimeJournal/AppState.swift TimeJournalTests/AppStateWeekTests.swift
git commit -m "Add session editing and week navigation to AppState"
```

---

### Task 8: Window shell and project switcher

The domain layer is finished and tested. Everything from here is visual — verified by building, launching, and looking.

**Files:**
- Modify: `TimeJournal/TimeJournalApp.swift`
- Modify: `TimeJournal/ContentView.swift`
- Create: `TimeJournal/ProjectBar.swift`

**Interfaces:**
- Consumes: `AppState` (Tasks 5–7).
- Produces: `ContentView`, `ProjectBar`. `AppState` is placed in the SwiftUI environment by `TimeJournalApp` and read with `@Environment(AppState.self)`.

- [ ] **Step 1: Wire AppState into the app**

Replace the entire contents of `TimeJournal/TimeJournalApp.swift`:

```swift
import SwiftUI

@main
struct TimeJournalApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 880, height: 540)
        .windowResizability(.contentMinSize)
    }
}
```

- [ ] **Step 2: Build the project switcher**

Create `TimeJournal/ProjectBar.swift`:

```swift
import SwiftUI

/// Top row: which project everything below refers to, plus create and delete.
struct ProjectBar: View {
    @Environment(AppState.self) private var app

    @State private var isNaming = false
    @State private var draftName = ""
    @State private var pendingDeletion: Project?

    var body: some View {
        HStack(spacing: 12) {
            if app.store.projects.isEmpty {
                Text("No projects yet")
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(app.store.projects) { project in
                        Button {
                            app.select(project.id)
                        } label: {
                            if project.id == app.store.selectedProjectID {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                    Divider()
                    if let selected = app.selectedProject {
                        Button("Delete \(selected.name)…", role: .destructive) {
                            pendingDeletion = selected
                        }
                    }
                } label: {
                    Text(app.selectedProject?.name ?? "Select a project")
                        .font(.title3.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            Button {
                draftName = ""
                isNaming = true
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.accessoryBar)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .alert("New Project", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                app.addProject(name: name)
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { project in
            Button("Delete Project and \(app.sessionCount(for: project.id)) Session\(app.sessionCount(for: project.id) == 1 ? "" : "s")",
                   role: .destructive) {
                app.deleteProject(project.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This cannot be undone.")
        }
    }
}
```

- [ ] **Step 3: Assemble the window**

Replace the entire contents of `TimeJournal/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            ProjectBar()
            Divider()
            HSplitView {
                Color.clear
                    .frame(minWidth: 320, idealWidth: 400)
                Color.clear
                    .frame(minWidth: 300, idealWidth: 420)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .alert("Time Log Problem",
               isPresented: Binding(get: { app.loadError != nil },
                                    set: { if !$0 { app.loadError = nil } })) {
            Button("OK") { app.loadError = nil }
        } message: {
            Text(app.loadError ?? "")
        }
    }
}

#Preview {
    // Point at a path that does NOT exist, so Storage.load() takes its first-launch branch
    // and the canvas renders the calm empty state. "/dev/null" would be worse than useless:
    // it exists, so load() tries to decode zero bytes, throws, and every preview render
    // comes up with the error alert on top of the UI you were trying to look at.
    ContentView()
        .environment(AppState(
            storage: Storage(url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("TimeJournalPreview-\(UUID().uuidString)/store.json")),
            now: Date.init,
            calendar: .current))
}
```

- [ ] **Step 4: Build, launch, and verify by hand**

Run: `./run.sh`

Check each of these:
- The window opens at roughly 880×540 with an empty two-pane split below the top bar.
- The bar reads "No projects yet".
- Clicking **New** opens a naming alert; creating "Thesis" makes it the menu title.
- Creating "Client" switches the title to "Client"; the menu lists both with a checkmark on the selected one.
- Selecting "Thesis" from the menu changes the title back.
- The menu's **Delete Thesis…** shows a confirmation reading "Delete Project and 0 Sessions"; **Cancel** leaves it alone, confirming removes it and selects "Client".
- Quit and relaunch — the remaining project is still there.

- [ ] **Step 5: Commit**

```bash
git add TimeJournal/TimeJournalApp.swift TimeJournal/ContentView.swift TimeJournal/ProjectBar.swift
git commit -m "Add window shell and project switcher"
```

---

### Task 9: Timer panel

**Files:**
- Create: `TimeJournal/TimerPanel.swift`
- Modify: `TimeJournal/ContentView.swift`

**Interfaces:**
- Consumes: `AppState`, `Format`.
- Produces: `TimerPanel` — the right pane. Replaces the second `Color.clear` in `ContentView`.

- [ ] **Step 1: Build the panel**

Create `TimeJournal/TimerPanel.swift`:

```swift
import SwiftUI

/// Right pane: what the displayed week adds up to, and the control that changes it.
struct TimerPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.isCurrentWeek ? "THIS WEEK" : app.weekLabel.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Text(Format.total(app.weekTotal))
                    .font(.system(size: 34, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text(Format.clock(app.elapsed))
                    .font(.system(size: 46, weight: .thin))
                    .monospacedDigit()
                    .foregroundStyle(app.isRunning ? Color.accentColor : .secondary)

                Button(action: toggle) {
                    Label(app.isRunning ? "Stop" : "Start",
                          systemImage: app.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(app.isRunning ? .red : .accentColor)
                .disabled(app.selectedProject == nil)
                .keyboardShortcut(.space, modifiers: [])
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle() {
        if let running = app.store.running {
            // Bring the timer's own project and week into view BEFORE stopping. Nothing stops
            // you switching project or paging weeks while a timer runs, and if we stop while
            // looking elsewhere the new session isn't in `weekSessions` — so the row never
            // renders, focus has nothing to land on, and stop-then-annotate dead-ends.
            // Ordering matters: correcting state first means the row exists by the time
            // `lastStoppedSessionID` changes and the focus handler fires.
            if app.store.selectedProjectID != running.projectID { app.select(running.projectID) }
            if !app.isCurrentWeek { app.goToCurrentWeek() }
            app.stop()
        } else if let project = app.selectedProject {
            app.start(projectID: project.id)
        }
    }
}
```

- [ ] **Step 2: Put it in the window**

In `TimeJournal/ContentView.swift`, replace the second pane:

```swift
                Color.clear
                    .frame(minWidth: 300, idealWidth: 420)
```

with:

```swift
                TimerPanel()
                    .frame(minWidth: 300, idealWidth: 420)
```

- [ ] **Step 3: Build, launch, and verify by hand**

Run: `./run.sh`

Check each of these:
- With no project, the Start button is disabled and the stopwatch reads `00:00:00` in grey.
- Creating a project enables Start.
- Pressing Start turns the stopwatch to the accent color and it counts up once a second; the button becomes a red **Stop**.
- The digits do not jitter or shift horizontally as they change — this is the `.monospacedDigit()` check.
- The space bar toggles the timer.
- Letting it run ~5 seconds and pressing Stop returns the stopwatch to `00:00:00` and raises "THIS WEEK" above `0m`.
- Running it a full minute makes "THIS WEEK" read `1m`.
- Starting a timer, quitting the app **without stopping**, and relaunching shows the stopwatch still running with the elapsed time carried across the restart.

- [ ] **Step 4: Commit**

```bash
git add TimeJournal/TimerPanel.swift TimeJournal/ContentView.swift
git commit -m "Add timer panel with week total and stopwatch"
```

---

### Task 10: Week view

**Files:**
- Create: `TimeJournal/WeekView.swift`
- Modify: `TimeJournal/ContentView.swift`

**Interfaces:**
- Consumes: `AppState`, `DayTotal`, `Format`.
- Produces: `WeekView` — the left pane. Replaces the first `Color.clear` in `ContentView`.

- [ ] **Step 1: Build the panel**

Create `TimeJournal/WeekView.swift`:

```swift
import SwiftUI

/// Left pane: seven days, bars scaled to the busiest day of the displayed week.
struct WeekView: View {
    @Environment(AppState.self) private var app

    private var weekdayNames: [String] {
        let formatter = DateFormatter()
        formatter.calendar = app.calendar
        formatter.timeZone = app.calendar.timeZone
        formatter.locale = app.calendar.locale ?? .current
        formatter.dateFormat = "EEE"
        return app.dayTotals.map { formatter.string(from: $0.date) }
    }

    /// Bars are relative to the busiest day of THIS week, so a light week is still
    /// legible instead of seven flat slivers.
    private var scale: TimeInterval {
        max(app.dayTotals.map(\.seconds).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 10) {
                ForEach(Array(app.dayTotals.enumerated()), id: \.element.id) { index, day in
                    row(day: day, name: weekdayNames[index])
                }
            }

            Spacer()

            Divider()
            HStack {
                Text("Total")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(Format.total(app.weekTotal))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if app.isCurrentWeek {
                Text("WEEK · \(app.weekLabel)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
            } else {
                Button {
                    app.goToCurrentWeek()
                } label: {
                    Text("WEEK · \(app.weekLabel)")
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                }
                .buttonStyle(.link)
                .help("Back to this week")
            }

            Spacer()

            Button { app.goToWeek(offset: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.accessoryBar)
            Button { app.goToWeek(offset: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.accessoryBar)
        }
    }

    private func row(day: DayTotal, name: String) -> some View {
        let isToday = app.calendar.isDateInToday(day.date)
        return HStack(spacing: 12) {
            Text(name)
                .font(.callout)
                .foregroundStyle(isToday ? Color.primary : .secondary)
                .fontWeight(isToday ? .semibold : .regular)
                .frame(width: 36, alignment: .leading)

            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3)
                    .fill(isToday ? Color.accentColor : Color.accentColor.opacity(0.45))
                    .frame(width: max(0, geometry.size.width * (day.seconds / scale)))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)

            Text(day.seconds == 0 ? "—" : Format.short(day.seconds))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(day.seconds == 0 ? .tertiary : .secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
```

- [ ] **Step 2: Put it in the window**

In `TimeJournal/ContentView.swift`, replace the first pane:

```swift
                Color.clear
                    .frame(minWidth: 320, idealWidth: 400)
```

with:

```swift
                WeekView()
                    .frame(minWidth: 320, idealWidth: 400)
```

- [ ] **Step 3: Build, launch, and verify by hand**

Run: `./run.sh`

Check each of these:
- Seven rows appear, `Mon` through `Sun` in that order — Monday first, not Sunday.
- Today's row label is bolder than the others.
- Days with no time show `—`, not `0:00`.
- Running a timer for a minute and stopping produces a bar on today's row and `0:01`.
- The `‹` button moves to the previous week: the header becomes a clickable link, all rows go to `—`, and the right panel's heading changes from "THIS WEEK" to the date range with a `0m` total.
- Clicking the header link returns to the current week and the data comes back.
- Paging back across a month boundary shows a label like `Jan 26 – Feb 1`.
- Dragging the split divider resizes both panes without clipping the totals column.

- [ ] **Step 4: Commit**

```bash
git add TimeJournal/WeekView.swift TimeJournal/ContentView.swift
git commit -m "Add week view with day bars and week paging"
```

---

### Task 11: Notes list

**Files:**
- Modify: `TimeJournal/TimerPanel.swift`

**Interfaces:**
- Consumes: `AppState.weekSessions`, `AppState.lastStoppedSessionID`, `AppState.updateSession`.
- Produces: `SessionRow` (used again in Task 12).

- [ ] **Step 1: Add the notes list**

In `TimeJournal/TimerPanel.swift`, replace the `Spacer()` near the end of `body` with:

```swift
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("NOTES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)

                if app.weekSessions.isEmpty {
                    Text("No sessions this week.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(app.weekSessions) { session in
                                SessionRow(session: session, focused: $focusedSession)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
```

Add the focus state at the top of `TimerPanel`, next to the `@Environment` line:

```swift
    @FocusState private var focusedSession: UUID?
```

And append this modifier to the outermost `VStack` in `body`, after `.padding(20)`:

```swift
        .onChange(of: app.lastStoppedSessionID) { _, id in
            // nil means a sub-second session was discarded — nothing landed, so move nothing.
            // Without this guard, a mis-click would yank the cursor out of the note being typed.
            // The visibility check is a backstop: focusing a row that isn't rendered is a silent
            // no-op that also leaves a stale id parked in focusedSession. `toggle()` is what
            // actually guarantees the row is on screen; this just refuses to lie if it isn't.
            guard let id, app.weekSessions.contains(where: { $0.id == id }) else { return }
            focusedSession = id   // cursor lands in the note that just appeared
        }
```

- [ ] **Step 2: Add the row view**

Append to `TimeJournal/TimerPanel.swift`:

```swift
/// One stopped session: the day it happened, an editable note, and its length.
/// Stopping the clock never blocks on this — an empty note is valid.
struct SessionRow: View {
    @Environment(AppState.self) private var app
    let session: Session
    @FocusState.Binding var focused: UUID?

    private var dayLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = app.calendar
        formatter.timeZone = app.calendar.timeZone
        formatter.locale = app.calendar.locale ?? .current
        formatter.dateFormat = "EEE"
        return formatter.string(from: session.start)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(dayLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .leading)

            TextField("What did you do?", text: Binding(
                get: { session.note },
                set: { newValue in
                    var updated = session
                    updated.note = newValue
                    app.updateSession(updated)
                }
            ))
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($focused, equals: session.id)

            Text(Format.short(session.duration))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
```

- [ ] **Step 3: Build, launch, and verify by hand**

Run: `./run.sh`

Check each of these:
- With no sessions, the panel reads "No sessions this week."
- Run a timer for ~5 seconds and press Stop: a row appears immediately with the day, an empty note field, and the duration.
- **The text cursor is already in that new note field** — you can type without clicking. This is the core flow; if it fails, the `.onChange`/`@FocusState` wiring is wrong.
- Typing a note and pressing Enter keeps it. Quit and relaunch: the note is still there.
- Pressing Escape instead of typing leaves the note blank, and the session is still recorded.
- Recording several sessions lists them newest-first.
- Paging to the previous week empties the list; paging back restores it.
- A sub-second start-then-immediately-stop adds no row at all.
- **Typing a space inside a note does not start or stop the timer.** Task 9 put a bare
  `.keyboardShortcut(.space, modifiers: [])` on the Start/Stop button; a focused
  `TextField` should consume the keystroke first. If it does not, delete that
  `.keyboardShortcut` line from `TimerPanel` — text entry wins over the shortcut.

- [ ] **Step 4: Commit**

```bash
git add TimeJournal/TimerPanel.swift
git commit -m "Add notes list with focus-on-stop"
```

---

### Task 12: Session editor

**Files:**
- Create: `TimeJournal/SessionEditor.swift`
- Modify: `TimeJournal/TimerPanel.swift`

**Interfaces:**
- Consumes: `AppState.updateSession`, `AppState.deleteSession`, `Format`.
- Produces: `SessionEditor` — a popover presented from `SessionRow`.

- [ ] **Step 1: Build the editor**

Create `TimeJournal/SessionEditor.swift`:

```swift
import SwiftUI

/// Repairs the inevitable "left it running overnight". Duration is derived from the
/// two dates and updates live, so there is no way to enter an inconsistent session.
struct SessionEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var start: Date
    @State private var end: Date
    private let session: Session

    init(session: Session) {
        self.session = session
        _start = State(initialValue: session.start)
        _end = State(initialValue: session.end)
    }

    private var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DatePicker("Start", selection: $start)
            DatePicker("End", selection: $end)

            HStack {
                Text("Duration")
                Spacer()
                Text(Format.clock(duration))
                    .monospacedDigit()
                    .foregroundStyle(end < start ? .red : .primary)
            }
            .font(.callout)

            if end < start {
                Text("The end is before the start.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Delete", role: .destructive) {
                    app.deleteSession(session.id)
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    var updated = session
                    updated.start = start
                    updated.end = end
                    app.updateSession(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(end < start)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
```

- [ ] **Step 2: Open it from the notes list**

In `TimeJournal/TimerPanel.swift`, add a state property to `SessionRow`:

```swift
    @State private var isEditing = false
```

Then add these modifiers to `SessionRow`'s outermost `HStack`, after `.padding(.vertical, 3)`:

```swift
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { isEditing = true }
        .contextMenu {
            Button("Edit Times…") { isEditing = true }
            Button("Delete Session", role: .destructive) { app.deleteSession(session.id) }
        }
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            SessionEditor(session: session)
                .environment(app)
        }
```

A double-click opens the editor rather than a single click, because a single click needs to place the cursor in the note field.

- [ ] **Step 3: Build, launch, and verify by hand**

Run: `./run.sh`

Check each of these:
- Record a session, then double-click its row: a popover opens with start and end pickers and the derived duration.
- Changing the end time updates the Duration line immediately without saving.
- Setting the end before the start turns the duration red, shows the warning, and disables Save.
- Fixing it and pressing Save closes the popover, and the row's duration and the week bars both update.
- Right-clicking a row offers **Edit Times…** and **Delete Session**; deleting removes the row and shrinks the week total.
- Deleting from inside the editor also closes the popover.
- Quit and relaunch: the edits persisted.

- [ ] **Step 4: Commit**

```bash
git add TimeJournal/SessionEditor.swift TimeJournal/TimerPanel.swift
git commit -m "Add session editor popover"
```

---

### Task 13: Menu bar timer

**Files:**
- Create: `TimeJournal/MenuBarPanel.swift`
- Modify: `TimeJournal/TimeJournalApp.swift`

**Interfaces:**
- Consumes: `AppState`, `Format`.
- Produces: `MenuBarPanel` — the popover content for `MenuBarExtra`.

- [ ] **Step 1: Build the popover**

Create `TimeJournal/MenuBarPanel.swift`:

```swift
import SwiftUI

/// Menu bar popover: stop what's running, or start something without opening the window.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let running = app.store.running,
               let project = app.store.projects.first(where: { $0.id == running.projectID }) {
                Text(project.name)
                    .font(.headline)
                Text(Format.clock(app.elapsed))
                    .font(.system(size: 26, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                Button {
                    app.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if app.store.projects.isEmpty {
                Text("No projects yet")
                    .foregroundStyle(.secondary)
            } else {
                Text("No timer running")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(app.store.projects) { project in
                    Button {
                        app.start(projectID: project.id)
                    } label: {
                        Label(project.name, systemImage: "play.fill").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.accessoryBar)
                }
            }

            Divider()
            Button("Quit Time Journal") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.accessoryBar)
        }
        .padding(14)
        .frame(width: 220)
    }
}
```

- [ ] **Step 2: Add the menu bar scene**

In `TimeJournal/TimeJournalApp.swift`, add a second scene after the `WindowGroup` block (after `.windowResizability(.contentMinSize)`):

```swift
        MenuBarExtra {
            MenuBarPanel()
                .environment(app)
        } label: {
            if app.isRunning {
                Text(Format.clock(app.elapsed))
                    .monospacedDigit()
            } else {
                Image(systemName: "timer")
            }
        }
        .menuBarExtraStyle(.window)
```

- [ ] **Step 3: Build, launch, and verify by hand**

Run: `./run.sh`

Check each of these:
- A `timer` icon appears in the macOS menu bar while idle.
- Clicking it opens a popover listing your projects; clicking one starts its timer.
- While running, the menu bar item **shows the elapsed time and updates every second** — this is what `.common` run loop mode buys; if it freezes while a menu is open, that mode was dropped.
- The popover then shows the project name, elapsed time, and a red Stop button.
- Stopping from the menu bar adds the session to the main window's notes list.
- Starting from the menu bar while a different project's timer runs stops the first and records it.
- **Quit Time Journal** quits the app.

- [ ] **Step 4: Commit**

```bash
git add TimeJournal/MenuBarPanel.swift TimeJournal/TimeJournalApp.swift
git commit -m "Add menu bar timer"
```

---

### Task 14: Full-suite check and polish pass

**Files:**
- Modify: any file needing adjustment after the review below.

**Interfaces:**
- Consumes: everything.
- Produces: no new API.

- [ ] **Step 1: Run the whole test suite**

Run: `xcodebuild test -scheme TimeJournal -configuration Debug -derivedDataPath build -only-testing:TimeJournalTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` with every test from Tasks 2–7 passing.

- [ ] **Step 2: Confirm the build is warning-clean**

Run: `xcodebuild -scheme TimeJournal -configuration Debug -derivedDataPath build build 2>&1 | grep -E "warning:" | grep -v "build/" | sort -u`
Expected: no output. Fix any warnings in the app's own source; ignore warnings from Apple SDK headers.

- [ ] **Step 3: Walk the whole app in both appearances**

Run: `./run.sh`, then switch between Light and Dark in System Settings → Appearance with the app open.

Check each of these:
- Text stays legible in both appearances; nothing is hardcoded to a color that only works in one.
- Changing the accent color in System Settings → Appearance recolors the bars, the running stopwatch, and the Start button.
- Resizing the window to its minimum does not clip or overlap any text.
- A project name long enough to overflow the switcher truncates rather than pushing **New** off the edge.
- The window's empty state (no projects at all) reads sensibly rather than showing a bare skeleton.

- [ ] **Step 4: Verify the data file**

Run: `cat ~/Library/Containers/com.alistair.TimeLogger/Data/Library/Application\ Support/TimeLogger/store.json`
Expected: readable pretty-printed JSON with ISO-8601 dates, containing the projects and sessions created during testing.

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "Polish pass: warnings, appearance, and layout edges"
```

---

## Definition of done

- `xcodebuild test` passes all suites from Tasks 2–7.
- The build produces no warnings from the app's own source.
- A full manual pass works: create a project, run a timer, stop it, annotate it, correct its times, page back a week and return, start and stop from the menu bar, delete a project, quit and relaunch with everything intact.
- Starting a timer and force-quitting the app does not lose the in-flight session.
