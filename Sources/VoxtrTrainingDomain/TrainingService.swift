import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// S3.0 scope only: the domain-level use case for logging completed
/// activities. Lives in `VoxtrTrainingDomain` itself (not
/// `VoxtrAppShell`) since it only ever touches Training's own entity via
/// `TrainingRepository` — no cross-domain concern here, same reasoning
/// `PlanningService` already established for its own domain.
///
/// No validation or business rules are added here beyond what
/// `LoggedActivity`'s own `precondition`s already enforce at
/// construction — nothing in the approved scope asked for more, and
/// inventing any would go beyond it.
@MainActor
public final class TrainingService {
    private let repository: TrainingRepository

    public init(repository: TrainingRepository) {
        self.repository = repository
    }

    /// Creates a `LoggedActivity`, optionally linked to a
    /// `PlannedActivity` by typed ID.
    public func logActivity(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId? = nil,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        activityType: ActivityType,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        durationMinutes: Int,
        status: ActivityStatus,
        perceivedExertion: Int? = nil,
        source: String,
        notes: String? = nil
    ) throws -> LoggedActivity {
        try repository.insertLoggedActivity(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            sportId: sportId,
            categoryIds: categoryIds,
            activityType: activityType,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMinutes: durationMinutes,
            status: status,
            perceivedExertion: perceivedExertion,
            source: source,
            notes: notes
        )
    }

    public func fetchLoggedActivities(forAthlete athleteId: AthleteId) throws -> [LoggedActivity] {
        try repository.fetchLoggedActivities(forAthlete: athleteId)
    }

    public func fetchLoggedActivities(
        forAthlete athleteId: AthleteId,
        from startDate: Date,
        to endDate: Date
    ) throws -> [LoggedActivity] {
        try repository.fetchLoggedActivities(forAthlete: athleteId, from: startDate, to: endDate)
    }
}
