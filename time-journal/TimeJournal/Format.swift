import Foundation

nonisolated enum Format {
    /// "04:12:33" — for the running stopwatch. Always two-digit padded.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "1:12" — for a single session or a day total.
    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }

    /// "9h 10m" — for week totals, where prose reads better than a colon.
    static func total(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let (h, m) = (s / 3600, (s % 3600) / 60)
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    // MARK: - Dates
    //
    // Date.FormatStyle rather than DateFormatter: it's a Sendable value type, so these can live
    // in a nonisolated enum without a shared mutable formatter. Every function takes the calendar
    // explicitly, like Week does, so tests can pin the time zone and locale.

    /// "Mon" — the weekday abbreviation used by the day bars, the notes list and the calendar.
    static func weekday(_ date: Date, calendar: Calendar) -> String {
        date.formatted(style(calendar).weekday(.abbreviated))
    }

    /// "9:30 AM", or "09:30" where the locale doesn't use a meridiem.
    static func time(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .omitted,
                                        time: .shortened,
                                        locale: locale(calendar),
                                        calendar: calendar,
                                        timeZone: calendar.timeZone))
    }

    /// "9:30 – 10:42 AM" when both ends share a meridiem, "11:30 AM – 1:05 PM" when they don't.
    /// A 24-hour locale has no symbol to share, so it falls through to "09:30 – 10:42".
    static func range(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        let first = time(start, calendar: calendar)
        let second = time(end, calendar: calendar)

        // Only the trailing form is dropped: locales that lead with the marker ("上午9:30")
        // fail the hasSuffix test and keep both, which reads correctly there.
        let symbols = DateFormatter()
        symbols.locale = locale(calendar)
        for symbol in [symbols.amSymbol, symbols.pmSymbol].compactMap({ $0 })
        where !symbol.isEmpty && first.hasSuffix(symbol) && second.hasSuffix(symbol) {
            let head = String(first.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
            return "\(head) – \(second)"
        }
        return "\(first) – \(second)"
    }

    /// "9 AM" / "09" — the hour gutter down the side of the calendar.
    static func hour(_ hour: Int, calendar: Calendar) -> String {
        // A fixed reference day: the label describes an hour of any day, not a particular one.
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = hour
        guard let date = calendar.date(from: components) else { return "\(hour)" }
        return date.formatted(style(calendar).hour(.defaultDigits(amPM: .abbreviated)))
    }

    private static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale(calendar), calendar: calendar, timeZone: calendar.timeZone)
    }

    private static func locale(_ calendar: Calendar) -> Locale {
        calendar.locale ?? .current
    }
}
