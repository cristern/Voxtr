import Foundation
import SwiftData
import VoxtrCore

/// Training domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns LoggedActivity,
/// ActivityLoad, and TrainingAttachment (Section 9). TrainingAttachment
/// is schema-only per Section 19 — no upload/download logic exists here
/// or anywhere else in this codebase. Load calculation logic itself
/// deliberately lives outside this module — see the separate
/// Calculation Engine design; Training only stores and validates.
///
/// S3.0: registers `TrainingRepository` and `TrainingService`.
public struct TrainingModule: VoxtrModule {
    public static let domainID = "training"

    public init() {}

    @MainActor
    public func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {
        let repository = TrainingRepository(modelContext: modelContainer.mainContext)
        container.register(TrainingRepository.self) { repository }

        let service = TrainingService(repository: repository, eventBus: eventBus)
        container.register(TrainingService.self) { service }
    }
}
