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
    ///
    /// `externalSourceId`/`externalSourceType` added for Recurring
    /// Planned Activities: both default to `nil`, so every existing
    /// call site is unaffected. When a caller supplies them (see
    /// `PlanningService.acceptSuggestion`), they're the mechanism that
    /// prevents the same recurring occurrence from being accepted
    /// twice — see `RecurringPlannedActivity`'s own doc comment.
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
        externalSourceId: String? = nil,
        externalSourceType: String? = nil,
        notes: String? = nil,
        location: String? = nil
    ) throws -> PlannedActivity {
        try insertPlannedActivity(
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
            externalSourceId: externalSourceId,
            externalSourceType: externalSourceType,
            notes: notes,
            location: location,
            saveOverride: nil
        )
    }

    /// Test-only seam, added for Recurring Planned Activities'
    /// `PlanningService.acceptSuggestion` — mirrors
    /// `insertRecurringPlannedActivity`'s own `saveOverride` pattern
    /// exactly, and the same pattern already established elsewhere in
    /// this project (e.g. `VoxtrParentDomain.ParentWorkspaceRepository`).
    /// Not `public`, reachable only via `@testable import`. Every
    /// production call site goes through the public overload above,
    /// which always passes `nil`.
    func insertPlannedActivity(
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
        externalSourceId: String? = nil,
        externalSourceType: String? = nil,
        notes: String? = nil,
        location: String? = nil,
        saveOverride: (() throws -> Void)?
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
            externalSourceId: externalSourceId,
            externalSourceType: externalSourceType,
            notes: notes,
            location: location
        )
        modelContext.insert(activity)
        if let saveOverride {
            try saveOverride()
        } else {
            try modelContext.save()
        }
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
    ///
    /// A2: also creates and persists a `PlannedActivityDeletionTombstone`
    /// recording the deletion, using `DeletionTombstone.now(...)`'s
    /// existing documented 30-day retention rule unchanged. Both the
    /// delete and the tombstone insert happen before the same
    /// `save()` — one atomic write, not two.
    public func deletePlannedActivity(_ activity: PlannedActivity, deletedBy: ActorId) throws {
        let tombstoneValue = DeletionTombstone.now(
            entityId: activity.id,
            entityType: "PlannedActivity",
            deletedBy: deletedBy
        )
        let tombstone = PlannedActivityDeletionTombstone(from: tombstoneValue)
        modelContext.insert(tombstone)
        modelContext.delete(activity)
        try modelContext.save()
    }

    /// Recurring Planned Activities: finds a `PlannedActivity` already
    /// stamped with the given `externalSourceId` within a specific
    /// `WeekPlan` — the duplicate-prevention check
    /// `PlanningService.acceptSuggestion` uses. Reuses
    /// `fetchPlannedActivities(forWeekPlan:)` rather than a separate
    /// fetch — no duplicated fetch/filter logic.
    public func fetchPlannedActivity(forExternalSourceId externalSourceId: String, weekPlanId: WeekPlanId) throws -> PlannedActivity? {
        try fetchPlannedActivities(forWeekPlan: weekPlanId).first { $0.externalSourceId == externalSourceId }
    }

    // MARK: - RecurringPlannedActivity

    /// Inserts a new `RecurringPlannedActivity` definition.
    public func insertRecurringPlannedActivity(
        athleteId: AthleteId,
        title: String,
        activityType: ActivityType,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        weekdays: [Weekday],
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        timeZoneId: TimeZoneId,
        location: String? = nil,
        effectiveStartDate: LocalDate,
        effectiveEndDate: LocalDate
    ) throws -> RecurringPlannedActivity {
        try insertRecurringPlannedActivity(
            athleteId: athleteId,
            title: title,
            activityType: activityType,
            sportId: sportId,
            categoryIds: categoryIds,
            weekdays: weekdays,
            startLocalTime: startLocalTime,
            plannedDurationMinutes: plannedDurationMinutes,
            timeZoneId: timeZoneId,
            location: location,
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate,
            saveOverride: nil
        )
    }

    /// Test-only seam, mirroring the `saveOverride` pattern already
    /// established elsewhere in this project (e.g.
    /// `VoxtrParentDomain.ParentWorkspaceRepository`) for deterministic
    /// save-failure testing — not `public`, reachable only via
    /// `@testable import`. Every production call site goes through the
    /// public overload above, which always passes `nil`.
    func insertRecurringPlannedActivity(
        athleteId: AthleteId,
        title: String,
        activityType: ActivityType,
        sportId: SportId? = nil,
        categoryIds: [ActivityCategoryId] = [],
        weekdays: [Weekday],
        startLocalTime: LocalTime? = nil,
        plannedDurationMinutes: Int? = nil,
        timeZoneId: TimeZoneId,
        location: String? = nil,
        effectiveStartDate: LocalDate,
        effectiveEndDate: LocalDate,
        saveOverride: (() throws -> Void)?
    ) throws -> RecurringPlannedActivity {
        let recurringActivity = RecurringPlannedActivity(
            athleteId: athleteId,
            title: title,
            activityType: activityType,
            sportId: sportId,
            categoryIds: categoryIds,
            weekdays: weekdays,
            startLocalTime: startLocalTime,
            plannedDurationMinutes: plannedDurationMinutes,
            timeZoneId: timeZoneId,
            location: location,
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate
        )
        modelContext.insert(recurringActivity)
        if let saveOverride {
            try saveOverride()
        } else {
            try modelContext.save()
        }
        return recurringActivity
    }

    /// Fetch a single `RecurringPlannedActivity` by ID, used by
    /// `PlanningService`'s edit/enable/disable paths.
    public func fetchRecurringPlannedActivity(byId recurringPlannedActivityId: RecurringPlannedActivityId) throws -> RecurringPlannedActivity? {
        let rawId = recurringPlannedActivityId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<RecurringPlannedActivity>())
        return all.first { $0.id == rawId }
    }

    /// Every recurring definition (enabled or disabled) belonging to an
    /// athlete — the management flow's own listing, and the source
    /// `PlanningService.deriveSuggestions` filters down to enabled-only
    /// occurrences within a specific week. Ordered deterministically by
    /// weekday then title, matching this repository's existing
    /// convention of never leaving fetch order to fetch-call chance.
    public func fetchRecurringPlannedActivities(forAthlete athleteId: AthleteId) throws -> [RecurringPlannedActivity] {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<RecurringPlannedActivity>())
        return all
            .filter { $0.athleteId == rawAthleteId }
            .sorted { lhs, rhs in
                let lhsFirst = lhs.weekdays.min()
                let rhsFirst = rhs.weekdays.min()
                if lhsFirst != rhsFirst {
                    // nil (no weekdays — precondition prevents this in
                    // practice, but Optional comparison needs a defined
                    // order) sorts last.
                    switch (lhsFirst, rhsFirst) {
                    case (nil, nil): break
                    case (nil, _): return false
                    case (_, nil): return true
                    case (let l?, let r?): return l < r
                    }
                }
                return lhs.title < rhs.title
            }
    }

    /// Enables or disables an already-fetched `RecurringPlannedActivity`
    /// — a named domain transition, not a generic field-update API.
    public func setRecurringPlannedActivityEnabled(_ recurringActivity: RecurringPlannedActivity, isEnabled: Bool) throws {
        recurringActivity.isEnabled = isEnabled
        recurringActivity.updatedAt = .now
        try modelContext.save()
    }
}
