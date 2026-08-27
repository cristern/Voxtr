import Foundation
import VoxtrCoreContracts
import SwiftUI

/// Area 3 (Parent Time Navigation & Weekly History package): one
/// reusable presentation mechanism for displaying an explicit Vǫxtr
/// week — Weekly Planning, Weekly Reflection, and Weekly History all
/// reuse this rather than each computing their own date-range string.
/// The canonical domain week itself is unchanged (Monday–Sunday via
/// `LocalDate.startOfWeek`, computed in `VoxtrCoreContracts`/
/// `TrainingPlanningCoordinationService`) — this is purely a
/// presentation layer over that existing identity, never a second
/// week-calculation implementation.
public enum WeekIdentityFormatter {
    /// Deterministic, locale-independent ISO week number — derived
    /// directly from the canonical Monday `weekStart` this app already
    /// uses everywhere (`LocalDate.startOfWeek`), never a second,
    /// independent week-numbering scheme that could disagree with it.
    /// `Calendar(identifier: .iso8601)` is used specifically because
    /// its week-of-year computation is locale-independent (unlike
    /// `.current`, whose `firstWeekday`/`minimumDaysInFirstWeek` vary
    /// by region) — it always agrees with Monday-start ISO weeks,
    /// matching Vǫxtr's own domain week model. Deterministic across
    /// year boundaries: a week start in late December that belongs to
    /// week 1 of the following ISO year (or vice versa) resolves
    /// correctly, since the calculation is driven by the actual
    /// Monday date, not a naive day-of-year divide.
    public static func weekNumber(forWeekStart weekStart: LocalDate) -> Int {
        var components = DateComponents()
        components.year = weekStart.year
        components.month = weekStart.month
        components.day = weekStart.day
        let isoCalendar = Calendar(identifier: .iso8601)
        guard let date = isoCalendar.date(from: components) else { return 0 }
        return isoCalendar.component(.weekOfYear, from: date)
    }

    /// "Jun 1" — a concise single calendar-date label (month + day, no
    /// year, no zero-padding). Statistics V1 UI (Development Timeline
    /// time-axis round): used for the Timeline's per-bucket date row,
    /// where year context is already shown separately above the chart
    /// so repeating it per-label would be redundant. Reuses the SAME
    /// short-month-symbol technique `dateRangeLabel` below already
    /// uses, rather than a second, independently-formatted date
    /// string.
    public static func shortDateLabel(for date: LocalDate) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        let month = formatter.shortMonthSymbols[date.month - 1]
        return "\(month) \(date.day)"
    }

    /// "10–16 Aug" (or "27 Jul–2 Aug" when the week spans two months,
    /// or "27 Dec–2 Jan" when it spans two years — the month/year is
    /// only shown where it's not already implied by the other end).
    public static func dateRangeLabel(forWeekStart weekStart: LocalDate) -> String {
        let weekEnd = weekStart.adding(days: 6)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        let startDay = String(format: "%02d", weekStart.day)
        let endDay = String(format: "%02d", weekEnd.day)
        let startMonth = formatter.shortMonthSymbols[weekStart.month - 1]
        let endMonth = formatter.shortMonthSymbols[weekEnd.month - 1]
        if weekStart.year != weekEnd.year {
            return "\(startDay) \(startMonth) \(weekStart.year)–\(endDay) \(endMonth) \(weekEnd.year)"
        }
        if weekStart.month != weekEnd.month {
            return "\(startDay) \(startMonth)–\(endDay) \(endMonth)"
        }
        return "\(startDay)–\(endDay) \(startMonth)"
    }

    /// "Week 33 · 10–16 Aug" — the stable, primary identity: week
    /// number + date range, never week number alone. This is the
    /// title-level content; relative context ("This week"/"Previous
    /// week") is deliberately NOT part of this string — see
    /// `contextualLabel` below, rendered as a separate secondary
    /// badge, never blended into this stable identity.
    public static func stableIdentityLabel(forWeekStart weekStart: LocalDate) -> String {
        "Week \(weekNumber(forWeekStart: weekStart)) · \(dateRangeLabel(forWeekStart: weekStart))"
    }

    /// Secondary, badge-only relative context. Only "THIS WEEK" and
    /// "PREVIOUS WEEK" — deliberately no "2 weeks ago"/"3 weeks ago"
    /// etc.; older weeks simply show their stable identity with no
    /// relative label at all, since a week's stable identity must
    /// never change as time moves forward.
    public static func contextualLabel(for weekStart: LocalDate, referenceWeekStart: LocalDate) -> String? {
        if weekStart == referenceWeekStart { return "THIS WEEK" }
        if weekStart == referenceWeekStart.adding(days: -7) { return "PREVIOUS WEEK" }
        return nil
    }

    /// Sprint 3 (Parent Time Navigation package)'s original combined
    /// string ("This week · 10–16 Aug") — retained ONLY for any
    /// existing consumer expecting a single flattened string, but
    /// superseded by `stableIdentityLabel`/`contextualLabel` rendered
    /// separately (see `WeekIdentityView` below), which is how every
    /// current surface actually presents this now.
    public static func identityLabel(forWeekStart weekStart: LocalDate, referenceWeekStart: LocalDate) -> String {
        stableIdentityLabel(forWeekStart: weekStart)
    }
}

/// A small, reusable view for the identity label itself, so every
/// consuming screen renders it identically rather than each
/// reimplementing the same `Text`/`.font`/`.foregroundStyle` styling.
/// Renders the stable identity (week number + date range) as the
/// primary content, with any relative context (THIS WEEK/PREVIOUS
/// WEEK) as a separate, secondary badge — never blended into the
/// title itself, matching the same secondary-badge treatment already
/// used for statuses like Recurring/Completed elsewhere in the app.
public struct WeekIdentityView: View {
    let weekStart: LocalDate
    let referenceWeekStart: LocalDate

    public init(weekStart: LocalDate, referenceWeekStart: LocalDate) {
        self.weekStart = weekStart
        self.referenceWeekStart = referenceWeekStart
    }

    public var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(WeekIdentityFormatter.stableIdentityLabel(forWeekStart: weekStart))
                .font(.subheadline)
                .foregroundStyle(VoxtrColor.textSecondary)
                .accessibilityIdentifier("weekIdentity.label")
            if let context = WeekIdentityFormatter.contextualLabel(for: weekStart, referenceWeekStart: referenceWeekStart) {
                Text(context)
                    .font(VoxtrTypography.caption)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("weekIdentity.contextBadge")
            }
        }
    }
}
