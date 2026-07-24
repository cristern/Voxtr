import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// S2.0 scope only: insert and fetch `WeekPlan` and `PlannedActivity`.
/// No commit-week behavior, no UI, no CloudKit, no calculations, no
/// `PlanningDecision` handling — those are separate, later stories.
///
/// No `#Predicate` (established project lesson — it caused a real Swift
/// Testing crash on this SwiftData/Xcode combination): every fetch here
/// fetches then filters in plain Swift instead.
///
/// No cross-domain SwiftData relationships — `athleteId` is a plain
/// typed-ID-backed `UUID` field, the same pattern every other repository
/// in this project already uses, not a `@Relationship`.
@MainActor
public final class PlanningRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Inserts a new `WeekPlan` draft. `status` is left at its default
    /// (`.draft`, per `WeekPlan`'s own initializer) — S2.0 doesn't
    /// implement commit-week, so nothing here can move a plan out of
    /// draft.
    public func insertWeekPlan(
        athleteId: AthleteId,
        weekStart: LocalDate,
        focusNote: String? = nil
    ) throws -> WeekPlan {
        let weekPlan = WeekPlan(athleteId: athleteId, weekStart: weekStart, focusNote: focusNote)
        modelContext.insert(weekPlan)
        try modelContext.save()
        return weekPlan
    }

    /// Inserts a `PlannedActivity` belonging to the given `WeekPlan`.
    /// Does not verify the `WeekPlan` exists — S2.0 is persistence
    /// infrastructure only; enforcing that relationship is a later
    /// story's concern, not invented here.
    public func insertPlannedActivity(
        weekPlanId: WeekPlanId,
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
        let activity = PlannedActivity(
            weekPlanId: weekPlanId,
            athleteId: athleteId,
            sportId: sportId,
            categoryIds: categoryIds,
            activityType: activityType,
            title: title,
            localDate: localDate,
            startLocalTime: startLocalTime,
            timeZoneId: timeZoneId,
            plannedDurationMinutes: plannedDurationMinutes,
            plannedIntensity: plannedIntensity,
            notes: notes
        )
        modelContext.insert(activity)
        try modelContext.save()
        return activity
    }

    /// Fetch `WeekPlan` by athlete and week. Sprint 1/2's model has at
    /// most one `WeekPlan` per athlete per `weekStart`, but that's not
    /// enforced here (no uniqueness constraint on the pair) — this
    /// returns the first match, since inventing an enforcement rule
    /// isn't part of S2.0's scope.
    public func fetchWeekPlan(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeekPlan? {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<WeekPlan>())
        return all.first { $0.athleteId == rawAthleteId && $0.weekStart == weekStart }
    }

    /// Fetch `WeekPlan` by its own ID. S2.2: used to check a `WeekPlan`
    /// actually exists before an edit is allowed to proceed against it.
    public func fetchWeekPlan(byId weekPlanId: WeekPlanId) throws -> WeekPlan? {
        let rawId = weekPlanId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<WeekPlan>())
        return all.first { $0.id == rawId }
    }

    /// S2.2: ordered deterministically by `localDate`, then `id` as a
    /// stable tiebreaker for same-day activities — not a business rule,
    /// just making repeated fetches return the same order every time.
    public func fetchPlannedActivities(forWeekPlan weekPlanId: WeekPlanId) throws -> [PlannedActivity] {
        let rawWeekPlanId = weekPlanId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<PlannedActivity>())
        return all
            .filter { $0.weekPlanId == rawWeekPlanId }
            .sorted { lhs, rhs in
                if lhs.localDate != rhs.localDate {
                    return lhs.localDate < rhs.localDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// S2.2: fetch a single `PlannedActivity` by ID, used by
    /// `PlanningService`'s edit path.
    public func fetchPlannedActivity(byId plannedActivityId: PlannedActivityId) throws -> PlannedActivity? {
        let rawId = plannedActivityId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<PlannedActivity>())
        return all.first { $0.id == rawId }
    }

    /// S2.2: persists in-place mutations to an already-fetched,
    /// already-managed instance (used by `PlanningService.
    /// editPlannedActivity`, which doesn't go through `insert...`).
    public func save() throws {
        try modelContext.save()
    }

    /// S2.4: deletes an already-fetched `PlannedActivity`. Whether this
    /// is allowed (e.g. only while the `WeekPlan` is still draft) is
    /// `PlanningService`'s decision, not this repository's — this is
    /// pure persistence, same as every other method here.
    public func deletePlannedActivity(_ activity: PlannedActivity) throws {
        modelContext.delete(activity)
        try modelContext.save()
    }
}
