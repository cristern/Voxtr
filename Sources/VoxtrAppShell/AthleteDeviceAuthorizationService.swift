import Foundation
import VoxtrParentAuthentication

/// Athlete Connection V1 (backend device authorization): the ONE type
/// that talks to the backend from the ATHLETE side —
/// `connection-request-submit`, `claim-challenge`, `claim-submit`. All
/// three are UNAUTHENTICATED (no Parent session, no `X-Voxtr-Parent-
/// Session` header at all — see each handler's own `verify_jwt`
/// posture); this is the Athlete-side counterpart to
/// `ParentAuthenticationService`, deliberately a separate type with a
/// separate error vocabulary (see `AthleteDeviceAuthorizationModels.swift`),
/// never a Parent-session-flavored one.
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
    private let transport: ParentAuthenticationTransport
    private let signingKeyStore: AthleteDeviceSigningKeyStoring

    public init(
        configuration: ParentAuthenticationConfiguration,
        transport: ParentAuthenticationTransport = URLSessionParentAuthenticationTransport(),
        signingKeyStore: AthleteDeviceSigningKeyStoring = KeychainAthleteDeviceSigningKeyStore()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.signingKeyStore = signingKeyStore
    }

    // MARK: - connection-request-submit

    /// Submits this installation's OWN signing key's public half against
    /// `invitationId` — the endpoint an Athlete installation calls after
    /// scanning a Parent's device-authorization QR. Loads/creates this
    /// installation's own signing key first (same key reused across
    /// retries — see `AthleteDeviceSigningKeyStore`'s own doc comment).
    public func submitConnectionRequest(invitationId: UUID) async throws -> ConnectionRequestSubmissionOutcome {
        let signingKey = try loadSigningKey()
        var request = makeRequest(path: "connection-request-submit")
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
    /// distinguishable failure.
    public func requestClaimChallenge(connectionRequestId: UUID) async throws -> ClaimChallengeOutcome {
        var request = makeRequest(path: "claim-challenge")
        request.httpBody = try encode(ClaimChallengeRequestBody(connectionRequestId: connectionRequestId.uuidString))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw AthleteDeviceAuthorizationError.network }
        let decoded = try decode(ClaimChallengeResponseBody.self, from: data)
        return try Self.mapClaimChallengeOutcome(decoded)
    }

    // MARK: - claim-submit

    /// Builds the exact canonical message bytes
    /// `cristern/Voxtr-Backend`'s `_shared/canonicalMessage.ts` requires,
    /// signs them with THIS installation's own stored key, and submits
    /// the proof. `invitationId`/`connectionRequestId`/`challengeId`/
    /// `nonce` must be exactly the values the corresponding
    /// `claim-challenge` response carried — never re-derived or guessed.
    public func submitClaim(
        invitationId: UUID,
        connectionRequestId: UUID,
        challengeId: UUID,
        nonce: Data
    ) async throws -> ClaimOutcome {
        let signingKey = try loadSigningKey()
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

        var request = makeRequest(path: "claim-submit")
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

    private func loadSigningKey() throws -> AthleteDeviceSigningKey {
        do {
            return try signingKeyStore.loadOrCreateSigningKey()
        } catch {
            throw AthleteDeviceAuthorizationError.signingKeyUnavailable
        }
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
    // _shared/base64url.ts's own encode/decode exactly)

    static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64UrlDecode(_ string: String) -> Data? {
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
                let displayCode = body.displayCode
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
                let rawNonce = body.nonce, let nonce = Self.base64UrlDecode(rawNonce),
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

    private func makeRequest(path: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Wraps `transport.send` so every failure surfaces as this file's
    /// own `AthleteDeviceAuthorizationError.network` — `transport` is the
    /// REUSED `VoxtrParentAuthentication` transport type, whose own
    /// thrown error type is internal to that package and not nameable
    /// here; catching broadly and remapping keeps this service's own
    /// thrown error surface single-vocabulary for every caller.
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
