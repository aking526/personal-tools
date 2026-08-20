import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ProjectBar()
            Divider()
            HSplitView {
                Group {
                    switch app.viewMode {
                    case .bars: WeekView()
                    case .calendar: CalendarView()
                    }
                }
                .frame(minWidth: app.viewMode == .calendar ? 380 : 320, idealWidth: 400)
                TimerPanel()
                    .frame(minWidth: 300, idealWidth: 420)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .alert("Time Log Problem",
               isPresented: Binding(get: { app.loadError != nil },
                                    set: { if !$0 { app.loadError = nil } })) {
            Button("OK") { app.loadError = nil }
        } message: {
            Text(app.loadError ?? "")
        }
    }
}

#Preview {
    // Point at a path that does NOT exist, so Storage.load() takes its first-launch branch
    // and the canvas renders the calm empty state. "/dev/null" would be worse than useless:
    // it exists, so load() tries to decode zero bytes, throws, and every preview render
    // comes up with the error alert on top of the UI you were trying to look at.
    ContentView()
        .environment(AppState(
            storage: Storage(url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("TimeJournalPreview-\(UUID().uuidString)/store.json")),
            now: Date.init,
            calendar: .current))
}
