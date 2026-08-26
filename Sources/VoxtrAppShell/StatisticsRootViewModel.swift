import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrAthleteDomain

/// Statistics V1 UI: the Parent Statistics root — a family overview,
/// one card per active athlete, `StatisticsPeriod.default` ("Last 4
/// Weeks"), no filter, no ranking. Never user-adjustable at the root
/// (no period/filter controls here) — those live on Athlete Statistics
/// once an athlete card is opened.
///
/// Only reads through canonical sources: `AthleteRepository` for the
/// active-athlete roster (the SAME `fetchAthletes(forWorkspace:)` +
/// `!isArchived` + `(createdAt, id)` ordering `FamilyHomeViewModel
/// .refreshActiveAthletes()`/`ParentTabShellView.fetchActiveAthletes(...)`
/// already establish — duplicated here rather than shared because both
/// of those are `private` to their own files, the same "no shared
/// private helper" precedent this codebase's tests already follow) and
/// `StatisticsService` for each athlete's summary. Owns no roster or
/// statistics truth of its own.
@MainActor
@Observable
public final class StatisticsRootViewModel {
    /// One family-overview card. Carries the already-computed
    /// `StatisticsAthleteSummary` (default period, no filter) rather
    /// than raw `AthleteProfile`/`@Model` state — the View never
    /// recomputes anything from it.
    public struct AthleteCard: Identifiable, Equatable {
        public let athleteId: AthleteId
        public let displayName: String
        public let summary: StatisticsAthleteSummary

        public var id: AthleteId { athleteId }
    }

    public enum LoadState: Equatable {
        case loading
        case loaded([AthleteCard])
        case failed
    }

    public private(set) var loadState: LoadState = .loading

    private let statisticsService: StatisticsService
    private let athleteRepository: AthleteRepository
    private let workspaceId: WorkspaceId

    public init(statisticsService: StatisticsService, athleteRepository: AthleteRepository, workspaceId: WorkspaceId) {
        self.statisticsService = statisticsService
        self.athleteRepository = athleteRepository
        self.workspaceId = workspaceId
    }

    /// `today` is injectable (defaults to the same device-local `.now`/
    /// `.current` every other "today" call in this codebase already
    /// uses via `TrainingPlanningCoordinationService.today()`) so tests
    /// can pin a deterministic reference date rather than depending on
    /// wall-clock time.
    public func load(today: LocalDate = TrainingPlanningCoordinationService.today()) {
        loadState = .loading
        do {
            let activeAthletes = try athleteRepository.fetchAthletes(forWorkspace: workspaceId)
                .filter { !$0.isArchived }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            let interval = StatisticsPeriod.default.interval(today: today)
            let cards = try activeAthletes.map { athlete in
                let summary = try statisticsService.athleteSummary(
                    forAthlete: athlete.athleteId,
                    from: interval.lowerBound,
                    through: interval.upperBound
                )
                return AthleteCard(athleteId: athlete.athleteId, displayName: athlete.givenName, summary: summary)
            }
            loadState = .loaded(cards)
        } catch {
            // A genuine technical failure (e.g. a SwiftData fetch
            // error) — NOT what an athlete with zero recorded training
            // in the period produces, since `StatisticsService
            // .athleteSummary` never throws for "no data," only for a
            // real read failure. See `LoadState.loaded([])`/an
            // `AthleteCard` whose `summary` is all-zero for the "no
            // data yet" case, which is `.loaded`, not `.failed`.
            loadState = .failed
        }
    }
}
