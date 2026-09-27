import Testing
import Foundation
@testable import TimeJournal

private func tempStorage() -> Storage {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeJournalTests-\(UUID().uuidString)")
    return Storage(url: dir.appendingPathComponent("store.json"))
}

/// The exact on-disk shape of a `store.json` written before tasks existed: no `todos` key, and no
/// `todoID` on either the stopped session or the in-flight timer.
///
/// Hand-written rather than produced by the current encoder, because the point is to pin the *old*
/// format — bytes the current code can no longer generate. Shared with `AppStateTodoTests` on
/// purpose: the decode guard here and the end-to-end no-quarantine test there must both be asserting
/// against the same old format, or the two can drift into testing two different pasts.
let legacyStoreJSON = """
{
  "projects" : [
    {
      "createdAt" : "2026-08-08T09:00:00Z",
      "id" : "2C451A9E-E412-46AB-9AC7-E5E962C5D95C",
      "name" : "Thesis"
    }
  ],
  "running" : {
    "projectID" : "2C451A9E-E412-46AB-9AC7-E5E962C5D95C",
    "start" : "2026-08-09T12:00:00Z"
  },
  "selectedProjectID" : "2C451A9E-E412-46AB-9AC7-E5E962C5D95C",
  "sessions" : [
    {
      "end" : "2026-08-09T11:00:00Z",
      "id" : "B1F0E3C4-0000-4000-8000-000000000001",
      "note" : "fixed ch.3",
      "projectID" : "2C451A9E-E412-46AB-9AC7-E5E962C5D95C",
      "start" : "2026-08-09T10:00:00Z"
    }
  ]
}
"""

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
        store.todos = [Todo(projectID: project.id,
                            title: "Read the paper",
                            createdAt: Date(timeIntervalSince1970: 1_000_000),
                            status: .paused)]

        try storage.save(store)
        let loaded = try storage.load()

        #expect(loaded.projects == store.projects)
        #expect(loaded.sessions == store.sessions)
        #expect(loaded.running == store.running)
        #expect(loaded.selectedProjectID == project.id)
        #expect(loaded.todos == store.todos)
    }

    /// The standing guard on every `store.json` written before tasks existed.
    ///
    /// Swift's synthesized decoder throws `keyNotFound` for a missing key *even when the
    /// property has a default value*, and `AppState.init` treats a decode failure as corruption:
    /// it moves the file aside and starts from an empty store. So a `Store` that gained a
    /// `todos` field without an absent-safe decoder would quarantine real history on first
    /// launch. `legacyStoreJSON` is that old shape, and all of it must still come back.
    @Test func legacyStoreWithoutTodosDecodes() throws {
        let storage = tempStorage()
        try FileManager.default.createDirectory(at: storage.url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data(legacyStoreJSON.utf8).write(to: storage.url)

        let store = try storage.load()

        #expect(store.projects.map(\.name) == ["Thesis"])
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.note == "fixed ch.3")
        #expect(store.sessions.first?.duration == 3600)
        #expect(store.sessions.first?.todoID == nil)     // absent key, not a decode failure
        #expect(store.running?.projectID == store.selectedProjectID)
        #expect(store.running?.todoID == nil)            // the in-flight timer survives too
        #expect(store.todos.isEmpty)                     // absent key, not a decode failure
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
