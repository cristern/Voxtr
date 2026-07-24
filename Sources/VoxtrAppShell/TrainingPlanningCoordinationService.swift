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

        return try todaysActivities.map { activity in
            let links = try trainingRepository.fetchLoggedActivities(forPlannedActivity: activity.plannedActivityId)
            return PlannedActivityCompletion(plannedActivity: activity, isCompleted: !links.isEmpty)
        }
    }
}
