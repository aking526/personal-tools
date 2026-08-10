import Foundation

/// Monday-based week arithmetic. Every function takes an explicit calendar so
/// callers (and tests) control the time zone.
nonisolated enum Week {
    /// Forces Monday-first regardless of locale.
    private static func mondayFirst(_ calendar: Calendar) -> Calendar {
        var cal = calendar
        cal.firstWeekday = 2
        return cal
    }

    static func start(of date: Date, calendar: Calendar) -> Date {
        let cal = mondayFirst(calendar)
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    static func days(from weekStart: Date, calendar: Calendar) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    static func shift(_ weekStart: Date, byWeeks weeks: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .weekOfYear, value: weeks, to: weekStart) ?? weekStart
    }

    /// "Feb 2 – 8" within one month, "Jan 26 – Feb 1" across a boundary.
    static func label(weekStart: Date, calendar: Calendar) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart

        let monthDay = DateFormatter()
        monthDay.calendar = calendar
        monthDay.timeZone = calendar.timeZone
        monthDay.locale = calendar.locale ?? Locale(identifier: "en_US")
        monthDay.dateFormat = "MMM d"

        let dayOnly = DateFormatter()
        dayOnly.calendar = calendar
        dayOnly.timeZone = calendar.timeZone
        dayOnly.locale = monthDay.locale
        dayOnly.dateFormat = "d"

        let sameMonth = calendar.isDate(weekStart, equalTo: end, toGranularity: .month)
        let tail = sameMonth ? dayOnly.string(from: end) : monthDay.string(from: end)
        return "\(monthDay.string(from: weekStart)) – \(tail)"
    }
}

nonisolated struct DayTotal: Identifiable, Hashable {
    let date: Date
    let seconds: TimeInterval
    var id: Date { date }
}

nonisolated enum Stats {
    /// Always returns exactly seven entries, one per day, zero-filled.
    /// A session belongs to the day it started on.
    static func dayTotals(sessions: [Session],
                          projectID: UUID,
                          weekStart: Date,
                          calendar: Calendar) -> [DayTotal] {
        let weekEnd = Week.shift(weekStart, byWeeks: 1, calendar: calendar)
        var sums: [Date: TimeInterval] = [:]
        for session in sessions
        where session.projectID == projectID && session.start >= weekStart && session.start < weekEnd {
            sums[calendar.startOfDay(for: session.start), default: 0] += session.duration
        }
        return Week.days(from: weekStart, calendar: calendar).map {
            DayTotal(date: $0, seconds: sums[$0] ?? 0)
        }
    }

    static func weekTotal(sessions: [Session],
                          projectID: UUID,
                          weekStart: Date,
                          calendar: Calendar) -> TimeInterval {
        dayTotals(sessions: sessions, projectID: projectID, weekStart: weekStart, calendar: calendar)
            .reduce(0) { $0 + $1.seconds }
    }
}
