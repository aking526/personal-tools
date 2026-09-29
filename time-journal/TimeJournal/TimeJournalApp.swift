import SwiftUI

@main
struct TimeJournalApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("Time Journal", id: "main", for: String.self) { _ in
            ContentView()
                .environment(app)
        } defaultValue: {
            "main"
        }
        .defaultSize(width: 880, height: 540)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarPanel()
                .environment(app)
        } label: {
            if app.isRunning {
                Text(Format.clock(app.elapsed))
                    .monospacedDigit()
            } else {
                Image(systemName: "timer")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
