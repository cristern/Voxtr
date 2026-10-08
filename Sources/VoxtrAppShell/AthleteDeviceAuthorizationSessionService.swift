import Foundation
import VoxtrParentAuthentication

/// Athlete Connection V1 device-authorization session contract (§3,
/// §8 steps 4-5): the client for `device-session-challenge`/
/// `device-session-submit`, covering all four actions —
/// `session_issue`/`session_renew` (§8 step 4) and `hydration_get`/
/// `hydration_ack` (§8 step 5, issue #111). The hydration ORCHESTRATION
/// (mapping a successful `hydration_get` into the legacy CloudKit
/// payload shape and feeding `AthleteIdentityHydrationService
/// .hydrate(_:)`, ack-gated on that succeeding) lives in its own
/// separate type, `AthleteBackendHydrationAdapter` — this service
/// itself stays a pure wire client, same as its `session_issue`/
/// `session_renew` methods (see `AthleteDeviceAuthorizationSessionModels.swift`'s
/// own doc comment).
///
/// REUSES `VoxtrParentAuthentication`'s plain HTTP primitives and
/// `AthleteDeviceAuthorizationGatewayConfiguration`'s exact Supabase
/// gateway convention (`apikey`/`Authorization: Bearer <anon key>`,
/// never a Parent-session header) — matching
/// `AthleteDeviceAuthorizationService`'s own established shape
/// exactly. This is that service's SIBLING for the device-
/// authorization-session slice, never a replacement of its
/// connection-request/claim-proof responsibilities, and never named
/// the same (see this file's own family naming note).
///
/// Every call signs with `AthleteDeviceSigningKeyStoring
/// .loadExistingSigningKey()` — NEVER `loadOrCreateSigningKey()`. A
/// device-authorization session can only ever be issued/renewed for an
/// installation that already holds an established, granted key;
/// minting a replacement here would silently change this
/// installation's identity mid-session, which §3.4 point 3 and this
/// type's own contract forbid. A missing/orphaned key (reinstall)
/// throws `.signingKeyUnavailable` and sends no request — the caller
/// (`AthleteDeviceAuthorizationSessionManager`) decides what that means
/// for stored state; this service itself never clears or mutates
/// anything on disk.
///
/// `@MainActor`, matching `AthleteDeviceAuthorizationService`'s own
/// established convention for this codebase's networking service types.
@MainActor
public final class AthleteDeviceAuthorizationSessionService {
    private let configuration: ParentAuthenticationConfiguration
    private let gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration
    private let transport: ParentAuthenticationTransport
    private let signingKeyStore: AthleteDeviceSigningKeyStoring

    public init(
        configuration: ParentAuthenticationConfiguration,
        gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration,
        transport: ParentAuthenticationTransport = URLSessionParentAuthenticationTransport(),
        signingKeyStore: AthleteDeviceSigningKeyStoring = KeychainAthleteDeviceSigningKeyStore()
    ) {
        self.configuration = configuration
        self.gatewayConfiguration = gatewayConfiguration
        self.transport = transport
        self.signingKeyStore = signingKeyStore
    }

    /// Review round 4 (PR #116, ChatGPT review 6020919614): lets a
    /// caller check, BEFORE trusting or renewing a cached session
    /// record, whether THIS installation can still produce the signing
    /// key that record is bound to — mirrors
    /// `AthleteDeviceAuthorizationService`'s own identically-named
    /// method exactly (same `loadExistingSigningKey()` contract: never
    /// generates a replacement). Session Keychain material can survive
    /// an app reinstall even though the signing key's own installation
    /// marker did not (§3.4 point 3) — `AthleteDeviceAuthorizationSessionManager`
    /// calls this before ever returning or renewing a cached token, not
    /// only once a network call happens to need to sign something.
    public func currentInstallationHasExistingSigningKey() -> Bool {
        (try? signingKeyStore.loadExistingSigningKey()) != nil
    }

    // MARK: - session_issue

    /// Performs the full issue dance: `device-session-challenge` (no
    /// presented session — `session_issue` is never session-bound) →
    /// sign the resulting challenge with THIS installation's existing
    /// key → `device-session-submit`. Starts a brand-new renewal chain
    /// with its own fresh 90-day absolute clock (§3.3/§3.5), revoking
    /// any prior active session for this grant server-side in the same
    /// transaction. The caller decides WHEN to call this (no stored
    /// session, a rejected renewal, or the absolute cap reached) — this
    /// method itself has no policy of its own.
    /// `checkNotCancelled` (R6 follow-up, ChatGPT review 6025279987):
    /// called right after the challenge succeeds, BEFORE signing or
    /// submitting — `requestChallenge` and `submit` below are TWO
    /// separate network awaits inside this one call, and a caller-level
    /// guard checked only before/after the whole call cannot stop a
    /// stale operation's own SUBMIT (which has a real server-side
    /// effect: `session_issue` revokes the grant's current active
    /// session) from being sent if invalidation happens while this
    /// call is suspended between the two. Defaults to a no-op so every
    /// other caller is unaffected.
    public func issueSession(
        deviceGrantId: UUID,
        checkNotCancelled: () throws -> Void = {}
    ) async throws -> AthleteDeviceAuthorizationSessionIssueOutcome {
        let challengeOutcome = try await requestChallenge(deviceGrantId: deviceGrantId, action: .sessionIssue, sessionToken: nil)
        switch challengeOutcome {
        case .challengeNotAvailable:
            return .grantNotAvailable
        case .sessionInvalid:
            // Unreachable in practice: session_issue is never
            // session-bound, so the backend never returns this for
            // this action. Folded the same as an unavailable grant
            // rather than treated as a crash-worthy impossible case.
            return .grantNotAvailable
        case .issued(let challengeId, let nonce, _):
            try checkNotCancelled()
            let message = AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(
                action: .sessionIssue, deviceGrantId: deviceGrantId, challengeId: challengeId, nonce: nonce
            )
            let signature = try sign(message)
            let submitOutcome = try await submit(
                deviceGrantId: deviceGrantId, action: .sessionIssue, challengeId: challengeId,
                signature: signature, sessionToken: nil
            )
            switch submitOutcome {
            case .issued(let sessionToken, let expiresAt, let absoluteExpiresAt):
                return .issued(sessionToken: sessionToken, expiresAt: expiresAt, absoluteExpiresAt: absoluteExpiresAt)
            case .renewed:
                throw AthleteDeviceAuthorizationSessionError.malformedResponse
            case .notAvailable:
                return .notAvailable
            }
        }
    }

    // MARK: - session_renew

    /// Rotates the SAME already-held bearer token's `expires_at`
    /// (clamped server-side to `absolute_expires_at`) — never mints a
    /// new token. Requires a fresh signature every call (§3.4 point 2:
    /// "never bearer-token possession alone").
    public func renewSession(
        deviceGrantId: UUID,
        sessionToken: String,
        checkNotCancelled: () throws -> Void = {}
    ) async throws -> AthleteDeviceAuthorizationSessionRenewOutcome {
        let challengeOutcome = try await requestChallenge(deviceGrantId: deviceGrantId, action: .sessionRenew, sessionToken: sessionToken)
        switch challengeOutcome {
        case .challengeNotAvailable:
            return .grantNotAvailable
        case .sessionInvalid:
            return .sessionInvalid
        case .issued(let challengeId, let nonce, _):
            try checkNotCancelled()
            let message = AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(
                action: .sessionRenew, deviceGrantId: deviceGrantId, challengeId: challengeId, nonce: nonce
            )
            let signature = try sign(message)
            let submitOutcome = try await submit(
                deviceGrantId: deviceGrantId, action: .sessionRenew, challengeId: challengeId,
                signature: signature, sessionToken: sessionToken
            )
            switch submitOutcome {
            case .renewed(let expiresAt, let absoluteExpiresAt):
                return .renewed(expiresAt: expiresAt, absoluteExpiresAt: absoluteExpiresAt)
            case .issued:
                throw AthleteDeviceAuthorizationSessionError.malformedResponse
            case .notAvailable:
                return .notAvailable
            }
        }
    }

    // MARK: - hydration_get

    /// Session-bound, exactly like `renewSession`: requires a valid,
    /// still-presented `sessionToken` AND a fresh signature over this
    /// call's own challenge — never bearer-token possession alone
    /// (§3.4 point 2). Returns the raw wire fields on `.hydrated`;
    /// mapping them into `AthleteConnectionInvitationCloudRecordPayload`
    /// and feeding `AthleteIdentityHydrationService.hydrate(_:)` is
    /// `AthleteBackendHydrationAdapter`'s own job, not this method's.
    public func getHydration(
        deviceGrantId: UUID,
        sessionToken: String,
        checkNotCancelled: () throws -> Void = {}
    ) async throws -> AthleteDeviceAuthorizationHydrationGetOutcome {
        let challengeOutcome = try await requestChallenge(deviceGrantId: deviceGrantId, action: .hydrationGet, sessionToken: sessionToken)
        switch challengeOutcome {
        case .challengeNotAvailable:
            return .grantNotAvailable
        case .sessionInvalid:
            return .sessionInvalid
        case .issued(let challengeId, let nonce, _):
            try checkNotCancelled()
            let message = AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(
                action: .hydrationGet, deviceGrantId: deviceGrantId, challengeId: challengeId, nonce: nonce
            )
            let signature = try sign(message)
            let submitOutcome = try await submit(
                deviceGrantId: deviceGrantId, action: .hydrationGet, challengeId: challengeId,
                signature: signature, sessionToken: sessionToken
            )
            switch submitOutcome {
            case .hydrated(let fields): return .hydrated(fields)
            case .notAvailable: return .notAvailable
            case .alreadyCompleted: return .alreadyCompleted
            case .deadlinePassed: return .deadlinePassed
            case .grantRevoked: return .grantRevoked
            case .issued, .renewed, .acked:
                throw AthleteDeviceAuthorizationSessionError.malformedResponse
            }
        }
    }

    // MARK: - hydration_ack

    /// Same session-bound shape as `getHydration` — a fresh signature
    /// every call, never a repeat of the proof that obtained the
    /// payload. The caller (`AthleteBackendHydrationAdapter`) must only
    /// ever call this AFTER `AthleteIdentityHydrationService.hydrate(_:)`
    /// has already returned successfully for the payload this exact
    /// session's `getHydration` call produced (§4.3: "`hydration-ack`
    /// is called only after `hydrate(...)` completes successfully end
    /// to end").
    public func ackHydration(
        deviceGrantId: UUID,
        sessionToken: String,
        checkNotCancelled: () throws -> Void = {}
    ) async throws -> AthleteDeviceAuthorizationHydrationAckOutcome {
        let challengeOutcome = try await requestChallenge(deviceGrantId: deviceGrantId, action: .hydrationAck, sessionToken: sessionToken)
        switch challengeOutcome {
        case .challengeNotAvailable:
            return .grantNotAvailable
        case .sessionInvalid:
            return .sessionInvalid
        case .issued(let challengeId, let nonce, _):
            try checkNotCancelled()
            let message = AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(
                action: .hydrationAck, deviceGrantId: deviceGrantId, challengeId: challengeId, nonce: nonce
            )
            let signature = try sign(message)
            let submitOutcome = try await submit(
                deviceGrantId: deviceGrantId, action: .hydrationAck, challengeId: challengeId,
                signature: signature, sessionToken: sessionToken
            )
            switch submitOutcome {
            case .acked: return .acked
            case .notAvailable: return .notAvailable
            case .alreadyCompleted: return .alreadyCompleted
            case .deadlinePassed: return .deadlinePassed
            case .grantRevoked: return .grantRevoked
            case .issued, .renewed, .hydrated:
                throw AthleteDeviceAuthorizationSessionError.malformedResponse
            }
        }
    }

    private func sign(_ message: Data) throws -> Data {
        let signingKey: AthleteDeviceSigningKey
        do {
            signingKey = try signingKeyStore.loadExistingSigningKey()
        } catch {
            throw AthleteDeviceAuthorizationSessionError.signingKeyUnavailable
        }
        do {
            return try signingKey.signature(for: message)
        } catch {
            throw AthleteDeviceAuthorizationSessionError.signingKeyUnavailable
        }
    }

    // MARK: - device-session-challenge

    private func requestChallenge(
        deviceGrantId: UUID,
        action: AthleteDeviceAuthorizationSessionAction,
        sessionToken: String?
    ) async throws -> AthleteDeviceAuthorizationSessionChallengeOutcome {
        var request = try makeGatewayRequest(path: "device-session-challenge")
        request.httpBody = try encode(DeviceSessionChallengeRequestBody(
            deviceGrantId: deviceGrantId.uuidString,
            action: action.rawValue,
            sessionToken: sessionToken
        ))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw AthleteDeviceAuthorizationSessionError.network }
        let decoded = try decode(DeviceSessionChallengeResponseBody.self, from: data)
        return try Self.mapChallengeOutcome(decoded)
    }

    // MARK: - device-session-submit

    private func submit(
        deviceGrantId: UUID,
        action: AthleteDeviceAuthorizationSessionAction,
        challengeId: UUID,
        signature: Data,
        sessionToken: String?
    ) async throws -> SubmitOutcome {
        var request = try makeGatewayRequest(path: "device-session-submit")
        request.httpBody = try encode(DeviceSessionSubmitRequestBody(
            deviceGrantId: deviceGrantId.uuidString,
            action: action.rawValue,
            challengeId: challengeId.uuidString,
            signature: Self.base64UrlEncode(signature),
            sessionToken: sessionToken
        ))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw AthleteDeviceAuthorizationSessionError.network }
        let decoded = try decode(DeviceSessionSubmitResponseBody.self, from: data)
        return try Self.mapSubmitOutcome(decoded)
    }

    /// Internal-only shape covering every action's wire outcomes before
    /// the caller above narrows to its own action-specific public
    /// outcome type — each public method throws `.malformedResponse` if
    /// another action's shape comes back, which should never happen
    /// since each only ever submits its own `action` value.
    private enum SubmitOutcome {
        case issued(sessionToken: String, expiresAt: Date, absoluteExpiresAt: Date)
        case renewed(expiresAt: Date, absoluteExpiresAt: Date)
        case hydrated(AthleteDeviceAuthorizationHydrationFields)
        case acked
        case alreadyCompleted
        case deadlinePassed
        case grantRevoked
        case notAvailable
    }

    // MARK: - Wire mapping

    private static func mapChallengeOutcome(_ body: DeviceSessionChallengeResponseBody) throws -> AthleteDeviceAuthorizationSessionChallengeOutcome {
        switch body.outcome {
        case "issued":
            guard
                let rawChallengeId = body.challengeId, let challengeId = UUID(uuidString: rawChallengeId),
                let rawNonce = body.nonce, let nonce = Self.base64UrlDecode(rawNonce), nonce.count == Self.expectedNonceByteCount,
                let rawExpiresAt = body.expiresAt, let expiresAt = Self.parseISO8601(rawExpiresAt)
            else {
                throw AthleteDeviceAuthorizationSessionError.malformedResponse
            }
            return .issued(challengeId: challengeId, nonce: nonce, expiresAt: expiresAt)
        case "challenge_not_available": return .challengeNotAvailable
        case "session_invalid": return .sessionInvalid
        default:
            throw AthleteDeviceAuthorizationSessionError.malformedResponse
        }
    }

    private static func mapSubmitOutcome(_ body: DeviceSessionSubmitResponseBody) throws -> SubmitOutcome {
        switch body.outcome {
        case "issued":
            guard
                let sessionToken = body.sessionToken, !sessionToken.isEmpty,
                let rawExpiresAt = body.expiresAt, let expiresAt = Self.parseISO8601(rawExpiresAt),
                let rawAbsolute = body.absoluteExpiresAt, let absoluteExpiresAt = Self.parseISO8601(rawAbsolute)
            else {
                throw AthleteDeviceAuthorizationSessionError.malformedResponse
            }
            return .issued(sessionToken: sessionToken, expiresAt: expiresAt, absoluteExpiresAt: absoluteExpiresAt)
        case "renewed":
            guard
                let rawExpiresAt = body.expiresAt, let expiresAt = Self.parseISO8601(rawExpiresAt),
                let rawAbsolute = body.absoluteExpiresAt, let absoluteExpiresAt = Self.parseISO8601(rawAbsolute)
            else {
                throw AthleteDeviceAuthorizationSessionError.malformedResponse
            }
            return .renewed(expiresAt: expiresAt, absoluteExpiresAt: absoluteExpiresAt)
        case "hydrated":
            guard
                let workspaceIdRaw = body.workspaceId, let workspaceId = UUID(uuidString: workspaceIdRaw),
                let intendedParticipantIdRaw = body.intendedParticipantId, let intendedParticipantId = UUID(uuidString: intendedParticipantIdRaw),
                let intendedAthleteIdRaw = body.intendedAthleteId, let intendedAthleteId = UUID(uuidString: intendedAthleteIdRaw),
                let parentIdRaw = body.parentId, let parentId = UUID(uuidString: parentIdRaw),
                let parentGivenName = body.parentGivenName, !parentGivenName.isEmpty,
                let workspaceDisplayName = body.workspaceDisplayName, !workspaceDisplayName.isEmpty,
                let ownerParticipantIdRaw = body.ownerParticipantId, let ownerParticipantId = UUID(uuidString: ownerParticipantIdRaw),
                let athleteGivenName = body.athleteGivenName, !athleteGivenName.isEmpty,
                let athleteBirthDateISO = body.athleteBirthDateIso,
                let athleteTimeZoneId = body.athleteTimeZoneId,
                let athleteDevelopmentStage = body.athleteDevelopmentStage
            else {
                throw AthleteDeviceAuthorizationSessionError.malformedResponse
            }
            return .hydrated(AthleteDeviceAuthorizationHydrationFields(
                workspaceId: workspaceId,
                intendedParticipantId: intendedParticipantId,
                intendedAthleteId: intendedAthleteId,
                parentId: parentId,
                parentGivenName: parentGivenName,
                workspaceDisplayName: workspaceDisplayName,
                ownerParticipantId: ownerParticipantId,
                athleteGivenName: athleteGivenName,
                athleteBirthDateISO: athleteBirthDateISO,
                athleteTimeZoneId: athleteTimeZoneId,
                athleteDevelopmentStage: athleteDevelopmentStage
            ))
        case "acked": return .acked
        case "already_completed": return .alreadyCompleted
        case "deadline_passed": return .deadlinePassed
        case "grant_revoked": return .grantRevoked
        case "not_available": return .notAvailable
        default:
            throw AthleteDeviceAuthorizationSessionError.malformedResponse
        }
    }

    /// Exactly matches `device-session-challenge/index.ts`'s own
    /// `NONCE_LENGTH_BYTES = 32`.
    static let expectedNonceByteCount = 32

    /// Same rationale as `AthleteDeviceAuthorizationService`'s own
    /// `parseISO8601`: these wire DTOs keep timestamps as `String` and
    /// parse explicitly, tolerating both with- and without-fractional-
    /// seconds ISO 8601.
    private static func parseISO8601(_ string: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

    /// Reuses `AthleteDeviceAuthorizationService`'s own base64url
    /// encode/decode exactly — both services live in the same module
    /// and target the identical RFC 4648 §5 (no padding) wire
    /// convention; a second implementation here would be a duplicate
    /// of logic already proven against the backend's own
    /// `_shared/base64url.ts` (see `AthleteConnectionCrossImplementationFixtureTests`).
    static func base64UrlEncode(_ data: Data) -> String {
        AthleteDeviceAuthorizationService.base64UrlEncode(data)
    }

    static func base64UrlDecode(_ string: String) -> Data? {
        AthleteDeviceAuthorizationService.base64UrlDecode(string)
    }

    // MARK: - HTTP plumbing

    /// Same gateway credential pair as every other Athlete-facing
    /// endpoint in this codebase (see `AthleteDeviceAuthorizationGatewayConfiguration`'s
    /// own doc comment) — fails closed, before any network attempt, if
    /// the anon key is empty.
    private func makeGatewayRequest(path: String) throws -> URLRequest {
        guard !gatewayConfiguration.anonKey.isEmpty else {
            throw AthleteDeviceAuthorizationSessionError.gatewayConfigurationMissing
        }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(gatewayConfiguration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(gatewayConfiguration.anonKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw AthleteDeviceAuthorizationSessionError.network
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AthleteDeviceAuthorizationSessionError.malformedResponse
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            return try encoder.encode(value)
        } catch {
            throw AthleteDeviceAuthorizationSessionError.malformedResponse
        }
    }
}

private struct DeviceSessionChallengeRequestBody: Encodable {
    let deviceGrantId: String
    let action: String
    let sessionToken: String?
}

private struct DeviceSessionChallengeResponseBody: Decodable {
    let outcome: String
    let challengeId: String?
    let nonce: String?
    let expiresAt: String?
}

private struct DeviceSessionSubmitRequestBody: Encodable {
    let deviceGrantId: String
    let action: String
    let challengeId: String
    let signature: String
    let sessionToken: String?
}

private struct DeviceSessionSubmitResponseBody: Decodable {
    let outcome: String
    let sessionToken: String?
    let expiresAt: String?
    let absoluteExpiresAt: String?
    // Hydration fields (§4, issue #111) — present only when outcome ==
    // "hydrated". Wire keys have NO "hydration_" prefix (unlike the SQL
    // RETURNS TABLE columns/bridge's own internal naming) — confirmed
    // directly against `device-session-submit/index.ts`'s own
    // `jsonResponse` call for the "hydrated" branch.
    let workspaceId: String?
    let intendedParticipantId: String?
    let intendedAthleteId: String?
    let parentId: String?
    let parentGivenName: String?
    let workspaceDisplayName: String?
    let ownerParticipantId: String?
    let athleteGivenName: String?
    /// Named to match `.convertFromSnakeCase`'s ACTUAL transform, not
    /// `AthleteConnectionInvitationCloudRecordPayload.athleteBirthDateISO`'s
    /// all-caps convention: that strategy title-cases each component
    /// after an underscore via `String.capitalized`, so the wire key
    /// `athlete_birth_date_iso` decodes to `athleteBirthDateIso`
    /// (capital I, lowercase "so") — never `athleteBirthDateISO`.
    /// Naming this property anything else would silently decode to
    /// `nil` every time. `mapSubmitOutcome` below bridges to the
    /// all-caps public field name explicitly.
    let athleteBirthDateIso: String?
    let athleteTimeZoneId: String?
    let athleteDevelopmentStage: String?
}
