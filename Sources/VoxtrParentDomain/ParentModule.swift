import Foundation
import VoxtrCore

/// Parent domain module descriptor (02_Architecture_v1_0).
///
/// As of Domain & Data Model v1.3, this package owns ParentProfile,
/// FamilyWorkspace, WorkspaceParticipant, and AthleteAccessGrant
/// (Section 7). FamilyMembership is implemented as a derived value type,
/// not a persisted entity, per the document's stated preference
/// (Section 7.4).
public struct ParentModule: VoxtrModule {
    public static let domainID = "parent"

    public init() {}
}
