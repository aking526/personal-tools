import Testing
import Foundation
@testable import TimeJournal

struct FormatTests {
    @Test func clockPadsToTwoDigits() {
        #expect(Format.clock(0) == "00:00:00")
        #expect(Format.clock(59) == "00:00:59")
        #expect(Format.clock(60) == "00:01:00")
        #expect(Format.clock(3600) == "01:00:00")
        #expect(Format.clock(15153) == "04:12:33")
    }

    @Test func clockClampsNegatives() {
        #expect(Format.clock(-10) == "00:00:00")
    }

    @Test func shortDropsSecondsAndLeadingZero() {
        #expect(Format.short(0) == "0:00")
        #expect(Format.short(4320) == "1:12")
        #expect(Format.short(4379) == "1:12")   // seconds truncate, never round up
        #expect(Format.short(37800) == "10:30")
    }

    @Test func totalReadsAsProse() {
        #expect(Format.total(0) == "0m")
        #expect(Format.total(600) == "10m")
        #expect(Format.total(3600) == "1h")
        #expect(Format.total(33000) == "9h 10m")
    }
}

/// ICU puts a narrow no-break space before AM/PM; comparing against a plain space would make
/// these tests fail for a reason that has nothing to do with the code.
private func plainSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
}

private func calendar(_ identifier: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    cal.locale = Locale(identifier: identifier)
    return cal
}

private func at(_ hour: Int, _ minute: Int, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 2, day: 2, hour: hour, minute: minute))!
}

struct FormatDateTests {
    @Test func weekdayIsAbbreviated() {
        let cal = calendar("en_US")
        #expect(Format.weekday(at(9, 0, cal), calendar: cal) == "Mon")   // 2 Feb 2026
    }

    /// The point of this one is the *absence* of the numeric form: the whole reason the session
    /// editor draws its own day button is that "8/ 9/2026" is what the numeric field looks like.
    @Test func dayIsSpelledOutRatherThanNumeric() {
        let cal = calendar("en_US")
        let text = Format.day(at(9, 30, cal), calendar: cal)   // Mon 2 Feb 2026
        #expect(text == "Mon, Feb 2, 2026")
        #expect(!text.contains("/"))
    }

    @Test func timeIsShortenedAndLocalised() {
        #expect(plainSpaces(Format.time(at(9, 30, calendar("en_US")), calendar: calendar("en_US"))) == "9:30 AM")
        #expect(Format.time(at(9, 30, calendar("en_GB")), calendar: calendar("en_GB")) == "9:30")
    }

    @Test func rangeDropsTheRepeatedMeridiem() {
        let cal = calendar("en_US")
        #expect(plainSpaces(Format.range(at(9, 30, cal), at(10, 42, cal), calendar: cal)) == "9:30 – 10:42 AM")
        #expect(plainSpaces(Format.range(at(16, 10, cal), at(17, 0, cal), calendar: cal)) == "4:10 – 5:00 PM")
    }

    @Test func rangeKeepsBothWhenTheyDiffer() {
        let cal = calendar("en_US")
        #expect(plainSpaces(Format.range(at(11, 30, cal), at(13, 5, cal), calendar: cal))
                == "11:30 AM – 1:05 PM")
    }

    /// A 24-hour locale has no meridiem to share, so nothing is stripped.
    @Test func rangeLeavesTwentyFourHourLocalesAlone() {
        let cal = calendar("en_GB")
        #expect(Format.range(at(9, 30, cal), at(10, 42, cal), calendar: cal) == "9:30 – 10:42")
    }

    @Test func hourLabelsSuitTheLocale() {
        let us = calendar("en_US")
        #expect(plainSpaces(Format.hour(9, calendar: us)) == "9 AM")
        #expect(plainSpaces(Format.hour(0, calendar: us)) == "12 AM")
        #expect(plainSpaces(Format.hour(13, calendar: us)) == "1 PM")

        let gb = Format.hour(9, calendar: calendar("en_GB"))
        #expect(gb.contains("9"))
        #expect(!gb.uppercased().contains("AM"))
    }
}
