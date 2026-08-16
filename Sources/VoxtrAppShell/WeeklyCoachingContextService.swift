import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrReflectionDomain

/// Sprint 6: the minimal protocol for the one read operation
/// `WeeklyCoachingContextService` needs from Reflection —
/// `ReflectionService.fetchParentObservations(forAthlete:)` (already
/// existed since S4.0). Same pattern `WeeklyReviewProviding`
/// established for `WeeklyReviewCoordinationService`: lets tests
/// substitute a deterministic throwing double instead of forcing a
/// genuine SwiftData failure. `ReflectionService` is the only
/// production conformer.
@MainActor
public protocol ParentObservationProviding {
    func fetchParentObservations(forAthlete athleteId: AthleteId) throws -> [ParentObservation]
}

extension ReflectionService: ParentObservationProviding {}

/// Sprint 9: the minimal protocol for `WeeklyCoachingContextService`'s
/// one read operation. Same pattern as `WeeklyReviewProviding`/
/// `ParentObservationProviding` above: lets `WeeklyReviewViewModel`'s
/// coaching-integration tests substitute a deterministic double instead
/// of requiring a full repository/`ModelContainer` setup for scenarios
/// (empty presentation, technical failure) that have nothing to do with
/// persistence mechanics. `WeeklyCoachingContextService` is the only
/// production conformer.
@MainActor
public protocol WeeklyCoachingContextProviding {
    func weeklyCoachingContext(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyCoachingContext
}

extension WeeklyCoachingContextService: WeeklyCoachingContextProviding {}

/// Sprint 6 (revised): assembles `WeeklyCoachingContext` for one
/// athlete/week. Read-only — nothing here inserts, updates, or deletes
/// anything.
///
/// Reuses `WeeklyReviewProviding` (Sprint 5.1/5.2) for the analysed
/// week — that protocol already aggregates Planning
/// (`WeekPlan`/`PlannedActivity`), Training (`LoggedActivity`), and
/// Reflection (`WeeklyReflection`) for a single week, with completion
/// state already derived exactly once (in
/// `TrainingPlanningCoordinationService`). This service calls it
/// **once** (not twice — see the revision note on `previousWeekStart`
/// below) and converts the result into `WeeklyCoachingContext`'s plain
/// value fields; the fetched `WeeklyReviewResult` (which holds `@Model`
/// references) never leaves this method.
///
/// REVISION: the original version of this service also fetched a full
/// previous week's `WeeklyReviewResult`, unused by anything. Removed —
/// only `previousWeekStart` (a plain `LocalDate`, computed, not
/// fetched) is included now. A future trend-analysis story should add
/// the previous-week fetch back once it actually has a consumer for it,
/// not before.
///
/// One of the few `VoxtrAppShell` files allowed to coordinate across
/// domains — consistent with `FamilyOnboardingCoordinator`/
/// `TrainingPlanningCoordinationService`/`WeeklyReviewCoordinationService`,
/// though in practice it only calls existing AppShell/Reflection
/// abstractions, never a Planning or Training type directly.
@MainActor
public final class WeeklyCoachingContextService {
    private let weeklyReviewProvider: any WeeklyReviewProviding
    private let parentObservationProvider: any ParentObservationProviding

    public init(
        weeklyReviewProvider: any WeeklyReviewProviding,
        parentObservationProvider: any ParentObservationProviding
    ) {
        self.weeklyReviewProvider = weeklyReviewProvider
        self.parentObservationProvider = parentObservationProvider
    }

    /// Assembles the context for `athleteId`'s week starting
    /// `weekStart`. Missing data (no plan, no reflection, no
    /// observations) is represented as `nil`/empty within the returned
    /// value type — this method only throws if `weeklyReviewProvider`
    /// or `parentObservationProvider` genuinely throws.
    public func weeklyCoachingContext(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyCoachingContext {
        let analysedWeek = try weeklyReviewProvider.weeklyReview(forAthlete: athleteId, weekStart: weekStart)
        let previousWeekStart = Self.addingDays(-7, to: weekStart)

        let weekEnd = Self.addingDays(6, to: weekStart)
        let allParentObservations = try parentObservationProvider.fetchParentObservations(forAthlete: athleteId)
        let parentObservations = allParentObservations
            .filter { $0.localDate >= weekStart && $0.localDate <= weekEnd }
            .map { ParentObservationSummary(localDate: $0.localDate, text: $0.text) }

        let weeklyReflection = analysedWeek.weeklyReflection.map { reflection in
            WeeklyReflectionSummary(
                overallSatisfaction: reflection.overallSatisfaction,
                loadFelt: reflection.loadFelt,
                whatWorked: reflection.whatWorked,
                whatWasDifficult: reflection.whatWasDifficult,
                learning: reflection.learning,
                nextWeekConsideration: reflection.nextWeekConsideration
            )
        }

        return WeeklyCoachingContext(
            athleteId: athleteId,
            weekStart: weekStart,
            previousWeekStart: previousWeekStart,
            weekPlanStatus: analysedWeek.weekPlan?.status,
            plannedActivityCount: analysedWeek.plannedActivities.count,
            // Review follow-up (cancellation sanity check, round 2):
            // `isGenuinelyCompleted`, not the broader `isCompleted` —
            // see `PlannedActivityCompletion`'s own doc comment.
            // `isCompleted` means "an outcome was resolved" (any
            // status, including Missed/Cancelled); this is consumed by
            // `CoachingAnalysisInputMapper` -> `CoachingEngine`, whose
            // `.allPlannedActivitiesCompleted`/`.somePlannedActivitiesMissed`
            // insights (presented as "All/Some planned activities
            // were(n't) completed this week") must never count a
            // cancelled or missed activity as completed training.
            // `uncompletedPlannedActivityCount` is the complement of
            // the SAME genuine-completion check (not a separate
            // "still pending" bucket) — this codebase's existing
            // Coaching contract has exactly two buckets, completed and
            // not-completed; introducing a third ("cancelled, neither")
            // would be a new product decision this task does not make.
            // A cancelled or missed activity is, factually, "not
            // completed this week" — the same true statement the
            // presentation text already makes — so it belongs here,
            // exactly where a never-logged planned activity already
            // does.
            completedPlannedActivityCount: analysedWeek.plannedActivities.filter(\.isGenuinelyCompleted).count,
            uncompletedPlannedActivityCount: analysedWeek.plannedActivities.filter { !$0.isGenuinelyCompleted }.count,
            unplannedLoggedActivityCount: analysedWeek.loggedActivities.filter { $0.plannedActivityId == nil }.count,
            totalLoggedActivityCount: analysedWeek.loggedActivities.count,
            weeklyReflection: weeklyReflection,
            parentObservations: parentObservations
        )
    }

    /// Shifts a `LocalDate` by `days` (positive or negative) — plain
    /// calendar arithmetic, not a business rule. No equivalent utility
    /// already exists in this project: the closest precedent
    /// (`WeeklyReviewCoordinationService.dateRange`) converts a
    /// `LocalDate` into a `Date` range but never shifts a `LocalDate`
    /// into another `LocalDate`, which is what "previous week start"
    /// and "end of this week" both need here.
    private static func addingDays(_ days: Int, to date: LocalDate, calendar: Calendar = .current) -> LocalDate {
        let components = DateComponents(year: date.year, month: date.month, day: date.day)
        guard let base = calendar.date(from: components),
              let shifted = calendar.date(byAdding: .day, value: days, to: base) else {
            return date
        }
        let shiftedComponents = calendar.dateComponents([.year, .month, .day], from: shifted)
        return LocalDate(
            year: shiftedComponents.year ?? date.year,
            month: shiftedComponents.month ?? date.month,
            day: shiftedComponents.day ?? date.day
        )
    }
}
