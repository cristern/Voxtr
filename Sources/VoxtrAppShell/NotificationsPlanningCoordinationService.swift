import Foundation
import VoxtrCore
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrNotificationsDomain

/// Notifications V1 Activity Reminder Foundation: the one place
/// `PlanningService` and `ActivityReminderService` are used together —
/// same placement rationale `TrainingPlanningCoordinationService`
/// already established for its own Planning+Training concern. Neither
/// `VoxtrPlanningDomain`/`VoxtrTrainingDomain` nor
/// `VoxtrNotificationsDomain` may depend on each other (no `*Domain`
/// target depends on another), so this cross-domain reaction can only
/// live here, in `VoxtrAppShell`.
///
/// Owns the EventBus subscriptions for the three business events this
/// V1 lifecycle needs (`PlannedActivityChanged`, `PlannedActivityDeleted`,
/// `ActivityLogged`) and the actual "recompute fire instant from current
/// canonical Planning truth" logic. `handle...` methods below are `internal`
/// (not `private`) precisely so tests can call them directly with a
/// constructed event and assert the resulting scheduler/repository state
/// deterministically, independent of the live, actor-hop-based EventBus
/// delivery `subscribeToEvents(_:)` wires in production — see that
/// method's own doc comment for why the live path itself is not
/// synchronously deterministic.
@MainActor
public final class NotificationsPlanningCoordinationService {
    /// Thrown by `createReminder` — the one entry point a later UI task
    /// will call. Not exercised by anything else in this PR (no UI exists
    /// yet), but the foundation must expose it.
    public enum CoordinationError: Error, Sendable, Equatable {
        case plannedActivityNotFound
        case plannedActivityBelongsToDifferentAthlete
        /// A reminder needs a concrete start time to compute "N minutes
        /// before it starts" — `PlannedActivity.startLocalTime` is
        /// optional, and an activity with no start time has nothing to
        /// count down from.
        case plannedActivityHasNoStartTime
    }

    private let activityReminderService: ActivityReminderService
    private let planningService: PlanningService

    public init(activityReminderService: ActivityReminderService, planningService: PlanningService) {
        self.activityReminderService = activityReminderService
        self.planningService = planningService
    }

    /// Registers this service's reaction to every business event this
    /// V1 lifecycle needs. Deliberately `async`, called once from
    /// `CompositionRoot.build()` (already `async`) — not from either
    /// domain module's own `configure`, since neither domain package may
    /// see the other (see this type's own doc comment).
    ///
    /// `EventBus.subscribe`'s handler type is a plain, synchronous
    /// `@Sendable (Event) -> Void` closure — it cannot itself `await` a
    /// hop onto `@MainActor` (where this service and its SwiftData-backed
    /// dependencies live), so each handler wraps its actual work in
    /// `Task { @MainActor in ... }`. This is NOT redesigning `EventBus`
    /// (its actor/closure shape is unchanged); it is the same "actor-hop
    /// via `Task`" pattern this project's own `EventBusTests.swift`
    /// already uses for its subscribers. The practical consequence: live,
    /// production event delivery through this path is asynchronous
    /// relative to the publish call, same as `PlanningService`/
    /// `TrainingService`'s own fire-and-forget publish — see those types'
    /// doc comments. Every `handle...` method's actual DECISION logic is
    /// still fully deterministic and directly unit-tested by calling it
    /// with a constructed event, bypassing this live async hop entirely.
    public func subscribeToEvents(_ eventBus: EventBus) async {
        await eventBus.subscribe(to: PlannedActivityChanged.self) { [weak self] event in
            Task { @MainActor in self?.handlePlannedActivityChanged(event) }
        }
        await eventBus.subscribe(to: PlannedActivityDeleted.self) { [weak self] event in
            Task { @MainActor in self?.handlePlannedActivityDeleted(event) }
        }
        await eventBus.subscribe(to: ActivityLogged.self) { [weak self] event in
            Task { @MainActor in self?.handleActivityLogged(event) }
        }
    }

    // MARK: - The one create entry point (foundation only — no UI calls this in this PR)

    /// Creates and schedules a reminder for `plannedActivityId`, owned by
    /// `athleteId`. Verifies the activity actually belongs to that
    /// athlete — privacy/isolation boundary, not merely a convenience
    /// check — before ever touching Notifications.
    @discardableResult
    public func createReminder(
        athleteId: AthleteId,
        plannedActivityId: PlannedActivityId,
        leadTimeMinutes: Int
    ) throws -> ActivityReminder {
        guard let activity = try planningService.fetchPlannedActivity(byId: plannedActivityId) else {
            throw CoordinationError.plannedActivityNotFound
        }
        guard activity.athleteId == athleteId.rawValue else {
            throw CoordinationError.plannedActivityBelongsToDifferentAthlete
        }
        guard let startLocalTime = activity.startLocalTime else {
            throw CoordinationError.plannedActivityHasNoStartTime
        }
        let fireInstant = try activity.localDate.absoluteDate(at: startLocalTime, in: activity.timeZoneId)
        let fireDate = fireInstant.addingTimeInterval(-Double(leadTimeMinutes) * 60)
        return try activityReminderService.createReminder(
            athleteId: athleteId,
            plannedActivityId: plannedActivityId,
            leadTimeMinutes: leadTimeMinutes,
            fireDate: fireDate,
            content: Self.buildContent(for: activity)
        )
    }

    // MARK: - Event reactions (internal: directly unit-testable)

    /// Planning date/time/timezone changes: preserves reminder intent,
    /// recomputes the fire instant from CURRENT canonical Planning truth
    /// (never trusting anything cached), and replaces the pending
    /// notification. A no-op if no reminder is active for this activity,
    /// or if the activity can no longer be found (deleted between the
    /// mutation and this handler running).
    func handlePlannedActivityChanged(_ event: PlannedActivityChanged) {
        guard let activity = try? planningService.fetchPlannedActivity(byId: event.plannedActivityId) else { return }
        guard (try? activityReminderService.fetchReminder(forPlannedActivity: event.plannedActivityId)) != nil else { return }
        reschedule(for: activity)
    }

    /// Planned activity deleted: cancels the pending notification and
    /// removes the reminder intent row. A no-op if no reminder was active.
    func handlePlannedActivityDeleted(_ event: PlannedActivityDeleted) {
        try? activityReminderService.cancelReminder(forPlannedActivity: event.plannedActivityId)
    }

    /// Linked activity logged/completed before the reminder fires:
    /// cancels any still-pending reminder. A no-op if the log isn't
    /// linked to a `PlannedActivity`, or no reminder was active for it.
    func handleActivityLogged(_ event: ActivityLogged) {
        guard let plannedActivityId = event.plannedActivityId else { return }
        try? activityReminderService.cancelReminder(forPlannedActivity: plannedActivityId)
    }

    // MARK: - Shared recompute path

    private func reschedule(for activity: PlannedActivity) {
        guard let startLocalTime = activity.startLocalTime else {
            // The activity no longer has a concrete start time to count
            // down from — there is nothing left to schedule against, so
            // the honest outcome is cancelling, not leaving a stale
            // fire instant in place.
            try? activityReminderService.cancelReminder(forPlannedActivity: activity.plannedActivityId)
            return
        }
        guard let existing = try? activityReminderService.fetchReminder(forPlannedActivity: activity.plannedActivityId) else { return }
        guard let fireInstant = try? activity.localDate.absoluteDate(at: startLocalTime, in: activity.timeZoneId) else { return }
        let fireDate = fireInstant.addingTimeInterval(-Double(existing.leadTimeMinutes) * 60)
        try? activityReminderService.rescheduleReminder(
            forPlannedActivity: activity.plannedActivityId,
            fireDate: fireDate,
            content: Self.buildContent(for: activity)
        )
    }

    /// Minimum factual content only — no motivational copy, no
    /// Reflection/private data, no coach-like language. Resolved fresh
    /// from the canonical activity every time this is called, never
    /// cached. Deliberately isolated in this one small function so a
    /// later UI/product task can refine wording without touching any
    /// lifecycle/scheduling code above.
    private static func buildContent(for activity: PlannedActivity) -> ActivityReminderContent {
        ActivityReminderContent(
            title: activity.title ?? "Planned activity",
            body: "Starting soon"
        )
    }
}
