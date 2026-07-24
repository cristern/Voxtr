import Foundation
import SwiftData
import VoxtrCore

/// Parent domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns ParentProfile,
/// FamilyWorkspace, WorkspaceParticipant, and AthleteAccessGrant
/// (Section 7). FamilyMembership is implemented as a derived value type,
/// not a persisted entity, per the document's stated preference
/// (Section 7.4).
///
/// S1.1: registers `ParentWorkspaceRepository`. S1.2: also registers
/// `AthleteAccessGrantRepository` (Parent-owned per v1.3 Section 7.5).
public struct ParentModule: VoxtrModule {
    public static let domainID = "parent"

    public init() {}

    @MainActor
    public func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {
        let workspaceRepository = ParentWorkspaceRepository(modelContext: modelContainer.mainContext)
        container.register(ParentWorkspaceRepository.self) { workspaceRepository }

        let grantRepository = AthleteAccessGrantRepository(modelContext: modelContainer.mainContext)
        container.register(AthleteAccessGrantRepository.self) { grantRepository }
    }
}
