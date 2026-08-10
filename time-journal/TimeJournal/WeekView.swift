import SwiftUI

/// Left pane: seven days, bars scaled to the busiest day of the displayed week.
struct WeekView: View {
    @Environment(AppState.self) private var app

    private var weekdayNames: [String] {
        app.dayTotals.map { Format.weekday($0.date, calendar: app.calendar) }
    }

    /// Bars are relative to the busiest day of THIS week, so a light week is still
    /// legible instead of seven flat slivers.
    private var scale: TimeInterval {
        max(app.dayTotals.map(\.seconds).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WeekHeader()

            VStack(spacing: 10) {
                ForEach(Array(app.dayTotals.enumerated()), id: \.element.id) { index, day in
                    row(day: day, name: weekdayNames[index])
                }
            }

            Spacer()

            Divider()
            HStack {
                Text("Total")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(Format.total(app.weekTotal))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(day: DayTotal, name: String) -> some View {
        let isToday = app.calendar.isDateInToday(day.date)
        return HStack(spacing: 12) {
            Text(name)
                .font(.callout)
                .foregroundStyle(isToday ? Color.primary : .secondary)
                .fontWeight(isToday ? .semibold : .regular)
                .frame(width: 36, alignment: .leading)

            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3)
                    .fill(isToday ? Color.accentColor : Color.accentColor.opacity(0.45))
                    .frame(width: max(0, geometry.size.width * (day.seconds / scale)))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)

            Text(day.seconds == 0 ? "—" : Format.short(day.seconds))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(day.seconds == 0 ? .tertiary : .secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
