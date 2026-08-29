import Foundation
import SwiftData
import VoxtrCoreContracts

// MARK: - ActivityReminder

/// Notifications V1 Activity Reminder Foundation.
///
/// Review of the prior scaffold (`NotificationRule`/`ScheduledReminder`/
/// `DeliveryRecord`, v1.3 Section 13): none of the three was ever
/// registered in `AppSchema.modelTypes` (confirmed by the Notifications
/// V1 Repository Audit), so nothing in the running app has ever
/// persisted or read one — they were schema-only scaffolding, not an
/// approved, activated product decision. Their shapes also do not fit
/// the approved V1 concept: `NotificationRule` models a general,
/// recurring time-of-day rule (`ruleType`, `localTime`) with no field
/// tying it to one concrete `PlannedActivity`; `ScheduledReminder`
/// persists rendering content (`titleKey`/`bodyKey`/`bodyArguments`) and
/// delivery `state`, which the approved V1 contract explicitly says not
/// to persist (content is resolved fresh from canonical Planning truth
/// at scheduling time; delivery history is explicitly out of scope);
/// `DeliveryRecord` IS the delivery-history model V1 is told not to add.
/// Reusing any of the three would have meant either misusing their
/// shape or immediately stripping most of their fields — replacing them
/// outright with the smallest model that matches the approved concept
/// is the cleaner, more maintainable outcome, and avoids leaving three
/// misleading, never-activated parallel models sitting beside the real
/// one. `ReminderDeliveryState` (their shared backing enum, declared in
/// `VoxtrCoreContracts/SharedEnums.swift`) is removed alongside them —
/// nothing else in this codebase ever referenced it.
///
/// `ActivityReminder` is the ONE persistent concept this slice needs:
/// "the user wants a reminder for this specific planned activity, with
/// this lead time." It references `PlannedActivity` by stable typed ID
/// only — Planning remains the sole owner of the activity's own title,
/// date, start time, sport, and activity type; none of that is copied
/// here (see this task's own explicit "do not persist copied Planning
/// truth" instruction). The row's mere existence for a given
/// `plannedActivityId` IS the "reminder is active" state — there is no
/// separate enabled/disabled flag, because this slice has no lifecycle
/// that needs one: creating a reminder inserts this row: the activity
/// being deleted, or its linked training being logged early, removes it
/// (see `ActivityReminderService` / `NotificationsPlanningCoordinationService`
/// in `VoxtrAppShell`) rather than merely flagging it inactive. No
/// delivery-history model exists alongside it, per the approved
/// contract.
@Model
public final class ActivityReminder {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var plannedActivityId: UUID
    public var leadTimeMinutes: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: ActivityReminderId = ActivityReminderId(),
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        precondition((0...10080).contains(leadTimeMinutes), "leadTimeMinutes must be 0-10080 (0 minutes to 7 days)")
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.plannedActivityId = plannedActivityId.rawValue
        self.leadTimeMinutes = leadTimeMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var activityReminderId: ActivityReminderId { ActivityReminderId(rawValue: id) }
}
