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
@MainActor
public final class ActivityReminderService {
    private let repository: ActivityReminderRepository
    private let scheduler: ActivityReminderScheduling

    public init(repository: ActivityReminderRepository, scheduler: ActivityReminderScheduling) {
        self.repository = repository
        self.scheduler = scheduler
    }

    public func fetchReminder(forPlannedActivity plannedActivityId: PlannedActivityId) throws -> ActivityReminder? {
        try repository.fetch(forPlannedActivity: plannedActivityId)
    }

    /// Creates a new reminder intent for `plannedActivityId` and
    /// schedules its notification at `fireDate`. Replaces — rather than
    /// duplicating alongside — any reminder already active for this
    /// activity, matching `ActivityReminder`'s own "at most one active
    /// reminder per PlannedActivity" contract.
    @discardableResult
    public func createReminder(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int,
        fireDate: Date,
        content: ActivityReminderContent
    ) throws -> ActivityReminder {
        if let existing = try repository.fetch(forPlannedActivity: plannedActivityId) {
            scheduler.cancelReminder(id: existing.activityReminderId)
            try repository.delete(existing)
        }
        let reminder = try repository.insert(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            leadTimeMinutes: leadTimeMinutes
        )
        scheduler.scheduleReminder(id: reminder.activityReminderId, fireDate: fireDate, content: content)
        return reminder
    }

    /// Reschedules the ALREADY-EXISTING reminder for `plannedActivityId`,
    /// if one is active — a no-op if none is. Never creates one: this is
    /// the "planned activity changed, preserve reminder intent" path
    /// (Planning date/time/timezone changes), never the initial-create
    /// path — see `createReminder` for that. `leadTimeMinutes` is
    /// intentionally not a parameter here: rescheduling recomputes the
    /// fire instant for the SAME already-persisted lead time, it does not
    /// let a Planning-side mutation silently change what the user asked
    /// for.
    public func rescheduleReminder(
        forPlannedActivity plannedActivityId: PlannedActivityId,
        fireDate: Date,
        content: ActivityReminderContent
    ) throws {
        guard let reminder = try repository.fetch(forPlannedActivity: plannedActivityId) else { return }
        scheduler.scheduleReminder(id: reminder.activityReminderId, fireDate: fireDate, content: content)
    }

    /// Cancels the pending notification (if any) and removes the
    /// reminder intent row — used both when the source `PlannedActivity`
    /// is deleted and when its linked training is logged before the
    /// reminder fires. A no-op if no reminder is active for this
    /// activity.
    public func cancelReminder(forPlannedActivity plannedActivityId: PlannedActivityId) throws {
        guard let reminder = try repository.fetch(forPlannedActivity: plannedActivityId) else { return }
        scheduler.cancelReminder(id: reminder.activityReminderId)
        try repository.delete(reminder)
    }
}
