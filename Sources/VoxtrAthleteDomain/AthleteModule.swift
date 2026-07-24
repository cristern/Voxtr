import Foundation
import SwiftData
import VoxtrCore

/// Athlete domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns AthleteProfile,
/// AthleteSettings, and AthleteSportParticipation (Section 6), and
/// publishes AthleteProfileCreated / AthleteProfileUpdated /
/// AthleteArchived (Section 6.1, Section 16).
///
/// S1.2: registers `AthleteRepository`.
public struct AthleteModule: VoxtrModule {
    public static let domainID = "athlete"

    public init() {}

    @MainActor
    public func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {
        let repository = AthleteRepository(modelContext: modelContainer.mainContext)
        container.register(AthleteRepository.self) { repository }
    }
}
