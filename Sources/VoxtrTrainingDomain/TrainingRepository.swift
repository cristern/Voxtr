import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// S3.0 scope only: insert and fetch `LoggedActivity`. No load
/// calculations, no sRPE/ACWR, no reflections, no UI — those are
/// separate, later stories. `ActivityLoad` is registered in the app
/// schema (see `AppSchema`) but not touched by this repository at all;
/// nothing in S3.0 creates one.
///
/// No `#Predicate` (established project lesson — it caused a real Swift
/// Testing crash on this SwiftData/Xcode combination): every fetch here
/// fetches then filters in plain Swift instead.
///
/// No cross-domain SwiftData relationships — `athleteId` and
/// `plannedActivityId` are plain typed-ID-backed `UUID` fields, the same
/// pattern every other repository in this project already uses, not a
/// `@Relationship`.
@MainActor
public final class TrainingRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Cross-domain coordinators may only form a single SwiftData unit
    /// of work when every participating repository owns this exact
    /// context instance.
    public func uses(modelContext: ModelContext) -> Bool {
        self.modelContext === modelContext
    }

    /// Inserts a `LoggedActivity`. `plannedActivityId` is optional —
    /// linking a log to a `PlannedActivity` is by typed ID only, per
    /// scope; nothing here verifies that `PlannedActivity` exists
    /// (that's a later story's concern, same principle S2.0 applied to
    /// `insertPlannedActivity` not verifying its `WeekPlan`).
    /// Athlete Connection Foundation A: `loggedByActorId` defaults to
    /// `nil` at this repository layer — see `LoggedActivity
    /// .loggedByActorId`'s own doc comment for why the entity itself
    /// stays permissive. The real, non-optional requirement ("every new
    /// manually-created record receives the current actor") is enforced
    /// one layer up, at `TrainingReflectionCoordinationService.logActivity`,
    /// which every production call site already goes through and which
    /// already requires a non-optional `authorId: ActorId` — this
    /// repository/service pair stays permissive here specifically so the
    /// many existing tests exercising `TrainingService`/`TrainingRepository`
    /// directly for other Training behavior are not forced to supply an
    /// actor unrelated to what they're testing.
    public func insertLoggedActivity(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId? = nil,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        activityType: ActivityType,
        title: String?,
        startedAt: Date,
        endedAt: Date? = nil,
        durationMinutes: Int,
        status: ActivityStatus,
        perceivedExertion: Int? = nil,
        source: String,
        notes: String? = nil,
        loggedByActorId: ActorId? = nil
    ) throws -> LoggedActivity {
        let activity = LoggedActivity(
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
            notes: notes,
            loggedByActorId: loggedByActorId
        )
        modelContext.insert(activity)
        try modelContext.save()
        return activity
    }

    /// Ordered deterministically by `startedAt`, then `id` as a stable
    /// tiebreaker — not a business rule, just making repeated fetches
    /// return the same order every time (same pattern
    /// `PlanningRepository.fetchPlannedActivities` already uses).
    public func fetchLoggedActivities(forAthlete athleteId: AthleteId) throws -> [LoggedActivity] {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<LoggedActivity>())
        return all
            .filter { $0.athleteId == rawAthleteId }
            .sorted(by: Self.deterministicOrder)
    }

    /// Same athlete scoping and ordering as above, additionally bounded
    /// to `[startDate, endDate]` inclusive on `startedAt`.
    public func fetchLoggedActivities(
        forAthlete athleteId: AthleteId,
        from startDate: Date,
        to endDate: Date
    ) throws -> [LoggedActivity] {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<LoggedActivity>())
        return all
            .filter { $0.athleteId == rawAthleteId && $0.startedAt >= startDate && $0.startedAt <= endDate }
            .sorted(by: Self.deterministicOrder)
    }

    private static func deterministicOrder(_ lhs: LoggedActivity, _ rhs: LoggedActivity) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// S3.2: every `LoggedActivity` already linked to this
    /// `PlannedActivity`. Used by `TrainingService.logActivity` to
    /// reject a second link to the same `PlannedActivity` — v1.3 never
    /// described more than a 1:1 relationship, and nothing in this
    /// project's scope asked for many-to-one logging against one plan.
    public func fetchLoggedActivities(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> [LoggedActivity] {
        let rawId = plannedActivityId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<LoggedActivity>())
        return all
            .filter { $0.plannedActivityId == rawId }
            .sorted(by: Self.deterministicOrder)
    }

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity): looked up by the entity's own stable id, never
    /// by title/date — the same identity rule every other fetch in this
    /// project already follows.
    public func fetchLoggedActivity(byId loggedActivityId: LoggedActivityId) throws -> LoggedActivity? {
        let rawId = loggedActivityId.rawValue
        return try modelContext.fetch(FetchDescriptor<LoggedActivity>()).first { $0.id == rawId }
    }

    /// Corrects the actual duration and RPE (perceivedExertion) already
    /// recorded on an existing `LoggedActivity`. Review follow-up:
    /// duration is now correctable alongside RPE — since
    /// `durationMinutes` is canonical training truth, required at
    /// initial logging for Completed/PartiallyCompleted, and the
    /// schema's own non-optional `Int`, a data-entry mistake caught
    /// after logging would otherwise be permanently uncorrectable.
    /// Mutates the SAME entity in place then saves — never
    /// delete+reinsert — the exact pattern
    /// `PlanningService.editPlannedActivity` already established for
    /// `PlannedActivity`, preserving the entity's own stable id and
    /// every other field untouched.
    public func updateLoggedActivity(_ activity: LoggedActivity, durationMinutes: Int, perceivedExertion: Int?) throws {
        activity.durationMinutes = durationMinutes
        activity.perceivedExertion = perceivedExertion
        activity.updatedAt = .now
        try modelContext.save()
    }

    /// Reversibility principle (Reopen Activity): a plain, low-level
    /// removal primitive — not itself exposed as a general UI
    /// capability. `TrainingService.reopenNoTrainingOutcome` is the one
    /// caller, and only after verifying athlete ownership and that the
    /// `LoggedActivity` is a reversible `.cancelled`/`.missed` outcome. The
    /// linked `PlannedActivity` (if any) is completely untouched — this
    /// only ever removes the `LoggedActivity` row itself, the same
    /// entity `insertLoggedActivity` above creates.
    public func deleteLoggedActivity(_ activity: LoggedActivity) throws {
        modelContext.delete(activity)
        try modelContext.save()
    }

    /// Stages the Training-owned deletion without committing it. The
    /// AppShell reopen coordinator combines this with Reflection's own
    /// staged deletion and owns the single save/rollback boundary.
    public func stageDeleteLoggedActivity(_ activity: LoggedActivity) {
        modelContext.delete(activity)
    }
}
