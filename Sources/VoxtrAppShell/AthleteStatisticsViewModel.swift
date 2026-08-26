import Foundation
import Observation
import VoxtrCoreContracts

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
        let interval = period.interval(today: today)
        do {
            let summary = try statisticsService.athleteSummary(
                forAthlete: athleteId,
                from: interval.lowerBound,
                through: interval.upperBound,
                filter: currentFilter
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
}
