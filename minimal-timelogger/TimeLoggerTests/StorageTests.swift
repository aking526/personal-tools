import Testing
import Foundation
@testable import TimeLogger

private func tempStorage() -> Storage {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TimeLoggerTests-\(UUID().uuidString)")
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
