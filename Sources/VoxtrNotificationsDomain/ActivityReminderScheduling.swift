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

/// Notifications V1 Activity Reminder UI slice: the three states this
/// foundation distinguishes for permission UX — deliberately not
/// `UNAuthorizationStatus` itself (`.provisional`/`.ephemeral` collapse
/// into `.authorized` here; nothing in this app requests those modes),
/// so no layer above the production adapter ever imports `UserNotifications`.
public enum ActivityReminderAuthorizationStatus: Sendable, Equatable {
    /// The user has never been asked.
    case notDetermined
    case authorized
    case denied
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

    /// Reports the CURRENT authorization decision without prompting the
    /// user — the "should I even ask?" check `NotificationsPlanningCoordinationService
    /// .enableReminder` makes before ever calling `requestAuthorization`
    /// below, per this UI slice's own explicit "permission requested
    /// contextually only when the user first attempts to enable a
    /// reminder" contract.
    ///
    /// `completion` is `@MainActor`-qualified so a caller already on
    /// `@MainActor` (every real caller in this app) can act on the
    /// result directly, with no `Task`/actor-hop of its own — the
    /// production adapter is the one place that DOES need a real hop
    /// (bridging `UNUserNotificationCenter`'s own arbitrary-queue
    /// completion handler back onto `@MainActor`), and it owns that
    /// entirely internally; callers never see it. See
    /// `UNUserNotificationCenterActivityReminderScheduler`'s own doc
    /// comment.
    func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void)

    /// Requests local-notification authorization from the user — the
    /// real system prompt, shown at most once per install (Apple's own
    /// `UNUserNotificationCenter.requestAuthorization` is idempotent:
    /// once the user has responded, calling it again never re-prompts,
    /// it just reports the existing decision). Only ever called by
    /// `NotificationsPlanningCoordinationService.enableReminder` when
    /// `authorizationStatus` above reports `.notDetermined` — this
    /// protocol requirement exists so the scheduling boundary owns the
    /// actual OS interaction; the DECISION of when to call it belongs to
    /// the coordination service, not to this adapter (see this
    /// protocol's own doc comment: "the scheduling adapter must not
    /// silently become the owner of UX permission flow").
    func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void)
}
