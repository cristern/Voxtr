import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrTrainingDomain

/// Sprint 12: mirrors `WeeklyReviewLoadState`/`CoachingPresentationLoadState`'s
/// exact shape — per this sprint's explicit instruction to follow
/// `WeeklyReviewViewModel`'s established pattern, not invent a
/// different one. No separate "empty" case, for the same reason those
/// two have none: an empty `[PlannedActivityCompletion]` array already
/// says "nothing planned today" on its own; the view reads that
/// directly.
public enum TodaysTrainingLoadState {
    case loading
    case loaded([PlannedActivityCompletion])
    case failed
}

/// Sprint 12: backs `HomeDashboardView`. Two independent load states —
/// today's training and the coaching summary — for the same reason
/// `WeeklyReviewViewModel` keeps its own two independent: a failure in
/// one must never block the other from loading or force it into
/// `.failed` too.
///
/// Reuses `CoachingPresentationLoadState` (defined alongside
/// `WeeklyReviewViewModel`) directly for the coaching summary, rather
/// than declaring a second, structurally-identical enum — that would
/// be exactly the "duplicate presentation model" this sprint asks to
/// avoid.
///
/// Nothing here recomputes anything. `todaysTraining` comes from
/// `TrainingPlanningCoordinationService.todaysPlannedActivitiesWithCompletion(forAthlete:)`
/// (already existed since Sprint 3.2 — completion state is derived
/// there, not here). `coachingSummary` comes from
/// `CoachingApplicationService.coachingPresentation(forAthlete:weekStart:)`
/// (Sprint 11) exactly as implemented — this type never touches
/// `WeeklyCoachingContext`, `CoachingEngine`, or
/// `CoachingPresentationMapper` directly, and never imports SwiftData
/// or a repository.
@MainActor
@Observable
public final class HomeDashboardViewModel {
    public private(set) var todaysTrainingState: TodaysTrainingLoadState = .loading
    public private(set) var coachingSummaryState: CoachingPresentationLoadState = .loading

    public let athleteId: AthleteId
    public let weekStart: LocalDate

    /// Concrete, not protocol-injected — matches
    /// `DailyTrainingViewModel`'s existing precedent for this exact
    /// dependency (it has never had a protocol wrapper in this
    /// project). Introducing one here, for this sprint alone, would be
    /// abstraction not yet justified anywhere else.
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    /// Protocol-injected — matches the established convention for this
    /// exact dependency since Sprint 11.
    private let coachingPresentationProvider: any CoachingPresentationProviding

    public init(
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        coachingPresentationProvider: any CoachingPresentationProviding,
        athleteId: AthleteId,
        weekStart: LocalDate
    ) {
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.coachingPresentationProvider = coachingPresentationProvider
        self.athleteId = athleteId
        self.weekStart = weekStart
    }

    public func loadTodaysTraining() {
        todaysTrainingState = .loading
        do {
            let activities = try trainingPlanningCoordinationService.todaysPlannedActivitiesWithCompletion(forAthlete: athleteId)
            todaysTrainingState = .loaded(activities)
        } catch {
            todaysTrainingState = .failed
        }
    }

    /// Pure delegation — the same pipeline call
    /// `WeeklyReviewViewModel.loadCoachingPresentation()` already makes,
    /// with no transformation. There is exactly one place in this
    /// codebase that performs the coaching orchestration
    /// (`CoachingApplicationService`); this method is not a second one.
    public func loadCoachingSummary() {
        coachingSummaryState = .loading
        do {
            let presentation = try coachingPresentationProvider.coachingPresentation(forAthlete: athleteId, weekStart: weekStart)
            coachingSummaryState = .loaded(presentation)
        } catch {
            coachingSummaryState = .failed
        }
    }
}
