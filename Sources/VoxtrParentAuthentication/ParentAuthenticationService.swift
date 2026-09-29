import Foundation

/// Athlete Connection V1 — the SIWA handshake orchestration, session
/// lifecycle, and existing-workspace enrollment redemption calls. This
/// is the ONE type in this package that talks to the backend; see
/// cristern/Voxtr Docs/Architecture/AthleteConnectionV1-
/// ParentAuthenticationContract.md §§1-2, 5-6 for the full contract
/// this implements, and the actual merged backend handlers (`auth-nonce`,
/// `parent-auth-complete`, `parent-session-refresh`, `parent-session-
/// revoke`, `workspace-enrollment-redeem` in `cristern/Voxtr-Backend`)
/// for the exact wire shapes below — deliberately read from the actual
/// merged source, not inferred from an earlier proposal.
///
/// `@MainActor`, matching this codebase's own established convention
/// for its service-layer classes (`ParentWorkspaceRepository`,
/// `CompositionRoot`, every `*Service`/`*Coordinator` in
/// `VoxtrAppShell`) rather than introducing a new isolation pattern.
/// SwiftUI's own `View.body`/action closures are themselves `@MainActor`
/// by the `View` protocol's own declaration, so this requires no extra
/// hopping from `ParentEnrollmentView`.
///
/// Every method below is intentionally `internal`, not `public` — the
/// only PUBLIC surface this package exposes is `ParentEnrollmentView`
/// (which lives in this same target and therefore can call these
/// freely) and this initializer, matching this codebase's own
/// established "internal on purpose, reachable only via `@testable
/// import`" pattern (see `ParentWorkspaceRepository`'s own
/// `saveOverride` seams) for exactly this reason: deterministic tests
/// exercise this orchestration logic directly, with a fake transport
/// and a fake session store, never through the real view or real
/// network/Apple boundary.
@MainActor
public final class ParentAuthenticationService {
    private let configuration: ParentAuthenticationConfiguration
    private let transport: ParentAuthenticationTransport
    private let sessionStore: ParentSessionStoring

    public init(
        configuration: ParentAuthenticationConfiguration,
        transport: ParentAuthenticationTransport = URLSessionParentAuthenticationTransport(),
        sessionStore: ParentSessionStoring = KeychainParentSessionStore()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sessionStore = sessionStore
    }

    // MARK: - Session state

    /// Whether a session token is currently stored — this is NOT a
    /// claim that the token is still valid/fresh server-side (only the
    /// backend is authoritative for that, per §2.6); it only reflects
    /// local Keychain state.
    func isSignedIn() -> Bool {
        sessionStore.loadToken() != nil
    }

    /// Clears the local token regardless of whether the network call
    /// completes — per this task's own explicit requirement: "Revoke/
    /// sign-out clears the local token even if the network request
    /// cannot complete, with a truthful user state." The revoke call is
    /// still attempted (best-effort server-side cleanup), but its
    /// result never gates the local clear.
    func signOut() async {
        guard let token = sessionStore.loadToken() else { return }
        var request = makeRequest(path: "parent-session-revoke")
        request.setValue(token, forHTTPHeaderField: parentSessionHeaderName)
        _ = try? await transport.send(request)
        sessionStore.deleteToken()
    }

    // MARK: - Step 1: begin the SIWA handshake

    /// Fetches a fresh, single-use nonce from `auth-nonce` and computes
    /// the exact hash `ASAuthorizationAppleIDRequest.nonce` must be set
    /// to (§1.2/§1.3). The caller (a SwiftUI view using the real
    /// `SignInWithAppleButton`) must call this BEFORE presenting the
    /// button, since `onRequest` is a synchronous callback that cannot
    /// itself await a network call.
    func beginSignIn() async throws -> PendingSiwaHandshake {
        let request = makeRequest(path: "auth-nonce")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw ParentAuthenticationError.network }
        let decoded = try decode(AuthNonceResponseBody.self, from: data)
        let hashedNonce = SiwaNonceHashing.hashedNonceHex(forRawNonce: decoded.nonce)
        return PendingSiwaHandshake(nonceId: decoded.nonceId, hashedNonceHex: hashedNonce)
    }

    // MARK: - Step 2: complete the SIWA handshake

    /// Completes the handshake begun by `beginSignIn()`, sending ONLY
    /// `nonce_id` and Apple's identity token — never a client-selected
    /// expected nonce of any kind (§1.4). On `.authenticated`, the new
    /// opaque session token REPLACES whatever was previously stored,
    /// atomically (see `KeychainParentSessionStore.saveToken`) — this is
    /// always a brand-new session, never an "upgrade" of an existing
    /// one (§2.2), so this is the correct behavior whether this is a
    /// first-ever sign-in or a fresh handshake performed to satisfy
    /// `reauthenticationRequired` (§2.6).
    func completeSignIn(
        handshake: PendingSiwaHandshake,
        credential: AppleIdentityCredential
    ) async throws -> SignInOutcome {
        var request = makeRequest(path: "parent-auth-complete")
        request.httpBody = try encode(ParentAuthCompleteRequestBody(
            nonceId: handshake.nonceId,
            appleIdentityToken: credential.identityToken
        ))
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw ParentAuthenticationError.network }
        let decoded = try decode(ParentAuthCompleteResponseBody.self, from: data)
        switch decoded.outcome {
        case "authenticated":
            guard let token = decoded.sessionToken else {
                throw ParentAuthenticationError.malformedResponse
            }
            try sessionStore.saveToken(token)
            return .authenticated
        case "authentication_failed":
            return .authenticationFailed
        default:
            throw ParentAuthenticationError.malformedResponse
        }
    }

    // MARK: - Refresh (rotation)

    /// Rotates the current session via `parent-session-refresh`,
    /// replacing the stored token atomically on success. Returns
    /// `false` — never throws — for every rejection (`session_invalid`/
    /// `absolute_lifetime_exceeded`/`session_expired`, or no session
    /// stored at all): the ONLY correct response to any of these is a
    /// full new SIWA handshake (§2.4's own "lost-response recovery"
    /// framing), and this method deliberately does not distinguish
    /// which one occurred, since every caller's next step is identical
    /// either way. This method never renews authentication FRESHNESS
    /// (§2.6) — `authenticated_at` is preserved server-side, unchanged,
    /// by design; this only extends how long the session credential
    /// itself remains valid.
    @discardableResult
    func refreshSessionIfPossible() async -> Bool {
        guard let token = sessionStore.loadToken() else { return false }
        var request = makeRequest(path: "parent-session-refresh")
        request.setValue(token, forHTTPHeaderField: parentSessionHeaderName)
        guard let (data, response) = try? await transport.send(request) else { return false }
        guard
            response.statusCode == 200,
            let decoded = try? decode(ParentSessionRefreshResponseBody.self, from: data),
            decoded.outcome == "rotated",
            let newToken = decoded.sessionToken
        else {
            return false
        }
        try? sessionStore.saveToken(newToken)
        return true
    }

    // MARK: - Existing-workspace enrollment redemption

    /// Submits `code` for `workspace.id` via `workspace-enrollment-
    /// redeem`, with the current session in the `X-Voxtr-Parent-Session`
    /// header. The backend alone decides whether a binding exists or
    /// can be created (§5) — this method neither infers nor asserts
    /// ownership itself, only relays `workspace.id` (the stable
    /// `FamilyWorkspace.workspaceId` the caller already holds locally)
    /// and the code exactly as entered.
    ///
    /// Throws `ParentAuthenticationError.sessionInvalid`/`.sessionExpired`
    /// for a token that no longer works at all (cleared locally before
    /// throwing, so a subsequent `isSignedIn()` correctly reports
    /// `false`) and `.reauthenticationRequired` for a session that is
    /// still live but stale for this SENSITIVE operation specifically
    /// (§2.6) — that token is deliberately left in place; only a fresh
    /// SIWA handshake, never a refresh, can satisfy it.
    func redeemEnrollment(workspace: EnrollableWorkspace, code: String) async throws -> RedemptionOutcome {
        guard let token = sessionStore.loadToken() else {
            throw ParentAuthenticationError.notSignedIn
        }
        var request = makeRequest(path: "workspace-enrollment-redeem")
        request.setValue(token, forHTTPHeaderField: parentSessionHeaderName)
        request.httpBody = try encode(WorkspaceEnrollmentRedeemRequestBody(
            workspaceId: workspace.id.uuidString,
            code: code
        ))
        let (data, response) = try await transport.send(request)

        if response.statusCode == 401 {
            let decoded = try? decode(ErrorResponseBody.self, from: data)
            switch decoded?.error {
            case "session_invalid":
                sessionStore.deleteToken()
                throw ParentAuthenticationError.sessionInvalid
            case "session_expired":
                sessionStore.deleteToken()
                throw ParentAuthenticationError.sessionExpired
            case "reauthentication_required":
                throw ParentAuthenticationError.reauthenticationRequired
            default:
                // "unauthenticated" (header rejected outright) or any
                // other unrecognized value — this call always attaches
                // a real header, so this path means the stored token
                // itself is no good; fail closed the same way an
                // explicit session_invalid would.
                sessionStore.deleteToken()
                throw ParentAuthenticationError.sessionInvalid
            }
        }

        guard response.statusCode == 200 else { throw ParentAuthenticationError.network }
        let decoded = try decode(WorkspaceEnrollmentRedeemResponseBody.self, from: data)
        return try Self.mapRedemptionOutcome(decoded)
    }

    // MARK: - Wire mapping

    private static func mapRedemptionOutcome(_ body: WorkspaceEnrollmentRedeemResponseBody) throws -> RedemptionOutcome {
        func requireOwnerBindingId() throws -> UUID {
            guard let raw = body.ownerBindingId, let id = UUID(uuidString: raw) else {
                throw ParentAuthenticationError.malformedResponse
            }
            return id
        }
        switch body.outcome {
        case "bound":
            return .bound(ownerBindingId: try requireOwnerBindingId())
        case "already_redeemed_same_parent":
            return .alreadyRedeemedBySameParent(ownerBindingId: try requireOwnerBindingId())
        case "binding_revoked":
            return .bindingRevoked(ownerBindingId: try requireOwnerBindingId())
        case "authorization_already_redeemed":
            return .authorizationAlreadyRedeemed
        case "workspace_already_bound":
            return .workspaceAlreadyBound
        case "inconsistent_state":
            return .inconsistentState
        case "authorization_not_available":
            return .authorizationNotAvailable
        default:
            throw ParentAuthenticationError.malformedResponse
        }
    }

    // MARK: - HTTP plumbing

    private let parentSessionHeaderName = "X-Voxtr-Parent-Session"

    private func makeRequest(path: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ParentAuthenticationError.malformedResponse
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            return try encoder.encode(value)
        } catch {
            throw ParentAuthenticationError.malformedResponse
        }
    }
}

// MARK: - Wire DTOs (internal — this file is the only thing that ever sees these)

private struct AuthNonceResponseBody: Decodable, Sendable {
    let nonceId: String
    let nonce: String
    let expiresAt: String
}

private struct ParentAuthCompleteRequestBody: Encodable, Sendable {
    let nonceId: String
    let appleIdentityToken: String
}

private struct ParentAuthCompleteResponseBody: Decodable, Sendable {
    let outcome: String
    let sessionToken: String?
    let expiresAt: String?
    let authenticatedAt: String?
}

private struct ParentSessionRefreshResponseBody: Decodable, Sendable {
    let outcome: String
    let sessionToken: String?
    let expiresAt: String?
}

private struct WorkspaceEnrollmentRedeemRequestBody: Encodable, Sendable {
    let workspaceId: String
    let code: String
}

private struct WorkspaceEnrollmentRedeemResponseBody: Decodable, Sendable {
    let outcome: String
    let ownerBindingId: String?
}

private struct ErrorResponseBody: Decodable, Sendable {
    let error: String?
}
