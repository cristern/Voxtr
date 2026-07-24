import Foundation
import VoxtrCore
import VoxtrParentDomain
import VoxtrAthleteDomain

/// S1.3: determines `FamilyRestorationState` by querying the existing
/// repositories (requirement 1) — never creates, updates, or deletes
/// anything (requirement 2). Lives in `VoxtrAppShell` per requirement 7,
/// same rule as `FamilyOnboardingCoordinator`: this is one of the few
/// places allowed to see both `VoxtrParentDomain` and `VoxtrAthleteDomain`.
///
/// CONSISTENCY RULES (Sprint 1 scope: exactly one family per device,
/// since multi-family support and CloudKit sharing aren't implemented
/// yet):
/// - Zero of all five entities → `.noExistingFamily`.
/// - Exactly one of each, AND every cross-reference matches:
///   - `participant.workspaceId == workspace.id`
///   - `participant.role == .workspaceOwner` (Sprint 1 never creates any
///     other participant role — see `FamilyOnboardingCoordinator`)
///   - `athlete.workspaceId == workspace.id`
///   - `grant.participantId == participant.id`
///   - `grant.athleteId == athlete.id`
///   → `.existingFamily`.
/// - Anything else — a missing entity, more than one of any entity (not
///   yet supported by Sprint 1's single-family assumption), or a
///   cross-reference that doesn't match — → `.inconsistentGraph`, with
///   a reason string naming which rule failed.
@MainActor
public final class FamilyRestorationService {
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

    public func restoreState() throws -> FamilyRestorationState {
        // Unscoped fetches for all five, so this check is robust to ANY
        // combination of what's in the store — not just combinations
        // reachable by chaining from parent -> workspace -> athlete.
        let parents = try parentWorkspaceRepository.fetchAllParentProfiles()
        let workspaces = try parentWorkspaceRepository.fetchAllWorkspaces()
        let participants = try parentWorkspaceRepository.fetchAllParticipants()
        let athletes = try athleteRepository.fetchAllAthletes()
        let grants = try athleteAccessGrantRepository.fetchAllGrants()

        let parentCount = parents.count
        let workspaceCount = workspaces.count
        let participantCount = participants.count
        let athleteCount = athletes.count
        let grantCount = grants.count

        if parentCount == 0 && workspaceCount == 0 && participantCount == 0 && athleteCount == 0 && grantCount == 0 {
            return .noExistingFamily
        }

        guard parentCount == 1, workspaceCount == 1, participantCount == 1, athleteCount == 1, grantCount == 1 else {
            return .inconsistentGraph(
                reason: "Expected exactly one of each entity (parent, workspace, participant, athlete, grant); "
                    + "found \(parentCount) parent(s), \(workspaceCount) workspace(s), \(participantCount) participant(s), "
                    + "\(athleteCount) athlete(s), \(grantCount) grant(s)."
            )
        }

        let parent = parents[0]
        let workspace = workspaces[0]
        let participant = participants[0]
        let athlete = athletes[0]
        let grant = grants[0]

        guard participant.workspaceId == workspace.id else {
            return .inconsistentGraph(reason: "WorkspaceParticipant.workspaceId does not match FamilyWorkspace.id.")
        }
        guard participant.role == .workspaceOwner else {
            return .inconsistentGraph(reason: "The sole WorkspaceParticipant's role is not workspaceOwner — unexpected for Sprint 1's model (no athlete participant is ever created).")
        }
        guard athlete.workspaceId == workspace.id else {
            return .inconsistentGraph(reason: "AthleteProfile.workspaceId does not match FamilyWorkspace.id.")
        }
        guard grant.participantId == participant.id else {
            return .inconsistentGraph(reason: "AthleteAccessGrant.participantId does not match WorkspaceParticipant.id.")
        }
        guard grant.athleteId == athlete.id else {
            return .inconsistentGraph(reason: "AthleteAccessGrant.athleteId does not match AthleteProfile.id.")
        }

        // `parent` itself has no direct reference to check here — it's
        // reachable only via `technicalOwnerAccountId`/`accountId`
        // matching AccountId.pending in Sprint 1 (both are), which
        // isn't a meaningful consistency signal yet since every record
        // uses the same placeholder. Nothing further to verify until
        // CloudKit gives AccountId real values.

        return .existingFamily(RestoredFamily(
            parent: parent,
            workspace: workspace,
            participant: participant,
            athlete: athlete,
            grant: grant
        ))
    }
}
