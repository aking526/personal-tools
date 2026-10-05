import SwiftUI
import Combine

/// Menu bar popover: start, stop, and edit a session without opening the window.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var stoppedSessionID: UUID?
    @State private var today = Date.now

    private var stoppedSession: Session? {
        stoppedSessionID.flatMap { id in app.store.sessions.first { $0.id == id } }
    }

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
                    // Keep the new session's editor in this popover. The main window still
                    // follows the session's project and week, but does not open a second editor.
                    if let session = app.stopAndReveal(focusNote: false) {
                        stoppedSessionID = session.id
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if let session = stoppedSession {
                Text("Session stopped")
                    .font(.headline)
                SessionEditor(session: session, focusNoteOnOpen: true,
                              savesNoteOnDisappear: true,
                              onFinish: { stoppedSessionID = nil })
                    .id(session.id)
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

            if let project = app.selectedProject {
                Divider()
                projectTotals(for: project)
            }

            Divider()
            Button {
                openWindow(id: "main", value: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Window", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.accessoryBar)

            Button("Quit Time Journal") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.accessoryBar)
        }
        .padding(14)
        .frame(width: stoppedSession != nil && !app.isRunning ? 408 : 220)
        .onAppear { today = app.currentDate }
        .onDisappear { stoppedSessionID = nil }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = app.currentDate
        }
    }

    private func projectTotals(for project: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOGGED TIME · \(project.name)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(alignment: .top, spacing: 12) {
                total("TODAY", seconds: app.dayTotal(for: today))
                Spacer(minLength: 0)
                total("THIS WEEK", seconds: app.currentWeekTotal(for: today))
            }
        }
    }

    private func total(_ label: String, seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text(Format.total(seconds))
                .font(.system(size: 18, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

}
