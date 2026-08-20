import SwiftUI
import Combine

/// Left pane, timeline mode: the same week the bars describe, drawn against the clock.
/// Hours down the side, the seven days across, one block per session.
struct CalendarView: View {
    @Environment(AppState.self) private var app

    /// The day the grid treats as today. Held in state rather than read from the clock as each
    /// column draws, so the day-change notification below can move the highlight and the
    /// now-line onto the new day in a window that was left open overnight.
    @State private var today = Date.now

    private let hourHeight: CGFloat = 44
    private let gutterWidth: CGFloat = 46

    private var dayHeight: CGFloat { hourHeight * 24 }

    private var days: [Date] {
        Week.days(from: app.displayedWeekStart, calendar: app.calendar)
    }

    private var blocks: [DayLayout.Block] {
        DayLayout.blocks(sessions: app.weekSessions,
                         weekStart: app.displayedWeekStart,
                         calendar: app.calendar)
    }

    var body: some View {
        let blocks = self.blocks
        let byDay = Dictionary(grouping: blocks, by: \.dayIndex)

        VStack(spacing: 0) {
            WeekHeader()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            dayHeaderRow
                .padding(.horizontal, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter
                        ForEach(Array(days.enumerated()), id: \.element) { index, day in
                            DayColumn(day: day,
                                      blocks: byDay[index] ?? [],
                                      hourHeight: hourHeight,
                                      showsNowLine: isToday(day))
                        }
                    }
                    .frame(height: dayHeight)
                    .padding(.horizontal, 8)
                }
                // A 24-hour column is always taller than the pane, so the bar only ever said
                // what the hour gutter beside it already says. `.never` rather than `.hidden`:
                // `.hidden` still draws the bar for anyone whose System Settings ask for scroll
                // bars always, which is the case this is meant to answer.
                .scrollIndicators(.never)
                // Open on the hours that matter rather than at midnight, and re-aim whenever
                // what "now" means changes: a new week paged in, or a window left running
                // through midnight.
                .onAppear {
                    today = app.currentDate
                    proxy.scrollTo(openingHour(), anchor: .top)
                }
                .onChange(of: app.displayedWeekStart) {
                    proxy.scrollTo(openingHour(), anchor: .top)
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                    today = app.currentDate
                    app.followDayChange()
                    proxy.scrollTo(openingHour(), anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isToday(_ day: Date) -> Bool {
        app.calendar.isDate(day, inSameDayAs: today)
    }

    /// Which hour goes to the top of the pane. On the current week that's the hour before now,
    /// so today's now-line opens on screen; on any other week it's the hour before the week's
    /// first session, and 8am when that week is empty. The hour of headroom either way keeps a
    /// block — or the now-line — off the top edge.
    private func openingHour() -> Int {
        if app.isCurrentWeek {
            return max(0, app.calendar.component(.hour, from: app.currentDate) - 1)
        }
        guard let earliest = blocks.map(\.start).min() else { return 8 }
        return max(0, Int(earliest * 24) - 1)
    }

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ForEach(Array(zip(days, app.dayTotals)), id: \.0) { day, total in
                let isToday = isToday(day)
                VStack(spacing: 1) {
                    Text(Format.weekday(day, calendar: app.calendar))
                        .font(.caption)
                    Text(String(app.calendar.component(.day, from: day)))
                        .font(.caption.weight(isToday ? .bold : .regular))
                        .monospacedDigit()
                    Text(total.seconds == 0 ? "—" : Format.short(total.seconds))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(total.seconds == 0 ? .tertiary : .secondary)
                }
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 8)
    }

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : Format.hour(hour, calendar: app.calendar))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: gutterWidth, height: hourHeight, alignment: .topTrailing)
                    // The label sits astride its own gridline rather than under it.
                    .offset(y: -5)
                    .padding(.trailing, 6)
                    .id(hour)
            }
        }
        .frame(width: gutterWidth)
    }
}

/// One day's column: the hour grid, the day's blocks, and — on today — the now-line.
private struct DayColumn: View {
    @Environment(AppState.self) private var app
    let day: Date
    let blocks: [DayLayout.Block]
    let hourHeight: CGFloat
    let showsNowLine: Bool

    /// A tap on empty space opens a draft session rather than saving one outright: a stray
    /// double-click should never quietly add time.
    @State private var draft: Draft?

    private struct Draft: Identifiable {
        let id = UUID()
        let start: Date
        let end: Date
    }

    private var dayHeight: CGFloat { hourHeight * 24 }
    private var minimumBlockHeight: CGFloat { 14 }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Bottom of the stack, so a tap that lands on a block goes to the block.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                        draft = makeDraft(at: tap.location.y)
                    })

                grid

                ForEach(blocks) { block in
                    let width = max(24, (geometry.size.width - 2) / CGFloat(block.laneCount))
                    BlockView(block: block, height: height(of: block))
                        .frame(width: width - 2, height: height(of: block), alignment: .top)
                        .offset(x: 1 + width * CGFloat(block.lane),
                                y: CGFloat(block.start) * dayHeight)
                }

                if showsNowLine { nowLine }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1)
        }
        .popover(item: $draft, arrowEdge: .trailing) { draft in
            if let project = app.selectedProject {
                SessionEditor(newSessionFor: project.id, start: draft.start, end: draft.end)
                    .environment(app)
            } else {
                Text("Create a project first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
    }

    private var grid: some View {
        Canvas { context, size in
            for hour in 1..<24 {
                let y = CGFloat(hour) * hourHeight
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line,
                               with: .color(.primary.opacity(hour % 6 == 0 ? 0.12 : 0.06)),
                               lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    /// Redraws itself once a minute. `app.tickNow` is no use here — it only advances while a
    /// timer is running, and the line has to be right whether or not the clock is going.
    private var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Rectangle()
                .fill(Color.red)
                .frame(height: 1)
                .overlay(alignment: .leading) {
                    Circle().fill(Color.red).frame(width: 5, height: 5).offset(x: -2)
                }
                .offset(y: CGFloat(DayLayout.fractionOfDay(context.date, calendar: app.calendar)) * dayHeight)
        }
        .allowsHitTesting(false)
    }

    private func height(of block: DayLayout.Block) -> CGFloat {
        max(minimumBlockHeight, CGFloat(block.end - block.start) * dayHeight)
    }

    /// Where in the day a click landed, rounded down to a quarter hour, plus the hour after it.
    private func makeDraft(at y: CGFloat) -> Draft? {
        let minutes = Int((y / dayHeight) * 24 * 60)
        let snapped = max(0, min(23 * 60 + 45, (minutes / 15) * 15))
        guard let start = app.calendar.date(byAdding: .minute, value: snapped, to: day),
              let end = app.calendar.date(byAdding: .hour, value: 1, to: start)
        else { return nil }
        return Draft(start: start, end: end)
    }
}

/// One session as it appears on the grid. Clicking opens the same editor the notes list uses.
private struct BlockView: View {
    @Environment(AppState.self) private var app
    let block: DayLayout.Block
    let height: CGFloat
    @State private var isEditing = false

    private var session: Session { block.session }

    private var range: String {
        Format.range(session.start, session.end, calendar: app.calendar)
    }

    private var title: String {
        session.note.isEmpty ? "—" : session.note
    }

    var body: some View {
        // A real Button rather than a tap gesture on a shape: this way the block answers to
        // the keyboard and to an accessibility press, not only to a mouse.
        Button { isEditing = true } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.22))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The tail of a session that began yesterday doesn't repeat the label.
                        if !block.isContinuation {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(height >= 44 ? 2 : 1)
                        }
                        if height >= 30 {
                            Text(range)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 7)
                    .padding(.trailing, 4)
                    .padding(.vertical, 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .help("\(title) · \(range) · \(Format.total(session.duration))")
            .accessibilityLabel("\(title), \(range)")
            .contextMenu {
                Button("Edit Times…") { isEditing = true }
                Button("Delete Session", role: .destructive) { app.deleteSession(session.id) }
            }
            .popover(isPresented: $isEditing, arrowEdge: .trailing) {
                SessionEditor(session: session)
                    .environment(app)
            }
    }
}
