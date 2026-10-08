import Foundation

/// Athlete Connection V1 device-authorization session contract (§3 of
/// `Docs/Architecture/AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md`).
///
/// NAMING: every type in this family is named
/// `AthleteDeviceAuthorizationSession...`, deliberately distinct from
/// `AthleteRuntimeSession` (`Sources/VoxtrAppShell/AthleteRuntimeSession.swift`,
/// Foundation B2.5) — that type is the unrelated CKShare-acceptance
/// runtime-presence holder (`CurrentSessionActor`); this contract's own
/// §0 naming note is explicit that the two are different, already-
/// shipped-vs-new concepts and must never be conflated.
///
/// SCOPE: this file and its siblings (`AthleteDeviceAuthorizationSessionService.swift`,
/// `AthleteDeviceAuthorizationSessionStore.swift`,
/// `AthleteDeviceAuthorizationSessionManager.swift`) originally
/// implemented only `session_issue`/`session_renew` end to end (§8 step
/// 4 of the contract). `hydration_get`/`hydration_ack` (§8 step 5,
/// issue #111) share the exact same wire family — challenge issuance,
/// canonical message shape, the `device-session-submit` transaction —
/// so `AthleteDeviceAuthorizationSessionService` now implements all
/// four actions in one place; only the domain hydration ORCHESTRATION
/// (mapping a successful `hydration_get` into
/// `AthleteConnectionInvitationCloudRecordPayload` and feeding
/// `AthleteIdentityHydrationService.hydrate(_:)`, ack-gated on that
/// succeeding) lives in its own separate type, `AthleteBackendHydrationAdapter`.
enum AthleteDeviceAuthorizationSessionAction: String, Sendable, Equatable, CaseIterable {
    case sessionIssue = "session_issue"
    case sessionRenew = "session_renew"
    case hydrationGet = "hydration_get"
    case hydrationAck = "hydration_ack"

    /// Explicit lookup table, never a literal template substitution of
    /// `rawValue` — the contract's own §3.3 and backend
    /// `_shared/canonicalMessage.ts`'s `DEVICE_SESSION_VERSION_LINES`
    /// both call out that `authz.device_session_challenges.action` is
    /// underscore-spelled (`session_issue`) while the SIGNED version
    /// line is hyphen-spelled (`session-issue`); interpolating
    /// `rawValue` directly would therefore produce different,
    /// non-interoperable bytes. This table is the Swift side of that
    /// exact backend table, not an independent re-derivation.
    var canonicalMessageVersionLine: String {
        switch self {
        case .sessionIssue: return "voxtr-athlete-session-issue-v1"
        case .sessionRenew: return "voxtr-athlete-session-renew-v1"
        case .hydrationGet: return "voxtr-athlete-hydration-get-v1"
        case .hydrationAck: return "voxtr-athlete-hydration-ack-v1"
        }
    }
}

/// The PRODUCTION canonical-message builder for the device-authorization-
/// session wire family — reused at RUNTIME by
/// `AthleteDeviceAuthorizationSessionService`, never a test-only
/// reimplementation. `Scripts/DeviceActions/sign.swift` (from PR #115)
/// is explicitly test-only (fixed scalar private keys, never used for a
/// real device installation) and is NOT this type; this type is what
/// actually signs on a real device.
///
/// Byte-exact mirror of backend `_shared/canonicalMessage.ts`'s
/// `buildDeviceSessionCanonicalMessageBytes`: four UTF-8 lines, each
/// terminated by `\n` including the last, concatenated with no other
/// separator; UUIDs lowercased regardless of input casing; nonce
/// base64url (RFC 4648 §5, no padding). Reuses
/// `AthleteDeviceAuthorizationService.base64UrlEncode` rather than a
/// second encoder — the existing claim-proof pattern this extends.
enum AthleteDeviceAuthorizationSessionCanonicalMessage {
    static func bytes(
        action: AthleteDeviceAuthorizationSessionAction,
        deviceGrantId: UUID,
        challengeId: UUID,
        nonce: Data
    ) -> Data {
        var text = "\(action.canonicalMessageVersionLine)\n"
        text += "device_grant_id=\(deviceGrantId.uuidString.lowercased())\n"
        text += "challenge_id=\(challengeId.uuidString.lowercased())\n"
        text += "nonce=\(AthleteDeviceAuthorizationService.base64UrlEncode(nonce))\n"
        return Data(text.utf8)
    }
}

// MARK: - Outcomes

/// `device-session-challenge`'s outcome family, scoped to what
/// `session_issue`/`session_renew` can actually receive back.
/// `sessionInvalid` is reachable only for `session_renew` (a
/// session-bound action) — the backend never returns it for
/// `session_issue`, which never presents a session token.
enum AthleteDeviceAuthorizationSessionChallengeOutcome: Equatable {
    case issued(challengeId: UUID, nonce: Data, expiresAt: Date)
    case challengeNotAvailable
    case sessionInvalid
}

/// `device-session-submit`'s outcome for `session_issue`. Confirmed
/// against `authz.device_session_submit`'s own source
/// (`20261005000000_authz_hydration_v1.sql`): for this action the only
/// reachable outcomes are `issued` and the generic `not_available`
/// fold — `grant_revoked`/`acked`/`already_completed`/`deadline_passed`
/// are reachable only for `hydration_get`/`hydration_ack`.
public enum AthleteDeviceAuthorizationSessionIssueOutcome: Equatable {
    case issued(sessionToken: String, expiresAt: Date, absoluteExpiresAt: Date)
    /// Folds an unknown `device_grant_id` and an inactive/revoked grant
    /// into one outcome, matching `challenge_not_available`'s own
    /// anti-enumeration fold at the challenge-issue step.
    case grantNotAvailable
    /// The generic `device-session-submit` fold: a race on the
    /// challenge (already used/expired), a binding no longer active,
    /// or — in practice unreachable for a signature this installation
    /// itself just produced — a signature mismatch. Callers retry with
    /// a fresh challenge, never treat this as a permanent failure on
    /// its own.
    case notAvailable
}

/// `device-session-submit`'s outcome for `session_renew`. `renewed`
/// never carries a new bearer token — the device keeps presenting the
/// SAME token it already holds; only `expiresAt`/`absoluteExpiresAt`
/// move (§3.3: "session_renew rotates the locked S's expires_at").
public enum AthleteDeviceAuthorizationSessionRenewOutcome: Equatable {
    case renewed(expiresAt: Date, absoluteExpiresAt: Date)
    /// The presented `session_token` is missing/expired/revoked —
    /// decided at the challenge-issue step, before any signature is
    /// even attempted.
    case sessionInvalid
    case grantNotAvailable
    case notAvailable
}

/// Athlete Connection V1 hydration lifecycle (§4, §8 step 5, issue
/// #111). Exactly the 11 §2.4 bootstrap fields, wire-decoded here as
/// plain `UUID`/`String` — deliberately NOT yet
/// `AthleteConnectionInvitationCloudRecordPayload` (that mapping, and
/// any date/timezone/stage parsing, is `AthleteBackendHydrationAdapter`'s
/// own job, reusing `AthleteIdentityHydrationService.hydrate(_:)`
/// unchanged — this type's only job is proving the wire response
/// actually carried all 11 fields).
public struct AthleteDeviceAuthorizationHydrationFields: Equatable, Sendable {
    public let workspaceId: UUID
    public let intendedParticipantId: UUID
    public let intendedAthleteId: UUID
    public let parentId: UUID
    public let parentGivenName: String
    public let workspaceDisplayName: String
    public let ownerParticipantId: UUID
    public let athleteGivenName: String
    public let athleteBirthDateISO: String
    public let athleteTimeZoneId: String
    public let athleteDevelopmentStage: String
}

/// `device-session-submit`'s outcome for `hydration_get`. Confirmed
/// against `authz.device_session_submit`'s own source
/// (`20261005000000_authz_hydration_v1.sql`): the permanent
/// `hydration_outcome` marker is checked FIRST inside the hydration
/// branch, so `.hydrated` is reachable only while that marker is still
/// `NULL` — `.alreadyCompleted`/`.deadlinePassed`/`.grantRevoked` are
/// never returned alongside a payload.
public enum AthleteDeviceAuthorizationHydrationGetOutcome: Equatable {
    case hydrated(AthleteDeviceAuthorizationHydrationFields)
    /// The presented `session_token` is missing/expired/revoked —
    /// decided at the challenge-issue step, same as `session_renew`
    /// (`hydration_get` is session-bound).
    case sessionInvalid
    case grantNotAvailable
    /// The generic `device-session-submit` security fold — including
    /// "nothing uploaded yet" (no `hydration_snapshots` row exists),
    /// a legitimate transient state, folded the same as every other
    /// non-security-sensitive "nothing to report yet" case elsewhere
    /// in this schema (migration's own §"WHY...NOT FOLDED" note).
    case notAvailable
    /// The permanent marker is `'acked'` — a previous `hydration_ack`
    /// already completed (possibly from an earlier, lost-response
    /// attempt this exact device made). Never represented as a newly
    /// delivered payload.
    case alreadyCompleted
    /// The permanent marker is `'expired'`, or the grant's own D2
    /// `recovery_deadline` has now passed — the fixed 24-hour deadline
    /// from grant creation, never a clock re-derived from upload/get.
    case deadlinePassed
    /// The permanent marker is `'revoked'`.
    case grantRevoked
}

/// `device-session-submit`'s outcome for `hydration_ack`. Mirrors
/// `AthleteDeviceAuthorizationHydrationGetOutcome`'s terminal-state
/// cases exactly — same permanent-marker vocabulary, same reasoning.
public enum AthleteDeviceAuthorizationHydrationAckOutcome: Equatable {
    case acked
    case sessionInvalid
    case grantNotAvailable
    case notAvailable
    /// A second `ack` against an already-tombstoned grant (§4.4) —
    /// idempotent success, never a failure: either THIS device's own
    /// earlier attempt's response was lost, or another resumed attempt
    /// already completed it. `AthleteBackendHydrationAdapter` treats
    /// this identically to `.acked`.
    case alreadyCompleted
    case deadlinePassed
    case grantRevoked
}

/// Every way a call into `AthleteDeviceAuthorizationSessionService` can
/// fail to even reach a business outcome — mirrors
/// `AthleteDeviceAuthorizationError`'s own vocabulary exactly, kept as
/// its own distinct type (never reused directly) so this file's own
/// family never silently inherits a vocabulary change made for the
/// unrelated claim-proof flow.
public enum AthleteDeviceAuthorizationSessionError: Error, Equatable {
    /// `loadExistingSigningKey()` failed — including the explicit "no
    /// key for this installation" case. A device-authorization session
    /// can only ever be issued/renewed for an installation that already
    /// holds an established, granted key; this is NEVER papered over by
    /// minting a replacement, which would silently change this
    /// installation's identity mid-session.
    case signingKeyUnavailable
    case gatewayConfigurationMissing
    case network
    case malformedResponse
}
