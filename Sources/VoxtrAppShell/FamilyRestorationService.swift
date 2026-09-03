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
/// for; Athlete Connection Foundation A: relaxed further from "exactly
/// one WorkspaceParticipant, always .workspaceOwner" to "exactly one
/// ACTIVE .workspaceOwner participant, plus zero or more .athlete
/// participants" — the participant model `ParentWorkspaceRepository
/// .createInvitedAthleteParticipant` (ADR-0001) already supports, which
/// this service previously rejected outright):
/// - Zero of all five entities → `.noExistingFamily`.
/// - Exactly one parent and one workspace, AND:
///   - every `WorkspaceParticipant.workspaceId == workspace.id`;
///   - exactly one participant has `role == .workspaceOwner`, and it is
///     `state == .active` (never zero, never more than one — this
///     Alpha model still has a single owner);
///   - every OTHER participant has `role == .athlete` (a
///     `.guardianEditor`/`.guardianViewer` participant is not yet
///     producible by anything in this codebase, so one appearing is
///     treated as inconsistent, not silently accepted);
///   - every `.athlete` participant's `linkedAthleteId` resolves to a
///     real `AthleteProfile` — an athlete participant is membership-
///     graph metadata about an existing `AthleteProfile`, never a
///     second identity for one;
///   - every `AthleteProfile.workspaceId == workspace.id` — this ALSO
///     covers "an athlete participant links to a profile in a different
///     workspace," since any such profile is necessarily present in the
///     unscoped `athletes` fetch this same rule already checks; there is
///     no separate, later check for that case, only this one;
///   - the `AthleteAccessGrant` set corresponds exactly to the
///     `AthleteProfile` set: same count, every grant's `participantId`
///     matches the sole workspace-owner participant (grants remain
///     Parent-owner-scoped — Athlete Connection Foundation A does not
///     redesign `AthleteAccessGrant`), and the grants' `athleteId` set
///     equals the athletes' `id` set exactly (no orphaned grant, no
///     athlete missing a grant) — this covers archived athletes too:
///     archiving (see `AthleteManagementService.archiveAthlete`) never
///     removes a grant, so an archived athlete still needs one.
///   → `.existingFamily`, with `RestoredFamily.athletes` and
///   `.athleteParticipants` possibly empty.
/// - Anything else — a missing parent/workspace, more than one of
///   either (not yet supported by Sprint 1's single-family assumption),
///   zero or multiple workspace-owner participants, a non-owner/
///   non-athlete participant role, an athlete participant linked to a
///   missing or cross-workspace `AthleteProfile`, or a cross-reference/
///   grant mismatch — → `.inconsistentGraph`, with a reason string
///   naming which rule failed.
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

        guard parentCount == 1, workspaceCount == 1 else {
            return .inconsistentGraph(
                reason: "Expected exactly one parent and workspace; "
                    + "found \(parentCount) parent(s), \(workspaceCount) workspace(s)."
            )
        }

        let parent = parents[0]
        let workspace = workspaces[0]

        guard participants.allSatisfy({ $0.workspaceId == workspace.id }) else {
            return .inconsistentGraph(reason: "At least one WorkspaceParticipant.workspaceId does not match FamilyWorkspace.id.")
        }

        // Athlete Connection Foundation A: the membership graph now
        // permits any number of `.athlete` participants alongside the
        // sole `.workspaceOwner` — the model `ParentWorkspaceRepository
        // .createInvitedAthleteParticipant` (ADR-0001) already supports.
        // No other role is producible by anything in this codebase yet,
        // so one appearing is treated as inconsistent rather than
        // silently accepted.
        let ownerParticipants = participants.filter { $0.role == .workspaceOwner }
        guard ownerParticipants.count == 1 else {
            return .inconsistentGraph(
                reason: "Expected exactly one workspace-owner participant; found \(ownerParticipants.count)."
            )
        }
        let participant = ownerParticipants[0]
        guard participant.state == .active else {
            return .inconsistentGraph(reason: "The workspace-owner participant must be in .active state; found \(participant.state).")
        }

        let athleteParticipants = participants.filter { $0.id != participant.id }
        guard athleteParticipants.allSatisfy({ $0.role == .athlete }) else {
            return .inconsistentGraph(reason: "Every WorkspaceParticipant other than the sole workspace owner must have role .athlete.")
        }

        guard athletes.allSatisfy({ $0.workspaceId == workspace.id }) else {
            return .inconsistentGraph(reason: "At least one AthleteProfile.workspaceId does not match FamilyWorkspace.id.")
        }

        // NOTE: resolving each link to a real AthleteProfile is checked
        // here; whether that profile belongs to THIS workspace is
        // already guaranteed by the `athletes.allSatisfy` guard directly
        // above — every element `athletesById` can possibly resolve to
        // already passed that check, so a separate "linked profile is in
        // a different workspace" branch here would be unreachable dead
        // code, not a second, distinct failure mode.
        let athletesById = Dictionary(uniqueKeysWithValues: athletes.map { ($0.id, $0) })
        for athleteParticipant in athleteParticipants {
            guard let linkedAthleteId = athleteParticipant.linkedAthleteId else {
                return .inconsistentGraph(reason: "An .athlete WorkspaceParticipant is missing linkedAthleteId.")
            }
            guard athletesById[linkedAthleteId] != nil else {
                return .inconsistentGraph(reason: "An .athlete WorkspaceParticipant's linkedAthleteId does not match any AthleteProfile.")
            }
        }

        guard grants.count == athletes.count else {
            return .inconsistentGraph(
                reason: "Expected exactly one AthleteAccessGrant per AthleteProfile (including archived); "
                    + "found \(athletes.count) athlete(s) and \(grants.count) grant(s)."
            )
        }
        guard grants.allSatisfy({ $0.participantId == participant.id }) else {
            return .inconsistentGraph(reason: "At least one AthleteAccessGrant.participantId does not match the workspace-owner WorkspaceParticipant.id.")
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
        let orderedAthleteParticipants = athleteParticipants.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return .existingFamily(RestoredFamily(
            parent: parent,
            workspace: workspace,
            participant: participant,
            athletes: orderedAthletes,
            grants: grants,
            athleteParticipants: orderedAthleteParticipants
        ))
    }
}
