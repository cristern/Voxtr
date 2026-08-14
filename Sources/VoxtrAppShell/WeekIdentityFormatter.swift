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
    /// "10–16 Aug" (or "27 Jul–2 Aug" when the week spans two months,
    /// or "27 Dec–2 Jan" when it spans two years — the month/year is
    /// only shown where it's not already implied by the other end).
    /// The date range itself is always authoritative; "This week"/
    /// "Previous week" (see `contextualLabel(for:referenceWeekStart:)`
    /// below) are optional, secondary context, never a substitute for
    /// the actual dates.
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

    /// Optional, secondary context label — "This week"/"Previous week"
    /// — relative to a reference week (normally the current Vǫxtr
    /// week). `nil` for any other week: the date range alone remains
    /// authoritative and sufficient identity, never requiring a label
    /// to be understood.
    public static func contextualLabel(for weekStart: LocalDate, referenceWeekStart: LocalDate) -> String? {
        if weekStart == referenceWeekStart { return "This week" }
        if weekStart == referenceWeekStart.adding(days: -7) { return "Previous week" }
        if weekStart == referenceWeekStart.adding(days: 7) { return "Next week" }
        return nil
    }

    /// The combined, canonical week identity string used across every
    /// surface that needs to show "which week is this" — e.g.
    /// "This week · 10–16 Aug" or, with no contextual label, just
    /// "27 Jul–2 Aug".
    public static func identityLabel(forWeekStart weekStart: LocalDate, referenceWeekStart: LocalDate) -> String {
        let range = dateRangeLabel(forWeekStart: weekStart)
        guard let context = contextualLabel(for: weekStart, referenceWeekStart: referenceWeekStart) else {
            return range
        }
        return "\(context) · \(range)"
    }
}

/// A small, reusable view for the identity label itself, so every
/// consuming screen renders it identically rather than each
/// reimplementing the same `Text`/`.font`/`.foregroundStyle` styling.
public struct WeekIdentityView: View {
    let weekStart: LocalDate
    let referenceWeekStart: LocalDate

    public init(weekStart: LocalDate, referenceWeekStart: LocalDate) {
        self.weekStart = weekStart
        self.referenceWeekStart = referenceWeekStart
    }

    public var body: some View {
        Text(WeekIdentityFormatter.identityLabel(forWeekStart: weekStart, referenceWeekStart: referenceWeekStart))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("weekIdentity.label")
    }
}
