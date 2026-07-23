import Foundation
import VoxtrCore

/// Notifications domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns NotificationRule,
/// ScheduledReminder, and DeliveryRecord (Section 13). Rules schedule
/// reminders; they do not directly deliver notifications (Section 13.1) —
/// actual scheduling/delivery logic against UNUserNotificationCenter
/// remains Sprint 1+ business logic, not implemented here.
public struct NotificationsModule: VoxtrModule {
    public static let domainID = "notifications"

    public init() {}
}
