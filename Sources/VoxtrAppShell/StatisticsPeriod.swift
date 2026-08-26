import Foundation
import VoxtrCoreContracts

/// Statistics V1 UI: which trailing period the Athlete Statistics
/// screen is showing. A presentation-layer concern only — `StatisticsService`
/// itself never knows about "periods," only an explicit
/// `[LocalDate, LocalDate]` interval — matching PR #23's own delivery
/// report reasoning for why a "default period" helper belongs to the UI
/// package, not the foundation.
///
/// Deliberately expressed in whole trailing weeks (not calendar months)
/// so the resulting interval's start always falls on the SAME weekday
/// boundary the Development Timeline already buckets by
/// (`LocalDate.startOfWeek`) — a period computed from calendar months
/// would give the timeline one truncated, arbitrary leading partial
/// week that no product decision actually asked for.
///
/// Per the task's own PERIOD section: "Keep V1 period choices small and
/// useful" — three options, smallest that's still useful across the
/// approved range (Last Month / Last 3 Months / Last 6 Months). No
/// custom date-range picker: nothing in this codebase already
/// establishes one, so adding one here would not be "nearly free."
public enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case lastMonth
    case last3Months
    case last6Months

    public var id: String { rawValue }

    /// Root's own fixed default (never user-adjustable at the root, per
    /// the approved contract) and the Athlete Statistics detail
    /// screen's own initial selection.
    public static let `default`: StatisticsPeriod = .lastMonth

    public var displayName: String {
        switch self {
        case .lastMonth: return "Last Month"
        case .last3Months: return "Last 3 Months"
        case .last6Months: return "Last 6 Months"
        }
    }

    /// Trailing whole weeks this period covers — "Last Month" reads as
    /// 4 weeks (28 days), not a true calendar month, for the week-
    /// alignment reason above.
    private var weekCount: Int {
        switch self {
        case .lastMonth: return 4
        case .last3Months: return 13
        case .last6Months: return 26
        }
    }

    /// `[start, today]` inclusive — exactly `weekCount` trailing weeks
    /// ending today — the same inclusive-interval shape
    /// `StatisticsService.athleteSummary(from:through:)` already
    /// expects.
    public func interval(today: LocalDate) -> ClosedRange<LocalDate> {
        let start = today.adding(days: -(weekCount * 7 - 1))
        return start...today
    }
}
