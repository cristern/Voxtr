import Foundation
import SwiftData
import VoxtrCore

/// Calendar Planning domain module descriptor (02_Architecture_v1_0).
/// Registers `ExternalPlanningSourceRepository` and
/// `CalendarImportDecisionRepository` (Family-Owned Calendar Sources V1,
/// current) plus `CalendarPlanningMappingRepository` (Calendar Planning
/// Source V1, legacy/Alpha — retained only so already-persisted rows
/// remain readable for the one-time migration read; see
/// `CalendarPlanningMapping`'s own doc comment), and (VX-038)
/// `DecomposedActivityLinkRepository`/`DecompositionEvidenceRepository`.
/// It does NOT subscribe
/// to `EventBus` or compose with Planning — that cross-domain work
/// (`CalendarPlanningCoordinationService`) lives in `VoxtrAppShell`,
/// same placement rationale `NotificationsPlanningCoordinationService`
/// already established for the equivalent Planning+Notifications
/// concern.
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
        let legacyMappingRepository = CalendarPlanningMappingRepository(modelContext: modelContainer.mainContext)
        container.register(CalendarPlanningMappingRepository.self) { legacyMappingRepository }

        let sourceRepository = ExternalPlanningSourceRepository(modelContext: modelContainer.mainContext)
        container.register(ExternalPlanningSourceRepository.self) { sourceRepository }

        let importDecisionRepository = CalendarImportDecisionRepository(modelContext: modelContainer.mainContext)
        container.register(CalendarImportDecisionRepository.self) { importDecisionRepository }

        let decomposedActivityLinkRepository = DecomposedActivityLinkRepository(modelContext: modelContainer.mainContext)
        container.register(DecomposedActivityLinkRepository.self) { decomposedActivityLinkRepository }

        let decompositionEvidenceRepository = DecompositionEvidenceRepository(modelContext: modelContainer.mainContext)
        container.register(DecompositionEvidenceRepository.self) { decompositionEvidenceRepository }
    }
}
