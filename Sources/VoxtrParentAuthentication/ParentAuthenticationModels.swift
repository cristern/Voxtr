import Foundation

/// Athlete Connection V1 — one existing `FamilyWorkspace` this device
/// already knows about locally, reduced to exactly what redemption
/// needs to send the backend: its stable identifier and a label to show
/// in the picker. Deliberately NOT `VoxtrParentDomain.FamilyWorkspace`
/// itself, and this package deliberately does not import
/// `VoxtrParentDomain`/`VoxtrCoreContracts` at all — per cristern/Voxtr
/// Docs/Architecture/AthleteConnectionV1-ParentAuthenticationContract.md
/// §6, this package owns the SIWA handshake, Keychain storage, and the
/// redemption/session HTTP calls, nothing about the SwiftData domain
/// model. The caller (`VoxtrAppShell`, the only place cross-domain
/// composition is legitimate) maps `FamilyWorkspace.workspaceId.rawValue`
/// to this type's `id` at the call site.
public struct EnrollableWorkspace: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// The plaintext Apple identity token the caller (a SwiftUI view using
/// the real `SignInWithAppleButton`) extracted from a real
/// `ASAuthorizationAppleIDCredential`. This package's own service layer
/// never imports `AuthenticationServices` types into its testable
/// surface — this plain string wrapper is the entire boundary, so
/// `ParentAuthenticationService` can be exercised deterministically with
/// a synthetic value, exactly as the task's own verification
/// requirements ask for.
struct AppleIdentityCredential: Sendable {
    let identityToken: String
}

/// Step 1 of the SIWA handshake, already completed: a fresh, single-use
/// nonce has been fetched from `auth-nonce` and its required hash
/// already computed (see `SiwaNonceHashing`). `hashedNonceHex` is what
/// the caller sets on `ASAuthorizationAppleIDRequest.nonce`;
/// `nonceId` is threaded back into `completeSignIn` unchanged.
struct PendingSiwaHandshake: Equatable, Sendable {
    let nonceId: String
    let hashedNonceHex: String
}

/// `parent-auth-complete`'s own outcome family — both cases are HTTP 200
/// (see that handler's own anti-enumeration doc comment: a caller can
/// never distinguish WHY authentication failed, only THAT it did).
enum SignInOutcome: Equatable, Sendable {
    case authenticated
    case authenticationFailed
}

/// `workspace-enrollment-redeem`'s non-session outcome family — the
/// three session-related outcomes (`session_invalid`/`session_expired`/
/// `reauthentication_required`) are surfaced as thrown
/// `ParentAuthenticationError` cases instead (see that type), since they
/// mean "this call could not be authorized at all," a different shape
/// of result than "the call was authorized and the backend decided
/// this business outcome." `ownerBindingId` is populated exactly where
/// the backend's own response includes it (see
/// `workspace-enrollment-redeem/index.ts`'s own `owner_binding_id`
/// field, present only when non-null) — a value here is never invented
/// or defaulted.
enum RedemptionOutcome: Equatable, Sendable {
    case bound(ownerBindingId: UUID)
    case alreadyRedeemedBySameParent(ownerBindingId: UUID)
    case bindingRevoked(ownerBindingId: UUID)
    case authorizationAlreadyRedeemed
    case workspaceAlreadyBound
    case inconsistentState
    case authorizationNotAvailable
}

/// Every way a call into this package's service can fail to even reach
/// a business outcome. `sessionInvalid`/`sessionExpired` mean the
/// stored token itself is now useless — the caller must sign in again
/// from scratch. `reauthenticationRequired` means the token is still a
/// LIVE session, just not fresh enough for this specific sensitive
/// operation (§2.6) — per the contract, only a brand-new SIWA handshake
/// (never a refresh/rotation) can produce a session fresh enough; the
/// existing token is deliberately left in place, not cleared, since it
/// remains valid for ordinary purposes.
/// Athlete Connection V1: made `public` (unlike every other type in this
/// file, deliberately kept `internal` since only `ParentEnrollmentView`
/// and this package's own tests ever needed them) because the three new
/// connection-invitation/request/decision methods below ARE `public` —
/// see those methods' own doc comments for why: their caller
/// (`VoxtrAppShell`'s own invitation/approval UI) genuinely lives outside
/// this package, since it needs `ParentWorkspaceRepository`/
/// `AthleteProfile` to resolve the athlete being connected, and this
/// package deliberately never imports `VoxtrParentDomain`/
/// `VoxtrCoreContracts` (§6) — unlike SIWA sign-in/redemption, whose only
/// caller is this package's own `ParentEnrollmentView`.
public enum ParentAuthenticationError: Error, Equatable, Sendable {
    case notSignedIn
    case sessionInvalid
    case sessionExpired
    case reauthenticationRequired
    case network
    case malformedResponse
}

/// `connection-invitation-create`'s non-session outcome family (see
/// cristern/Voxtr-Backend's own `authzBridge.ts`
/// `CreateConnectionInvitationOutcome` for the authoritative wire set).
/// The three session-related outcomes are surfaced as thrown
/// `ParentAuthenticationError` cases instead — same convention as
/// `RedemptionOutcome` — since `connection-invitation-create` is a
/// SENSITIVE operation per the backend's own 10-minute freshness gate.
/// `ownerBindingNotActive` means this device's workspace ownership
/// binding is not (or no longer) active server-side; never inferred
/// locally.
public enum ConnectionInvitationCreationOutcome: Equatable, Sendable {
    case created(invitationId: UUID, expiresAt: Date)
    case ownerBindingNotActive
}

/// `connection-request-list`'s own per-row shape. `displayCode` is the
/// code the Parent visually compares against the Athlete's actual
/// device before approving — a selection consistency check, never
/// authorization itself (per cristern/Voxtr-Backend's
/// `connection-request-decide/index.ts` own doc comment).
public struct ConnectionRequestSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayCode: String
    public let status: ConnectionRequestStatus
    public let createdAt: Date

    public init(id: UUID, displayCode: String, status: ConnectionRequestStatus, createdAt: Date) {
        self.id = id
        self.displayCode = displayCode
        self.status = status
        self.createdAt = createdAt
    }
}

/// Mirrors `authzBridge.ts`'s own `ConnectionRequestListItem.status`
/// union exactly.
public enum ConnectionRequestStatus: String, Equatable, Sendable {
    case pending
    case approved
    case rejected
    case claimed
}

/// `connection-request-list`'s non-session outcome family — this
/// operation is ORDINARY (only ordinary session validity is required,
/// never freshness), so unlike `ConnectionInvitationCreationOutcome`
/// there is no `reauthenticationRequired` case at all on this endpoint.
public enum ConnectionRequestListOutcome: Equatable, Sendable {
    case ok(requests: [ConnectionRequestSummary])
    case invitationNotFound
    case ownerBindingNotActive
}

/// The decision a Parent makes for one specific connection request —
/// mirrors `connection-request-decide`'s own `decision` field exactly.
public enum ConnectionRequestDecision: String, Equatable, Sendable {
    case approved
    case rejected
}

/// `connection-request-decide`'s non-session outcome family (see
/// `authzBridge.ts`'s own `DecideConnectionRequestOutcome` for the
/// authoritative wire set). Every invitation-state conflict is its own
/// distinct, named outcome — never collapsed to a generic failure —
/// matching this package's own established explicit-outcome convention.
public enum ConnectionRequestDecisionOutcome: Equatable, Sendable {
    case approved
    case rejected
    case invitationNotFound
    case requestNotFound
    case ownerBindingNotActive
    case codeMismatch
    case requestClaimed
    case alreadyDecided
    case invitationExpired
    case invitationConsumed
    case invitationAlreadyHasApprovedRequest
}

/// Parent hydration upload (runtime contract §4.2, merged backend
/// `authz.hydration_upload` — see `cristern/Voxtr-Backend`
/// `20261005000000_authz_hydration_v1.sql`'s own authoritative outcome
/// list). SENSITIVE operation, same session-handling shape as
/// `createConnectionInvitation`/`decideConnectionRequest` — the three
/// session-related outcomes (`session_invalid`/`session_expired`/
/// `reauthentication_required`) are thrown `ParentAuthenticationError`
/// cases instead, never collapsed into this type, matching every other
/// outcome enum in this file.
///
/// Every outcome is its own distinct, named case — never collapsed to a
/// generic "failed"/"succeeded" — because each means something
/// genuinely different for retry/idempotency (see the backend's own
/// migration comment above `authz.hydration_upload` for the exact
/// semantics of each):
/// - `.staged`: no device grant exists yet; this exact payload is held,
///   keyed by `connection_request_id`, governed by the invitation's own
///   expiry until the Athlete claims it. Resending the IDENTICAL
///   payload again is itself idempotent and returns `.staged` again.
/// - `.uploaded`: a device grant already exists and this upload is now
///   directly associated with it.
/// - `.uploadRejected`: a retry against an ALREADY-associated upload —
///   this is the backend's own asymmetry versus `.staged`'s retry
///   idempotency (associated retries are rejected outright, without
///   even comparing payload bytes) — in practice this means a PRIOR
///   attempt already genuinely succeeded, even if this exact caller
///   never saw that attempt's own response.
/// - `.alreadyCompleted` / `.deadlinePassed` / `.grantRevoked`: the
///   grant's own PERMANENT `hydration_outcome` marker already answers
///   this grant's hydration lifecycle — checked first, before any
///   payload comparison — so none of these three ever depends on what
///   payload this call happened to send.
/// - `.payloadMismatch`: the already-staged/associated row (or the
///   invitation's own canonical identity) has DIFFERENT bytes than this
///   call just sent — a genuine identity/payload inconsistency, never
///   silently resolved. A caller must never recompute a changed payload
///   on retry; the original, immutable, resolved-at-approval-time
///   payload must always be resent unchanged.
/// - `.requestNotFound` / `.invitationNotFound` / `.ownerBindingNotActive`:
///   defensive/isolation outcomes — the target connection request,
///   its invitation, or the owner binding backing it, could not be
///   resolved as this Parent's own.
/// - `.notYetApproved`: the request is not (or no longer) approved —
///   this plan's own caller only ever uploads after an actual approval
///   success, so this should not occur in the ordinary flow; surfaced
///   explicitly rather than silently retried forever.
public enum HydrationUploadOutcome: Equatable, Sendable {
    case staged
    case uploaded
    case uploadRejected
    case alreadyCompleted
    case deadlinePassed
    case grantRevoked
    case payloadMismatch
    case requestNotFound
    case invitationNotFound
    case ownerBindingNotActive
    case notYetApproved
}
