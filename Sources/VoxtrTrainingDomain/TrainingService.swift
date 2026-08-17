import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// S3.2: thrown by `TrainingService.logActivity` when the requested
/// link would duplicate one that already exists.
public enum TrainingServiceError: Error, Equatable {
    case plannedActivityAlreadyLinked
    /// Planned/Logged Activity lifecycle consistency cleanup: thrown by
    /// `correctLoggedActivity` when no `LoggedActivity` exists for the
    /// given id, or exists but belongs to a different athlete —
    /// athlete isolation, never inferred from title/date.
    case loggedActivityNotFound
    /// Reversibility principle (Reopen Activity): thrown by
    /// `reopenCancelledActivity` when the `LoggedActivity` it was asked
    /// to reopen exists and belongs to the caller's athlete, but its
    /// `status` is not `.cancelled` — this lifecycle command is
    /// deliberately narrow to undoing an erroneous cancellation only,
    /// never a way to un-complete or un-miss a genuinely resolved
    /// outcome.
    case activityNotCancelled
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

    /// Runtime closeout (stale recurring preview fix): a thin
    /// passthrough for the exact same relationship lookup
    /// `TrainingPlanningCoordinationService.plannedActivitiesWithCompletion`
    /// already uses to derive completion elsewhere — never a second,
    /// separate completion-checking mechanism.
    public func fetchLoggedActivities(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> [LoggedActivity] {
        try repository.fetchLoggedActivities(forPlannedActivity: plannedActivityId)
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

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity -> RPE + Form), extended by review follow-up to
    /// also correct actual duration: corrects the duration and RPE
    /// already recorded on an existing `LoggedActivity`. Athlete-scoped:
    /// only ever operates on a `LoggedActivity` that already belongs to
    /// `athleteId` — the same isolation every other athlete-scoped
    /// method here already provides. Never creates a `LoggedActivity`;
    /// `logActivity` remains the only way one comes into existence.
    /// `durationMinutes` is always the schema's non-optional `Int` —
    /// callers pass the corrected value when the caller's own UI
    /// offered duration correction, or the activity's existing
    /// unchanged value otherwise, so this call can never silently
    /// rewrite a duration nobody asked to change.
    @discardableResult
    public func correctLoggedActivity(
        _ loggedActivityId: LoggedActivityId,
        athleteId: AthleteId,
        durationMinutes: Int,
        perceivedExertion: Int?
    ) throws -> LoggedActivity {
        guard let activity = try repository.fetchLoggedActivity(byId: loggedActivityId),
              activity.athleteId == athleteId.rawValue else {
            throw TrainingServiceError.loggedActivityNotFound
        }
        try repository.updateLoggedActivity(activity, durationMinutes: durationMinutes, perceivedExertion: perceivedExertion)
        return activity
    }

    /// Reversibility principle: undoes an erroneous cancellation.
    /// Cancellation is represented as a `PlannedActivity` with a linked
    /// `LoggedActivity(status: .cancelled)` — never a flag on
    /// `PlannedActivity` itself. Reopening therefore means removing
    /// exactly that `LoggedActivity`, never touching the
    /// `PlannedActivity` it was linked to: the plan's own stable
    /// identity, title, date, and every other field are completely
    /// unaffected, and it becomes unresolved (`outcomeStatus == nil`)
    /// again the moment this returns — loggable, cancellable again, or
    /// editable, exactly like any other never-yet-resolved planned
    /// activity. Athlete-scoped and status-scoped: throws
    /// `.loggedActivityNotFound` for a missing or cross-athlete id (the
    /// same isolation `correctLoggedActivity` above already enforces),
    /// and `.activityNotCancelled` for any other status — this command
    /// can never un-complete or un-miss a genuinely resolved outcome,
    /// only undo a cancellation.
    public func reopenCancelledActivity(_ loggedActivityId: LoggedActivityId, athleteId: AthleteId) throws {
        guard let activity = try repository.fetchLoggedActivity(byId: loggedActivityId),
              activity.athleteId == athleteId.rawValue else {
            throw TrainingServiceError.loggedActivityNotFound
        }
        guard activity.status == .cancelled else {
            throw TrainingServiceError.activityNotCancelled
        }
        try repository.deleteLoggedActivity(activity)
    }
}
