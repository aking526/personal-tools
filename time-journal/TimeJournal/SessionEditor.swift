import SwiftUI
import AppKit

/// Repairs the inevitable "left it running overnight", logs the block of work you forgot to
/// start the clock for, and is the one place a session's note and its times can be corrected
/// together. Duration is derived from the two dates and updates live, so there is no way to
/// enter an inconsistent session.
struct SessionEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var start: Date
    @State private var end: Date
    @State private var note: String
    @FocusState private var isNoteFocused: Bool
    @State private var refusedInitialFocus = false
    /// Which row has its month grid open, if either. It lives here rather than in the row so
    /// that opening one closes the other — two grids at once would make the popover taller
    /// than the calendar it sits over.
    @State private var openDay: Field?
    /// nil when logging time after the fact — nothing exists yet to update or delete.
    private let session: Session?
    private let projectID: UUID
    /// When true (notes-list click / post-stop annotate), keep the note field focused and
    /// move the caret to the end so typing doesn't wipe an existing note. When false
    /// (calendar / Edit Times / Log Time), refuse AppKit's automatic first-responder so the
    /// note isn't selected for someone who opened the popover to adjust times.
    private let focusNoteOnOpen: Bool

    private enum Field { case start, end }

    init(session: Session, focusNoteOnOpen: Bool = false) {
        self.session = session
        self.projectID = session.projectID
        self.focusNoteOnOpen = focusNoteOnOpen
        _start = State(initialValue: session.start)
        _end = State(initialValue: session.end)
        _note = State(initialValue: session.note)
    }

    init(newSessionFor projectID: UUID, start: Date, end: Date, focusNoteOnOpen: Bool = false) {
        self.session = nil
        self.projectID = projectID
        self.focusNoteOnOpen = focusNoteOnOpen
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        _note = State(initialValue: "")
    }

    private var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Equal times are rejected as well as inverted ones: a 0:00 row is never what anyone meant.
    private var isValid: Bool { end > start }

    private let labelWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            noteField

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                row(.start, label: "Start", date: $start)
                row(.end, label: "End", date: $end)
                durationRow
            }

            if !isValid {
                Text("The end must be after the start.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            buttons
        }
        .padding(16)
        .frame(width: 380)
        // AppKit hands first responder to the first text field in a popover, and a text field
        // selects everything it holds when it gets it — so this opened with the whole note
        // highlighted, one keystroke from being wiped by someone who came to read the times.
        // Nothing can be clicked before the popover exists, so the first focus it ever sees is
        // that automatic one. Refuse it unless the caller asked for note focus; in that case
        // keep focus but move the caret to the end so typing extends the note.
        // Pre-empting with `defaultFocus` / `.task` does not work: both run before SwiftUI assigns.
        .onChange(of: isNoteFocused) { _, focused in
            guard focused, !refusedInitialFocus else { return }
            refusedInitialFocus = true
            if focusNoteOnOpen {
                DispatchQueue.main.async { placeCaretAtEndOfNote() }
            } else {
                isNoteFocused = false
            }
        }
    }

    /// AppKit's automatic first-responder selects the whole field; collapse that to a caret
    /// after the last character so an existing note isn't one keystroke from deletion.
    private func placeCaretAtEndOfNote() {
        guard let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView else { return }
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
    }

    /// The note is the session's title, so it sits where a title goes and carries a title's
    /// weight. It is drawn as a field rather than as bare text on purpose: this popover could
    /// already correct a session's times, and nothing said its words could be corrected too.
    private var noteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("What did you do?", text: $note)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .focused($isNoteFocused)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isNoteFocused ? Color.accentColor
                                                            : Color.primary.opacity(0.12))
                        }
                }

            if let name = app.project(projectID)?.name {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
        }
    }

    private func row(_ field: Field, label: String, date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)

                // A button onto a month grid rather than the textual date picker's date half:
                // that control reserves two digits for the month and for the day, so the ninth
                // of August reads as "8/ 9/2026" — gaps that look like a mistake in the data.
                Button {
                    openDay = (openDay == field) ? nil : field
                } label: {
                    HStack(spacing: 4) {
                        Text(Format.day(date.wrappedValue, calendar: app.calendar))
                            .font(.callout)
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("\(label) day")

                Spacer(minLength: 0)

                // Only the clock: the day above is the button's job, so nothing here pads.
                DatePicker("", selection: date, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("\(label) time")
            }

            if openDay == field {
                DatePicker("", selection: date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.leading, labelWidth + 10)
                    // Picking a day is the only reason the grid is open, so it puts itself away
                    // again. Changing the time leaves it alone — that isn't what it was for.
                    .onChange(of: date.wrappedValue) { was, now in
                        if !app.calendar.isDate(was, inSameDayAs: now) { openDay = nil }
                    }
            }
        }
    }

    private var durationRow: some View {
        HStack(spacing: 10) {
            Text("Duration")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            Text(Format.clock(duration))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(isValid ? Color.primary : .red)

            Spacer(minLength: 0)
        }
    }

    private var buttons: some View {
        HStack {
            if let session {
                Button("Delete", role: .destructive) {
                    app.deleteSession(session.id)
                    dismiss()
                }
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            Spacer()
            Button(session == nil ? "Add" : "Save") {
                if var updated = session {
                    updated.start = start
                    updated.end = end
                    updated.note = note
                    app.updateSession(updated)
                } else {
                    app.addSession(projectID: projectID, start: start, end: end, note: note)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
    }
}
