import Foundation
import VoxtrCoreContracts

/// Notifications V1 Activity Reminder Foundation: the minimum factual
/// content a scheduled local notification needs. Deliberately not
/// persisted anywhere (see `ActivityReminder`'s own doc comment) —
/// resolved fresh from canonical Planning truth at scheduling time by
/// `NotificationsPlanningCoordinationService`, and kept isolated in this
/// one small value type precisely so a later UI/product task can refine
/// wording without touching any lifecycle/scheduling code. No
/// motivational copy, no Reflection data, no coach-like language — see
/// this type's only production call site for the current minimal
/// content.
public struct ActivityReminderContent: Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Notifications V1 Activity Reminder Foundation: the scheduling
/// boundary that keeps every other layer (domain/application logic,
/// tests) free of any direct `UNUserNotificationCenter` dependency —
/// exactly what this task's "Scheduling boundary" requirement asks for.
/// `UNUserNotificationCenterActivityReminderScheduler` is the one
/// production conformance; tests use their own recording fake.
///
/// Every method is keyed by `ActivityReminderId`, never by title, date,
/// or any other mutable/derived content — so rescheduling or cancelling
/// a reminder always targets the exact same underlying notification
/// request regardless of how its content has changed since it was first
/// scheduled. See `UNUserNotificationCenterActivityReminderScheduler
/// .requestIdentifier(for:)` for the deterministic identifier this
/// produces.
///
/// Deliberately synchronous, not `async` — `UNUserNotificationCenter`'s
/// own schedule/cancel calls are fire-and-forget from the caller's
/// perspective (its completion handler exists for error diagnostics,
/// not for callers to await), so keeping this boundary synchronous keeps
/// every caller (including `EventBus` subscription closures, which are
/// themselves plain synchronous `@Sendable` closures) simple and
/// deterministic to test — no `Task`/actor-hop needed just to schedule
/// or cancel a reminder.
public protocol ActivityReminderScheduling: Sendable {
    /// Schedules (or replaces, if one with this `id` is already pending)
    /// a local notification to fire at `fireDate`. A `fireDate` that has
    /// already passed is the caller's concern (`NotificationsPlanningCoordinationService`
    /// does not call this for a past fire date) — implementations are not
    /// required to guard against it themselves, though the production
    /// adapter does as defense-in-depth.
    func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent)

    /// Cancels any pending local notification for this `id`. A no-op if
    /// none is pending.
    func cancelReminder(id: ActivityReminderId)

    /// Requests local-notification authorization from the user.
    ///
    /// Exposed here so the scheduling boundary is complete for the
    /// LATER contextual "enable a reminder" UI flow this foundation
    /// exists to support — it is deliberately never called by anything
    /// in this task (no production call site exists in this PR). Apple's
    /// own `UNUserNotificationCenter.requestAuthorization` is itself
    /// idempotent — once the user has responded, calling it again never
    /// re-prompts, it just reports the existing decision — so this
    /// method needs no separate "check current status first" step of its
    /// own.
    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void)
}
