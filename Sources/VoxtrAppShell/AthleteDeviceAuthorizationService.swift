import Foundation
import VoxtrParentAuthentication

/// Where Supabase's own project gateway requires at least the anon
/// key, for the THREE Athlete-facing functions whose `verify_jwt` is
/// left at its default (`true`) — `connection-request-submit`,
/// `claim-challenge`, `claim-submit` (see `cristern/Voxtr-Backend`'s own
/// `supabase/config.toml` comments on those three functions, and
/// `tests/integration/postgrest_bridge_integration.ts`'s own
/// `apikey`/`authorization: Bearer <ANON_KEY>` header pair for the
/// tested pattern this mirrors exactly). This is Supabase's OWN gateway
/// gate, not a Vǫxtr credential of any kind — it carries no Parent
/// session, no service-role key, and no operator secret; those three
/// never belong on an Athlete-side call.
///
/// `anonKey` is deliberately just a plain string with NO safe default —
/// see `CompositionRoot`'s own local-development-only placeholder
/// comment for why a real hosted key is never committed here.
public struct AthleteDeviceAuthorizationGatewayConfiguration: Sendable {
    public let anonKey: String

    public init(anonKey: String) {
        self.anonKey = anonKey
    }
}

/// Athlete Connection V1 (backend device authorization): the ONE type
/// that talks to the backend from the ATHLETE side —
/// `connection-request-submit`, `claim-challenge`, `claim-submit`. None
/// of the three carry a Parent session (no `X-Voxtr-Parent-Session`
/// header at all) — this is the Athlete-side counterpart to
/// `ParentAuthenticationService`, deliberately a separate type with a
/// separate error vocabulary (see `AthleteDeviceAuthorizationModels.swift`),
/// never a Parent-session-flavored one. They DO require the ordinary
/// Supabase gateway `apikey`/`Authorization: Bearer <anon key>` pair —
/// see `AthleteDeviceAuthorizationGatewayConfiguration`'s own doc
/// comment for exactly why and where that's attached.
///
/// REUSES `VoxtrParentAuthentication`'s plain HTTP primitives
/// (`ParentAuthenticationConfiguration`, `ParentAuthenticationTransport`,
/// `URLSessionParentAuthenticationTransport`) — those three types carry
/// no Parent-session-specific behavior themselves (the session header is
/// added at `ParentAuthenticationService`'s own call sites, not baked
/// into the transport), so reusing them here avoids a second, duplicate
/// URLSession-wrapper/base-URL-holder pair purely for infrastructure
/// plumbing, per this codebase's own domain-ownership reuse rule.
///
/// Every payload/outcome below is derived directly from
/// `cristern/Voxtr-Backend`'s actual merged handler source and
/// `_shared/canonicalMessage.ts`/`p256.ts`/`base64url.ts` — not inferred
/// or copied from an earlier proposal.
///
/// `@MainActor`, matching `ParentAuthenticationService`'s own established
/// convention for this codebase's networking service types.
@MainActor
public final class AthleteDeviceAuthorizationService {
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

    // MARK: - connection-request-submit

    /// Submits this installation's OWN signing key's public half against
    /// `invitationId` — the endpoint an Athlete installation calls after
    /// scanning a Parent's device-authorization QR. This STARTS a new
    /// pairing attempt, so it uses `loadOrCreateSigningKey()` (may
    /// generate a fresh key for a new/reinstalled install) — never
    /// `loadExistingSigningKey()`, which is reserved for CONTINUING an
    /// attempt already bound to a specific key (see `submitClaim` below).
    public func submitConnectionRequest(invitationId: UUID) async throws -> ConnectionRequestSubmissionOutcome {
        let signingKey: AthleteDeviceSigningKey
        do {
            signingKey = try signingKeyStore.loadOrCreateSigningKey()
        } catch {
            throw AthleteDeviceAuthorizationError.signingKeyUnavailable
        }
        var request = try makeGatewayRequest(path: "connection-request-submit")
        request.httpBody = try encode(ConnectionRequestSubmitRequestBody(
            invitationId: invitationId.uuidString,
            devicePublicKey: Self.base64UrlEncode(signingKey.publicKeyX963Representation)
        ))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw AthleteDeviceAuthorizationError.network }
        let decoded = try decode(ConnectionRequestSubmitResponseBody.self, from: data)
        return try Self.mapSubmissionOutcome(decoded)
    }

    // MARK: - claim-challenge

    /// Requests a fresh, single-use claim challenge for
    /// `connectionRequestId`. The backend folds EVERY reason a challenge
    /// should not be issued yet (not found, still pending Parent
    /// approval, already claimed, etc.) into the same
    /// `.requestNotAvailable` outcome — this is the anti-enumeration fold
    /// the caller is expected to simply retry/poll against, never a
    /// distinguishable failure. Does not touch the signing key at all —
    /// issuing a challenge requires no signature yet.
    public func requestClaimChallenge(connectionRequestId: UUID) async throws -> ClaimChallengeOutcome {
        var request = try makeGatewayRequest(path: "claim-challenge")
        request.httpBody = try encode(ClaimChallengeRequestBody(connectionRequestId: connectionRequestId.uuidString))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw AthleteDeviceAuthorizationError.network }
        let decoded = try decode(ClaimChallengeResponseBody.self, from: data)
        return try Self.mapClaimChallengeOutcome(decoded)
    }

    // MARK: - claim-submit

    /// Builds the exact canonical message bytes
    /// `cristern/Voxtr-Backend`'s `_shared/canonicalMessage.ts` requires,
    /// signs them with THIS installation's own ALREADY-ESTABLISHED key,
    /// and submits the proof. This CONTINUES an attempt already bound to
    /// a specific key (the one `submitConnectionRequest` already
    /// submitted its public half of) — it uses `loadExistingSigningKey()`,
    /// which throws explicitly rather than creating a replacement if the
    /// key is missing or corrupt, so a known pairing attempt fails
    /// safely instead of silently signing with a mismatched new key.
    /// `invitationId`/`connectionRequestId`/`challengeId`/`nonce` must be
    /// exactly the values the corresponding `claim-challenge` response
    /// carried — never re-derived or guessed.
    public func submitClaim(
        invitationId: UUID,
        connectionRequestId: UUID,
        challengeId: UUID,
        nonce: Data
    ) async throws -> ClaimOutcome {
        let signingKey: AthleteDeviceSigningKey
        do {
            signingKey = try signingKeyStore.loadExistingSigningKey()
        } catch {
            throw AthleteDeviceAuthorizationError.signingKeyUnavailable
        }
        let message = Self.canonicalMessageBytes(
            challengeId: challengeId,
            requestId: connectionRequestId,
            invitationId: invitationId,
            nonce: nonce
        )
        let signatureBytes: Data
        do {
            signatureBytes = try signingKey.signature(for: message)
        } catch {
            throw AthleteDeviceAuthorizationError.signingKeyUnavailable
        }

        var request = try makeGatewayRequest(path: "claim-submit")
        request.httpBody = try encode(ClaimSubmitRequestBody(
            invitationId: invitationId.uuidString,
            connectionRequestId: connectionRequestId.uuidString,
            challengeId: challengeId.uuidString,
            signature: Self.base64UrlEncode(signatureBytes)
        ))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw AthleteDeviceAuthorizationError.network }
        let decoded = try decode(ClaimSubmitResponseBody.self, from: data)
        return try Self.mapClaimOutcome(decoded)
    }

    // MARK: - Canonical message (mirrors _shared/canonicalMessage.ts
    // exactly: five `\n`-terminated UTF-8 lines, including the last,
    // concatenated with no other separator; UUIDs lowercased)

    static func canonicalMessageBytes(challengeId: UUID, requestId: UUID, invitationId: UUID, nonce: Data) -> Data {
        var text = "voxtr-athlete-connection-claim-v1\n"
        text += "challenge_id=\(challengeId.uuidString.lowercased())\n"
        text += "request_id=\(requestId.uuidString.lowercased())\n"
        text += "invitation_id=\(invitationId.uuidString.lowercased())\n"
        text += "nonce=\(Self.base64UrlEncode(nonce))\n"
        return Data(text.utf8)
    }

    // MARK: - base64url (RFC 4648 §5, no padding — mirrors
    // _shared/base64url.ts's own encode/decode exactly, including its
    // own strict charset check BEFORE attempting to decode)

    static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: only the base64url alphabet (`A-Za-z0-9_-`) is accepted —
    /// matches `_shared/base64url.ts`'s own `decodeBase64Url`, which
    /// rejects embedded `+`/`/`/`=` or any other character up front
    /// rather than relying on a lenient underlying decoder's own
    /// behavior. Returns `nil` for anything that doesn't strictly match,
    /// never partially decodes.
    static func base64UrlDecode(_ string: String) -> Data? {
        guard !string.isEmpty, string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingNeeded = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: paddingNeeded)
        return Data(base64Encoded: base64)
    }

    // MARK: - Wire mapping

    private static func mapSubmissionOutcome(_ body: ConnectionRequestSubmitResponseBody) throws -> ConnectionRequestSubmissionOutcome {
        switch body.outcome {
        case "submitted":
            guard
                let rawId = body.connectionRequestId, let id = UUID(uuidString: rawId),
                let displayCode = body.displayCode, Self.isWellFormedDisplayCode(displayCode)
            else {
                throw AthleteDeviceAuthorizationError.malformedResponse
            }
            return .submitted(connectionRequestId: id, displayCode: displayCode)
        case "invitation_not_available": return .invitationNotAvailable
        case "invalid_device_key": return .invalidDeviceKey
        case "too_many_requests": return .tooManyRequests
        case "inconsistent_state": return .inconsistentState
        default:
            throw AthleteDeviceAuthorizationError.malformedResponse
        }
    }

    private static func mapClaimChallengeOutcome(_ body: ClaimChallengeResponseBody) throws -> ClaimChallengeOutcome {
        switch body.outcome {
        case "issued":
            guard
                let rawChallengeId = body.challengeId, let challengeId = UUID(uuidString: rawChallengeId),
                let rawNonce = body.nonce, let nonce = Self.base64UrlDecode(rawNonce), nonce.count == Self.expectedNonceByteCount,
                let rawExpiresAt = body.expiresAt, let expiresAt = Self.parseISO8601(rawExpiresAt)
            else {
                throw AthleteDeviceAuthorizationError.malformedResponse
            }
            return .issued(challengeId: challengeId, nonce: nonce, expiresAt: expiresAt)
        case "request_not_available":
            return .requestNotAvailable
        default:
            throw AthleteDeviceAuthorizationError.malformedResponse
        }
    }

    private static func mapClaimOutcome(_ body: ClaimSubmitResponseBody) throws -> ClaimOutcome {
        switch body.outcome {
        case "granted", "already_granted":
            guard
                let rawGrantId = body.grantId, let grantId = UUID(uuidString: rawGrantId),
                let rawDeadline = body.recoveryDeadline, let deadline = Self.parseISO8601(rawDeadline)
            else {
                throw AthleteDeviceAuthorizationError.malformedResponse
            }
            return body.outcome == "granted"
                ? .granted(grantId: grantId, recoveryDeadline: deadline)
                : .alreadyGranted(grantId: grantId, recoveryDeadline: deadline)
        case "invitation_not_found": return .invitationNotFound
        case "request_not_found": return .requestNotFound
        case "request_not_approved": return .requestNotApproved
        case "invitation_expired": return .invitationExpired
        case "invitation_claimed_by_other_request": return .invitationClaimedByOtherRequest
        case "grant_revoked": return .grantRevoked
        case "recovery_window_expired": return .recoveryWindowExpired
        case "inconsistent_state": return .inconsistentState
        case "challenge_invalid": return .challengeInvalid
        default:
            throw AthleteDeviceAuthorizationError.malformedResponse
        }
    }

    /// Exactly matches `authz.submit_connection_request`'s own
    /// generation: `upper(substr(replace(gen_random_uuid()::text, '-',
    /// ''), 1, 6))` — 6 uppercase hex characters, never anything else.
    static let expectedDisplayCodeLength = 6
    private static func isWellFormedDisplayCode(_ code: String) -> Bool {
        code.count == expectedDisplayCodeLength && code.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isLowercase }
    }

    /// Exactly matches `claim-challenge/index.ts`'s own
    /// `NONCE_LENGTH_BYTES = 32`.
    static let expectedNonceByteCount = 32

    /// Same rationale as `ParentAuthenticationService`'s own
    /// `parseISO8601`: these wire DTOs keep timestamps as `String` and
    /// parse explicitly here, tolerating both with- and
    /// without-fractional-seconds ISO 8601.
    private static func parseISO8601(_ string: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

    // MARK: - HTTP plumbing

    /// Builds the request AND attaches the Supabase gateway credential
    /// pair — throws immediately, before any network attempt, if
    /// `gatewayConfiguration.anonKey` is empty, rather than letting a
    /// request go out that the gateway can only ever reject. All three
    /// of this service's own endpoints need this pair (see this file's
    /// own `AthleteDeviceAuthorizationGatewayConfiguration` doc comment);
    /// none of them ever carry a Parent session, service-role key, or
    /// operator secret.
    private func makeGatewayRequest(path: String) throws -> URLRequest {
        guard !gatewayConfiguration.anonKey.isEmpty else {
            throw AthleteDeviceAuthorizationError.gatewayConfigurationMissing
        }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(gatewayConfiguration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(gatewayConfiguration.anonKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Wraps `transport.send` so every failure surfaces as this file's
    /// own `AthleteDeviceAuthorizationError.network` — `transport` is the
    /// REUSED `VoxtrParentAuthentication` transport type, whose own
    /// thrown error type is internal to that package and not nameable
    /// here; catching broadly and remapping keeps this service's own
    /// thrown error surface single-vocabulary for every caller. A caller
    /// that observes `.network` from `submitClaim` specifically cannot
    /// tell whether the backend received and processed the proof before
    /// the connection dropped — that ambiguity is inherent and must be
    /// handled by retrying with a FRESH challenge for the same request,
    /// never by resubmitting the connection request itself (see
    /// `AthleteDeviceAuthorizationPairingCoordinator`'s own recovery
    /// handling).
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw AthleteDeviceAuthorizationError.network
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AthleteDeviceAuthorizationError.malformedResponse
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            return try encoder.encode(value)
        } catch {
            throw AthleteDeviceAuthorizationError.malformedResponse
        }
    }
}

private struct ConnectionRequestSubmitRequestBody: Encodable {
    let invitationId: String
    let devicePublicKey: String
}

private struct ConnectionRequestSubmitResponseBody: Decodable {
    let outcome: String
    let connectionRequestId: String?
    let displayCode: String?
}

private struct ClaimChallengeRequestBody: Encodable {
    let connectionRequestId: String
}

private struct ClaimChallengeResponseBody: Decodable {
    let outcome: String
    let challengeId: String?
    let nonce: String?
    let expiresAt: String?
}

private struct ClaimSubmitRequestBody: Encodable {
    let invitationId: String
    let connectionRequestId: String
    let challengeId: String
    let signature: String
}

private struct ClaimSubmitResponseBody: Decodable {
    let outcome: String
    let grantId: String?
    let recoveryDeadline: String?
}
