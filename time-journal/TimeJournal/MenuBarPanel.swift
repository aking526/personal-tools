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
