import Foundation
import VoxtrCoreContracts

/// Statistics — Trend View round: one week's smoothed values — a pure,
/// deterministic rolling-average PRESENTATION of the SAME factual
/// weekly buckets `DevelopmentTimelinePoint` already projects, never a
/// second Statistics read model and never persisted.
/// `trainingTrendMinutes` is always defined (Training's factual zero
/// participates in every average — see `DevelopmentTimelineTrendProjector`'s
/// own doc comment); `formTrendMean`/`sleepTrendMean` stay `nil`
/// whenever fewer than `DevelopmentTimelineTrendProjector
/// .minimumSampleCount` weekly values are available inside that point's
/// own rolling window — missing Form/Sleep is never treated as zero,
/// and is never fabricated into a trend value from a single
/// observation.
public struct DevelopmentTimelineTrendPoint: Identifiable, Hashable, Sendable {
    public let weekStart: LocalDate
    public let trainingTrendMinutes: Double
    public let formTrendMean: Double?
    public let sleepTrendMean: Double?

    public var id: LocalDate { weekStart }

    public init(
        weekStart: LocalDate,
        trainingTrendMinutes: Double,
        formTrendMean: Double?,
        sleepTrendMean: Double?
    ) {
        self.weekStart = weekStart
        self.trainingTrendMinutes = trainingTrendMinutes
        self.formTrendMean = formTrendMean
        self.sleepTrendMean = sleepTrendMean
    }
}

/// Statistics — Trend View round: the ONE pure projection from
/// already-loaded `DevelopmentTimelinePoint`s (themselves already a
/// projection of `StatisticsAthleteSummary.weeklyBuckets` — see that
/// type's own doc comment) into a smoothed, rolling-average
/// presentation. Fetches nothing, mutates nothing, and reads no
/// domain/persistence state of its own — every input is already-
/// loaded, already-filtered plain values, so Sport/Activity Type
/// filtering (Training/Form) and Sleep's established filter-
/// independence are inherited automatically from whatever `points`
/// already represents, with no separate filtering logic here (One
/// Truth: exactly one place decides what a week's factual values are —
/// `StatisticsService` — this type only smooths them).
///
/// FIXED 4-WEEK ROLLING WINDOW (V1): no configurable window size — see
/// the approved contract's own reasoning (deterministic, bounded scope,
/// avoids turning Statistics into an analytical configuration tool).
///
/// PROGRESSIVE WINDOW, BOUNDED TO THE SELECTED PERIOD: for index `i`
/// into `points` (already exactly the SELECTED Statistics period's own
/// buckets — never a wider fetch), the window is
/// `points[max(0, i - rollingWindowSize + 1)...i]`. The first
/// `rollingWindowSize - 1` points therefore use a shorter, growing
/// window (week 1's trend is just week 1's own value; week 2 averages
/// weeks 1–2; and so on), and week `rollingWindowSize` onward uses the
/// full trailing window. No data from before the selected period is
/// ever fetched or included, per the approved contract ("Trend
/// describes the selected Statistics interval").
///
/// TRAINING: arithmetic mean of `trainingMinutes` across the window —
/// EVERY bucket has a factual value, including a genuine zero-training
/// week, so this is always defined and a zero week always participates
/// (never excluded, never treated as missing, never normalized).
///
/// FORM / SLEEP: mean of only the weekly `formMean`/`sleepMean` values
/// that actually exist (non-`nil`) inside the window — a missing week
/// contributes nothing (never interpolated, never treated as zero).
/// Requires at least `minimumSampleCount` available values inside the
/// window; with fewer, the trend point is `nil` — a single observation
/// never fabricates an apparent trend.
public enum DevelopmentTimelineTrendProjector {
    /// V1: fixed, not user-configurable.
    public static let rollingWindowSize = 4
    /// V1: at least two available weekly Form/Sleep values must fall
    /// inside a point's own rolling window before a trend value is
    /// produced for it — the approved contract's own recommended
    /// minimum.
    public static let minimumSampleCount = 2

    public static func points(from points: [DevelopmentTimelinePoint]) -> [DevelopmentTimelineTrendPoint] {
        points.indices.map { index in
            let windowStart = max(0, index - rollingWindowSize + 1)
            let window = points[windowStart...index]
            let trainingTrend = Double(window.reduce(0) { $0 + $1.trainingMinutes }) / Double(window.count)
            return DevelopmentTimelineTrendPoint(
                weekStart: points[index].weekStart,
                trainingTrendMinutes: trainingTrend,
                formTrendMean: trendMean(window.compactMap(\.formMean)),
                sleepTrendMean: trendMean(window.compactMap(\.sleepMean))
            )
        }
    }

    private static func trendMean(_ values: [Double]) -> Double? {
        guard values.count >= minimumSampleCount else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
