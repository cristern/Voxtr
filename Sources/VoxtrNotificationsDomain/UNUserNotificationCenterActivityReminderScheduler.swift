import Foundation
import UserNotifications
import VoxtrCoreContracts

/// Notifications V1 Activity Reminder Foundation: the ONE production
/// conformance of `ActivityReminderScheduling` — encapsulates every
/// `UNUserNotificationCenter` call in this codebase behind that
/// protocol, per this task's explicit "do not expose
/// UNUserNotificationCenter into Planning or Training" requirement.
/// Local notifications only (v1 approved architecture): no APNs, no
/// remote push, nothing here talks to a server.
///
/// A plain `struct` with no stored state — every call goes straight to
/// `UNUserNotificationCenter.current()`, so this is trivially `Sendable`
/// with no `@unchecked` needed.
public struct UNUserNotificationCenterActivityReminderScheduler: ActivityReminderScheduling {

    public init() {}

    /// Deterministic, stable-identity-based request identifier — never
    /// derived from title/body/fire date — so scheduling the SAME
    /// `ActivityReminderId` again (e.g. after the linked activity moved)
    /// replaces the existing pending request rather than accumulating a
    /// second one, and cancellation always targets the exact request a
    /// prior `scheduleReminder` call created.
    public static func requestIdentifier(for id: ActivityReminderId) -> String {
        "voxtr.activityReminder.\(id.rawValue.uuidString)"
    }

    public func scheduleReminder(id: ActivityReminderId, fireDate: Date, content: ActivityReminderContent) {
        let identifier = Self.requestIdentifier(for: id)
        let interval = fireDate.timeIntervalSinceNow
        // UNTimeIntervalNotificationTrigger requires a positive interval;
        // a fire date that has already passed by the time this runs has
        // nothing left to schedule — silently doing nothing here is
        // correct, not a hidden failure, since `NotificationsPlanningCoordinationService`
        // is the layer responsible for deciding whether a reminder is
        // still worth scheduling at all.
        guard interval > 0 else { return }

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = content.title
        notificationContent.body = content.body

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: notificationContent, trigger: trigger)

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.add(request, withCompletionHandler: nil)
    }

    public func cancelReminder(id: ActivityReminderId) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier(for: id)])
    }

    /// `UNUserNotificationCenter.getNotificationSettings`'s completion
    /// handler runs on an arbitrary queue (Apple's own documented
    /// behavior, not Swift-concurrency-isolated) — `Task { @MainActor in
    /// ... }` is the genuine, unavoidable bridge back onto `@MainActor`
    /// so `completion`'s own `@MainActor` type is honored. This is the
    /// ONE place in the whole Activity Reminder feature that needs this
    /// kind of hop: every caller of THIS method (via `ActivityReminderService`/
    /// `NotificationsPlanningCoordinationService`) can assume `completion`
    /// always runs on `@MainActor`, with no hop of their own.
    public func authorizationStatus(completion: @escaping @MainActor @Sendable (ActivityReminderAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: ActivityReminderAuthorizationStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                status = .authorized
            case .denied:
                status = .denied
            case .notDetermined:
                status = .notDetermined
            @unknown default:
                status = .notDetermined
            }
            Task { @MainActor in completion(status) }
        }
    }

    /// Badge is deliberately NOT requested — this feature never sets an
    /// app badge, per this UI slice's own explicit "do not
    /// request/use badge permission" requirement. Same arbitrary-queue
    /// completion-handler bridging as `authorizationStatus` above, for
    /// the same reason.
    public func requestAuthorization(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }
}
