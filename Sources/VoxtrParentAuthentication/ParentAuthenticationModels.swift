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
enum ParentAuthenticationError: Error, Equatable, Sendable {
    case notSignedIn
    case sessionInvalid
    case sessionExpired
    case reauthenticationRequired
    case network
    case malformedResponse
}
