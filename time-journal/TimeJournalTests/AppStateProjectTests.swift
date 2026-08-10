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
