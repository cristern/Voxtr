import Foundation
import VoxtrCoreContracts
import VoxtrParentDomain

/// Athlete Connection Foundation B2.4: turns an already-validated
/// `BoundAthleteIdentity` (B2.3's result) into the AthleteApp's active
/// runtime actor — the final step in the chain `accepted share →
/// BoundAthleteIdentity → existing WorkspaceParticipant →
/// CurrentSessionActor`. Does NOT skip the participant step: this
/// service re-fetches and re-validates the actual `WorkspaceParticipant`
/// record by `BoundAthleteIdentity.participantId` rather than trusting
/// `BoundAthleteIdentity`'s fields as authority on their own — see
/// REVALIDATION below.
///
/// SCOPE: runtime session activation only. Does NOT build Athlete Home,
/// does NOT reopen B2.3's ambiguity resolution (a `BoundAthleteIdentity`
/// already names exactly one `participantId` — this service checks that
/// specific participant, never re-runs "which of several eligible
/// participants" logic), and does NOT perform the `.invited → .active`
/// transition (`AcceptWorkspaceInvitationService` remains the sole,
/// unmodified, uncalled canonical path for that — a participant that is
/// not already `.active` fails activation explicitly rather than being
/// auto-accepted).
///
/// REVALIDATION: `BoundAthleteIdentity` was true at B2.3 bind time, but
/// local state (participant revoked, athlete re-linked, etc.) may have
/// changed since. This service re-fetches the specific
/// `WorkspaceParticipant` referenced by `boundIdentity.participantId`
/// and re-checks every fact `BoundAthleteIdentity` asserts — workspace,
/// role, state, athlete link — against that FRESH record before
/// resolving a session actor from it. A stale/mismatched
/// `BoundAthleteIdentity` fails explicitly; it is never treated as
/// authority on its own.
///
/// REUSES, DOES NOT DUPLICATE: `ParentWorkspaceRepository
/// .fetchAllParticipants()` (already exists — S1.3 uses the same
/// fetch-then-filter-in-Swift convention, see that method's own doc
/// comment for why `#Predicate` is avoided) for the lookup, and
/// `CurrentSessionActor.resolve(from:)` (Foundation A's canonical,
/// non-throwing actor resolver — see that type's own doc comment) for
/// producing the session actor. No second lookup-by-ID or
/// actor-resolution path is introduced.
///
/// NO NEW SESSION-HOLDER TYPE: `CurrentSessionActor` already carries
/// every stable ID a later slice needs (`participantId`, `workspaceId`,
/// `role`, `linkedAthleteId`) — see that type's own doc comment.
/// Wrapping it in a new `AthleteSessionState`/`SessionContext` type here
/// would just duplicate that same identity in a second mutable place,
/// which is exactly what One Truth forbids. `activate(boundIdentity:)`
/// therefore returns `CurrentSessionActor` directly, the first shape
/// this slice's own task description recommends. Nothing in this file
/// stores that result anywhere — the caller (a later slice, e.g. an
/// AthleteApp session holder or `RootView`-equivalent) owns doing that;
/// this service is called explicitly by that caller, never at
/// `CompositionRoot.build()`/application-launch time.
///
/// ACTOR ISOLATION: `@MainActor`, matching its one dependency
/// (`ParentWorkspaceRepository`, itself `@MainActor` because it touches
/// `ModelContext`). The actual matching/validation logic lives in a
/// separate `nonisolated static` function, `resolve(boundIdentity:
/// participants:)`, operating on an already-fetched `[WorkspaceParticipant]`
/// — no `ModelContext` access, so it needs no isolation and is directly
/// unit-testable by constructing `WorkspaceParticipant` values in-memory,
/// matching `AthleteConnectionIdentityBindingService`'s own established
/// pure/impure split (see that type's own doc comment).
@MainActor
public final class AthleteSessionActivationService {

    private let parentWorkspaceRepository: ParentWorkspaceRepository

    public init(parentWorkspaceRepository: ParentWorkspaceRepository) {
        self.parentWorkspaceRepository = parentWorkspaceRepository
    }

    /// Idempotent by construction: this method never mutates anything,
    /// so repeated calls with the same `boundIdentity` against unchanged
    /// local persistence always resolve the same `CurrentSessionActor`
    /// (or the same failure).
    public func activate(boundIdentity: BoundAthleteIdentity) throws -> CurrentSessionActor {
        let participants = try parentWorkspaceRepository.fetchAllParticipants()
        return try Self.resolve(boundIdentity: boundIdentity, participants: participants)
    }

    /// PURE matching/validation only — no persistence I/O. Each `guard`
    /// below maps to exactly one of this slice's required, differentiated
    /// failure cases (never collapsed to `nil`/`Bool`, never an arbitrary
    /// first-match winner). Deliberately does NOT re-run B2.3's
    /// eligibility/ambiguity logic (e.g. "which `.athlete` participant is
    /// currently `.active`") — it only re-checks the ONE specific
    /// participant `boundIdentity` already names.
    nonisolated static func resolve(
        boundIdentity: BoundAthleteIdentity,
        participants: [WorkspaceParticipant]
    ) throws -> CurrentSessionActor {
        let matches = participants.filter { $0.id == boundIdentity.participantId }
        guard !matches.isEmpty else {
            throw AthleteSessionActivationError.participantNotFound
        }
        // `@Attribute(.unique)` on `WorkspaceParticipant.id` should make
        // this structurally impossible from a real repository fetch —
        // surfaced explicitly rather than silently picking the first
        // match, matching `AthleteConnectionIdentityBindingService`'s
        // own `duplicateAthleteIdentity` precedent for the same kind of
        // defense-in-depth.
        guard matches.count == 1, let participant = matches.first else {
            throw AthleteSessionActivationError.localIdentityGraphInconsistent
        }
        guard participant.workspaceId == boundIdentity.workspaceId.rawValue else {
            throw AthleteSessionActivationError.workspaceMismatch
        }
        guard participant.role == .athlete else {
            throw AthleteSessionActivationError.participantRoleMismatch
        }
        guard participant.state == .active else {
            throw AthleteSessionActivationError.participantNotActive
        }
        guard participant.linkedAthleteId == boundIdentity.athleteId.rawValue else {
            throw AthleteSessionActivationError.athleteLinkMismatch
        }

        // `CurrentSessionActor.resolve(from:)` is a pure, non-throwing
        // mapping from an already-validated `WorkspaceParticipant` — it
        // cannot fail independently of the checks above, so this service
        // deliberately does NOT define an `actorResolutionFailed` case;
        // doing so would just be another unreachable branch (see this
        // repository's own PR #65 follow-up, which removed exactly that
        // kind of impossible case/test for `AthleteConnectionIdentityBindingService`).
        return CurrentSessionActor.resolve(from: participant)
    }
}

/// Explicit, differentiated failure semantics — never collapsed to `nil`
/// or a generic Bool, mirroring `AthleteConnectionIdentityBindingError`'s
/// (B2.3) own established reasoning. `Sendable`/`Equatable`: no case
/// wraps an existential `Error`, so both conformances are safe to
/// declare directly.
public enum AthleteSessionActivationError: Error, Sendable, Equatable {
    /// No `WorkspaceParticipant` with `boundIdentity.participantId`
    /// exists any more — e.g. it was somehow removed between binding and
    /// activation.
    case participantNotFound
    /// More than one `WorkspaceParticipant` shares
    /// `boundIdentity.participantId` — should be structurally impossible
    /// given SwiftData's own uniqueness enforcement on
    /// `WorkspaceParticipant.id`, but surfaced explicitly rather than
    /// silently picking the first match.
    case localIdentityGraphInconsistent
    /// The participant's current `workspaceId` no longer matches
    /// `boundIdentity.workspaceId` — e.g. moved/mismatched workspace
    /// since binding.
    case workspaceMismatch
    /// The participant's current `role` is no longer `.athlete` — B2.4
    /// only ever activates an Athlete-role participant as the AthleteApp
    /// session actor.
    case participantRoleMismatch
    /// The participant's current `state` is not `.active` — e.g.
    /// revoked, declined, or reverted to `.invited` since binding. This
    /// slice never auto-transitions `.invited → .active`
    /// (`AcceptWorkspaceInvitationService` remains that transition's
    /// sole canonical, unmodified, uncalled path); a non-`.active`
    /// participant simply fails activation.
    case participantNotActive
    /// The participant's current `linkedAthleteId` no longer matches
    /// `boundIdentity.athleteId` — e.g. re-linked to a different athlete
    /// since binding.
    case athleteLinkMismatch
}
