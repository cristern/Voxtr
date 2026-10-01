import Foundation

/// Athlete Connection V1 (backend device authorization) — the Athlete
/// installation's own outcome families and errors. Deliberately separate
/// from `VoxtrParentAuthentication`'s models: this side is UNAUTHENTICATED
/// (no Parent session concept at all — see `connection-request-submit`/
/// `claim-challenge`/`claim-submit`'s own `verify_jwt` posture), so
/// nothing here borrows the Parent session-error vocabulary.

/// `connection-request-submit`'s outcome family (see
/// cristern/Voxtr-Backend's own `authzBridge.ts`
/// `SubmitConnectionRequestOutcome` for the authoritative wire set).
public enum ConnectionRequestSubmissionOutcome: Equatable {
    case submitted(connectionRequestId: UUID, displayCode: String)
    case invitationNotAvailable
    case invalidDeviceKey
    case tooManyRequests
    case inconsistentState
}

/// `claim-challenge`'s outcome family. `requestNotAvailable` is the
/// SAME anti-enumeration fold the backend uses for every reason a
/// challenge should not be issued yet (not found, not approved, already
/// claimed, etc.) — this client never tries to distinguish those cases,
/// matching the backend's own deliberate design.
public enum ClaimChallengeOutcome: Equatable {
    case issued(challengeId: UUID, nonce: Data, expiresAt: Date)
    case requestNotAvailable
}

/// `claim-submit`'s outcome family — mirrors `authzBridge.ts`'s own
/// `ClaimDeviceGrantOutcome` exactly, plus the handler's own
/// `challengeInvalidResponse()` anti-enumeration fold for every rejection
/// before a successful signature verification.
public enum ClaimOutcome: Equatable {
    case granted(grantId: UUID, recoveryDeadline: Date)
    case alreadyGranted(grantId: UUID, recoveryDeadline: Date)
    case invitationNotFound
    case requestNotFound
    case requestNotApproved
    case invitationExpired
    case invitationClaimedByOtherRequest
    case grantRevoked
    case recoveryWindowExpired
    case inconsistentState
    case challengeInvalid
}

/// Every way a call into `AthleteDeviceAuthorizationService` can fail to
/// even reach a business outcome.
public enum AthleteDeviceAuthorizationError: Error, Equatable {
    /// `loadOrCreateSigningKey()`/`loadExistingSigningKey()` failed —
    /// includes the explicit "no key for this known, already-submitted
    /// attempt" case (`AthleteDeviceSigningKeyStoreError
    /// .noKeyForCurrentInstallation`), never silently papered over by
    /// generating and continuing with a different key.
    case signingKeyUnavailable
    /// Review round 2: thrown BEFORE any network attempt when
    /// `AthleteDeviceAuthorizationGatewayConfiguration.anonKey` is empty
    /// — fails clearly instead of sending a request the Supabase gateway
    /// can only ever reject.
    case gatewayConfigurationMissing
    case network
    case malformedResponse
}
