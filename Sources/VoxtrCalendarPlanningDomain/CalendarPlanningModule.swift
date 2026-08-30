import Foundation
import SwiftData
import VoxtrCore

/// Calendar Planning Source V1 domain module descriptor
/// (02_Architecture_v1_0). Registers `CalendarPlanningMappingRepository`
/// only; it does NOT subscribe to `EventBus` or compose with Planning —
/// that cross-domain work (`CalendarPlanningCoordinationService`) lives
/// in `VoxtrAppShell`, same placement rationale
/// `NotificationsPlanningCoordinationService` already established for
/// the equivalent Planning+Notifications concern.
///
/// No Calendar permission is requested here or anywhere in this module
/// — `CalendarEventProviding.requestAuthorization` exists for a later,
/// explicit, contextual UI flow to call, never automatically at
/// configure/launch time.
public struct CalendarPlanningModule: VoxtrModule {
    public static let domainID = "calendarPlanning"

    public init() {}

    @MainActor
    public func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {
        let repository = CalendarPlanningMappingRepository(modelContext: modelContainer.mainContext)
        container.register(CalendarPlanningMappingRepository.self) { repository }
    }
}
