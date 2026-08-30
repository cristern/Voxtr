import Foundation
import VoxtrCoreContracts

/// Notifications V1 Activity Reminder Foundation: the domain-level
/// service Notifications itself owns. Deliberately knows nothing about
/// `PlannedActivity` — no import of `VoxtrPlanningDomain` anywhere in
/// this package (see `Package.swift`'s own dependency rule: no
/// `*Domain` target may depend on another). Every method here takes an
/// already-resolved `fireDate`/`ActivityReminderContent` from its
/// caller; resolving those from canonical Planning truth is
/// `NotificationsPlanningCoordinationService`'s job, in `VoxtrAppShell`
/// — the one place cross-domain composition is legitimate, mirroring
/// `TrainingPlanningCoordinationService`'s own existing placement
/// rationale for the equivalent Planning+Training concern.
///
/// Activity Reminder What/When: generalized from "at most one active
/// reminder per activity" to "zero, one, or many independent
/// reminders" — see `ActivityReminder`/`ActivityReminderRepository`'s
/// own updated doc comments. Every method below now addresses either
/// ONE specific reminder (by its own stable `ActivityReminderId`) or
/// EVERY reminder for one `PlannedActivity`, never an implicit
/// "the singular one."
@MainActor
public final class ActivityReminderService {
    public enum ActivityReminderServiceError: Error, Sendable, Equatable {
        /// `updateReminder`/`cancelReminder` addressed an
        /// `ActivityReminderId` that no longer exists (already removed
        /// by a concurrent lifecycle reaction, or never existed).
        case reminderNotFound
    }

    private let repository: ActivityReminderRepository
    private let scheduler: ActivityReminderScheduling

    public init(repository: ActivityReminderRepository, scheduler: ActivityReminderScheduling) {
        self.repository = repository
        self.scheduler = scheduler
    }

    /// Every currently-active reminder for one `PlannedActivity` — zero,
    /// one, or many. Used both to prefill the create/edit UI and by
    /// every lifecycle reconciliation path below.
    public func fetchReminders(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> [ActivityReminder] {
        try repository.fetchAll(forPlannedActivity: plannedActivityId)
    }

    /// Notifications V1 Activity Reminder UI slice: thin passthroughs to
    /// the scheduling boundary's own permission surface — kept here (not
    /// skipped in favor of callers reaching the scheduler directly) so
    /// `NotificationsPlanningCoordinationService` only ever depends on
    /// `ActivityReminderService`, never on `ActivityReminderScheduling`
    /// itself, matching this file's own "Notifications owns reminder
    /// intent and delivery infrastructure" boundary.
    public func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        scheduler.authorizationStatus(completion: completion)
    }

    public func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        scheduler.requestAuthorization(completion: completion)
    }

    /// Creates and schedules a NEW, independent reminder for
    /// `plannedActivityId`. Activity Reminder What/When: never replaces
    /// or removes any existing reminder for the same activity — a
    /// concrete `PlannedActivity` may have zero, one, or multiple
    /// reminders, each with its own text/lead time/schedule. Changing an
    /// ALREADY-EXISTING reminder in place is `updateReminder(_:...)`
    /// below, reached by that reminder's own stable id, never by calling
    /// this again.
    @discardableResult
    public func createReminder(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        reminderText: String? = nil,
        fireDate: Date,
        content: ActivityReminderContent
    ) throws -> ActivityReminder {
        let reminder = try repository.insert(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            leadTimeMinutes: leadTimeMinutes,
            reminderText: reminderText
        )
        scheduler.scheduleReminder(id: reminder.activityReminderId, fireDate: fireDate, content: content)
        return reminder
    }

    /// Updates the SAME already-existing reminder — addressed by its own
    /// stable `ActivityReminderId`, never re-inserted — with a new lead
    /// time/text, and reschedules its pending notification under that
    /// SAME request identity. The user-initiated "edit this reminder"
    /// path; never affects any sibling reminder for the same activity.
    @discardableResult
    public func updateReminder(
        _ activityReminderId: ActivityReminderId,
        leadTimeMinutes: Int,
        reminderText: String? = nil,
        fireDate: Date,
        content: ActivityReminderContent
    ) throws -> ActivityReminder {
        guard let reminder = try repository.fetch(byId: activityReminderId) else {
            throw ActivityReminderServiceError.reminderNotFound
        }
        let updated = try repository.update(reminder, leadTimeMinutes: leadTimeMinutes, reminderText: reminderText)
        scheduler.scheduleReminder(id: updated.activityReminderId, fireDate: fireDate, content: content)
        return updated
    }

    /// Reschedules an ALREADY-EXISTING reminder's pending notification
    /// at a recomputed `fireDate`, its own lead time/text unchanged —
    /// the "the linked PlannedActivity moved" lifecycle path
    /// (`NotificationsPlanningCoordinationService.handlePlannedActivityChanged`),
    /// never the initial-create or user-edited-lead-time path (those go
    /// through `createReminder`/`updateReminder` above, which also
    /// persist the change). Caller already holds the reminder (from
    /// `fetchReminders(forPlannedActivity:)`); nothing here re-fetches.
    public func rescheduleReminder(_ reminder: ActivityReminder, fireDate: Date, content: ActivityReminderContent) {
        scheduler.scheduleReminder(id: reminder.activityReminderId, fireDate: fireDate, content: content)
    }

    /// Cancels the pending notification (if any) and removes exactly ONE
    /// reminder's intent row, addressed by its own stable id. Never
    /// affects any sibling reminder for the same `PlannedActivity`. A
    /// safe no-op if no reminder with this id exists.
    public func cancelReminder(_ activityReminderId: ActivityReminderId) throws {
        guard let reminder = try repository.fetch(byId: activityReminderId) else { return }
        scheduler.cancelReminder(id: activityReminderId)
        try repository.delete(reminder)
    }

    /// Cancels the pending notification and removes EVERY reminder for
    /// one `PlannedActivity` — the activity-deleted / activity-logged /
    /// start-time-removed lifecycle paths, which must reconcile ALL
    /// reminders belonging to that activity, never only the first one
    /// created. A safe no-op if none are active.
    public func cancelAllReminders(forPlannedActivity plannedActivityId: PlannedActivityId) throws {
        let reminders = try repository.fetchAll(forPlannedActivity: plannedActivityId)
        for reminder in reminders {
            scheduler.cancelReminder(id: reminder.activityReminderId)
            try repository.delete(reminder)
        }
    }

    /// Recent-text suggestions for the free-text "what" field — see
    /// `ActivityReminderRepository.fetchRecentDistinctReminderTexts(forAthlete:limit:)`
    /// for the exact recency/privacy-scope/dedup rules; this is a thin
    /// passthrough.
    public func fetchRecentReminderTexts(forAthlete athleteId: AthleteId, limit: Int = 5) throws -> [String] {
        try repository.fetchRecentDistinctReminderTexts(forAthlete: athleteId, limit: limit)
    }
}
