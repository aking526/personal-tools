import SwiftUI
import Combine

/// Right pane: what the displayed week and today add up to, and the control that changes them.
struct TimerPanel: View {
    @Environment(AppState.self) private var app
    @State private var isLoggingManually = false
    @State private var wrapNotes = false
    /// Which notes-list row has `SessionEditor` open, if any.
    @State private var editingSessionID: UUID?
    /// Whether that popover should autofocus the note (row click / post-stop) or not (Edit Times…).
    @State private var focusNoteWhenEditing = true

    /// The day the "today" figure is about. Held in state rather than read from the clock as the
    /// tally draws, so the day-change notification below can move it onto the new day in a window
    /// that was left open overnight — otherwise the panel would keep calling yesterday "today".
    @State private var today = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                tally(app.isCurrentWeek ? "THIS WEEK" : app.weekLabel.uppercased(),
                      seconds: app.weekTotal)
                Divider()
                    .frame(height: 44)
                tally("TODAY", seconds: app.dayTotal(for: today))
                Spacer(minLength: 0)
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text(Format.clock(app.elapsed))
                    .font(.system(size: 46, weight: .thin))
                    .monospacedDigit()
                    .foregroundStyle(app.isRunning ? Color.accentColor : .secondary)

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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("NOTES")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)

                    Spacer()

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

                if app.weekSessions.isEmpty {
                    Text("No sessions this week.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                } else {
                    ScrollView {
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
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: app.focusSessionID) { _, id in
            // nil means a sub-second session was discarded — nothing landed, so open nothing.
            // Owned here (not on the row) so a brand-new session still opens the popover:
            // the row may not exist yet when `focusSessionID` flips, and a row-level
            // `onChange` would miss that first assignment.
            guard let id, app.weekSessions.contains(where: { $0.id == id }) else { return }
            openEditor(sessionID: id, focusNote: true)
        }
        .onAppear { today = app.currentDate }   // the app's clock, which a test can pin
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = app.currentDate
            // This panel is on screen in both week drawings, so it is also the one place that can
            // carry the window into the new week whichever one is showing. The calendar does the
            // same when it's up; the call only moves a window still parked on the current week.
            app.followDayChange()
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
        if let running = app.store.running {
            // Bring the timer's own project and week into view BEFORE stopping. Nothing stops
            // you switching project or paging weeks while a timer runs, and if we stop while
            // looking elsewhere the new session isn't in `weekSessions` — so the row never
            // renders, the annotate popover has nothing to attach to, and stop-then-annotate
            // dead-ends. Ordering matters: correcting state first means the row exists by the
            // time `focusSessionID` changes and the popover opens.
            if app.store.selectedProjectID != running.projectID { app.select(running.projectID) }
            if !app.isCurrentWeek { app.goToCurrentWeek() }
            app.stop()
        } else if let project = app.selectedProject {
            app.start(projectID: project.id)
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

/// One stopped session: the day it happened, its note, and its length.
/// Stopping the clock never blocks on this — an empty note is valid.
struct SessionRow: View {
    @Environment(AppState.self) private var app
    let session: Session
    let wrapNotes: Bool
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
