import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain

/// S1.2: orchestrates the full "create a family" flow — parent profile,
/// workspace, the parent's own participant record, the first athlete,
/// and the access grant connecting them. This coordination can only
/// live in `VoxtrAppShell`: it's the only place in the codebase allowed
/// to import both `VoxtrParentDomain` and `VoxtrAthleteDomain` (same
/// rule `ModuleRegistry.swift` documents for itself).
///
/// Out of scope for S1.2, per the approved scope: no UI calls this yet
/// (S1.4), no athlete `WorkspaceParticipant` is created (confirmed out
/// of scope for Sprint 1 entirely), no family-restoration logic (S1.3),
/// no input validation layer (deferred).
@MainActor
public final class FamilyOnboardingCoordinator {
    private let parentWorkspaceRepository: ParentWorkspaceRepository
    private let athleteRepository: AthleteRepository
    private let athleteAccessGrantRepository: AthleteAccessGrantRepository

    public init(
        parentWorkspaceRepository: ParentWorkspaceRepository,
        athleteRepository: AthleteRepository,
        athleteAccessGrantRepository: AthleteAccessGrantRepository
    ) {
        self.parentWorkspaceRepository = parentWorkspaceRepository
        self.athleteRepository = athleteRepository
        self.athleteAccessGrantRepository = athleteAccessGrantRepository
    }

    public struct Result {
        public let parent: ParentProfile
        public let workspace: FamilyWorkspace
        public let participant: WorkspaceParticipant
        public let athlete: AthleteProfile
        public let grant: AthleteAccessGrant
    }

    /// Creates parent + workspace + participant, then the first athlete,
    /// then a full-access grant connecting them.
    ///
    /// NOT ATOMIC ACROSS ALL THREE STEPS, FLAGGED: each repository call
    /// saves independently (`ParentWorkspaceRepository.
    /// createParentAndWorkspace` is its own atomic unit; athlete
    /// creation and grant creation are each their own). If athlete or
    /// grant creation throws after the parent/workspace step already
    /// succeeded, the parent/workspace remain persisted with no athlete
    /// yet. Whether that's acceptable, or whether a later story needs a
    /// rollback/compensation strategy, is not resolved here — inventing
    /// one wasn't part of the approved S1.2 scope.
    public func createFamily(
        parentGivenName: String,
        parentFamilyName: String? = nil,
        parentPreferredName: String? = nil,
        athleteGivenName: String,
        athleteFamilyName: String? = nil,
        athletePreferredName: String? = nil,
        athleteBirthDate: LocalDate,
        athleteTimeZoneId: TimeZoneId,
        athleteDevelopmentStage: DevelopmentStage
    ) throws -> Result {
        let parentResult = try parentWorkspaceRepository.createParentAndWorkspace(
            givenName: parentGivenName,
            familyName: parentFamilyName,
            preferredName: parentPreferredName
        )

        let athlete = try athleteRepository.createAthlete(
            workspaceId: parentResult.workspace.workspaceId,
            givenName: athleteGivenName,
            familyName: athleteFamilyName,
            preferredName: athletePreferredName,
            birthDate: athleteBirthDate,
            timeZoneId: athleteTimeZoneId,
            developmentStage: athleteDevelopmentStage
        )

        let grant = try athleteAccessGrantRepository.createFullAccessGrant(
            workspaceId: parentResult.workspace.workspaceId,
            participantId: parentResult.participant.id,
            athleteId: athlete.athleteId
        )

        return Result(
            parent: parentResult.parent,
            workspace: parentResult.workspace,
            participant: parentResult.participant,
            athlete: athlete,
            grant: grant
        )
    }
}
