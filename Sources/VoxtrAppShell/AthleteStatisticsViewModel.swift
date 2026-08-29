import Foundation
import Observation
import VoxtrCoreContracts

/// Training Breakdown round: which lens the Development Timeline's
/// Training bars are currently drawn through — a presentation choice
/// only. Never changes which activities are included, totals, filters,
/// period, buckets, or Form/Sleep; see `DevelopmentTimelineChart`'s own
/// doc comment for how each mode renders.
public enum TrainingBreakdownMode: String, CaseIterable, Identifiable, Sendable {
    case total, sport, activityType

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .total: return "Total"
        case .sport: return "Sport"
        case .activityType: return "Activity Type"
        }
    }
}

/// Statistics — Plan vs Actual round: which factual question the
/// Development Timeline's Training series is currently answering — a
/// presentation choice only, deliberately separate from
/// `TrainingBreakdownMode` above rather than folded into it, since the
/// two ask genuinely different questions: `TrainingBreakdownMode`
/// answers "what did actual training consist of?" (Total/Sport/Activity
/// Type, always Actual-only); `TimelineComparisonMode` answers "how did
/// reality compare with plan?" (`.actual`, the original single-series
/// Training bar this screen always showed; `.planVsActual`, a second,
/// factual Planned series drawn alongside it — see
/// `DevelopmentTimelineChart`'s own doc comment for how the two bars
/// render). `.planVsActual` never breaks Training down by Sport/Activity
/// Type — combining both would overload the chart, per the approved V1
/// contract — so `TrainingBreakdownMode` stays relevant only while
/// `timelineComparisonMode == .actual`. Default `.actual` reproduces the
/// Development Timeline exactly as it rendered before this round.
public enum TimelineComparisonMode: String, CaseIterable, Identifiable, Sendable {
    case actual
    case planVsActual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .actual: return "Actual"
        case .planVsActual: return "Plan vs Actual"
        }
    }
}

/// Statistics — Trend View round: which presentation the Development
/// Timeline's Training/Form/Sleep series currently render as — a
/// presentation choice only, exactly like `TrainingBreakdownMode`/
/// `TimelineComparisonMode` above. `.weekly` is the original, factual
/// per-week presentation (bars/points, unchanged); `.trend` is a
/// deterministic 4-week rolling-average smoothing of the SAME factual
/// weekly buckets (see `DevelopmentTimelineTrendProjector`'s own doc
/// comment) — never a new Statistics read, never persisted truth.
/// Trend is only ever effectively applied while `TimelineComparisonMode
/// == .actual` (see `DevelopmentTimelineChart`'s own compatibility
/// rule) — this enum itself carries no awareness of that rule, matching
/// how `TrainingBreakdownMode`/`TimelineComparisonMode` are likewise
/// unaware of each other's compatibility constraints.
public enum TimelineTrendMode: String, CaseIterable, Identifiable, Sendable {
    case weekly
    case trend

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .trend: return "Trend"
        }
    }
}

/// Statistics V1 UI — backs the Athlete Statistics detail screen.
/// Mirrors `WeeklyReviewLoadState`'s established shape (`.loading`/
/// `.loaded(Result)`/`.failed`) — no separate "empty"/"no data" case,
/// since a period/filter with zero matching training is still a
/// normal, factual `.loaded` result (`StatisticsAthleteSummary`'s own
/// zero counts and `nil` Form/Sleep means already say so); the View
/// reads that directly, the same way `WeeklyReviewView` does.
@MainActor
@Observable
public final class AthleteStatisticsViewModel {
    public enum LoadState: Equatable {
        case loading
        case loaded(StatisticsAthleteSummary)
        case failed
    }

    public let athleteId: AthleteId
    public let athleteDisplayName: String

    public private(set) var loadState: LoadState = .loading
    public private(set) var period: StatisticsPeriod
    public private(set) var sportFilter: SportId?
    public private(set) var activityTypeFilter: ActivityType?

    /// Sport filter catalog refinement round: which Sports this athlete
    /// has actually recorded performed Statistics history against —
    /// refreshed on every `load()`, independent of the currently
    /// selected period/filter (see `StatisticsService
    /// .availableSportIds(forAthlete:)`'s own doc comment). The View
    /// intersects this against the canonical Sport reference-data list
    /// to build the Sport filter's options — never the full canonical
    /// catalog, and never a second, View-owned availability read.
    public private(set) var availableSportIds: Set<SportId> = []

    /// Activity Type filter catalog refinement round: the exact same
    /// availability contract as `availableSportIds` above, keyed by
    /// `ActivityType` — refreshed on every `load()`, independent of the
    /// currently selected period/Sport/Activity Type filter (see
    /// `StatisticsService.availableActivityTypes(forAthlete:)`'s own
    /// doc comment). The View intersects this against
    /// `ActivityType.selectableCases` to build the Activity Type
    /// filter's options, preserving that canonical ordering.
    public private(set) var availableActivityTypes: Set<ActivityType> = []

    /// Development Timeline series-toggle state. Deliberately plain,
    /// side-effect-free `public var`s — toggling which series render is
    /// a presentation-only concern and must never trigger a reload or
    /// alter `loadState`/the underlying `StatisticsAthleteSummary` in
    /// any way, per the approved contract ("series-toggle state does
    /// not mutate/alter underlying Statistics data"). Unlike
    /// `period`/`sportFilter`/`activityTypeFilter` below, changing one
    /// of these never calls `load()`.
    public var isTrainingSeriesVisible = true
    public var isFormSeriesVisible = true
    public var isSleepSeriesVisible = true

    /// Training Breakdown round: same presentation-only contract as the
    /// series-visibility toggles above — changing this never triggers
    /// `load()` or alters `loadState`/the underlying
    /// `StatisticsAthleteSummary` in any way. Default `.total` reproduces
    /// the Development Timeline's pre-existing Training bar exactly.
    public var trainingBreakdownMode: TrainingBreakdownMode = .total

    /// Statistics — Plan vs Actual round: same presentation-only
    /// contract as `trainingBreakdownMode`/the series-visibility toggles
    /// above — changing this never triggers `load()` or alters
    /// `loadState`/the underlying `StatisticsAthleteSummary` in any way
    /// (`StatisticsAthleteSummary.plannedActivityCount`/`.plannedMinutes`
    /// are already present on every loaded summary regardless of this
    /// mode; this only changes how the Development Timeline presents
    /// them). Default `.actual` reproduces the Development Timeline's
    /// pre-existing Training bar exactly. A plain `public var`, shared
    /// identically by portrait (`AthleteStatisticsView`) and fullscreen
    /// (`DevelopmentTimelineFullscreenView`) — never persisted.
    public var timelineComparisonMode: TimelineComparisonMode = .actual

    /// Statistics — Trend View round: same presentation-only contract
    /// as `trainingBreakdownMode`/`timelineComparisonMode` above —
    /// changing this never triggers `load()` or alters `loadState`/the
    /// underlying `StatisticsAthleteSummary` in any way; it only
    /// changes how the Development Timeline chart PRESENTS the SAME
    /// already-loaded weekly buckets (see
    /// `DevelopmentTimelineTrendProjector`'s own doc comment for the
    /// pure rolling-average projection this drives). Default `.weekly`
    /// reproduces the Development Timeline's pre-existing chart exactly.
    /// A plain `public var`, shared identically by portrait
    /// (`AthleteStatisticsView`) and fullscreen
    /// (`DevelopmentTimelineFullscreenView`) — never persisted.
    public var timelineTrendMode: TimelineTrendMode = .weekly

    /// Week Drilldown round: which canonical week's drilldown is
    /// currently open, if any — presentation/navigation state only,
    /// never persisted, never Statistics domain truth. `nil` means no
    /// drilldown is open. Shared identically by portrait
    /// (`AthleteStatisticsView`, which owns the actual `.sheet`
    /// presentation) and fullscreen (`DevelopmentTimelineFullscreenView`,
    /// which can set it via the same `selectWeek(_:)` call) — selecting
    /// a week from EITHER surface opens the SAME drilldown, chained on
    /// top of whichever surface is currently on screen, never two
    /// independent presentation-state owners. Reading/writing this
    /// property never triggers `load()` or alters `loadState` — opening
    /// or closing the drilldown must never mutate the parent Statistics
    /// filter/period state it explains.
    public private(set) var selectedWeekStart: LocalDate?

    private let statisticsService: StatisticsService
    /// Fixed for this screen's lifetime once loaded — a period/filter
    /// change recomputes the interval from the SAME reference date
    /// rather than silently drifting to a new "today" mid-session.
    /// `public` (read-only) so the View can bound its calendar-month
    /// year picker relative to it, without a second "what is today"
    /// concept of its own.
    public let today: LocalDate

    public init(
        statisticsService: StatisticsService,
        athleteId: AthleteId,
        athleteDisplayName: String,
        period: StatisticsPeriod = .default,
        today: LocalDate = TrainingPlanningCoordinationService.today()
    ) {
        self.statisticsService = statisticsService
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.period = period
        self.today = today
    }

    /// The exact `StatisticsFilter` the current Sport/Activity Type
    /// selection maps to — `nil` on either side means "no constraint,"
    /// the same convention `StatisticsFilter` itself already documents.
    public var currentFilter: StatisticsFilter {
        StatisticsFilter(sportId: sportFilter, activityType: activityTypeFilter)
    }

    public func load() {
        loadState = .loading
        do {
            // Sport filter catalog refinement round: refreshed BEFORE the
            // filter used to fetch `summary` is built (`currentFilter`
            // reads `sportFilter` below), so a reset here is already
            // reflected in the SAME load — never a stale filter fetching
            // against Sport history that no longer exists.
            let available = try statisticsService.availableSportIds(forAthlete: athleteId)
            availableSportIds = available
            // Filter validity: a previously selected Sport that no
            // longer has recorded history must not be held as a silent,
            // invalid filter — reset to "All Sports" rather than a
            // selection that would otherwise just return an unexplained
            // empty result. Never silently substitutes a DIFFERENT
            // Sport.
            if let sportFilter, !available.contains(sportFilter) {
                self.sportFilter = nil
            }
            // Activity Type filter catalog refinement round: same
            // refresh-then-validate ordering as Sport immediately
            // above, entirely independent of it — an invalid Sport
            // resetting never touches `activityTypeFilter`, and vice
            // versa (Sport + Activity Type stay independently ANDed).
            let availableTypes = try statisticsService.availableActivityTypes(forAthlete: athleteId)
            availableActivityTypes = availableTypes
            if let activityTypeFilter, !availableTypes.contains(activityTypeFilter) {
                self.activityTypeFilter = nil
            }
            let interval = period.interval(today: today)
            // Plan vs Actual round: `today` is the SAME reference date
            // `interval` was just computed from — never re-derived — so
            // the Planned side's future-date clamp inside `athleteSummary`
            // can never disagree with the interval this ViewModel itself
            // requested.
            let summary = try statisticsService.athleteSummary(
                forAthlete: athleteId,
                from: interval.lowerBound,
                through: interval.upperBound,
                filter: currentFilter,
                today: today
            )
            loadState = .loaded(summary)
        } catch {
            loadState = .failed
        }
    }

    public func setPeriod(_ newPeriod: StatisticsPeriod) {
        guard newPeriod != period else { return }
        period = newPeriod
        load()
    }

    public func setSportFilter(_ sportId: SportId?) {
        guard sportId != sportFilter else { return }
        sportFilter = sportId
        load()
    }

    public func setActivityTypeFilter(_ activityType: ActivityType?) {
        guard activityType != activityTypeFilter else { return }
        activityTypeFilter = activityType
        load()
    }

    /// Week Drilldown round: opens the drilldown for `weekStart` — pure
    /// presentation state, never a reload. The canonical `LocalDate`
    /// week-start identity is the ONLY thing recorded here; the actual
    /// bounded query context (interval/filter/today) a drilldown needs
    /// is captured separately, at the moment `AthleteStatisticsView`
    /// constructs its `WeekDrilldownViewModel` from THIS ViewModel's
    /// current `loadState`/`currentFilter`/`today` — an explicit,
    /// immutable snapshot of what the user had selected, not a live
    /// reference back to this ViewModel (see `WeekDrilldownViewModel`'s
    /// own doc comment).
    public func selectWeek(_ weekStart: LocalDate) {
        selectedWeekStart = weekStart
    }

    /// Closes the drilldown. Also invoked by the `.sheet(isPresented:)`
    /// binding's own setter on a swipe-to-dismiss, so this is the ONE
    /// path a drilldown ever closes through, regardless of how.
    public func dismissWeekDrilldown() {
        selectedWeekStart = nil
    }

    /// Week Drilldown round: constructs the immutable query-context
    /// snapshot a just-opened drilldown needs, from THIS ViewModel's
    /// own current `loadState`/`currentFilter`/`today` — the View never
    /// touches `statisticsService` directly, matching this ViewModel's
    /// own established "the service stays private here" boundary
    /// (`AthleteStatisticsView` already never sees `statisticsService`
    /// itself, only `sportRepository`, passed in separately). Returns
    /// `nil` only if no week is currently selected or `loadState` isn't
    /// `.loaded` — the selector affordance that calls `selectWeek(_:)`
    /// only ever renders from an already-loaded chart, so this is
    /// defensive, not an expected path.
    public func makeWeekDrilldownViewModel() -> WeekDrilldownViewModel? {
        guard let selectedWeekStart, case .loaded(let summary) = loadState else { return nil }
        return WeekDrilldownViewModel(
            statisticsService: statisticsService,
            athleteId: athleteId,
            athleteDisplayName: athleteDisplayName,
            weekStart: selectedWeekStart,
            intervalStart: summary.intervalStart,
            intervalEnd: summary.intervalEnd,
            filter: currentFilter,
            today: today
        )
    }

    /// Week Drilldown round (fullscreen presentation-ownership fix): the
    /// PURE decision rule `weekDrilldownSheet(viewModel:sports:isActive:)`
    /// uses for "should THIS presenter show the drilldown sheet right
    /// now" — extracted out of that View extension's `Binding` closure
    /// so the rule itself is directly testable without SwiftUI
    /// rendering. `selectedWeekStart` remains the sole selection
    /// identity (never a second one); `isActive` only decides which
    /// already-mounted presenter is the one currently allowed to act on
    /// it — portrait passes `!isShowingFullscreenTimeline`, fullscreen
    /// passes `true` unconditionally (it IS the active surface whenever
    /// it's mounted at all). For any given moment, at most one of the
    /// two calls this function is capable of returning `true` for the
    /// SAME `selectedWeekStart`, since portrait's and fullscreen's own
    /// `isActive` values are always each other's exact complement.
    public static func shouldPresentWeekDrilldown(selectedWeekStart: LocalDate?, isActive: Bool) -> Bool {
        isActive && selectedWeekStart != nil
    }
}
