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
/// S1.1: registers `ParentWorkspaceRepository`. `AthleteAccessGrant`
/// persistence is explicitly out of scope for S1.1 (S1.2 work) — no
/// repository for it is registered here yet.
public struct ParentModule: VoxtrModule {
    public static let domainID = "parent"

    public init() {}

    @MainActor
    public func configure(container: DIContainer, eventBus: EventBus, modelContainer: ModelContainer) async {
        let repository = ParentWorkspaceRepository(modelContext: modelContainer.mainContext)
        container.register(ParentWorkspaceRepository.self) { repository }
    }
}
