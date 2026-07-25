import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// S2.2: thrown by `PlanningService` when an add/edit can't proceed.
/// Not a new business rule — these two cases are exactly the two guards
/// the approved scope asks for.
public enum PlanningServiceError: Error, Equatable {
    case weekPlanNotFound
    case plannedActivityNotFound
    case plannedActivityDoesNotBelongToWeekPlan
    case weekPlanNotDraft
    case invalidField(String)
}

/// S2.1 scope only: one use case — get-or-create a draft `WeekPlan` for
/// a given athlete and calendar week. No commit-week behavior, no
/// `PlannedActivity` editing, no UI. Lives in `VoxtrPlanningDomain`
/// itself (not `VoxtrAppShell`) since it only ever touches Planning's
/// own entity via `PlanningRepository` — no cross-domain concern here.
@MainActor
public final class PlanningService {
    private let repository: PlanningRepository

    public init(repository: PlanningRepository) {
        self.repository = repository
    }

    /// Returns the existing draft `WeekPlan` for this athlete/week if
    /// one already exists; otherwise creates one and returns it. Never
    /// creates a second `WeekPlan` for the same athlete/week — the
    /// fetch-then-insert-if-absent check below is this use case's only
    /// business rule, matching the approved scope exactly ("one plan
    /// per athlete/week"), not inventing anything further. Status stays
    /// at `WeekPlan`'s own default (`.draft`) and revision at its own
    /// default (`1`) — this method sets neither explicitly, so any
    /// future change to those defaults is the entity's decision, not
    /// duplicated here.
    public func getOrCreateWeekPlan(athleteId: AthleteId, weekStart: LocalDate) throws -> WeekPlan {
        if let existing = try repository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) {
            return existing
        }
        return try repository.insertWeekPlan(athleteId: athleteId, weekStart: weekStart)
    }

    /// S2.3: commits a draft WeekPlan. Delegates entirely to `WeekPlan.
    /// commit` for the actual transition/revision-increment logic (the
    /// existing optimistic-concurrency model) — this method's only job
    /// is the existence check ("commit a WeekPlan that doesn't exist"
    /// isn't one of the two error cases `WeekPlan.commit` itself can
    /// express, since it needs an instance to call this on).
    /// `WeekPlanConflictError` (stale revision / already committed)
    /// propagates directly, unwrapped — same as how `AthleteProfile.
    /// applyMutation`'s conflict error is surfaced.
    @discardableResult
    public func commitWeekPlan(
        _ weekPlanId: WeekPlanId,
        expectedRevision: Int,
        committedBy: ActorId
    ) throws -> WeekPlan {
        guard let weekPlan = try repository.fetchWeekPlan(byId: weekPlanId) else {
            throw PlanningServiceError.weekPlanNotFound
        }
        try weekPlan.commit(expectedRevision: expectedRevision, committedBy: committedBy)
        try repository.save()
        return weekPlan
    }

    /// S2.2: adds a `PlannedActivity` to an existing `WeekPlan`.
    /// Requirement: "Prevent edits when the referenced WeekPlan does
    /// not exist" — checked here before any insert is attempted.
    public func addPlannedActivity(
        toWeekPlan weekPlanId: WeekPlanId,
        athleteId: AthleteId,
        activityType: ActivityType,
        title: String,
        localDate: LocalDate,
        timeZoneId: TimeZoneId,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        plannedIntensity: Int? = nil,
        notes: String? = nil
    ) throws -> PlannedActivity {
        guard try repository.fetchWeekPlan(byId: weekPlanId) != nil else {
            throw PlanningServiceError.weekPlanNotFound
        }
        try Self.validate(
            title: title,
            plannedDurationMinutes: plannedDurationMinutes,
            plannedIntensity: plannedIntensity,
            notes: notes
        )
        return try repository.insertPlannedActivity(
            weekPlanId: weekPlanId,
            athleteId: athleteId,
            activityType: activityType,
            title: title,
            localDate: localDate,
            timeZoneId: timeZoneId,
            sportId: sportId,
            categoryIds: categoryIds,
            startLocalTime: startLocalTime,
            plannedDurationMinutes: plannedDurationMinutes,
            plannedIntensity: plannedIntensity,
            notes: notes
        )
    }

    /// S2.2: edits an existing `PlannedActivity`. Requirements: "Prevent
    /// edits when the referenced WeekPlan does not exist" and "...when
    /// the PlannedActivity does not belong to the supplied WeekPlan" —
    /// both checked before any field is changed. `id`, `weekPlanId`,
    /// `athleteId`, and `createdAt` are identity/ownership/audit fields
    /// and are not editable through this method — everything else
    /// `PlannedActivity` stores is.
    public func editPlannedActivity(
        _ plannedActivityId: PlannedActivityId,
        expectedWeekPlanId weekPlanId: WeekPlanId,
        activityType: ActivityType,
        title: String,
        localDate: LocalDate,
        timeZoneId: TimeZoneId,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        plannedIntensity: Int? = nil,
        notes: String? = nil
    ) throws -> PlannedActivity {
        guard let weekPlan = try repository.fetchWeekPlan(byId: weekPlanId) else {
            throw PlanningServiceError.weekPlanNotFound
        }
        guard weekPlan.status == .draft else {
            throw PlanningServiceError.weekPlanNotDraft
        }
        guard let activity = try repository.fetchPlannedActivity(byId: plannedActivityId) else {
            throw PlanningServiceError.plannedActivityNotFound
        }
        guard activity.weekPlanId == weekPlanId.rawValue else {
            throw PlanningServiceError.plannedActivityDoesNotBelongToWeekPlan
        }
        try Self.validate(
            title: title,
            plannedDurationMinutes: plannedDurationMinutes,
            plannedIntensity: plannedIntensity,
            notes: notes
        )

        activity.activityType = activityType
        activity.title = title
        activity.localDate = localDate
        activity.timeZoneId = timeZoneId
        activity.sportId = sportId?.rawValue
        activity.categoryIds = categoryIds.map(\.rawValue)
        activity.startLocalTime = startLocalTime
        activity.plannedDurationMinutes = plannedDurationMinutes
        activity.plannedIntensity = plannedIntensity
        activity.notes = notes
        activity.updatedAt = .now

        try repository.save()
        return activity
    }

    /// S2.2: mirrors — does not replace — `PlannedActivity`'s own
    /// `precondition` bounds (v1.3 Section 8.2). `insertPlannedActivity`
    /// already goes through the entity's real initializer, which
    /// enforces these directly; this exists so `editPlannedActivity`
    /// (which mutates an already-constructed instance in place, so the
    /// initializer's preconditions don't run again) can reject the same
    /// invalid input with a catchable error instead of a crash.
    private static func validate(
        title: String,
        plannedDurationMinutes: Int?,
        plannedIntensity: Int?,
        notes: String?
    ) throws {
        guard (1...120).contains(title.count) else {
            throw PlanningServiceError.invalidField("title must be 1-120 characters")
        }
        if let duration = plannedDurationMinutes {
            guard (1...1440).contains(duration) else {
                throw PlanningServiceError.invalidField("plannedDurationMinutes must be 1-1440")
            }
        }
        if let intensity = plannedIntensity {
            guard (1...10).contains(intensity) else {
                throw PlanningServiceError.invalidField("plannedIntensity must be 1-10")
            }
        }
        if let notes, notes.count > 500 {
            throw PlanningServiceError.invalidField("notes must be 0-500 characters")
        }
    }

    /// S2.4: passthrough so UI code only ever depends on
    /// `PlanningService`, never `PlanningRepository` directly (same
    /// "reuse PlanningService" boundary every other UI-facing method
    /// here already follows).
    public func fetchPlannedActivities(forWeekPlan weekPlanId: WeekPlanId) throws -> [PlannedActivity] {
        try repository.fetchPlannedActivities(forWeekPlan: weekPlanId)
    }

    /// S2.4: deletes a `PlannedActivity`, only while its `WeekPlan` is
    /// still draft — the same two existence/ownership guards
    /// `editPlannedActivity` already uses, plus the explicitly-requested
    /// draft-only restriction.
    ///
    /// A2: `deletedBy` attributes the resulting tombstone — required,
    /// not defaulted, matching how `WeekPlan.commit(committedBy:)`
    /// already requires an explicit actor rather than fabricating one.
    public func deletePlannedActivity(
        _ plannedActivityId: PlannedActivityId,
        expectedWeekPlanId weekPlanId: WeekPlanId,
        deletedBy: ActorId
    ) throws {
        guard let weekPlan = try repository.fetchWeekPlan(byId: weekPlanId) else {
            throw PlanningServiceError.weekPlanNotFound
        }
        guard weekPlan.status == .draft else {
            throw PlanningServiceError.weekPlanNotDraft
        }
        guard let activity = try repository.fetchPlannedActivity(byId: plannedActivityId) else {
            throw PlanningServiceError.plannedActivityNotFound
        }
        guard activity.weekPlanId == weekPlanId.rawValue else {
            throw PlanningServiceError.plannedActivityDoesNotBelongToWeekPlan
        }
        try repository.deletePlannedActivity(activity, deletedBy: deletedBy)
    }
}
