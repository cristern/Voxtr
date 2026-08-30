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
///
/// Activity Reminder What/When round: `reminderText` is the ONE new
/// field this round adds — the user-authored "what" ("Pack hockey bag",
/// "Eat") a reminder is for, distinct from Planning's own activity
/// title. Optional (`String?`), not because a NEW reminder may
/// meaningfully have no text (the create/edit UI always collects one),
/// but purely so a pre-existing PR #37 reminder row — created before
/// this field existed, with no user-authored text to migrate from —
/// gets an honest `nil` rather than a fabricated value; see
/// `AppSchemaVersioning.swift`'s V5→V6 migration stage for the exact
/// mechanics, and `NotificationsPlanningCoordinationService.buildContent(for:reminderText:)`
/// for how a `nil` text degrades to this reminder's pre-existing
/// generic notification wording rather than showing an empty title.
///
/// Activity Reminder What/When round: the prior "at most one active
/// reminder per PlannedActivity" assumption is REMOVED — nothing in
/// this type itself ever enforced that (no `@Attribute(.unique)` on
/// `plannedActivityId`), so no schema change is needed to allow
/// multiple rows per activity; only the repository/service-layer
/// "fetch (singular) / replace on create" logic built on top of it
/// needed to change (see `ActivityReminderRepository`/
/// `ActivityReminderService`'s own updated doc comments).
@Model
public final class ActivityReminder {
    @Attribute(.unique) public var id: UUID
    public var athleteId: UUID
    public var plannedActivityId: UUID
    public var leadTimeMinutes: Int
    public var reminderText: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: ActivityReminderId = ActivityReminderId(),
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        reminderText: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        // PR #37 follow-up: the prior `0...10080` (7-day) ceiling was an
        // unapproved product limit — the approved contract only requires
        // "arbitrary lead time before the activity" for Custom, with no
        // maximum. This precondition now enforces only what persistence
        // and downstream fire-date arithmetic genuinely need — a
        // non-negative value — never a product-level cap. An
        // extreme value simply resolves to a fire date far in the past,
        // which `NotificationsPlanningCoordinationService.createReminder`'s
        // own past-fire-date guard already rejects calmly; nothing here
        // needs a second, redundant ceiling to stay safe.
        precondition(leadTimeMinutes >= 0, "leadTimeMinutes must be non-negative")
        self.id = id.rawValue
        self.athleteId = athleteId.rawValue
        self.plannedActivityId = plannedActivityId.rawValue
        self.leadTimeMinutes = leadTimeMinutes
        self.reminderText = reminderText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public var activityReminderId: ActivityReminderId { ActivityReminderId(rawValue: id) }
}
