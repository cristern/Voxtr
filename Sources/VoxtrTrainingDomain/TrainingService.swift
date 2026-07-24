import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// S3.2: thrown by `TrainingService.logActivity` when the requested
/// link would duplicate one that already exists.
public enum TrainingServiceError: Error, Equatable {
    case plannedActivityAlreadyLinked
}

/// S3.0/S3.1: the domain-level use case for logging completed
/// activities. Lives in `VoxtrTrainingDomain` itself (not
/// `VoxtrAppShell`) since it only ever touches Training's own entity via
/// `TrainingRepository` — no cross-domain concern here, same reasoning
/// `PlanningService` already established for its own domain.
///
/// No validation or business rules are added here beyond what
/// `LoggedActivity`'s own `precondition`s already enforce at
/// construction — nothing in the approved scope asked for more, and
/// inventing any would go beyond it.
///
/// S3.1 FLAGGED DECISION: scope asks for "optional duration," but
/// `LoggedActivity.durationMinutes` is a non-optional `Int` with its own
/// precondition (1–1440) — the v1.3 schema has no concept of "unknown
/// duration." Rather than inventing a derivation (e.g. from an
/// unrequested `endedAt`) or a meaningless placeholder, `durationMinutes`
/// below defaults to `1` — the schema's OWN minimum valid value, not a
/// new rule. `status` defaults to `.completed` and `source` to
/// `"manual"`, since something being logged after the fact, by a
/// person, is what those values already mean — both remain fully
/// overridable, not hidden.
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
        durationMinutes: Int = 1,
        status: ActivityStatus = .completed,
        perceivedExertion: Int? = nil,
        source: String = "manual",
        notes: String? = nil
    ) throws -> LoggedActivity {
        // S3.2: prevent the same PlannedActivity from being linked more
        // than once — checked before any insert is attempted.
        if let plannedActivityId {
            let existingLinks = try repository.fetchLoggedActivities(forPlannedActivity: plannedActivityId)
            guard existingLinks.isEmpty else {
                throw TrainingServiceError.plannedActivityAlreadyLinked
            }
        }
        return try repository.insertLoggedActivity(
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

    /// S3.1: convenience for "today's" activities — computes the
    /// device's current calendar-day bounds and reuses the existing
    /// date-range fetch (same deterministic ordering, no new query
    /// capability, just a convenience wrapper).
    public func fetchTodaysLoggedActivities(
        forAthlete athleteId: AthleteId,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) throws -> [LoggedActivity] {
        let startOfDay = calendar.startOfDay(for: referenceDate)
        let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay) ?? referenceDate
        return try repository.fetchLoggedActivities(forAthlete: athleteId, from: startOfDay, to: endOfDay)
    }
}
