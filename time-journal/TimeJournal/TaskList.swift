import SwiftUI

/// The fold control every section in the right pane shares: a chevron and a small caps label.
/// Deliberately just those two things — the caller puts its own buttons in an `HStack` around it, so
/// TASKS, its two groups, and SESSIONS can't drift apart in type, spacing, or the way they fold, while
/// each keeps the controls that belong to it.
struct SectionHeader: View {
    let title: String
    let isCollapsed: Bool
    /// Shown in the title when present. It is what tells you a folded group is holding something.
    /// An optional `var` already defaults to nil in the memberwise init, so callers that don't pass
    /// one get no count.
    var count: Int?
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(label)
                    .tracking(0.8)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
    }

    private var label: String {
        guard let count else { return title }
        return "\(title) (\(count))"
    }
}

/// A task named in a capsule — the one drawing used wherever something says that a session is about a
/// task. The timer under the clock names the task in full; a session row shows only the mark, because
/// the note beside it is usually that same title already, and the mark answers the question the row is
/// asked — "is this one tagged?" — without repeating the text. Hovering says which task it is, which
/// is the one thing a bare mark can't say for itself.
struct TaskChip: View {
    let title: String
    /// Whether the title is drawn beside the mark. False where the surrounding row already names the
    /// task (a task's own disclosure) or already carries it as the note (the sessions list).
    var showsTitle = true
    /// What hovering explains. Defaults to naming the task.
    var help: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checklist")
                .imageScale(.small)
            if showsTitle {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, showsTitle ? 8 : 5)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .help(help ?? title)
        .accessibilityLabel("Task: \(title)")
    }
}

/// The task list for the selected project: what's to do, what's in progress, what's finished.
///
/// Tasks belong to a project, so this list follows the project switcher above it — the same rule the
/// week and the totals follow.
struct TasksSection: View {
    @Environment(AppState.self) private var app
    @State private var isNaming = false
    @State private var draftTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionHeader(title: "TASKS",
                              isCollapsed: app.isCollapsed(.tasks)) { app.toggleSection(.tasks) }

                Spacer(minLength: 0)

                Button {
                    draftTitle = ""
                    isNaming = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(.accessoryBar)
                .disabled(app.selectedProject == nil)
                .help("Add a task to this project")
            }
            .alert("New Task", isPresented: $isNaming) {
                TextField("What needs doing?", text: $draftTitle)
                Button("Cancel", role: .cancel) {}
                // A blank title is refused by `addTodo` itself, so there is only one rule about what
                // a task can be called and this button can't disagree with it.
                Button("Create") { app.addTodo(title: draftTitle) }
            }

            if !app.isCollapsed(.tasks) {
                if app.todos.isEmpty {
                    Text("No tasks yet.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(app.openTodos) { TaskRow(todo: $0) }
                        group(.inProgress, title: "IN PROGRESS", todos: app.inProgressTodos)
                        group(.done, title: "DONE", todos: app.doneTodos)
                    }
                }
            }
        }
    }

    /// A foldable subgroup, drawn only when it holds something — which is what keeps a young task list
    /// from carrying two empty labels. A paused task lands here, with the sessions it has already
    /// earned listed under it; that is the work you picked up and put down.
    @ViewBuilder
    private func group(_ section: PaneSection, title: String, todos: [Todo]) -> some View {
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionHeader(title: title,
                                  isCollapsed: app.isCollapsed(section),
                                  count: todos.count) { app.toggleSection(section) }
                    Spacer(minLength: 0)
                }
                if !app.isCollapsed(section) {
                    ForEach(todos) { TaskRow(todo: $0) }
                }
            }
        }
    }
}

/// One task: start a session on it, finish it, set it down, rename or delete it, and see the time it
/// has already cost.
struct TaskRow: View {
    @Environment(AppState.self) private var app
    let todo: Todo

    /// Whether this task's sessions are listed underneath it. Local state rather than a stored
    /// preference: a disclosure is about the moment you were looking at, and remembering it per task
    /// would mean writing view state into the store.
    @State private var isExpanded = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    /// Whether this task's own `SessionEditor` is open, logging an hour by hand rather than by
    /// running the clock. Held per row like the disclosure, because it is about this task.
    @State private var isLoggingManually = false
    /// Which listed session has its editor open, and whether that editor should focus the note. The
    /// same two pieces of state `TimerPanel` keeps for its rows, for the same reason.
    @State private var editingSessionID: UUID?
    @State private var focusNoteWhenEditing = true

    private var isRunning: Bool { app.runningTodo?.id == todo.id }
    private var sessions: [Session] { app.sessions(forTodo: todo.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if isExpanded { listedSessions }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            title
            timeSpent
            // Every verb sits in one cluster at the trailing edge, in the order you reach for them:
            // the clock, then setting the task down, then finishing it. Leading the row with a
            // lone play button while the pause sat at the other end read as two halves of one
            // transport control, which is precisely what they are not — playing starts a session,
            // pausing changes the task's status, and neither implies the other.
            transportButton
            pauseSlot
            completeButton
            disclosureButton
        }
        .padding(.vertical, 1)
        .contextMenu {
            // First, because it is the verb you reach for on a task you did the work for without
            // starting the clock — the same reason it sits above the sessions in the disclosure.
            Button("Log Time…") { isLoggingManually = true }
            Button("Rename…") {
                draftTitle = todo.title
                isRenaming = true
            }
            Button("Delete Task", role: .destructive) { app.deleteTodo(todo.id) }
        }
        .alert("Rename Task", isPresented: $isRenaming) {
            TextField("What needs doing?", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            // As with Create: a blank title is not a rename, and `renameTodo` refuses it, so the
            // description can't be erased by accident.
            Button("Rename") { app.renameTodo(todo.id, title: draftTitle) }
        }
        // Attached to the whole row, not to either button that opens it: the context-menu item and
        // the button in the disclosure are two doors to one popover, and only the row is present
        // whichever one was used.
        .popover(isPresented: $isLoggingManually, arrowEdge: .trailing) {
            // Defaults are read as the popover opens, so they reflect the week on screen rather than
            // whenever this row was built — the same reason the notes list reads them here.
            let span = app.newSessionSpan
            // The task's own project, not the selection: a session logged under this task belongs
            // where the task does, and the title is the note just as `stop()` would have written it.
            SessionEditor(newSessionFor: todo.projectID,
                          todoID: todo.id,
                          start: span.start,
                          end: span.end,
                          note: todo.title,
                          focusNoteOnOpen: true)
                .environment(app)
        }
    }

    /// One button for the clock: play when it is idle, stop when this task's session is the one
    /// running.
    ///
    /// The stop half is not decoration. It used to be a static play icon, which meant the only way to
    /// stop a task session was the big button above — while the row you were looking at showed a
    /// control that looked pressable and wasn't. It calls `stopAndReveal` rather than `stop` so it
    /// brings the session it commits into view first, exactly as the main button does; otherwise
    /// stopping from here while browsing another week would leave the new row unrendered and the
    /// annotate popover with nothing to open on.
    ///
    /// Pressing play on finished work reopens it — a rule that lives in `AppState.start(todoID:)` so
    /// every caller inherits it rather than each button remembering it.
    private var transportButton: some View {
        Button {
            if isRunning {
                app.stopAndReveal()
            } else {
                app.start(todoID: todo.id)
            }
        } label: {
            // Accent for go and red for stop, matching the big button's own colours, so the two
            // controls can't be read as meaning different things.
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .foregroundStyle(isRunning ? Color.red : Color.accentColor)
        }
        .buttonStyle(.accessoryBar)
        .frame(width: 14)
        .help(isRunning ? "Stop this session" : "Start a session on this task")
    }

    private var title: some View {
        Text(todo.title)
            .font(.callout)
            .strikethrough(todo.status == .done, color: .secondary)
            .foregroundStyle(titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(todo.title)
    }

    private var titleColor: Color {
        if isRunning { return .accentColor }
        return todo.status == .done ? .secondary : .primary
    }

    /// The time this task has cost, all of it — and while it runs, the clock instead of the total, so
    /// the row and the stopwatch above it never show two different numbers for the same session.
    @ViewBuilder
    private var timeSpent: some View {
        if sessions.isEmpty {
            EmptyView()
        } else if isRunning {
            Text(Format.clock(app.elapsed))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
        } else {
            Text(Format.short(app.total(forTodo: todo.id)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var completeButton: some View {
        Button {
            app.setTodoStatus(todo.id, todo.status == .done ? .open : .done)
        } label: {
            Image(systemName: todo.status == .done ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.accessoryBar)
        .help(todo.status == .done ? "Move back to tasks" : "Mark done")
    }

    /// One button for two directions rather than a pair: pausing and un-pausing are the same decision
    /// seen twice, and a filled icon says which way this task is currently pointing.
    private var pauseButton: some View {
        Button {
            app.setTodoStatus(todo.id, todo.status == .paused ? .open : .paused)
        } label: {
            Image(systemName: todo.status == .paused ? "pause.circle.fill" : "pause.circle")
        }
        .buttonStyle(.accessoryBar)
        .help(todo.status == .paused ? "Move back to tasks" : "Set this task down for now")
    }

    /// The pause column. A finished task draws nothing there, but the column stays reserved so its
    /// time and controls still line up with the rows above it — the same trick the disclosure uses.
    @ViewBuilder
    private var pauseSlot: some View {
        if todo.status == .done {
            emptySlot
        } else {
            pauseButton
        }
    }

    /// Stands in for a control a row doesn't draw, so every row's columns stay aligned.
    private var emptySlot: some View { Color.clear.frame(width: 14, height: 1) }

    @ViewBuilder
    private var disclosureButton: some View {
        if sessions.isEmpty {
            emptySlot
        } else {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .buttonStyle(.accessoryBar)
            .frame(width: 14)
            .help(isExpanded ? "Hide this task's sessions" : "Show this task's sessions")
        }
    }

    /// Every session ever run against this task, newest first, with the total under them: a task
    /// outlives a week, so this is deliberately not the week on screen. The rows are the notes list's
    /// own rows, so clicking one opens the usual editor for its times and its note.
    private var listedSessions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sessions) { session in
                SessionRow(session: session,
                           wrapNotes: false,
                           showsTask: false,
                           isEditing: editingBinding(for: session.id),
                           focusNoteOnOpen: focusNoteWhenEditing,
                           onEdit: { focusNote in
                               focusNoteWhenEditing = focusNote
                               editingSessionID = session.id
                           })
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Logging time by hand belongs where the sessions it will join are listed: this is the
            // task's history, and an hour you forgot to time is part of it. The context menu carries
            // the same verb for a task with no sessions, which has no disclosure to open.
            Button {
                isLoggingManually = true
            } label: {
                Label("Log Time", systemImage: "plus")
            }
            .buttonStyle(.accessoryBar)
            .help("Log time on this task by hand")
        }
        .padding(.top, 2)
        .padding(.leading, 22)
    }

    private var summary: String {
        let count = sessions.count
        return "\(count) session\(count == 1 ? "" : "s") · \(Format.short(app.total(forTodo: todo.id)))"
    }

    private func editingBinding(for sessionID: UUID) -> Binding<Bool> {
        Binding(
            get: { editingSessionID == sessionID },
            set: { isEditing in
                if isEditing {
                    editingSessionID = sessionID
                } else if editingSessionID == sessionID {
                    editingSessionID = nil
                    if app.focusSessionID == sessionID {
                        app.focusSessionID = nil
                    }
                }
            }
        )
    }
}
