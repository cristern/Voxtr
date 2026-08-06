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
/// yet; Multi-Athlete Family Foundation: relaxed from "exactly one
/// athlete" to "zero or more athletes," each still fully accounted
/// for):
/// - Zero of all five entities → `.noExistingFamily`.
/// - Exactly one parent, one workspace, one participant, AND every
///   cross-reference matches:
///   - `participant.workspaceId == workspace.id`
///   - `participant.role == .workspaceOwner` (Sprint 1 never creates any
///     other participant role — see `FamilyOnboardingCoordinator`)
///   - every `AthleteProfile.workspaceId == workspace.id`
///   - the `AthleteAccessGrant` set corresponds exactly to the
///     `AthleteProfile` set: same count, every grant's `participantId`
///     matches the sole participant, and the grants' `athleteId` set
///     equals the athletes' `id` set exactly (no orphaned grant, no
///     athlete missing a grant) — this covers archived athletes too:
///     archiving (see `AthleteManagementService.archiveAthlete`) never
///     removes a grant, so an archived athlete still needs one.
///   → `.existingFamily`, with `RestoredFamily.athletes` possibly
///   empty.
/// - Anything else — a missing parent/workspace/participant, more than
///   one of any of those three (not yet supported by Sprint 1's
///   single-family assumption), or a cross-reference/grant mismatch —
///   → `.inconsistentGraph`, with a reason string naming which rule
///   failed.
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

        if parentCount == 0 && workspaceCount == 0 && participantCount == 0 && athletes.isEmpty && grants.isEmpty {
            return .noExistingFamily
        }

        guard parentCount == 1, workspaceCount == 1, participantCount == 1 else {
            return .inconsistentGraph(
                reason: "Expected exactly one parent, workspace, and participant; "
                    + "found \(parentCount) parent(s), \(workspaceCount) workspace(s), \(participantCount) participant(s)."
            )
        }

        let parent = parents[0]
        let workspace = workspaces[0]
        let participant = participants[0]

        guard participant.workspaceId == workspace.id else {
            return .inconsistentGraph(reason: "WorkspaceParticipant.workspaceId does not match FamilyWorkspace.id.")
        }
        guard participant.role == .workspaceOwner else {
            return .inconsistentGraph(reason: "The sole WorkspaceParticipant's role is not workspaceOwner — unexpected for Sprint 1's model (no athlete participant is ever created).")
        }

        guard athletes.allSatisfy({ $0.workspaceId == workspace.id }) else {
            return .inconsistentGraph(reason: "At least one AthleteProfile.workspaceId does not match FamilyWorkspace.id.")
        }

        guard grants.count == athletes.count else {
            return .inconsistentGraph(
                reason: "Expected exactly one AthleteAccessGrant per AthleteProfile (including archived); "
                    + "found \(athletes.count) athlete(s) and \(grants.count) grant(s)."
            )
        }
        guard grants.allSatisfy({ $0.participantId == participant.id }) else {
            return .inconsistentGraph(reason: "At least one AthleteAccessGrant.participantId does not match the sole WorkspaceParticipant.id.")
        }
        guard Set(grants.map(\.athleteId)) == Set(athletes.map(\.id)) else {
            return .inconsistentGraph(reason: "The AthleteAccessGrant set does not correspond exactly to the AthleteProfile set (an orphaned grant, or an athlete missing its grant).")
        }

        // `parent` itself has no direct reference to check here — it's
        // reachable only via `technicalOwnerAccountId`/`accountId`
        // matching AccountId.pending in Sprint 1 (both are), which
        // isn't a meaningful consistency signal yet since every record
        // uses the same placeholder. Nothing further to verify until
        // CloudKit gives AccountId real values.

        // Deterministic ordering — never leave a caller (e.g. a
        // management list UI) to fetch order by chance, the same
        // convention this project already applies to every other
        // multi-row fetch. createdAt first (oldest athlete first,
        // matching how they were actually added), then id as a stable
        // tiebreaker for the (practically impossible but not
        // structurally excluded) case of two identical createdAt
        // values.
        let orderedAthletes = athletes.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return .existingFamily(RestoredFamily(
            parent: parent,
            workspace: workspace,
            participant: participant,
            athletes: orderedAthletes,
            grants: grants
        ))
    }
}
