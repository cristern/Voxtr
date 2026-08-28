import Foundation
import Observation
import VoxtrCoreContracts

/// Week Drilldown round: backs the Week Drilldown screen — "what
/// actually happened in this week," never why. Deliberately an
/// IMMUTABLE query-context snapshot, not a live reference back to the
/// parent `AthleteStatisticsViewModel`: `athleteId`/`weekStart`/
/// `intervalStart`/`intervalEnd`/`filter`/`today` are all captured at
/// the moment the drilldown was opened (see `AthleteStatisticsViewModel
/// .selectWeek(_:)`'s own doc comment) and never change for this
/// instance's lifetime, even if the parent screen's period/filter later
/// changes while the drilldown happens to still be open. This is the
/// smaller of the two coherent architectures the approved contract
/// considered ("shared, live-updating ViewModel" vs. "explicit
/// immutable snapshot") — it keeps "this screen explains exactly the
/// state the user selected" true without ever mixing live parent state
/// with a stale week identity, and without creating a second, editable
/// filter owner (Week Drilldown has none of its own — see
/// `WeekDrilldownView`'s own doc comment).
@MainActor
@Observable
public final class WeekDrilldownViewModel {
    public enum LoadState: Equatable {
        case loading
        case loaded(StatisticsWeekDetail)
        case failed
    }

    public let athleteId: AthleteId
    public let athleteDisplayName: String
    /// The canonical Monday-start week identity this drilldown
    /// represents — stable, never a display string/index.
    public let weekStart: LocalDate

    private let intervalStart: LocalDate
    private let intervalEnd: LocalDate
    private let filter: StatisticsFilter
    private let today: LocalDate
    private let statisticsService: StatisticsService

    public private(set) var loadState: LoadState = .loading

    public init(
        statisticsService: StatisticsService,
        athleteId: AthleteId,
        athleteDisplayName: String,
        weekStart: LocalDate,
        intervalStart: LocalDate,
        intervalEnd: LocalDate,
        filter: StatisticsFilter,
        today: LocalDate
    ) {
        self.statisticsService = statisticsService
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.weekStart = weekStart
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.filter = filter
        self.today = today
    }

    /// One-shot read — this ViewModel never reacts to any later change
    /// in the parent Statistics screen's period/filter (it has no
    /// reference back to it at all), so `load()` always produces the
    /// SAME result for the SAME already-captured query context. Called
    /// once, on the drilldown's own `.onAppear`.
    public func load() {
        loadState = .loading
        do {
            let detail = try statisticsService.weekDetail(
                forAthlete: athleteId,
                weekStart: weekStart,
                within: intervalStart,
                through: intervalEnd,
                filter: filter,
                today: today
            )
            loadState = .loaded(detail)
        } catch {
            loadState = .failed
        }
    }
}
