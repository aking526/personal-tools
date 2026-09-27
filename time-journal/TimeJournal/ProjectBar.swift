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
            Button(deleteLabel(for: project), role: .destructive) {
                app.deleteProject(project.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            if app.store.running?.projectID == project.id {
                Text("Its timer is still running — that time will be discarded too. This cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
    }

    /// Names everything the confirm is about to destroy. The sessions are the irreplaceable part; the
    /// tasks go too, because a task whose project is gone has nothing left to run against. With no
    /// tasks the sentence is word-for-word what it was before tasks existed.
    private func deleteLabel(for project: Project) -> String {
        let sessions = app.sessionCount(for: project.id)
        let tasks = app.todoCount(for: project.id)
        let sessionText = "\(sessions) Session\(sessions == 1 ? "" : "s")"
        guard tasks > 0 else { return "Delete Project and \(sessionText)" }
        return "Delete Project, \(sessionText) and \(tasks) Task\(tasks == 1 ? "" : "s")"
    }
}
