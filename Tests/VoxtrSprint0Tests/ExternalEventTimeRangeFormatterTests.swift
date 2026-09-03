import Testing
import Foundation
@testable import VoxtrAppShell
import VoxtrCalendarPlanningDomain

/// External Calendar Event Time Range Presentation: focused coverage
/// for the one shared formatter every Calendar Import Review /
/// Diagnostic surface reuses to render an `ExternalCalendarEvent`'s
/// provider-owned schedule facts. Pure/deterministic — no persistence,
/// no SwiftData, runs in every environment. `calendar`/`locale` are
/// fixed (UTC, en_US_POSIX) so assertions never depend on the
/// environment this suite happens to run in.
@Suite("ExternalEventTimeRangeFormatter")
struct ExternalEventTimeRangeFormatterTests {

    private static let utc = TimeZone(identifier: "UTC")!
    private static let locale = Locale(identifier: "en_US_POSIX")

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = utc
        return calendar.date(from: components)!
    }

    @Test("Same-day timed event renders both the start and end time")
    func sameDayTimedEventRendersStartAndEnd() {
        let start = Self.date(2026, 9, 3, 18, 0)
        let end = Self.date(2026, 9, 3, 19, 30)
        let label = ExternalEventTimeRangeFormatter.label(startDate: start, endDate: end, isAllDay: false, calendar: Self.calendar, locale: Self.locale)
        #expect(label.contains("6:00"))
        #expect(label.contains("7:30"))
        #expect(label.contains("–"))
        // A same-day range must not repeat the calendar date twice —
        // only one "Sep 3, 2026"-style date component is present.
        #expect(label.range(of: "2026")?.upperBound == label.range(of: "2026", options: .backwards)?.upperBound)
    }

    @Test("Start-only fallback when the model has no usable end time")
    func startOnlyWhenEndMissing() {
        let start = Self.date(2026, 9, 3, 18, 0)
        let withNoEnd = ExternalEventTimeRangeFormatter.label(startDate: start, endDate: nil, isAllDay: false, calendar: Self.calendar, locale: Self.locale)
        #expect(withNoEnd.contains("6:00"))
        #expect(!withNoEnd.contains("–"))

        // An end at/before start is not a real interval — same
        // start-only fallback, never a zero/negative-length range.
        let withDegenerateEnd = ExternalEventTimeRangeFormatter.label(startDate: start, endDate: start, isAllDay: false, calendar: Self.calendar, locale: Self.locale)
        #expect(withDegenerateEnd == withNoEnd)
    }

    @Test("All-day event never fabricates a clock time")
    func allDayEventNeverFabricatesClockTime() {
        let start = Self.date(2026, 9, 3, 0, 0)
        let end = Self.date(2026, 9, 4, 0, 0)
        let label = ExternalEventTimeRangeFormatter.label(startDate: start, endDate: end, isAllDay: true, calendar: Self.calendar, locale: Self.locale)
        #expect(!label.contains(":"))
        #expect(!label.contains("–"))
    }

    @Test("Crossing midnight shows both dates rather than implying a false same-day interval")
    func crossingMidnightShowsBothDates() {
        let start = Self.date(2026, 9, 3, 23, 0)
        let end = Self.date(2026, 9, 4, 1, 0)
        let label = ExternalEventTimeRangeFormatter.label(startDate: start, endDate: end, isAllDay: false, calendar: Self.calendar, locale: Self.locale)
        #expect(label.contains("Sep 3"))
        #expect(label.contains("Sep 4"))
        #expect(label.contains("11:00"))
        #expect(label.contains("1:00"))
    }

    @Test("The formatted label is identical regardless of which review state calls it — review state is never a parameter")
    func labelIsIndependentOfReviewState() {
        let start = Self.date(2026, 9, 3, 18, 0)
        let end = Self.date(2026, 9, 3, 19, 30)
        // Every Calendar Import Review row state (Needs Review, Ready,
        // Suggested Ignore, Ignored) calls this exact same function with
        // the exact same event — simulated here by calling it multiple
        // times, matching how each row independently renders the label.
        let labels = (0..<4).map { _ in
            ExternalEventTimeRangeFormatter.label(startDate: start, endDate: end, isAllDay: false, calendar: Self.calendar, locale: Self.locale)
        }
        #expect(Set(labels).count == 1)
    }

    @Test("The label never depends on Vǫxtr planned duration or split-child duration — only startDate/endDate/isAllDay are read")
    func labelHasNoPlannedOrSplitDurationInput() {
        // The formatter's own signature is the proof: it accepts only
        // startDate/endDate/isAllDay (plus presentation-only
        // calendar/locale) — there is no plannedDurationMinutes or
        // split-child parameter it could read even by accident. This
        // test pins the actual computed value for a known interval so a
        // future regression that tried to thread such a value in would
        // have to change this assertion too.
        let start = Self.date(2026, 9, 3, 18, 0)
        let end = Self.date(2026, 9, 3, 19, 30)
        let label = ExternalEventTimeRangeFormatter.label(startDate: start, endDate: end, isAllDay: false, calendar: Self.calendar, locale: Self.locale)
        #expect(label.contains("6:00"))
        #expect(label.contains("7:30"))
    }

    @Test("ExternalCalendarEvent overload delegates to the same start/end/isAllDay label")
    func externalCalendarEventOverloadDelegatesCorrectly() {
        let start = Self.date(2026, 9, 3, 18, 0)
        let end = Self.date(2026, 9, 3, 19, 30)
        let event = ExternalCalendarEvent(
            eventIdentifier: "evt-1", calendarIdentifier: "cal-1", title: "Practice",
            startDate: start, endDate: end, isAllDay: false, isRecurring: false
        )
        let viaEvent = ExternalEventTimeRangeFormatter.label(for: event, calendar: Self.calendar, locale: Self.locale)
        let viaFields = ExternalEventTimeRangeFormatter.label(startDate: start, endDate: end, isAllDay: false, calendar: Self.calendar, locale: Self.locale)
        #expect(viaEvent == viaFields)
    }
}
