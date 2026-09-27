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

/// A thing to do later, against one project.
///
/// Named `Todo` rather than `Task` on purpose: `Task` is Swift Concurrency's type, and declaring
/// our own at module scope would shadow it for every file in the module — including the ticker in
/// `AppState`, which the compiler is entitled to use there.
nonisolated struct Todo: Codable, Identifiable, Hashable {
    /// `paused` is a state rather than a flag on `open`: it is what the IN PROGRESS group is made
    /// of, and it reads as "started, put down" instead of "not yet begun".
    nonisolated enum Status: String, Codable {
        case open, paused, done
    }

    let id: UUID
    var projectID: UUID
    var title: String
    var createdAt: Date
    var status: Status
    /// When it moved to `.done`; cleared if it is reopened. Only the DONE group's order needs it —
    /// nothing else is derived from it, so it can never disagree with the sessions behind it.
    var completedAt: Date?

    init(id: UUID = UUID(), projectID: UUID, title: String, createdAt: Date,
         status: Status = .open, completedAt: Date? = nil) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt
        self.status = status
        self.completedAt = completedAt
    }
}

nonisolated struct Session: Codable, Identifiable, Hashable {
    let id: UUID
    var projectID: UUID
    var start: Date
    var end: Date
    var note: String
    /// The task this session was started from, when it was started from one.
    ///
    /// Optional so that every session written before tasks existed still decodes: synthesized
    /// decoding uses `decodeIfPresent` for optionals. It does NOT fall back to a property's
    /// default value for a missing non-optional key — see `Store.init(from:)`.
    var todoID: UUID?

    init(id: UUID = UUID(), projectID: UUID, start: Date, end: Date, note: String = "",
         todoID: UUID? = nil) {
        self.id = id
        self.projectID = projectID
        self.start = start
        self.end = end
        self.note = note
        self.todoID = todoID
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

nonisolated struct Running: Codable, Hashable {
    var projectID: UUID
    var start: Date
    /// Set when the running session was started from a task. Optional for the same reason as
    /// `Session.todoID`: a timer persisted by an earlier build has no such key, and losing an
    /// in-flight session to a decode failure is the one thing the persistence design refuses.
    /// An optional `var` already gets a default of nil in the memberwise init, so
    /// `Running(projectID:start:)` keeps working unchanged.
    var todoID: UUID?
}

nonisolated struct Store: Codable {
    var projects: [Project]
    var sessions: [Session]
    var todos: [Todo]
    var running: Running?
    var selectedProjectID: UUID?

    /// The on-disk schema, spelled out because `init(from:)` below is hand-written. This list is
    /// the contract with every store.json already on disk, so it is worth reading at a glance.
    private enum CodingKeys: String, CodingKey {
        case projects, sessions, todos, running, selectedProjectID
    }

    init(projects: [Project] = [], sessions: [Session] = [], todos: [Todo] = [],
         running: Running? = nil, selectedProjectID: UUID? = nil) {
        self.projects = projects
        self.sessions = sessions
        self.todos = todos
        self.running = running
        self.selectedProjectID = selectedProjectID
    }

    /// Hand-written rather than synthesized, and this is load-bearing.
    ///
    /// The synthesized decoder throws `keyNotFound` for a missing key **even when the property
    /// has a default value**. So adding `todos` to this struct without the decoder below would
    /// make every store.json written before tasks existed fail to decode — and `AppState.init`
    /// treats a decode failure as corruption: it moves the file aside and starts from an empty
    /// store, quarantining years of history for the crime of being old.
    ///
    /// `decodeIfPresent` on every field is what keeps the schema additive: old files load, new
    /// fields default, and no file is ever moved aside merely for predating a feature.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects          = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions          = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        todos             = try container.decodeIfPresent([Todo].self, forKey: .todos) ?? []
        running           = try container.decodeIfPresent(Running.self, forKey: .running)
        selectedProjectID = try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
    }
}
