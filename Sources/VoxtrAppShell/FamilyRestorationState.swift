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

    /// All five entities exist and reference each other consistently —
    /// see `FamilyRestorationService`'s doc comment for exactly what
    /// "consistent" means.
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
public struct RestoredFamily {
    public let parent: ParentProfile
    public let workspace: FamilyWorkspace
    public let participant: WorkspaceParticipant
    public let athlete: AthleteProfile
    public let grant: AthleteAccessGrant
}
