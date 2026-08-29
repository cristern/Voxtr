import Foundation
import SwiftData
import VoxtrCore

/// Notifications domain module descriptor (02_Architecture_v1_0).
///
/// Notifications V1 Activity Reminder Foundation: this package now owns
/// `ActivityReminder` (reminder intent for one concrete `PlannedActivity`,
/// stable-ID-referenced — see that type's own doc comment for why the
/// prior `NotificationRule`/`ScheduledReminder`/`DeliveryRecord` scaffold
/// was replaced rather than reused), the `ActivityReminderScheduling`
/// boundary and its production `UNUserNotificationCenter` adapter, and
/// `ActivityReminderService`. This module registers the repository and
/// service; it does NOT subscribe to `EventBus` itself, because reacting
/// to Planning/Training mutations requires reading canonical
/// `PlannedActivity` data, which this package is architecturally
/// forbidden from importing (no `*Domain` target depends on another —
/// see `Package.swift`). That cross-domain reaction is
/// `NotificationsPlanningCoordinationService`'s job, in `VoxtrAppShell`,
/// registered and subscribed after this module's own `configure` runs
/// (same placement rationale `TrainingPlanningCoordinationService`
/// already established for the equivalent Planning+Training concern).
///
/// No notification authorization is requested here or anywhere in this
/// module — `ActivityReminderScheduling.requestAuthorization` exists for
/// a later, explicit, contextual UI flow to call, never automatically at
/// configure/launch time.
public struct NotificationsModule: VoxtrModule {
    public static let domainID = "notifications"

    public init() {}

    @MainActor
    public func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {
        let repository = ActivityReminderRepository(modelContext: modelContainer.mainContext)
        container.register(ActivityReminderRepository.self) { repository }

        let service = ActivityReminderService(
            repository: repository,
            scheduler: UNUserNotificationCenterActivityReminderScheduler()
        )
        container.register(ActivityReminderService.self) { service }
    }
}
