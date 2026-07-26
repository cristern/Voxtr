import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// S3.2: "today's planned activities together with completion state"
/// genuinely needs both `PlannedActivity` (Planning) and
/// `LoggedActivity` (Training) — this is one of the few files allowed
/// to import both domain packages, the same rule
/// `FamilyOnboardingCoordinator`/`FamilyRestorationService` already
/// established for Parent+Athlete. It does not touch either domain's
/// SwiftData schema directly — only their existing repositories.
///
/// Completion is DERIVED, never stored: a `PlannedActivity` counts as
/// completed purely because a `LoggedActivity` already references it by
/// typed ID. `PlannedActivity`'s own schema is untouched — nothing new
/// is persisted to represent "completed."
public struct PlannedActivityCompletion {
    public let plannedActivity: PlannedActivity
    public let isCompleted: Bool
}

@MainActor
public final class TrainingPlanningCoordinationService {
    private let planningRepository: PlanningRepository
    private let trainingRepository: TrainingRepository

    public init(planningRepository: PlanningRepository, trainingRepository: TrainingRepository) {
        self.planningRepository = planningRepository
        self.trainingRepository = trainingRepository
    }

    /// Today's date, per the device's own calendar — not a business
    /// rule, the same kind of device-provided default
    /// `WeeklyPlanningViewModel.currentWeekStart` already uses.
    public static func today(referenceDate: Date = .now, calendar: Calendar = .current) -> LocalDate {
        let components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Start of the calendar week containing `referenceDate` — same
    /// computation `WeeklyPlanningViewModel.currentWeekStart` already
    /// uses, duplicated here rather than shared across the module
    /// boundary between `VoxtrAppShell` types, to keep this type
    /// self-contained.
    public static func weekStart(referenceDate: Date = .now, calendar: Calendar = .current) -> LocalDate {
        let start = calendar.dateInterval(of: .weekOfYear, for: referenceDate)?.start ?? referenceDate
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Returns today's `PlannedActivity` records for the athlete's
    /// current week, each paired with whether a `LoggedActivity`
    /// already references it. Empty (not an error) if no `WeekPlan`
    /// exists yet for this athlete/week — same "nothing to show yet"
    /// meaning `.noExistingFamily` carries elsewhere in this codebase.
    /// Ordering is inherited unchanged from
    /// `PlanningRepository.fetchPlannedActivities`'s own deterministic
    /// order (`localDate` then `id`); filtering to today doesn't
    /// disturb it.
    public func todaysPlannedActivitiesWithCompletion(
        forAthlete athleteId: AthleteId,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) throws -> [PlannedActivityCompletion] {
        let today = Self.today(referenceDate: referenceDate, calendar: calendar)
        let weekStart = Self.weekStart(referenceDate: referenceDate, calendar: calendar)

        guard let weekPlan = try planningRepository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) else {
            return []
        }
        let todaysActivities = try planningRepository
            .fetchPlannedActivities(forWeekPlan: weekPlan.weekPlanId)
            .filter { $0.localDate == today }

        return try plannedActivitiesWithCompletion(todaysActivities)
    }

    /// Sprint 5.1: the completion-derivation primitive, extracted so
    /// `WeeklyReviewCoordinationService` can reuse it for a whole week's
    /// planned activities instead of duplicating this check — the
    /// derivation itself (a `PlannedActivity` counts as completed
    /// purely because a `LoggedActivity` already references it) doesn't
    /// change; only its scope (today vs. a whole week) varies by
    /// caller. `todaysPlannedActivitiesWithCompletion` above now
    /// delegates here too, so there is exactly one copy of this check
    /// in the codebase. Order is preserved from the input array — pass
    /// already-ordered activities in, get them back in the same order.
    public func plannedActivitiesWithCompletion(_ plannedActivities: [PlannedActivity]) throws -> [PlannedActivityCompletion] {
        try plannedActivities.map { activity in
            let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
            return PlannedActivityCompletion(plannedActivity: activity, isCompleted: !links.isEmpty)
        }
    }
}

/// Sprint 13 (architecture correction): the narrowest protocol around
/// `TrainingPlanningCoordinationService`'s one method
/// `HomeDashboardViewModel` needs — same pattern as
/// `WeeklyReviewProviding`/`WeeklyCoachingContextProviding`/
/// `CoachingPresentationProviding`. Introduced only now, because only
/// now does something (`HomeDashboardViewModel`'s tests, specifically
/// deterministic call-count and independent-failure scenarios) actually
/// need it — `DailyTrainingViewModel` still takes the concrete type
/// directly, unchanged, since it has no such need.
/// `TrainingPlanningCoordinationService` is the only production
/// conformer.
@MainActor
public protocol TodaysTrainingProviding {
    func todaysPlannedActivitiesWithCompletion(forAthlete athleteId: AthleteId) throws -> [PlannedActivityCompletion]
}

extension TrainingPlanningCoordinationService: TodaysTrainingProviding {
    /// FIX: default arguments (`referenceDate`/`calendar` on the
    /// existing `todaysPlannedActivitiesWithCompletion(forAthlete:
    /// referenceDate:calendar:)` above) do not satisfy Swift protocol
    /// conformance — a protocol requirement with a single parameter is
    /// a distinct method signature from one with three parameters,
    /// defaults or not. This is a pure forwarding adapter, not a
    /// second implementation: it calls the existing method with its
    /// existing defaults (`.now`/`.current`) and changes no existing
    /// public API. The existing three-parameter method is untouched —
    /// callers that need to pass a specific `referenceDate`/`calendar`
    /// (none currently do, but the capability remains) still can.
    public func todaysPlannedActivitiesWithCompletion(forAthlete athleteId: AthleteId) throws -> [PlannedActivityCompletion] {
        try todaysPlannedActivitiesWithCompletion(forAthlete: athleteId, referenceDate: .now, calendar: .current)
    }
}
