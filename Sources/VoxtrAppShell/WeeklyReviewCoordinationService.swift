import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 5.1: the dedicated, immutable result of assembling one
/// athlete's week for review. Contains only what a future Weekly Review
/// UI needs — no calculation-engine output, no derived scores. `nil`
/// `weekPlan`/`weeklyReflection` are explicit, expected states (no plan
/// yet / no reflection yet), not error conditions.
public struct WeeklyReviewResult {
    public let athleteId: AthleteId
    public let weekStart: LocalDate
    public let weekPlan: WeekPlan?
    /// Every planned activity for the week, each paired with whether a
    /// `LoggedActivity` already references it — reuses
    /// `PlannedActivityCompletion`, the same result shape
    /// `TrainingPlanningCoordinationService` already established in
    /// S3.2, rather than introducing a parallel one for weekly scope.
    public let plannedActivities: [PlannedActivityCompletion]
    /// Every logged activity for the week — including any not linked
    /// to a planned activity at all. This is the full set, not just the
    /// ones referenced by `plannedActivities`; an unplanned session
    /// stays exactly that (unplanned), never backfilled with an
    /// invented `PlannedActivity`.
    public let loggedActivities: [LoggedActivity]
    public let weeklyReflection: WeeklyReflection?
}

/// Sprint 5.1: assembles everything needed to review one athlete's
/// week. Genuinely needs Planning, Training, and Reflection together —
/// one of the few `VoxtrAppShell` files allowed to import more than one
/// domain, the same rule `FamilyOnboardingCoordinator`/
/// `TrainingPlanningCoordinationService` already established.
///
/// No calculations, no trends, no scores — this only assembles
/// already-persisted data via already-existing repositories. Completion
/// state is computed via `TrainingPlanningCoordinationService.
/// plannedActivitiesWithCompletion(_:)` (the same primitive
/// `todaysPlannedActivitiesWithCompletion` uses) rather than
/// re-deriving it — there is exactly one place in this codebase that
/// decides whether a `PlannedActivity` counts as completed.
@MainActor
public final class WeeklyReviewCoordinationService {
    private let planningRepository: PlanningRepository
    private let trainingRepository: TrainingRepository
    private let weeklyReflectionRepository: WeeklyReflectionRepository
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService

    public init(
        planningRepository: PlanningRepository,
        trainingRepository: TrainingRepository,
        weeklyReflectionRepository: WeeklyReflectionRepository,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    ) {
        self.planningRepository = planningRepository
        self.trainingRepository = trainingRepository
        self.weeklyReflectionRepository = weeklyReflectionRepository
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
    }

    /// Assembles the review data for `athleteId`'s week starting
    /// `weekStart`. Never throws for "nothing found yet" — a missing
    /// `WeekPlan` or missing `WeeklyReflection` are both represented as
    /// `nil` in the result, not as an error.
    public func weeklyReview(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyReviewResult {
        let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart)

        let plannedActivities: [PlannedActivity]
        if let weekPlan {
            plannedActivities = try planningRepository.fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
        } else {
            plannedActivities = []
        }
        let plannedWithCompletion = try trainingPlanningCoordinationService
            .plannedActivitiesWithCompletion(plannedActivities)

        let loggedActivities: [LoggedActivity]
        if let (start, end) = Self.dateRange(forWeekStart: weekStart) {
            loggedActivities = try trainingRepository.fetchLoggedActivities(forAthlete: athleteId, from: start, to: end)
        } else {
            loggedActivities = []
        }

        let weeklyReflection = try weeklyReflectionRepository.fetchWeeklyReflection(forAthlete: athleteId, weekStart: weekStart)

        return WeeklyReviewResult(
            athleteId: athleteId,
            weekStart: weekStart,
            weekPlan: weekPlan,
            plannedActivities: plannedWithCompletion,
            loggedActivities: loggedActivities,
            weeklyReflection: weeklyReflection
        )
    }

    /// Converts a `LocalDate` week start into the `[start, end]` `Date`
    /// bounds `TrainingRepository`'s existing date-range fetch expects
    /// — a 7-day window, matching the same "one calendar week" meaning
    /// `WeekPlan`/`PlannedActivity` already use. `nil` only if the
    /// `LocalDate`'s components can't form a valid `Date` at all (not
    /// expected in practice for any real `weekStart`).
    private static func dateRange(forWeekStart weekStart: LocalDate, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let components = DateComponents(year: weekStart.year, month: weekStart.month, day: weekStart.day)
        guard let start = calendar.date(from: components) else { return nil }
        let end = calendar.date(byAdding: DateComponents(day: 7, second: -1), to: start) ?? start
        return (start, end)
    }
}
