import SwiftUI
import Combine

/// Right pane: what the displayed week and today add up to, the control that changes them, and the
/// two lists underneath — what you intend to do, and what you have done.
struct TimerPanel: View {
    @Environment(AppState.self) private var app

    /// The day the "today" figure is about. Held in state rather than read from the clock as the
    /// tally draws, so the day-change notification below can move it onto the new day in a window
    /// that was left open overnight — otherwise the panel would keep calling yesterday "today".
    @State private var today = Date.now

    /// macOS draws the pane's vertical scroller *over* its scroll content rather than beside it, so
    /// the last column of every row — a session's duration, a task's disclosure chevron — sat under
    /// the scroller's track. Visible, but not usable: a click on the covered chevron scrolled the
    /// list instead of opening the task. Measured against the running app, the track is 19 points
    /// wide and starts 18 points in from the scroll area's trailing edge.
    ///
    /// This is what gets reserved to clear it. It goes on the *content*, not on the `ScrollView`: a
    /// narrower scroll view would just move its own scroller inward and cover the content again in
    /// the new place, because the scroller always sits at the trailing edge of whatever it belongs
    /// to. The heading takes the same inset, so the Start button doesn't overhang the rows beneath
    /// it — one right margin for the whole pane rather than two.
    private static let scrollerGutter: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading

            // One scroll region for both lists rather than one each. Two scroll views would split the
            // pane's leftover height evenly between them, so a three-item task list would hold half
            // the pane and squeeze the sessions for no reason. The clock above stays put either way.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TasksSection()
                    Divider()
                    SessionsSection()
                }
                .padding(.trailing, Self.scrollerGutter)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { today = app.currentDate }   // the app's clock, which a test can pin
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = app.currentDate
            // This panel is on screen in both week drawings, so it is also the one place that can
            // carry the window into the new week whichever one is showing. The calendar does the
            // same when it's up; the call only moves a window still parked on the current week.
            app.followDayChange()
        }
    }

    /// The figures and the clock: what never scrolls, so the stopwatch stays in reach while you read
    /// down a long week of sessions. Split out only so it can carry the scroller gutter above — it is
    /// still the same tallies, rule, timer, rule the pane has always been.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 20) {
            tallies
            Divider()
            timerBlock
            Divider()
        }
        .padding(.trailing, Self.scrollerGutter)
    }

    private var tallies: some View {
        HStack(alignment: .top, spacing: 16) {
            tally(app.isCurrentWeek ? "THIS WEEK" : app.weekLabel.uppercased(),
                  seconds: app.weekTotal)
            Divider()
                .frame(height: 44)
            tally("TODAY", seconds: app.dayTotal(for: today))
            Spacer(minLength: 0)
        }
    }

    private var timerBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Format.clock(app.elapsed))
                .font(.system(size: 46, weight: .thin))
                .monospacedDigit()
                .foregroundStyle(app.isRunning ? Color.accentColor : .secondary)

            // The one thing that separates a session started from the task list from a plain Start.
            // Drawn under the clock rather than as a column of its own, because it describes that
            // clock: when there is no task behind the running session, there is nothing here at all.
            if let todo = app.runningTodo {
                TaskChip(title: todo.title,
                         help: "Started from the task list — the task's title becomes this session's note")
            }

            Button(action: toggle) {
                Label(app.isRunning ? "Stop" : "Start",
                      systemImage: app.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(app.isRunning ? .red : .accentColor)
            .disabled(app.selectedProject == nil)
        }
    }

    /// One headline figure with its label. Both tallies share this so the week and the day can't
    /// drift apart in type or spacing.
    private func tally(_ label: String, seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            Text(Format.total(seconds))
                .font(.system(size: 34, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText())
                // A three-digit hour count is rare but real. Shrinking beats a clipped total,
                // and beats the two figures shoving each other out of the pane.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func toggle() {
        if app.isRunning {
            // Ordering matters and lives in `stopAndReveal`, so this button and a task row's own stop
            // button can't drift apart on it.
            app.stopAndReveal()
        } else if let project = app.selectedProject {
            app.start(projectID: project.id)
        }
    }
}

/// The sessions list: this week's stopped sessions for the selected project, newest first, plus the
/// two things you can do to it — wrap their notes, or log an hour by hand.
struct SessionsSection: View {
    @Environment(AppState.self) private var app
    @State private var wrapNotes = false
    @State private var isLoggingManually = false
    /// Which sessions-list row has `SessionEditor` open, if any.
    @State private var editingSessionID: UUID?
    /// Whether that popover should autofocus the note (row click / post-stop) or not (Edit Times…).
    @State private var focusNoteWhenEditing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionHeader(title: "SESSIONS",
                              isCollapsed: app.isCollapsed(.sessions)) { app.toggleSection(.sessions) }

                Spacer(minLength: 0)

                Button {
                    wrapNotes.toggle()
                } label: {
                    Label("Wrap Text", systemImage: wrapNotes
                          ? "text.word.spacing"
                          : "text.alignleft")
                }
                .buttonStyle(.accessoryBar)
                .help(wrapNotes ? "Show notes on one line" : "Wrap notes onto multiple lines")

                Button {
                    isLoggingManually = true
                } label: {
                    Label("Log Time", systemImage: "plus")
                }
                .buttonStyle(.accessoryBar)
                .disabled(app.selectedProject == nil)
                .popover(isPresented: $isLoggingManually, arrowEdge: .bottom) {
                    if let project = app.selectedProject {
                        // Defaults are read as the popover opens, so they reflect the
                        // week on screen rather than whenever this view was built.
                        let span = app.newSessionSpan
                        SessionEditor(newSessionFor: project.id,
                                      start: span.start,
                                      end: span.end)
                            .environment(app)
                    }
                }
            }

            if !app.isCollapsed(.sessions) {
                if app.weekSessions.isEmpty {
                    Text("No sessions this week.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(app.weekSessions) { session in
                            SessionRow(
                                session: session,
                                wrapNotes: wrapNotes,
                                isEditing: editingBinding(for: session.id),
                                focusNoteOnOpen: focusNoteWhenEditing,
                                onEdit: { focusNote in
                                    openEditor(sessionID: session.id, focusNote: focusNote)
                                }
                            )
                        }
                    }
                }
            }
        }
        .onChange(of: app.focusSessionID) { _, id in
            // nil means a sub-second session was discarded — nothing landed, so open nothing.
            // Owned here (not on the row) so a brand-new session still opens the popover:
            // the row may not exist yet when `focusSessionID` flips, and a row-level
            // `onChange` would miss that first assignment.
            guard let id, app.weekSessions.contains(where: { $0.id == id }) else { return }
            // Unfold first: a collapsed section draws no rows, so the popover would have nothing to
            // attach to and stopping a timer would dead-end in exactly the way `toggle()` warns of.
            app.expandSection(.sessions)
            openEditor(sessionID: id, focusNote: true)
        }
    }

    private func openEditor(sessionID: UUID, focusNote: Bool) {
        focusNoteWhenEditing = focusNote
        editingSessionID = sessionID
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

/// One stopped session: the day it happened, its note, its length, and — when it is filed under a
/// task — the mark that says so.
/// Stopping the clock never blocks on this — an empty note is valid.
struct SessionRow: View {
    @Environment(AppState.self) private var app
    let session: Session
    let wrapNotes: Bool
    /// Whether the row marks the task the session is linked to, if any. False inside a task's own
    /// disclosure, where every row is already underneath that task and a mark would say nothing.
    var showsTask = true
    @Binding var isEditing: Bool
    let focusNoteOnOpen: Bool
    let onEdit: (Bool) -> Void

    var body: some View {
        HStack(alignment: wrapNotes ? .top : .center, spacing: 10) {
            Text(Format.weekday(session.start, calendar: app.calendar))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .leading)
                .padding(.top, wrapNotes ? 2 : 0)

            Text(session.note.isEmpty ? "What did you do?" : session.note)
                .font(.callout)
                .foregroundStyle(session.note.isEmpty ? .tertiary : .primary)
                .lineLimit(wrapNotes ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: wrapNotes)

            // Only the mark: a session started from a task already carries the task's title as its
            // note, so naming it again would just print the same words twice. Hovering says which
            // task, and clicking the row opens the editor where the link can be changed.
            if showsTask, let todo = session.todoID.flatMap({ app.todo($0) }) {
                TaskChip(title: todo.title, showsTitle: false)
                    .padding(.top, wrapNotes ? 2 : 0)
            }

            // When the work happened, then how much of it. `fixedSize` keeps the times whole
            // when the pane is dragged narrow — the note is what gives up the space.
            Text(Format.range(session.start, session.end, calendar: app.calendar))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize()
                .padding(.top, wrapNotes ? 2 : 0)

            Text(Format.short(session.duration))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, wrapNotes ? 2 : 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onEdit(true) }
        .contextMenu {
            Button("Edit Times…") { onEdit(false) }
            Button("Delete Session", role: .destructive) { app.deleteSession(session.id) }
        }
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            SessionEditor(session: session, focusNoteOnOpen: focusNoteOnOpen)
                .environment(app)
        }
    }
}
