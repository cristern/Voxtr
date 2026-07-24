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

    public func fetchPlannedActivities(forWeekPlan weekPlanId: WeekPlanId) throws -> [PlannedActivity] {
        let rawWeekPlanId = weekPlanId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<PlannedActivity>())
        return all.filter { $0.weekPlanId == rawWeekPlanId }
    }
}
