import Foundation
import SwiftData
import VoxtrCoreContracts

/// Notifications V1 Activity Reminder Foundation: insert/fetch/delete
/// `ActivityReminder` only — pure persistence, matching the same
/// "no #Predicate, fetch-then-filter" and "no cross-domain SwiftData
/// relationships" conventions `PlanningRepository`/`TrainingRepository`
/// already established (`plannedActivityId`/`athleteId` are plain typed-
/// ID-backed `UUID` fields here too, never a `@Relationship`). Whether a
/// reminder SHOULD be created/rescheduled/cancelled for a given
/// `PlannedActivity` is `ActivityReminderService`'s and
/// `NotificationsPlanningCoordinationService`'s decision, not this
/// repository's.
@MainActor
public final class ActivityReminderRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Cross-domain coordinators may only form a single SwiftData unit
    /// of work when every participating repository owns this exact
    /// context instance — same contract `TrainingRepository.uses(modelContext:)`
    /// already establishes.
    public func uses(modelContext: ModelContext) -> Bool {
        self.modelContext === modelContext
    }

    /// Inserts a new `ActivityReminder`. Does not verify the referenced
    /// `PlannedActivity` exists — same "persistence infrastructure only"
    /// boundary `PlanningRepository.insertPlannedActivity` already
    /// established for `WeekPlan`; the caller (`ActivityReminderService`,
    /// via `NotificationsPlanningCoordinationService`) is responsible for
    /// resolving the canonical activity first.
    public func insert(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int
    ) throws -> ActivityReminder {
        let reminder = ActivityReminder(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            leadTimeMinutes: leadTimeMinutes
        )
        modelContext.insert(reminder)
        try modelContext.save()
        return reminder
    }

    /// At most one active reminder per `PlannedActivity` — the natural
    /// reading of the approved contract ("an optional reminder
    /// associated with one concrete canonical PlannedActivity," singular).
    /// Returns the first match if more than one were ever somehow
    /// created; nothing in this repository enforces uniqueness at the
    /// storage layer (no `@Attribute(.unique)` on `plannedActivityId`,
    /// same as how `PlanningRepository.fetchWeekPlan(forAthlete:weekStart:)`
    /// documents its own equivalent one-per-key assumption without a
    /// storage-level constraint).
    public func fetch(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> ActivityReminder? {
        let rawId = plannedActivityId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<ActivityReminder>())
        return all.first { $0.plannedActivityId == rawId }
    }

    public func fetch(byId activityReminderId: ActivityReminderId) throws -> ActivityReminder? {
        let rawId = activityReminderId.rawValue
        return try modelContext.fetch(FetchDescriptor<ActivityReminder>()).first { $0.id == rawId }
    }

    /// Removes an already-fetched `ActivityReminder`. The row's mere
    /// absence for a given `plannedActivityId` IS "no active reminder" —
    /// see `ActivityReminder`'s own doc comment for why no separate
    /// enabled/disabled flag exists.
    public func delete(_ reminder: ActivityReminder) throws {
        modelContext.delete(reminder)
        try modelContext.save()
    }
}
