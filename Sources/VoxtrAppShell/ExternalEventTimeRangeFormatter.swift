import Foundation
import VoxtrCalendarPlanningDomain

/// External Calendar Event Time Range Presentation: the one, shared way
/// every AppShell surface renders an `ExternalCalendarEvent`'s
/// provider-owned schedule facts — deliberately separate from
/// `PlannedTimeRangeFormatter`, which formats Vǫxtr's own canonical
/// `PlannedActivity.startLocalTime`/`.plannedDurationMinutes`. The two
/// can produce visually similar `18:00–19:30` output, but their
/// source-of-truth semantics are different: this type reads only
/// `ExternalCalendarEvent.startDate`/`.endDate`/`.isAllDay` — the
/// provider's own schedule envelope — and never Vǫxtr planned duration
/// or split-child timing. "External source owns source start, source
/// end... Vǫxtr owns its own post-import Planning classification."
///
/// Pure presentation: takes `Date`/`Bool` values as input, persists
/// nothing, and has no opinion on Calendar Import Review state — the
/// same label renders identically regardless of which review state
/// (Needs Review / Ready / Suggested Ignore / Ignored) is currently
/// showing it, since none of those states change the event's own
/// `startDate`/`endDate`/`isAllDay`.
public enum ExternalEventTimeRangeFormatter {
    /// `calendar`/`locale` are injectable — defaulting to the device's
    /// current settings for production, overridable by tests for
    /// deterministic output. `calendar` also supplies the time zone
    /// (`calendar.timeZone`) every formatted value and the same-day
    /// check below are computed in, so the "does this event cross
    /// midnight" decision matches what the formatted strings actually
    /// show, rather than being computed in a different zone than the
    /// text a reader sees.
    public static func label(
        for event: ExternalCalendarEvent,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        label(
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            calendar: calendar,
            locale: locale
        )
    }

    public static func label(
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        // All-day: the provider's own explicit "no time of day" signal
        // — never fabricate a clock time by formatting the midnight-
        // anchored startDate as though it were a real scheduled instant.
        if isAllDay {
            return dateOnly(startDate, calendar: calendar, locale: locale)
        }

        let start = dateAndTime(startDate, calendar: calendar, locale: locale)

        // "Usable end" excludes a missing end and a non-positive
        // interval — an end at or before start is not a real range to
        // present, so start-only presentation is preserved instead of
        // showing a nonsensical or zero-length range.
        guard let endDate, endDate > startDate else {
            return start
        }

        if calendar.isDate(startDate, inSameDayAs: endDate) {
            return "\(start)–\(timeOnly(endDate, calendar: calendar, locale: locale))"
        }

        // Crossing midnight: a bare end time would misleadingly imply
        // the same calendar day as the start — the end gets its own
        // full date + time instead, the smallest factual presentation
        // that stays unambiguous about which day it falls on.
        return "\(start) – \(dateAndTime(endDate, calendar: calendar, locale: locale))"
    }

    /// `DateFormatter`, not the newer `Date.FormatStyle`/`.formatted(date:time:)`
    /// convenience the call sites used before this round: this is the
    /// same, already-established deterministic-formatting mechanism
    /// `WeekIdentityFormatter` already uses elsewhere in this module
    /// (explicit `.calendar`/`.timeZone`/`.locale`, never left to
    /// `.current`/`.autoupdatingCurrent` implicitly), and it's the only
    /// way this type's `calendar`/`locale` parameters above can actually
    /// govern the rendered text deterministically for tests.
    /// `.medium`/`.short` are `DateFormatter`'s own closest equivalents
    /// to the previous call sites' `.abbreviated`/`.shortened` styles —
    /// visually the same convention ("Sep 3, 2026", "6:00 PM"), not a
    /// new date/time presentation being introduced.
    private static func formatted(_ date: Date, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    private static func dateAndTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        formatted(date, dateStyle: .medium, timeStyle: .short, calendar: calendar, locale: locale)
    }

    private static func dateOnly(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        formatted(date, dateStyle: .medium, timeStyle: .none, calendar: calendar, locale: locale)
    }

    private static func timeOnly(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        formatted(date, dateStyle: .none, timeStyle: .short, calendar: calendar, locale: locale)
    }
}
