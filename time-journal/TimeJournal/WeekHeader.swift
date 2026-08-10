import SwiftUI

/// The row both drawings of the week share: which week is on screen, how to page it, and
/// which drawing to use. Living in one place is what keeps the week from jumping when you
/// switch between them.
struct WeekHeader: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 8) {
            if app.isCurrentWeek {
                Text("WEEK · \(app.weekLabel)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
            } else {
                Button {
                    app.goToCurrentWeek()
                } label: {
                    Text("WEEK · \(app.weekLabel)")
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                }
                .buttonStyle(.link)
                .help("Back to this week")
            }

            Spacer()

            Picker("View", selection: $app.viewMode) {
                // Labels rather than bare images: the segments render as icons but still
                // announce themselves.
                Label("Day totals", systemImage: "chart.bar.fill")
                    .tag(WeekViewMode.bars)
                Label("Day timeline", systemImage: "calendar.day.timeline.left")
                    .tag(WeekViewMode.calendar)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            .help("Switch between weekly totals and the day timeline")

            Button { app.goToWeek(offset: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.accessoryBar)
                .help("Previous week")
            Button { app.goToWeek(offset: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.accessoryBar)
                .help("Next week")
        }
    }
}
