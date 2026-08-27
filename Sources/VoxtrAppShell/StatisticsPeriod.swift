import Foundation
import VoxtrCoreContracts

/// Statistics V1 UI: which period the Athlete Statistics screen is
/// showing. A presentation-layer concern only — `StatisticsService`
/// itself never knows about "periods," only an explicit
/// `[LocalDate, LocalDate]` interval.
///
/// Review follow-up (PR #24): two modes, per the locked V1 contract.
/// - `.rolling`: "Last 4/13/26 Weeks" — never "months." Each option
///   represents EXACTLY that many canonical Monday-start week buckets,
///   the current (possibly partial) week counted as the newest one.
/// - `.calendarMonth`: one specific calendar month (e.g. June 2026),
///   the exact `[firstDay, lastDay]` of that month — deliberately NOT
///   forced onto a Monday boundary, since a calendar month is a
///   different, independent unit from the rolling weekly windows. The
///   Development Timeline's weekly buckets stay canonical Monday-start
///   weeks regardless (see `StatisticsService.weekStarts`), so a
///   calendar-month interval can legitimately produce a partial first
///   and/or last weekly bucket — that is the correct, honest
///   representation of "this calendar month, bucketed into the same
///   canonical weeks everything else uses," not a bug to hide.
public enum StatisticsPeriod: Hashable, Sendable {
    case rolling(RollingWindow)
    case calendarMonth(year: Int, month: Int)

    /// Root's own fixed default (never user-adjustable at the root, per
    /// the approved contract) and the Athlete Statistics detail
    /// screen's own initial selection.
    public static let `default`: StatisticsPeriod = .rolling(.last4Weeks)

    public var displayName: String {
        switch self {
        case .rolling(let window):
            return window.displayName
        case .calendarMonth(let year, let month):
            return "\(Self.monthName(month)) \(year)"
        }
    }

    /// `[start, end]` inclusive.
    /// - `.rolling`: `end` is `today`; `start` is
    ///   `today.startOfWeek.adding(days: -7 * (weekCount - 1))` — the
    ///   Monday `weekCount - 1` canonical weeks before the CURRENT
    ///   week's own Monday. This is always itself a Monday, so the
    ///   Development Timeline's week-walk starts exactly there with no
    ///   partial leading week, and always produces exactly `weekCount`
    ///   buckets (proven by test): the current partial week (today back
    ///   to its own Monday) counts as the newest canonical week, plus
    ///   the `weekCount - 1` preceding full canonical weeks.
    /// - `.calendarMonth`: the exact first-through-last day of that
    ///   month — `today` is ignored for this case. Never adjusted to a
    ///   week boundary (see this type's own doc comment above).
    public func interval(today: LocalDate) -> ClosedRange<LocalDate> {
        switch self {
        case .rolling(let window):
            let start = today.startOfWeek.adding(days: -7 * (window.weekCount - 1))
            return start...today
        case .calendarMonth(let year, let month):
            let start = LocalDate(year: year, month: month, day: 1)
            let end = LocalDate(year: year, month: month, day: Self.daysInMonth(year: year, month: month))
            return start...end
        }
    }

    /// UTC-anchored — the SAME locale/timezone-independence convention
    /// `LocalDate`'s own arithmetic already uses (see that type's
    /// private `arithmeticCalendar`), so a calendar month's true length
    /// (leap-year February included) never depends on the device's
    /// current time zone.
    private static func daysInMonth(year: Int, month: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard
            let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
            let range = calendar.range(of: .day, in: .month, for: date)
        else {
            return 30
        }
        return range.count
    }

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// `month` is 1-12. A fixed English name table rather than
    /// `DateFormatter`/`Locale` — deterministic, no locale dependency to
    /// reason about for a period label.
    public static func monthName(_ month: Int) -> String {
        guard (1...12).contains(month) else { return "Month \(month)" }
        return monthNames[month - 1]
    }

    /// Review follow-up (PR #24): how far back the calendar-month Year
    /// picker offers, relative to `today`. This is a UI SAFETY BOUND
    /// ONLY — deliberately broad (a quarter century), never a product/
    /// history rule. No genuine "earliest recorded data" signal is
    /// cheaply available from current Statistics inputs
    /// (`StatisticsService`/`StatisticsAthleteSummary` expose no such
    /// thing, and adding one would mean a new read capability — out of
    /// scope for a UI picker bound); rather than hard-code a narrow
    /// window that would silently make older, perfectly readable
    /// canonical Statistics data unreachable from this screen, this
    /// bound is generous enough that no realistic athlete/family
    /// history could exceed it. Widening it further has no data-model
    /// impact at all — it only changes how many Year options a picker
    /// offers.
    private static let calendarMonthYearLookback = 25

    /// The calendar-month Year picker's valid range: from the UI safety
    /// bound above through `today`'s own year — never a future year.
    public static func selectableCalendarMonthYears(today: LocalDate) -> ClosedRange<Int> {
        (today.year - calendarMonthYearLookback)...today.year
    }

    /// The calendar-month Month picker's valid range for `year`: the
    /// full `1...12` for any past year, or `1...today.month` when
    /// `year == today.year` — a future month within the current year is
    /// never offered.
    public static func selectableCalendarMonths(forYear year: Int, today: LocalDate) -> ClosedRange<Int> {
        year == today.year ? 1...today.month : 1...12
    }

    /// Clamps `month` into `selectableCalendarMonths(forYear:today:)`
    /// for `year` — used when the Year picker changes to a year where
    /// the previously-selected month would now be in the future (e.g.
    /// switching from a past year with month 11 selected to the
    /// current year when `today.month` is 3).
    public static func clampCalendarMonth(_ month: Int, forYear year: Int, today: LocalDate) -> Int {
        let range = selectableCalendarMonths(forYear: year, today: today)
        return min(max(month, range.lowerBound), range.upperBound)
    }

    /// The rolling-window half of `StatisticsPeriod`. Locked V1
    /// contract — three trailing-week windows, deliberately never
    /// labelled or reasoned about as "months."
    public enum RollingWindow: String, CaseIterable, Identifiable, Sendable {
        case last4Weeks
        case last13Weeks
        case last26Weeks

        public var id: String { rawValue }

        public var weekCount: Int {
            switch self {
            case .last4Weeks: return 4
            case .last13Weeks: return 13
            case .last26Weeks: return 26
            }
        }

        public var displayName: String {
            switch self {
            case .last4Weeks: return "Last 4 Weeks"
            case .last13Weeks: return "Last 13 Weeks"
            case .last26Weeks: return "Last 26 Weeks"
            }
        }
    }
}
