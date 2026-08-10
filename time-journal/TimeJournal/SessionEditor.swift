import SwiftUI

/// Repairs the inevitable "left it running overnight", and logs the block of work you
/// forgot to start the clock for. Duration is derived from the two dates and updates
/// live, so there is no way to enter an inconsistent session.
struct SessionEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var start: Date
    @State private var end: Date
    /// nil when logging time after the fact — nothing exists yet to update or delete.
    private let session: Session?
    private let projectID: UUID

    init(session: Session) {
        self.session = session
        self.projectID = session.projectID
        _start = State(initialValue: session.start)
        _end = State(initialValue: session.end)
    }

    init(newSessionFor projectID: UUID, start: Date, end: Date) {
        self.session = nil
        self.projectID = projectID
        _start = State(initialValue: start)
        _end = State(initialValue: end)
    }

    private var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Equal times are rejected as well as inverted ones: a 0:00 row is never what anyone meant.
    private var isValid: Bool { end > start }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DatePicker("Start", selection: $start)
            DatePicker("End", selection: $end)

            HStack {
                Text("Duration")
                Spacer()
                Text(Format.clock(duration))
                    .monospacedDigit()
                    .foregroundStyle(isValid ? Color.primary : .red)
            }
            .font(.callout)

            if !isValid {
                Text("The end must be after the start.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

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
                        app.updateSession(updated)
                    } else {
                        app.addSession(projectID: projectID, start: start, end: end)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
