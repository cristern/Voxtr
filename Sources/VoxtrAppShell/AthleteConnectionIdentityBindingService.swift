import Foundation
import VoxtrCoreContracts
import VoxtrParentDomain
import VoxtrAthleteDomain

/// Athlete Connection Foundation B2.3: binds a CloudKit-accepted
/// FamilyWorkspace share's stable `workspaceId` to the EXISTING local
/// Vǫxtr identity it corresponds to — `FamilyWorkspace` →
/// `WorkspaceParticipant` (Athlete role) → `AthleteProfile`.
///
/// SCOPE: this is where "accepted CloudKit transport facts" ends and
/// "existing Vǫxtr business identity" begins. It does NOT decide the
/// active app session (`CurrentSessionActor` — see that type's own doc
/// comment; a later slice resolves it FROM this result, never the other
/// way around) and does NOT build Athlete Home. `CKShare`/CloudKit types
/// never appear anywhere in this file — see this type's own `bind(
/// acceptedWorkspaceId:intendedParticipantId:)` signature, which takes two
/// raw `UUID`s, exactly the provider-neutral shape
/// `FamilyWorkspaceParticipantShareCoordinator` (B2.2, `VoxtrCore`)
/// already produces as `AcceptedFamilyWorkspaceShare.workspaceId`/
/// `.intendedParticipantId` — the caller (a later slice) is expected to
/// pass those two fields, not the whole B2.2 result.
///
/// Athlete Connection Foundation B2.6: `intendedParticipantId` closes the
/// architectural gap this type's own AMBIGUITY doc comment (below)
/// originally identified — a `workspaceId` alone cannot say WHICH athlete
/// in a multi-athlete family a share-acceptance corresponds to. That
/// signal now travels alongside the share as a separate CloudKit child
/// record (`AthleteConnectionInvitationCloudRecordMapping`, B2.2/B2.6);
/// this type only ever sees the already-decoded stable `UUID`, never any
/// CloudKit-specific type. This is an EXACT-ID lookup, not a heuristic:
/// no display name, order, age, or CloudKit-participant identity is ever
/// consulted.
///
/// READ-ONLY: this type creates or mutates nothing. It answers "does an
/// existing, locally consistent Vǫxtr identity already match this
/// accepted share" — it never creates a `FamilyWorkspace`,
/// `WorkspaceParticipant`, `AthleteProfile`, or `AthleteAccessGrant`, and
/// never performs `WorkspaceParticipant`'s own `.invited → .active`
/// transition (that remains `AcceptWorkspaceInvitationService`'s
/// canonical, unmodified responsibility — see this type's own ELIGIBILITY
/// doc comment below for exactly how that interacts with this slice).
///
/// REUSES, DOES NOT DUPLICATE: `FamilyRestorationService` (same target)
/// already performs the canonical, exhaustive consistency validation of
/// this device's local family graph — exactly one parent/workspace,
/// participant roles/states, every `.athlete` participant's link
/// resolving to a real `AthleteProfile` in the same workspace, and the
/// `AthleteAccessGrant` set corresponding exactly to the `AthleteProfile`
/// set. This service calls it rather than re-deriving any of that
/// consistency logic itself — see `bind(acceptedWorkspaceId:intendedParticipantId:)`.
///
/// ATHLETEACCESSGRANT: deliberately NOT part of this binding chain.
/// Confirmed by inspection of `AthleteAccessGrantRepository` and
/// `FamilyRestorationService` (both in this same PR's own repository):
/// `AthleteAccessGrant.participantId` is scoped to the workspace-OWNER
/// (Parent) participant, not the Athlete's own `WorkspaceParticipant` —
/// it represents the PARENT's permission to view/edit an athlete's data,
/// an entirely different relationship from "does this Athlete-side
/// participant exist and is it eligible." `FamilyRestorationService`
/// already validates the grant set's own consistency (one grant per
/// `AthleteProfile`, all owned by the sole workspace-owner participant)
/// as part of the reused restoration check above — this service does not
/// re-validate or otherwise touch grants beyond that.
///
/// PARTICIPANT ELIGIBILITY: "eligible" here means an EXISTING `.athlete`-
/// role `WorkspaceParticipant`, in this workspace, already `state ==
/// .active`. A participant still `.invited` is a distinct, explicit
/// failure (`participantNotEligible`) rather than something this method
/// auto-transitions — this slice is read-only. The canonical
/// `.invited → .active` transition remains `AcceptWorkspaceInvitationService`
/// .accept(...), unmodified and uncalled here; deciding exactly when/how
/// that transition is invoked as part of the overall CKShare-acceptance
/// product flow (before or after this binding step, and by which actor)
/// is left as an explicit open question for the next bounded slice — see
/// this PR's own delivery report.
///
/// AMBIGUITY (CLOSED by B2.6): a `workspaceId` alone carries no signal
/// about WHICH athlete in a multi-athlete family this specific
/// share-acceptance corresponds to (B2.1's `CKShare` is rooted on the
/// `FamilyWorkspace` record, not on any specific athlete). `resolve(...)`
/// now matches the EXACT `intendedParticipantId` the invitation-intent
/// record carried, rather than filtering to "the one `.active`
/// participant" and failing if more than one exists. A duplicate
/// `WorkspaceParticipant.id` within a workspace should be structurally
/// impossible (SwiftData's own uniqueness enforcement), but is still
/// surfaced explicitly as `duplicateWorkspaceParticipantIdentity` rather
/// than silently picking a first match, matching this file's own
/// established defense-in-depth pattern for `AthleteProfile.id`
/// (`duplicateAthleteIdentity`, unchanged below).
///
/// ACTOR ISOLATION: `@MainActor`, matching its one dependency
/// (`FamilyRestorationService`, itself `@MainActor` because it ultimately
/// touches `ModelContext`). The actual matching/validation logic lives in
/// a separate `nonisolated static` function, `resolve(acceptedWorkspaceId:
/// restorationState:)`, operating on the already-fetched, plain
/// `FamilyRestorationState`/`RestoredFamily` value — no `ModelContext`
/// access, so it needs no isolation and is directly unit-testable by
/// constructing `RestoredFamily`/`WorkspaceParticipant`/`AthleteProfile`
/// values in-memory (SwiftData `@Model` classes are plain, freely
/// constructible Swift objects when never inserted into any
/// `ModelContext` — no SwiftData I/O, no `ModelContainer`, needed for
/// those tests).
@MainActor
public final class AthleteConnectionIdentityBindingService {

    private let familyRestorationService: FamilyRestorationService

    public init(familyRestorationService: FamilyRestorationService) {
        self.familyRestorationService = familyRestorationService
    }

    /// Idempotent by construction: this method never mutates anything,
    /// so repeated calls with the same `workspaceId`/`intendedParticipantId`
    /// against unchanged local persistence always resolve the same
    /// `BoundAthleteIdentity` (or the same failure) — no state to
    /// converge, nothing to duplicate.
    public func bind(acceptedWorkspaceId workspaceId: UUID, intendedParticipantId: UUID) throws -> BoundAthleteIdentity {
        let restorationState = try familyRestorationService.restoreState()
        return try Self.resolve(acceptedWorkspaceId: workspaceId, intendedParticipantId: intendedParticipantId, restorationState: restorationState)
    }

    /// PURE matching/validation only — no persistence I/O. See this
    /// type's own doc comment for the full rationale; each `guard`
    /// below maps to exactly one of this slice's required, differentiated
    /// failure cases (never collapsed to `nil`/`Bool`, never an arbitrary
    /// first-match winner).
    nonisolated static func resolve(
        acceptedWorkspaceId workspaceId: UUID,
        intendedParticipantId: UUID,
        restorationState: FamilyRestorationState
    ) throws -> BoundAthleteIdentity {
        let family: RestoredFamily
        switch restorationState {
        case .noExistingFamily:
            // No local family at all — this device has nothing the
            // accepted share's workspaceId could possibly match.
            throw AthleteConnectionIdentityBindingError.workspaceNotFound
        case .inconsistentGraph(let reason):
            // The device's OWN local graph fails FamilyRestorationService's
            // canonical consistency rules — a distinct failure from
            // "workspace not found," surfaced with that service's own
            // reason rather than force-fit into an unrelated case.
            throw AthleteConnectionIdentityBindingError.localFamilyGraphInconsistent(reason: reason)
        case .existingFamily(let restoredFamily):
            family = restoredFamily
        }

        // Sprint 1's single-family-per-device assumption (still current —
        // see FamilyRestorationService's own doc comment) means there is
        // at most one local FamilyWorkspace to compare against; a
        // mismatch here means "not found on this device," the same
        // outcome as .noExistingFamily above, not a distinct "duplicate"
        // case — FamilyRestorationService's own workspaceCount == 1 guard
        // already rules out this device genuinely holding more than one.
        guard family.workspace.id == workspaceId else {
            throw AthleteConnectionIdentityBindingError.workspaceNotFound
        }

        // `family.athleteParticipants` = every .athlete-role participant
        // in this workspace, in ANY lifecycle state (guaranteed by
        // FamilyRestorationService). Athlete Connection Foundation B2.6:
        // matched by EXACT `intendedParticipantId`, never by "the one
        // active participant" — a 0-match result here subsumes what used
        // to be the separate "no athlete participant record exists at
        // all" check, since an exact-ID lookup against an empty (or
        // non-matching) set fails identically either way.
        let matchingParticipants = family.athleteParticipants.filter { $0.id == intendedParticipantId }
        guard !matchingParticipants.isEmpty else {
            throw AthleteConnectionIdentityBindingError.athleteParticipantNotFound
        }
        guard matchingParticipants.count == 1, let participant = matchingParticipants.first else {
            throw AthleteConnectionIdentityBindingError.duplicateWorkspaceParticipantIdentity
        }
        guard participant.state == .active else {
            throw AthleteConnectionIdentityBindingError.participantNotEligible
        }

        // `participant` is `role == .athlete` (it was drawn from
        // `family.athleteParticipants`), so `linkedAthleteId` is
        // guaranteed non-nil twice over: `WorkspaceParticipant`'s own
        // canonical initializer (ParentEntities.swift) enforces
        // `precondition(role != .athlete || linkedAthleteId != nil, ...)`
        // at construction time — an `.athlete` participant with a nil
        // link cannot exist as an object at all — and `RestoredFamily`'s
        // own doc comment additionally guarantees `FamilyRestorationService`
        // already validated this before ever constructing this value.
        // A nil value here would mean that invariant was violated
        // upstream, not a legitimate binding outcome — matching this
        // codebase's own established pattern for role-dependent
        // invariants (see `ParentWorkspaceRepository.acceptInvitation`'s
        // doc comment: "crashes rather than throws ... represents a
        // caller error, not a runtime/environment failure").
        guard let linkedAthleteIdRaw = participant.linkedAthleteId else {
            preconditionFailure("role == .athlete WorkspaceParticipant must have a non-nil linkedAthleteId (WorkspaceParticipant's own initializer precondition, v1.3 Section 7.3)")
        }

        let matchingAthletes = family.athletes.filter { $0.id == linkedAthleteIdRaw }
        guard !matchingAthletes.isEmpty else {
            throw AthleteConnectionIdentityBindingError.athleteNotFound
        }
        guard matchingAthletes.count == 1, let athlete = matchingAthletes.first else {
            throw AthleteConnectionIdentityBindingError.duplicateAthleteIdentity
        }
        guard athlete.workspaceId == workspaceId else {
            throw AthleteConnectionIdentityBindingError.athleteWorkspaceMismatch
        }

        return BoundAthleteIdentity(
            workspaceId: WorkspaceId(rawValue: family.workspace.id),
            participantId: participant.id,
            athleteId: AthleteId(rawValue: athlete.id)
        )
    }
}

/// The minimum this slice's caller needs to move forward with session
/// activation — deliberately not richer. Stable IDs only: no
/// `CurrentSessionActor`, UI state, CloudKit object, email, or display
/// name. `Sendable`/`Equatable`: holds only `WorkspaceId`/`UUID`/
/// `AthleteId`, all themselves `Sendable`/`Equatable` — unlike B2.1/B2.2's
/// CloudKit-adjacent result types, nothing here forces avoiding
/// `Sendable`.
public struct BoundAthleteIdentity: Sendable, Equatable {
    public let workspaceId: WorkspaceId
    public let participantId: UUID
    public let athleteId: AthleteId
}

/// Explicit, differentiated failure semantics — never collapsed to `nil`
/// or a generic Bool, mirroring B2.1/B2.2's own established reasoning.
/// `Sendable`/`Equatable`: unlike `FamilyWorkspaceSharingError`/
/// `FamilyWorkspaceShareAcceptanceError` (B2.1/B2.2), no case here wraps
/// an existential `Error`, so both conformances are safe to declare
/// directly.
public enum AthleteConnectionIdentityBindingError: Error, Sendable, Equatable {
    /// No local `FamilyWorkspace` matches the accepted share's
    /// `workspaceId` — either no family exists on this device at all, or
    /// the one that does exist has a different `id`.
    case workspaceNotFound
    /// This device's own local family graph fails
    /// `FamilyRestorationService`'s canonical consistency rules — `reason`
    /// is that service's own diagnostic string, not re-derived here.
    case localFamilyGraphInconsistent(reason: String)
    /// No `.athlete`-role `WorkspaceParticipant` in this workspace has the
    /// EXACT `intendedParticipantId` the invitation-intent record
    /// specified.
    case athleteParticipantNotFound
    /// More than one `WorkspaceParticipant` in this workspace shares the
    /// same `id` as `intendedParticipantId` — should be structurally
    /// impossible given SwiftData's own uniqueness enforcement on
    /// `WorkspaceParticipant.id`, but surfaced explicitly rather than
    /// silently picking a first match (renamed from the pre-B2.6
    /// `ambiguousAthleteParticipant`, which described a different,
    /// now-closed ambiguity — see this type's own AMBIGUITY doc comment).
    case duplicateWorkspaceParticipantIdentity
    /// The exact intended participant exists, but is not currently
    /// `.active` (e.g. still `.invited`, or `.declined`/`.revoked`) — see
    /// this type's own ELIGIBILITY doc comment for why this slice does
    /// not auto-transition `.invited → .active` itself.
    case participantNotEligible
    /// The participant's `linkedAthleteId` does not resolve to any
    /// `AthleteProfile` in the restored family — structurally guaranteed
    /// not to happen by `FamilyRestorationService`'s own consistency
    /// rules (it validates every `.athlete` participant's link before
    /// ever constructing a `RestoredFamily`), but surfaced explicitly
    /// as defense-in-depth rather than force-unwrapped.
    case athleteNotFound
    /// More than one `AthleteProfile` shares the same `id` — should be
    /// structurally impossible given SwiftData's own uniqueness
    /// enforcement on `AthleteProfile.id`, but surfaced explicitly rather
    /// than silently picking the first match.
    case duplicateAthleteIdentity
    /// The resolved `AthleteProfile.workspaceId` does not match the
    /// accepted share's `workspaceId` — same structural guarantee as
    /// `athleteNotFound` above.
    case athleteWorkspaceMismatch
}
