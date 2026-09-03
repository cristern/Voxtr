import Foundation
import VoxtrParentDomain
import VoxtrAthleteDomain

/// S1.3: the three-way result of checking what's persisted on this
/// device at app launch. This type only describes what was found —
/// `FamilyRestorationService`, which produces it, never inserts,
/// updates, or deletes anything (requirement 2).
public enum FamilyRestorationState {
    /// Nothing persisted yet — first launch, or onboarding was never
    /// completed. Sprint 1's onboarding UI (S1.4) is the next step for
    /// this state; that UI is not built here.
    case noExistingFamily

    /// Parent, workspace, and participant exist and reference each
    /// other consistently, and every `AthleteProfile` present has
    /// exactly one matching `AthleteAccessGrant` — see
    /// `FamilyRestorationService`'s doc comment for exactly what
    /// "consistent" means. `RestoredFamily.athletes` may be empty
    /// (Multi-Athlete Family Foundation: this is a real, expected state
    /// — every athlete archived, or none ever added — not an error).
    case existingFamily(RestoredFamily)

    /// Some but not all of the five entities exist, or they exist but
    /// don't reference each other correctly. Per requirement 6: this is
    /// an explicit, recoverable state — restoration does NOT crash and
    /// does NOT delete anything to "fix" it. `reason` names which
    /// specific consistency rule failed, for diagnostics. What a caller
    /// should DO about this state (repair flow, support contact, etc.)
    /// is not decided here — out of scope for S1.3.
    case inconsistentGraph(reason: String)
}

/// The fully consistent result — every field is guaranteed to reference
/// the others correctly, per the rules `FamilyRestorationService`
/// enforces before ever constructing one of these.
///
/// Multi-Athlete Family Foundation: `athletes`/`grants` were
/// `athlete: AthleteProfile`/`grant: AthleteAccessGrant` (singular)
/// before this change — that was the actual root cause of this
/// project's single-athlete limitation, not a schema constraint (see
/// `FamilyRestorationService`'s own updated doc comment). `athletes`
/// holds every `AthleteProfile` in the family, archived or not, in a
/// deterministic order (see `FamilyRestorationService`); `grants`
/// holds the corresponding `AthleteAccessGrant` for each — guaranteed
/// by `FamilyRestorationService` to be exactly one grant per athlete,
/// from the sole parent participant. Existing consumers built for
/// exactly one athlete (e.g. `HomeDashboardView`, unchanged by this
/// work package) use `activeAthletes.first`.
public struct RestoredFamily {
    public let parent: ParentProfile
    public let workspace: FamilyWorkspace
    /// The sole `.workspaceOwner` participant — unchanged meaning from
    /// before Athlete Connection Foundation A. ParentApp continues to
    /// act as this participant; see `currentActor` below.
    public let participant: WorkspaceParticipant
    public let athletes: [AthleteProfile]
    public let grants: [AthleteAccessGrant]
    /// Athlete Connection Foundation A: every `role == .athlete`
    /// `WorkspaceParticipant` in this workspace, in ANY lifecycle state
    /// (invited/active/declined/revoked) — the membership graph, not a
    /// filtered "currently usable" view. `FamilyRestorationService`
    /// guarantees each one's `linkedAthleteId` resolves to a real
    /// `AthleteProfile` present in `athletes`, in this same workspace.
    /// A Parent-only athlete simply has no entry here at all — this
    /// array is deliberately allowed to be empty. Deterministically
    /// ordered by `FamilyRestorationService` (`createdAt`, then `id`).
    public let athleteParticipants: [WorkspaceParticipant]

    public init(
        parent: ParentProfile,
        workspace: FamilyWorkspace,
        participant: WorkspaceParticipant,
        athletes: [AthleteProfile],
        grants: [AthleteAccessGrant],
        athleteParticipants: [WorkspaceParticipant] = []
    ) {
        self.parent = parent
        self.workspace = workspace
        self.participant = participant
        self.athletes = athletes
        self.grants = grants
        self.athleteParticipants = athleteParticipants
    }

    /// Athletes that should actually appear anywhere in the product —
    /// an archived athlete is still a real row (see
    /// `AthleteManagementService.archiveAthlete`'s own doc comment for
    /// why it's never removed), but it is never "active."
    public var activeAthletes: [AthleteProfile] {
        athletes.filter { !$0.isArchived }
    }

    /// Athlete Connection Foundation A: the canonical current-session
    /// actor for this restored family — resolved once, from the
    /// workspace-owner participant, since ParentApp is the only
    /// production actor this PR wires in. Every AppShell business
    /// mutation that previously constructed `ActorId(rawValue:
    /// family.participant.id)` directly should read `currentActor.actorId`
    /// here instead. See `CurrentSessionActor`'s own doc comment for why
    /// this is never derived from the selected athlete or screen state.
    public var currentActor: CurrentSessionActor {
        CurrentSessionActor.resolve(from: participant)
    }
}
