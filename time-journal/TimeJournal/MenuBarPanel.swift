import SwiftUI

/// Menu bar popover: start, stop, and name a session without opening the window.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var app
    @State private var stoppedSessionID: UUID?
    @State private var note = ""
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let running = app.store.running,
               let project = app.store.projects.first(where: { $0.id == running.projectID }) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                // Which task this time belongs to, when it belongs to one. The menu bar's own label is
                // too narrow for a title, so it goes here, where the running session is described.
                if let todo = app.runningTodo {
                    Label(todo.title, systemImage: "checklist")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(todo.title)
                }
                Text(Format.clock(app.elapsed))
                    .font(.system(size: 26, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                Button {
                    // Keep the new session's note editor in this popover. The main window still
                    // follows the session's project and week, but does not open a second editor.
                    if let session = app.stopAndReveal(focusNote: false) {
                        note = session.note
                        stoppedSessionID = session.id
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if let session = stoppedSessionID.flatMap({ id in
                app.store.sessions.first { $0.id == id }
            }) {
                stoppedSessionEditor(for: session)
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

    private func stoppedSessionEditor(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session stopped")
                .font(.headline)
            if let project = app.project(session.projectID) {
                Text(project.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TextField("What did you do?", text: $note)
                .textFieldStyle(.roundedBorder)
                .focused($isNoteFocused)
                .onSubmit(saveNote)
            Button("Done") { saveNote() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear {
            DispatchQueue.main.async {
                if stoppedSessionID == session.id { isNoteFocused = true }
            }
        }
        // Closing the menu bar popover should keep text already typed into the field.
        .onDisappear { saveNote() }
    }

    private func saveNote() {
        guard let id = stoppedSessionID,
              var session = app.store.sessions.first(where: { $0.id == id }) else { return }
        if session.note != note {
            session.note = note
            app.updateSession(session)
        }
        isNoteFocused = false
        stoppedSessionID = nil
    }
}
