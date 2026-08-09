import Foundation

/// Turns sessions into positioned blocks for the calendar grid. Pure geometry, expressed as
/// fractions of a day rather than points — the view owns the sizing, this stays testable.
nonisolated enum DayLayout {
    /// One session's span within one day. A session that crosses midnight produces two.
    struct Block: Identifiable, Hashable {
        let session: Session
        /// 0 = Monday of the displayed week.
        let dayIndex: Int
        /// Fractions of the day, 0...1, measured by wall clock so a block always lines up with
        /// the hour row that bears its label — including on the two DST-transition days, where
        /// one hour row is simply doubled or skipped.
        let start: Double
        let end: Double
        let lane: Int
        let laneCount: Int
        /// The tail of a session that began the previous day: drawn without a repeated label.
        let isContinuation: Bool

        /// Not the session id: one session can appear on two days.
        var id: String { "\(session.id)-\(dayIndex)" }
    }

    /// `sessions` is expected to be pre-filtered to the displayed week and project — that is
    /// `AppState.weekSessions`. Anything outside the seven days is clipped away.
    static func blocks(sessions: [Session], weekStart: Date, calendar: Calendar) -> [Block] {
        let days = Week.days(from: weekStart, calendar: calendar)
        var byDay: [Int: [Segment]] = [:]
        for session in sessions {
            for segment in segments(of: session, days: days, calendar: calendar) {
                byDay[segment.dayIndex, default: []].append(segment)
            }
        }
        return byDay.values
            .flatMap(pack)
            .sorted { ($0.dayIndex, $0.start, $0.lane) < ($1.dayIndex, $1.start, $1.lane) }
    }

    // MARK: - Splitting

    private struct Segment {
        let session: Session
        let dayIndex: Int
        let start: Double
        let end: Double
        let isContinuation: Bool
    }

    private static func segments(of session: Session, days: [Date], calendar: Calendar) -> [Segment] {
        // Normalised, so a session whose end somehow precedes its start still draws rather than
        // silently vanishing from a week where the notes list is happy to show it.
        let from = min(session.start, session.end)
        let to = max(session.start, session.end)

        var result: [Segment] = []
        for (index, dayStart) in days.enumerated() {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let clippedStart = max(from, dayStart)
            let clippedEnd = min(to, dayEnd)
            // The `>=` branch keeps a zero-length session visible on its own day; the view
            // clamps it to a minimum height so it can still be clicked.
            guard clippedEnd > clippedStart || (from == to && from >= dayStart && from < dayEnd)
            else { continue }

            result.append(Segment(
                session: session,
                dayIndex: index,
                start: clippedStart <= dayStart ? 0 : fractionOfDay(clippedStart, calendar: calendar),
                end: clippedEnd >= dayEnd ? 1 : fractionOfDay(clippedEnd, calendar: calendar),
                isContinuation: from < dayStart))
        }
        return result
    }

    /// Where a moment sits in its day, by the clock on the wall. Also what the calendar's
    /// now-line is positioned by, so the line and the blocks agree.
    static func fractionOfDay(_ date: Date, calendar: Calendar) -> Double {
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = (time.hour ?? 0) * 3600 + (time.minute ?? 0) * 60 + (time.second ?? 0)
        return min(1, max(0, Double(seconds) / 86_400))
    }

    // MARK: - Overlaps

    /// Sessions may overlap — nothing stops you logging time twice over. Overlapping blocks
    /// share the column's width between them.
    private static func pack(_ segments: [Segment]) -> [Block] {
        let sorted = segments.sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        // Width is shared only within a run of transitively overlapping blocks, so one
        // double-booked morning doesn't halve an unrelated block that afternoon.
        var blocks: [Block] = []
        var cluster: [Segment] = []
        var clusterEnd = -Double.infinity
        for segment in sorted {
            if !cluster.isEmpty && segment.start >= clusterEnd {
                blocks += layOut(cluster)
                cluster = []
            }
            cluster.append(segment)
            clusterEnd = max(clusterEnd, segment.end)
        }
        return blocks + layOut(cluster)
    }

    private static func layOut(_ cluster: [Segment]) -> [Block] {
        var laneEnds: [Double] = []
        var lanes: [Int] = []
        for segment in cluster {
            if let lane = laneEnds.firstIndex(where: { $0 <= segment.start }) {
                laneEnds[lane] = segment.end
                lanes.append(lane)
            } else {
                lanes.append(laneEnds.count)
                laneEnds.append(segment.end)
            }
        }
        return zip(cluster, lanes).map { segment, lane in
            Block(session: segment.session,
                  dayIndex: segment.dayIndex,
                  start: segment.start,
                  end: segment.end,
                  lane: lane,
                  laneCount: laneEnds.count,
                  isContinuation: segment.isContinuation)
        }
    }
}
