import Foundation

nonisolated struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

nonisolated struct Session: Codable, Identifiable, Hashable {
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

nonisolated struct Running: Codable, Hashable {
    var projectID: UUID
    var start: Date
}

nonisolated struct Store: Codable {
    var projects: [Project] = []
    var sessions: [Session] = []
    var running: Running?
    var selectedProjectID: UUID?
}
