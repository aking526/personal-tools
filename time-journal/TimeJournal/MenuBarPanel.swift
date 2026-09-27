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
                    app.stopAndReveal()
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
