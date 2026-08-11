import SwiftUI
import Combine

/// Right pane: what the displayed week and today add up to, and the control that changes them.
struct TimerPanel: View {
    @Environment(AppState.self) private var app
    @FocusState.Binding var focusedSession: UUID?
    @State private var isLoggingManually = false

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
                                SessionRow(session: session, focused: $focusedSession)
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
            // nil means a sub-second session was discarded — nothing landed, so move nothing.
            // Without this guard, a mis-click would yank the cursor out of the note being typed.
            // The visibility check is a backstop: focusing a row that isn't rendered is a silent
            // no-op that also leaves a stale id parked in focusedSession. `toggle()` is what
            // actually guarantees the row is on screen; this just refuses to lie if it isn't.
            guard let id, app.weekSessions.contains(where: { $0.id == id }) else { return }
            focusedSession = id   // cursor lands in the note that just appeared
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
            // renders, focus has nothing to land on, and stop-then-annotate dead-ends.
            // Ordering matters: correcting state first means the row exists by the time
            // `focusSessionID` changes and the focus handler fires.
            if app.store.selectedProjectID != running.projectID { app.select(running.projectID) }
            if !app.isCurrentWeek { app.goToCurrentWeek() }
            app.stop()
        } else if let project = app.selectedProject {
            // A button click never reaches the window's tap-to-dismiss, so starting a new
            // timer while a note is being edited would otherwise leave the cursor parked in it.
            focusedSession = nil
            app.start(projectID: project.id)
        }
    }
}

/// One stopped session: the day it happened, an editable note, and its length.
/// Stopping the clock never blocks on this — an empty note is valid.
struct SessionRow: View {
    @Environment(AppState.self) private var app
    let session: Session
    @FocusState.Binding var focused: UUID?
    @State private var isEditing = false
    /// The note is edited here and written back when typing pauses or the field is left.
    /// Writing through on every keystroke re-rendered the whole list mid-word, and
    /// characters that arrived during the redraw were dropped.
    @State private var draft: String

    init(session: Session, focused: FocusState<UUID?>.Binding) {
        self.session = session
        _focused = focused
        _draft = State(initialValue: session.note)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(Format.weekday(session.start, calendar: app.calendar))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .leading)

            TextField("What did you do?", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused, equals: session.id)
                .onSubmit { commit(); focused = nil }        // Return saves and leaves the field
                .onExitCommand { commit(); focused = nil }   // Escape keeps what was typed
                .task(id: draft) {
                    // Autosave, debounced: .task(id:) cancels and restarts on every
                    // keystroke, so the write only lands once typing stops.
                    guard draft != session.note else { return }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    commit()
                }
                .onChange(of: focused) { _, id in
                    if id != session.id { commit() }   // clicking away saves immediately
                }
                .onDisappear { commit() }              // paging weeks must not drop a pending edit

            // When the work happened, then how much of it. `fixedSize` keeps the times whole
            // when the pane is dragged narrow — the note field is what gives up the space.
            Text(Format.range(session.start, session.end, calendar: app.calendar))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize()

            Text(Format.short(session.duration))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { isEditing = true }
        .contextMenu {
            Button("Edit Times…") { isEditing = true }
            Button("Delete Session", role: .destructive) { app.deleteSession(session.id) }
        }
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            SessionEditor(session: session)
                .environment(app)
        }
    }

    private func commit() {
        guard draft != session.note else { return }
        var updated = session
        updated.note = draft
        app.updateSession(updated)
    }
}
