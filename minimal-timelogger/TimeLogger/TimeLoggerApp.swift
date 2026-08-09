import SwiftUI

@main
struct TimeLoggerApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 880, height: 540)
        .windowResizability(.contentMinSize)

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
