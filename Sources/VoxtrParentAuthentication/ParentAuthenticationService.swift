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
    /// Bumped by every `signOut()` call. `completeSignIn(handshake:credential:)`
    /// and `refreshSessionIfPossible()` each capture this value before
    /// their own network `await`, and refuse to write a token back if it
    /// changed while they were suspended — the actor's own reentrancy
    /// means a `signOut()` call CAN interleave with either of those
    /// methods across an `await` point, and without this guard the
    /// in-flight call could resurrect a session the user just explicitly
    /// signed out of. See each method's own doc comment for the exact
    /// check.
    private var sessionGeneration = 0

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

    /// Clears the local token BEFORE attempting the network revoke call —
    /// per this task's own explicit requirement: the UI must never
    /// appear signed in during a slow or failed network call, so
    /// `isSignedIn()` reflects sign-out immediately, synchronously,
    /// before any `await`. The revoke call is still attempted
    /// (best-effort server-side cleanup) using the token captured before
    /// it was cleared, but its result never gates the local clear.
    ///
    /// Also bumps `sessionGeneration`, so a `completeSignIn`/
    /// `refreshSessionIfPossible` call already in flight when this runs
    /// cannot write a new token back afterward (see that field's own doc
    /// comment).
    ///
    /// Returns whether the server actually confirmed revocation —
    /// `true` when nothing needed revoking (no token was stored) or the
    /// revoke call returned 200, `false` when the network call failed or
    /// returned anything else. Callers must not claim server-side
    /// revocation succeeded when this returns `false`; the local token
    /// is cleared unconditionally either way.
    @discardableResult
    func signOut() async -> Bool {
        // Bumped unconditionally, even when there is no local token to
        // clear — an in-flight FIRST-TIME `completeSignIn` has no token
        // stored yet either (that's exactly what it's suspended trying
        // to write), so gating the bump on "a token existed" would miss
        // precisely that race. Sign-out always invalidates any
        // authentication attempt already in flight, regardless of
        // whether a stale token happened to exist locally when it ran.
        sessionGeneration += 1
        guard let token = sessionStore.loadToken() else { return true }
        sessionStore.deleteToken()
        var request = makeRequest(path: "parent-session-revoke")
        request.setValue(token, forHTTPHeaderField: parentSessionHeaderName)
        guard let (_, response) = try? await transport.send(request) else { return false }
        return response.statusCode == 200
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
        let generationAtStart = sessionGeneration
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
            // The backend really did authenticate this handshake and
            // hand back a live session — but if the user signed out
            // while this call was suspended on the network await above,
            // writing that session back locally would silently
            // resurrect a session the user just explicitly ended. Treat
            // it the same as an unsuccessful attempt from THIS caller's
            // perspective: nothing is persisted, and the newly-created
            // server-side session is simply left unused rather than
            // stored (see `sessionGeneration`'s own doc comment).
            guard generationAtStart == sessionGeneration else {
                return .authenticationFailed
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
        let generationAtStart = sessionGeneration
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
        // The user signed out while this call was suspended on the
        // network await above — the backend already rotated server-side
        // (orphaning the OLD token this call started with), but writing
        // the new one back now would resurrect a session the user just
        // explicitly ended. Discard it, same rationale as
        // `completeSignIn`'s own generation check.
        guard generationAtStart == sessionGeneration else { return false }
        do {
            try sessionStore.saveToken(newToken)
            return true
        } catch {
            // The backend already rotated server-side, orphaning the
            // token this call started with — if the replacement can't be
            // persisted locally, that old token is now dead everywhere.
            // Fail closed rather than keep presenting an invalid token
            // as signed-in: clear it so `isSignedIn()` correctly reports
            // `false` and the only path forward is a fresh SIWA
            // handshake.
            sessionStore.deleteToken()
            return false
        }
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

    // MARK: - Athlete Connection V1: invitation creation, request listing, decision

    /// Creates a new connection invitation for exactly the given
    /// `(workspaceId, participantId, athleteId)` triple — three opaque,
    /// already-resolved iOS-owned stable identifiers (the caller, in
    /// `VoxtrAppShell`, is responsible for resolving `participantId` to
    /// the intended athlete's own `WorkspaceParticipant.id`, exactly as
    /// `connection-invitation-create/index.ts`'s own header describes).
    /// This method neither infers nor validates their relationship to
    /// each other — the backend cannot either. SENSITIVE operation per
    /// the backend's own 10-minute freshness gate, so a stale-but-live
    /// session surfaces as `.reauthenticationRequired` without clearing
    /// the stored token — same shape as `redeemEnrollment`. `public`
    /// (unlike every other method in this class — see
    /// `ParentAuthenticationError`'s own updated doc comment for why):
    /// this method's real caller lives in `VoxtrAppShell`, not inside
    /// this package.
    public func createConnectionInvitation(
        workspaceId: UUID,
        participantId: UUID,
        athleteId: UUID
    ) async throws -> ConnectionInvitationCreationOutcome {
        guard let token = sessionStore.loadToken() else {
            throw ParentAuthenticationError.notSignedIn
        }
        var request = makeRequest(path: "connection-invitation-create")
        request.setValue(token, forHTTPHeaderField: parentSessionHeaderName)
        request.httpBody = try encode(ConnectionInvitationCreateRequestBody(
            workspaceId: workspaceId.uuidString,
            participantId: participantId.uuidString,
            athleteId: athleteId.uuidString
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
                sessionStore.deleteToken()
                throw ParentAuthenticationError.sessionInvalid
            }
        }

        guard response.statusCode == 200 else { throw ParentAuthenticationError.network }
        let decoded = try decode(ConnectionInvitationCreateResponseBody.self, from: data)
        return try Self.mapConnectionInvitationCreationOutcome(decoded)
    }

    /// Lists every connection request submitted against `invitationId` —
    /// ORDINARY operation (only ordinary session validity is required,
    /// never the 10-minute freshness gate), so unlike
    /// `createConnectionInvitation`/`decideConnectionRequest` a 401 here
    /// never means `.reauthenticationRequired`. `public` — same reason as
    /// `createConnectionInvitation`.
    public func listConnectionRequests(invitationId: UUID) async throws -> ConnectionRequestListOutcome {
        guard let token = sessionStore.loadToken() else {
            throw ParentAuthenticationError.notSignedIn
        }
        var request = makeRequest(path: "connection-request-list")
        request.setValue(token, forHTTPHeaderField: parentSessionHeaderName)
        request.httpBody = try encode(ConnectionRequestListRequestBody(invitationId: invitationId.uuidString))
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
            default:
                sessionStore.deleteToken()
                throw ParentAuthenticationError.sessionInvalid
            }
        }

        guard response.statusCode == 200 else { throw ParentAuthenticationError.network }
        let decoded = try decode(ConnectionRequestListResponseBody.self, from: data)
        return try Self.mapConnectionRequestListOutcome(decoded)
    }

    /// Approves or rejects exactly one connection request, carrying back
    /// the exact `displayCode` the Parent visually compared on screen —
    /// a selection consistency check, never authorization itself (see
    /// `connection-request-decide/index.ts`'s own header). SENSITIVE
    /// operation, same session-handling shape as
    /// `createConnectionInvitation`. `public` — same reason as that
    /// method.
    public func decideConnectionRequest(
        invitationId: UUID,
        connectionRequestId: UUID,
        decision: ConnectionRequestDecision,
        displayCode: String
    ) async throws -> ConnectionRequestDecisionOutcome {
        guard let token = sessionStore.loadToken() else {
            throw ParentAuthenticationError.notSignedIn
        }
        var request = makeRequest(path: "connection-request-decide")
        request.setValue(token, forHTTPHeaderField: parentSessionHeaderName)
        request.httpBody = try encode(ConnectionRequestDecideRequestBody(
            invitationId: invitationId.uuidString,
            connectionRequestId: connectionRequestId.uuidString,
            decision: decision.rawValue,
            displayCode: displayCode
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
                sessionStore.deleteToken()
                throw ParentAuthenticationError.sessionInvalid
            }
        }

        guard response.statusCode == 200 else { throw ParentAuthenticationError.network }
        let decoded = try decode(ConnectionRequestDecideResponseBody.self, from: data)
        return try Self.mapConnectionRequestDecisionOutcome(decoded)
    }

    /// Uploads the exact 11 §2.4 bootstrap fields for `connectionRequestId`
    /// via `hydration-upload` — the Parent-authenticated prerequisite
    /// runtime contract §4.2/the merged CloudKit transition plan §5.1
    /// describe. Every parameter is a raw, already-resolved identifier/
    /// string value — this method neither infers nor validates their
    /// relationship to each other, mirroring
    /// `createConnectionInvitation`'s own established convention; the
    /// caller (`ParentHydrationUploadService`, in `VoxtrAppShell`) owns
    /// resolving and FREEZING this exact payload once, at approval time,
    /// and must resend the IDENTICAL values on every retry — never
    /// recomputed from possibly-changed current profile data, per the
    /// backend's own same-byte-idempotent/different-byte-rejected
    /// contract (see `HydrationUploadOutcome`'s own doc comment).
    /// SENSITIVE operation per the backend's own 10-minute freshness
    /// gate, same session-handling shape as `createConnectionInvitation`/
    /// `decideConnectionRequest`. `public` — same reason as those two
    /// methods: this method's real caller lives in `VoxtrAppShell`.
    public func uploadHydration(
        connectionRequestId: UUID,
        workspaceId: UUID,
        intendedParticipantId: UUID,
        intendedAthleteId: UUID,
        parentId: UUID,
        parentGivenName: String,
        workspaceDisplayName: String,
        ownerParticipantId: UUID,
        athleteGivenName: String,
        athleteBirthDateIso: String,
        athleteTimeZoneId: String,
        athleteDevelopmentStage: String
    ) async throws -> HydrationUploadOutcome {
        guard let token = sessionStore.loadToken() else {
            throw ParentAuthenticationError.notSignedIn
        }
        var request = makeRequest(path: "hydration-upload")
        request.setValue(token, forHTTPHeaderField: parentSessionHeaderName)
        request.httpBody = try encode(HydrationUploadRequestBody(
            connectionRequestId: connectionRequestId.uuidString,
            workspaceId: workspaceId.uuidString,
            intendedParticipantId: intendedParticipantId.uuidString,
            intendedAthleteId: intendedAthleteId.uuidString,
            parentId: parentId.uuidString,
            parentGivenName: parentGivenName,
            workspaceDisplayName: workspaceDisplayName,
            ownerParticipantId: ownerParticipantId.uuidString,
            athleteGivenName: athleteGivenName,
            athleteBirthDateIso: athleteBirthDateIso,
            athleteTimeZoneId: athleteTimeZoneId,
            athleteDevelopmentStage: athleteDevelopmentStage
        ))
        let (data, response) = try await transport.send(request)

        if response.statusCode == 401 {
            let decoded = try? decode(ErrorResponseBody.self, from: data)
            // Only clear the stored token if it is STILL the exact token
            // this call started with. This call's own `token` was
            // captured before the network `await` above; if the Parent
            // signed out and completed a brand-new SIWA handshake while
            // this call was suspended, a DIFFERENT, valid token may now
            // be stored — deleting it here would destroy a session that
            // has nothing to do with this stale rejection, incorrectly
            // signing the Parent out of a session they only just
            // established (review finding: a delayed 401 for an old
            // token must never erase a freshly-authenticated one).
            let tokenStillCurrent = sessionStore.loadToken() == token
            switch decoded?.error {
            case "session_invalid":
                if tokenStillCurrent { sessionStore.deleteToken() }
                throw ParentAuthenticationError.sessionInvalid
            case "session_expired":
                if tokenStillCurrent { sessionStore.deleteToken() }
                throw ParentAuthenticationError.sessionExpired
            case "reauthentication_required":
                throw ParentAuthenticationError.reauthenticationRequired
            default:
                if tokenStillCurrent { sessionStore.deleteToken() }
                throw ParentAuthenticationError.sessionInvalid
            }
        }

        guard response.statusCode == 200 else { throw ParentAuthenticationError.network }
        let decoded = try decode(HydrationUploadResponseBody.self, from: data)
        return try Self.mapHydrationUploadOutcome(decoded)
    }

    // MARK: - Wire mapping

    private static func mapConnectionInvitationCreationOutcome(_ body: ConnectionInvitationCreateResponseBody) throws -> ConnectionInvitationCreationOutcome {
        switch body.outcome {
        case "created":
            guard
                let rawId = body.invitationId, let id = UUID(uuidString: rawId),
                let rawExpiresAt = body.expiresAt, let expiresAt = Self.parseISO8601(rawExpiresAt)
            else {
                throw ParentAuthenticationError.malformedResponse
            }
            return .created(invitationId: id, expiresAt: expiresAt)
        case "owner_binding_not_active":
            return .ownerBindingNotActive
        default:
            throw ParentAuthenticationError.malformedResponse
        }
    }

    private static func mapConnectionRequestListOutcome(_ body: ConnectionRequestListResponseBody) throws -> ConnectionRequestListOutcome {
        switch body.outcome {
        case "ok":
            let summaries = try (body.requests ?? []).map { item -> ConnectionRequestSummary in
                guard
                    let id = UUID(uuidString: item.id),
                    let status = ConnectionRequestStatus(rawValue: item.status),
                    let createdAt = Self.parseISO8601(item.createdAt)
                else {
                    throw ParentAuthenticationError.malformedResponse
                }
                return ConnectionRequestSummary(id: id, displayCode: item.displayCode, status: status, createdAt: createdAt)
            }
            return .ok(requests: summaries)
        case "invitation_not_found":
            return .invitationNotFound
        case "owner_binding_not_active":
            return .ownerBindingNotActive
        default:
            throw ParentAuthenticationError.malformedResponse
        }
    }

    private static func mapConnectionRequestDecisionOutcome(_ body: ConnectionRequestDecideResponseBody) throws -> ConnectionRequestDecisionOutcome {
        switch body.outcome {
        case "approved": return .approved
        case "rejected": return .rejected
        case "invitation_not_found": return .invitationNotFound
        case "request_not_found": return .requestNotFound
        case "owner_binding_not_active": return .ownerBindingNotActive
        case "code_mismatch": return .codeMismatch
        case "request_claimed": return .requestClaimed
        case "already_decided": return .alreadyDecided
        case "invitation_expired": return .invitationExpired
        case "invitation_consumed": return .invitationConsumed
        case "invitation_already_has_approved_request": return .invitationAlreadyHasApprovedRequest
        default:
            throw ParentAuthenticationError.malformedResponse
        }
    }

    private static func mapHydrationUploadOutcome(_ body: HydrationUploadResponseBody) throws -> HydrationUploadOutcome {
        switch body.outcome {
        case "staged": return .staged
        case "uploaded": return .uploaded
        case "upload_rejected": return .uploadRejected
        case "already_completed": return .alreadyCompleted
        case "deadline_passed": return .deadlinePassed
        case "grant_revoked": return .grantRevoked
        case "payload_mismatch": return .payloadMismatch
        case "request_not_found": return .requestNotFound
        case "invitation_not_found": return .invitationNotFound
        case "owner_binding_not_active": return .ownerBindingNotActive
        case "not_yet_approved": return .notYetApproved
        default:
            throw ParentAuthenticationError.malformedResponse
        }
    }

    /// None of this package's existing wire DTOs decode a timestamp
    /// field as `Date` (see `AuthNonceResponseBody.expiresAt`'s own
    /// `String` type) — `decode<T>`'s shared `JSONDecoder` is left at
    /// its default (non-ISO8601) date strategy so it stays correct for
    /// every other call site. These three new outcome types need real
    /// `Date` values, so parsing happens explicitly here instead,
    /// tolerating both with- and without-fractional-seconds ISO 8601
    /// (Postgres `timestamptz` text output includes fractional seconds).
    private static func parseISO8601(_ string: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

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

private struct ConnectionInvitationCreateRequestBody: Encodable, Sendable {
    let workspaceId: String
    let participantId: String
    let athleteId: String
}

private struct ConnectionInvitationCreateResponseBody: Decodable, Sendable {
    let outcome: String
    let invitationId: String?
    let expiresAt: String?
}

private struct ConnectionRequestListRequestBody: Encodable, Sendable {
    let invitationId: String
}

private struct ConnectionRequestListItemBody: Decodable, Sendable {
    let id: String
    let displayCode: String
    let status: String
    let createdAt: String
}

private struct ConnectionRequestListResponseBody: Decodable, Sendable {
    let outcome: String
    let requests: [ConnectionRequestListItemBody]?
}

private struct ConnectionRequestDecideRequestBody: Encodable, Sendable {
    let invitationId: String
    let connectionRequestId: String
    let decision: String
    let displayCode: String
}

private struct ConnectionRequestDecideResponseBody: Decodable, Sendable {
    let outcome: String
}

/// Flat wire shape, matching `hydration-upload/index.ts`'s own
/// `parseRequestBody` exactly — `connection_request_id` plus the 11
/// §2.4 fields are all top-level, never nested under a "payload" key.
/// `athleteBirthDateIso`: deliberately capital-I-lowercase-"so" — NOT
/// `athleteBirthDateISO` — per this codebase's own proven
/// `.convertToSnakeCase`/`.convertFromSnakeCase` precedent for this
/// exact field (see `AthleteDeviceAuthorizationSessionService.swift`'s
/// own doc comment: "`athlete_birth_date_iso` decodes to
/// `athleteBirthDateIso` ... never `athleteBirthDateISO`").
private struct HydrationUploadRequestBody: Encodable, Sendable {
    let connectionRequestId: String
    let workspaceId: String
    let intendedParticipantId: String
    let intendedAthleteId: String
    let parentId: String
    let parentGivenName: String
    let workspaceDisplayName: String
    let ownerParticipantId: String
    let athleteGivenName: String
    let athleteBirthDateIso: String
    let athleteTimeZoneId: String
    let athleteDevelopmentStage: String
}

private struct HydrationUploadResponseBody: Decodable, Sendable {
    let outcome: String
}
