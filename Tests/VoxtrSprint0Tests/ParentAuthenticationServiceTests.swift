import Testing
import Foundation
@testable import VoxtrParentAuthentication

// Athlete Connection V1 (Slice D). These tests exercise
// `ParentAuthenticationService`'s orchestration logic directly, against
// fakes at both boundaries the real production types touch (the Apple/
// network boundary via `FakeParentAuthenticationTransport`, and Keychain
// via `FakeParentSessionStore`) — no live network, no real Apple sign-in,
// matching this task's own requirement to run deterministically in
// Codemagic. Every method under test is `internal`, and
// `ParentAuthenticationError`/`PendingSiwaHandshake`/`SignInOutcome`/
// `RedemptionOutcome`/`AppleIdentityCredential` are all `internal` too —
// this file requires `@testable import VoxtrParentAuthentication`,
// matching this codebase's own established "internal on purpose,
// reachable only via `@testable import`" pattern (see
// `ParentWorkspaceRepository`'s own `saveOverride` seams,
// `AthleteSessionActivationServiceTests.swift`'s own header note).
//
// Wire JSON below uses snake_case keys deliberately — the service
// decodes/encodes with `.convertFromSnakeCase`/`.convertToSnakeCase`, so
// these fakes must speak the exact wire shape the real backend handlers
// use (see `ParentAuthenticationService.swift`'s own doc comment citing
// the actual merged `cristern/Voxtr-Backend` source), not a Swift-
// convention shortcut.

private final class FakeParentAuthenticationTransport: ParentAuthenticationTransport, @unchecked Sendable {
    struct Stub {
        let statusCode: Int
        let body: Data
    }

    private var stubsByPath: [String: [Stub]] = [:]
    private(set) var sentRequests: [URLRequest] = []

    struct NoStubConfigured: Error {}

    func enqueue(path: String, statusCode: Int, json: [String: Any?]) {
        let cleaned = json.compactMapValues { $0 }
        let body = try! JSONSerialization.data(withJSONObject: cleaned)
        stubsByPath[path, default: []].append(Stub(statusCode: statusCode, body: body))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sentRequests.append(request)
        let path = request.url!.lastPathComponent
        guard var stubs = stubsByPath[path], !stubs.isEmpty else {
            throw NoStubConfigured()
        }
        let stub = stubs.removeFirst()
        stubsByPath[path] = stubs
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (stub.body, response)
    }
}

private final class FakeParentSessionStore: ParentSessionStoring, @unchecked Sendable {
    struct SaveFailure: Error {}

    var currentToken: String?
    private(set) var savedTokens: [String] = []
    private(set) var deleteCallCount = 0
    /// When `true`, `saveToken(_:)` throws instead of persisting —
    /// models a real Keychain write failure (disk full, device locked
    /// in an unusual state, etc.) so callers can be tested for correct
    /// fail-closed behavior rather than assumed to always succeed.
    var failNextSave = false

    func loadToken() -> String? { currentToken }

    func saveToken(_ token: String) throws {
        if failNextSave {
            failNextSave = false
            throw SaveFailure()
        }
        currentToken = token
        savedTokens.append(token)
    }

    func deleteToken() {
        currentToken = nil
        deleteCallCount += 1
    }
}

/// A fake transport that reports, for each request it sees, whether the
/// session store's token was already `nil` at the moment the request was
/// DISPATCHED (i.e. the instant `send(_:)` began running) — not when its
/// response eventually arrives. Since Swift executes a function's
/// synchronous prefix up to its own first suspension point before any
/// other code can interleave, this is a fully deterministic way to
/// assert an ordering invariant ("X happens before this network call is
/// even sent") without any timing-dependent `Task.sleep`/`Task.yield`
/// guessing.
private final class OrderRecordingTransport: ParentAuthenticationTransport, @unchecked Sendable {
    private let sessionStore: FakeParentSessionStore
    private let statusCode: Int
    private(set) var tokenWasNilWhenRequestDispatched: Bool?

    init(sessionStore: FakeParentSessionStore, statusCode: Int = 200) {
        self.sessionStore = sessionStore
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        tokenWasNilWhenRequestDispatched = (sessionStore.currentToken == nil)
        let body = try! JSONSerialization.data(withJSONObject: ["outcome": "revoked"] as [String: Any])
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// A fake transport whose `send(_:)` call for ONE specific path
/// (`gatedPath`) suspends indefinitely until the test calls `release()`
/// — every other path responds immediately with a canned success. Used
/// to deterministically construct "this async call is suspended on its
/// own network await right now" scenarios (via real `CheckedContinuation`
/// signaling, never a timing guess) so a concurrent `signOut()` can be
/// driven to completion while the gated call is still in flight,
/// exercising `sessionGeneration`'s own race guard. An `actor` (not a
/// `@unchecked Sendable` class) — the whole point of this fake is to be
/// genuinely thread-safe under real concurrent access from two tasks.
private actor SuspendableFakeTransport: ParentAuthenticationTransport {
    private let gatedPath: String
    private let gatedStatusCode: Int
    private let gatedBody: Data
    private var hasStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var shouldRelease = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(gatedPath: String, statusCode: Int, body: Data) {
        self.gatedPath = gatedPath
        self.gatedStatusCode = statusCode
        self.gatedBody = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.lastPathComponent == gatedPath else {
            let body = try! JSONSerialization.data(withJSONObject: ["outcome": "revoked"] as [String: Any])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await waitForRelease()
        let response = HTTPURLResponse(url: request.url!, statusCode: gatedStatusCode, httpVersion: nil, headerFields: nil)!
        return (gatedBody, response)
    }

    /// Suspends until the gated `send(_:)` call has actually started
    /// (i.e. reached its own suspension point) — never a fixed delay.
    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func release() {
        shouldRelease = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func waitForRelease() async {
        if shouldRelease { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }
}

@Suite("ParentAuthenticationService (Athlete Connection V1, Slice D)", .serialized)
@MainActor
struct ParentAuthenticationServiceTests {

    private static let baseURL = URL(string: "https://parent-auth.invalid/functions/v1")!

    private func makeService(
        transport: FakeParentAuthenticationTransport = FakeParentAuthenticationTransport(),
        sessionStore: FakeParentSessionStore = FakeParentSessionStore()
    ) -> (ParentAuthenticationService, FakeParentAuthenticationTransport, FakeParentSessionStore) {
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        return (service, transport, sessionStore)
    }

    private func requestBodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - isSignedIn()

    @Test("isSignedIn() reflects local Keychain/session-store state only")
    func isSignedInReflectsLocalStoreOnly() {
        let (service, _, sessionStore) = makeService()
        #expect(service.isSignedIn() == false)

        sessionStore.currentToken = "some-token"
        #expect(service.isSignedIn() == true)
    }

    // MARK: - Step 1: beginSignIn()

    @Test("beginSignIn() maps auth-nonce's nonce_id/nonce into a PendingSiwaHandshake, hashing the exact nonce string received")
    func beginSignInMapsNonceResponse() async throws {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "auth-nonce", statusCode: 200, json: [
            "nonce_id": "nonce-id-123",
            "nonce": "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
            "expires_at": "2026-09-29T00:01:00Z",
        ])

        let handshake = try await service.beginSignIn()

        #expect(handshake.nonceId == "nonce-id-123")
        #expect(handshake.hashedNonceHex == SiwaNonceHashing.hashedNonceHex(forRawNonce: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"))
        #expect(transport.sentRequests.count == 1)
        #expect(transport.sentRequests[0].httpMethod == "POST")
        #expect(transport.sentRequests[0].url?.absoluteString == "\(Self.baseURL.absoluteString)/auth-nonce")
    }

    @Test("beginSignIn() throws .network for a non-200 response")
    func beginSignInThrowsNetworkOnNon200() async {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "auth-nonce", statusCode: 500, json: [:])

        await #expect(throws: ParentAuthenticationError.network) {
            try await service.beginSignIn()
        }
    }

    // MARK: - Step 2: completeSignIn(handshake:credential:)

    @Test("completeSignIn() sends ONLY nonce_id and the Apple identity token — never a client-selected expected nonce")
    func completeSignInSendsOnlyNonceIdAndIdentityToken() async throws {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "parent-auth-complete", statusCode: 200, json: [
            "outcome": "authenticated",
            "session_token": "brand-new-session-token",
            "expires_at": "2026-09-30T00:00:00Z",
            "authenticated_at": "2026-09-29T00:00:00Z",
        ])
        let handshake = PendingSiwaHandshake(nonceId: "nonce-id-abc", hashedNonceHex: "deadbeef")

        _ = try await service.completeSignIn(handshake: handshake, credential: AppleIdentityCredential(identityToken: "apple-identity-token-xyz"))

        let sent = try requestBodyJSON(transport.sentRequests[0])
        #expect(sent.count == 2)
        #expect(sent["nonce_id"] as? String == "nonce-id-abc")
        #expect(sent["apple_identity_token"] as? String == "apple-identity-token-xyz")
    }

    @Test("completeSignIn() .authenticated outcome atomically replaces the stored session token")
    func completeSignInAuthenticatedSavesToken() async throws {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "stale-token"
        transport.enqueue(path: "parent-auth-complete", statusCode: 200, json: [
            "outcome": "authenticated",
            "session_token": "fresh-session-token",
            "expires_at": "2026-09-30T00:00:00Z",
            "authenticated_at": "2026-09-29T00:00:00Z",
        ])
        let handshake = PendingSiwaHandshake(nonceId: "nonce-id", hashedNonceHex: "hash")

        let outcome = try await service.completeSignIn(handshake: handshake, credential: AppleIdentityCredential(identityToken: "token"))

        #expect(outcome == .authenticated)
        #expect(sessionStore.currentToken == "fresh-session-token")
        #expect(sessionStore.savedTokens == ["fresh-session-token"])
    }

    @Test("completeSignIn() .authenticationFailed outcome never touches the session store (anti-enumeration: both cases are HTTP 200)")
    func completeSignInAuthenticationFailedDoesNotTouchStore() async throws {
        let (service, transport, sessionStore) = makeService()
        transport.enqueue(path: "parent-auth-complete", statusCode: 200, json: ["outcome": "authentication_failed"])
        let handshake = PendingSiwaHandshake(nonceId: "nonce-id", hashedNonceHex: "hash")

        let outcome = try await service.completeSignIn(handshake: handshake, credential: AppleIdentityCredential(identityToken: "token"))

        #expect(outcome == .authenticationFailed)
        #expect(sessionStore.currentToken == nil)
        #expect(sessionStore.savedTokens.isEmpty)
    }

    @Test("completeSignIn() throws .malformedResponse for an authenticated outcome missing session_token")
    func completeSignInMalformedWhenTokenMissing() async {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "parent-auth-complete", statusCode: 200, json: ["outcome": "authenticated"])
        let handshake = PendingSiwaHandshake(nonceId: "nonce-id", hashedNonceHex: "hash")

        await #expect(throws: ParentAuthenticationError.malformedResponse) {
            try await service.completeSignIn(handshake: handshake, credential: AppleIdentityCredential(identityToken: "token"))
        }
    }

    // MARK: - Refresh (rotation)

    @Test("refreshSessionIfPossible() replaces the stored token atomically on a rotated outcome and returns true")
    func refreshRotatesTokenOnSuccess() async throws {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "old-token"
        transport.enqueue(path: "parent-session-refresh", statusCode: 200, json: [
            "outcome": "rotated",
            "session_token": "rotated-token",
            "expires_at": "2026-09-30T00:00:00Z",
        ])

        let didRefresh = await service.refreshSessionIfPossible()

        #expect(didRefresh == true)
        #expect(sessionStore.currentToken == "rotated-token")
        #expect(transport.sentRequests[0].value(forHTTPHeaderField: "X-Voxtr-Parent-Session") == "old-token")
    }

    @Test("refreshSessionIfPossible() never throws and returns false for every rejection reason, leaving the prior token untouched by this call")
    func refreshReturnsFalseOnRejection() async {
        for reason in ["session_invalid", "absolute_lifetime_exceeded", "session_expired"] {
            let (service, transport, sessionStore) = makeService()
            sessionStore.currentToken = "old-token"
            transport.enqueue(path: "parent-session-refresh", statusCode: 401, json: ["error": reason])

            let didRefresh = await service.refreshSessionIfPossible()

            #expect(didRefresh == false, "reason: \(reason)")
            // refreshSessionIfPossible only ever ADDS a new token on
            // success; a rejection must never itself clear it (only
            // redeemEnrollment's own explicit 401 handling does that).
            #expect(sessionStore.currentToken == "old-token", "reason: \(reason)")
        }
    }

    @Test("refreshSessionIfPossible() returns false immediately, without sending any request, when no session is stored")
    func refreshReturnsFalseImmediatelyWithNoStoredSession() async {
        let (service, transport, _) = makeService()

        let didRefresh = await service.refreshSessionIfPossible()

        #expect(didRefresh == false)
        #expect(transport.sentRequests.isEmpty)
    }

    @Test("refreshSessionIfPossible() fails closed — if the backend rotated but the Keychain save throws, the old token is discarded rather than kept as a falsely-usable session")
    func refreshFailsClosedWhenSaveThrows() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "old-token"
        sessionStore.failNextSave = true
        transport.enqueue(path: "parent-session-refresh", statusCode: 200, json: [
            "outcome": "rotated",
            "session_token": "rotated-token-that-cannot-be-persisted",
            "expires_at": "2026-09-30T00:00:00Z",
        ])

        let didRefresh = await service.refreshSessionIfPossible()

        #expect(didRefresh == false)
        // The backend already rotated server-side (orphaning "old-token"),
        // and the replacement couldn't be persisted — the old token must
        // not be left in place looking usable; only a fresh SIWA
        // handshake can recover from here.
        #expect(sessionStore.currentToken == nil)
        #expect(sessionStore.savedTokens.isEmpty)
    }

    @Test("An in-flight refreshSessionIfPossible() cannot write a token back if signOut() runs while it is suspended on the network await")
    func refreshCannotResurrectTokenAfterConcurrentSignOut() async throws {
        let sessionStore = FakeParentSessionStore()
        sessionStore.currentToken = "old-token"
        let rotatedBody = try JSONSerialization.data(withJSONObject: [
            "outcome": "rotated",
            "session_token": "rotated-token-that-should-be-discarded",
            "expires_at": "2026-09-30T00:00:00Z",
        ] as [String: Any])
        let transport = SuspendableFakeTransport(gatedPath: "parent-session-refresh", statusCode: 200, body: rotatedBody)
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )

        let refreshTask = Task { await service.refreshSessionIfPossible() }
        await transport.waitUntilStarted()

        // The refresh call is now suspended on its own network await,
        // already holding a "rotated" response it intends to write back
        // once released — sign out while it's stuck there.
        let signedOut = await service.signOut()
        #expect(signedOut == true)
        #expect(sessionStore.currentToken == nil)

        await transport.release()
        let didRefresh = await refreshTask.value

        #expect(didRefresh == false)
        #expect(sessionStore.currentToken == nil, "the in-flight refresh must not resurrect a session after signOut()")
        #expect(sessionStore.savedTokens.isEmpty)
    }

    // MARK: - Sign-out

    @Test("signOut() clears the local token even when the network revoke call fails outright, and reports the server side as unconfirmed")
    func signOutClearsTokenEvenWhenNetworkFails() async {
        struct AlwaysFailingTransport: ParentAuthenticationTransport {
            struct Failure: Error {}
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw Failure() }
        }
        let sessionStore = FakeParentSessionStore()
        sessionStore.currentToken = "token-to-clear"
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: AlwaysFailingTransport(),
            sessionStore: sessionStore
        )

        let serverConfirmed = await service.signOut()

        #expect(serverConfirmed == false)
        #expect(sessionStore.currentToken == nil)
        #expect(sessionStore.deleteCallCount == 1)
    }

    @Test("signOut() returns false — never claiming server-side success — when the revoke request returns a non-200 status")
    func signOutReturnsFalseOnNon200Revoke() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "token-to-revoke"
        transport.enqueue(path: "parent-session-revoke", statusCode: 500, json: [:])

        let serverConfirmed = await service.signOut()

        #expect(serverConfirmed == false)
        #expect(sessionStore.currentToken == nil)
    }

    @Test("signOut() attempts a real revoke call carrying the session header, then clears the local token, and reports server confirmation truthfully")
    func signOutSendsRevokeThenClearsToken() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "token-to-revoke"
        transport.enqueue(path: "parent-session-revoke", statusCode: 200, json: ["outcome": "revoked"])

        let serverConfirmed = await service.signOut()

        #expect(serverConfirmed == true)
        #expect(transport.sentRequests.count == 1)
        #expect(transport.sentRequests[0].value(forHTTPHeaderField: "X-Voxtr-Parent-Session") == "token-to-revoke")
        #expect(sessionStore.currentToken == nil)
    }

    @Test("signOut() with no stored token does nothing — no request sent, no spurious delete — and reports true (nothing needed revoking)")
    func signOutWithNoStoredTokenIsANoOp() async {
        let (service, transport, sessionStore) = makeService()

        let serverConfirmed = await service.signOut()

        #expect(serverConfirmed == true)
        #expect(transport.sentRequests.isEmpty)
        #expect(sessionStore.deleteCallCount == 0)
    }

    @Test("signOut() clears the local token BEFORE the revoke request is even dispatched — the UI must never appear signed in during that network call")
    func signOutClearsTokenBeforeDispatchingRevoke() async {
        let sessionStore = FakeParentSessionStore()
        sessionStore.currentToken = "token-to-clear"
        let transport = OrderRecordingTransport(sessionStore: sessionStore)
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )

        _ = await service.signOut()

        #expect(transport.tokenWasNilWhenRequestDispatched == true)
    }

    @Test("An in-flight completeSignIn() cannot write a token back if signOut() runs while it is suspended on the network await")
    func completeSignInCannotResurrectTokenAfterConcurrentSignOut() async throws {
        let sessionStore = FakeParentSessionStore()
        let authenticatedBody = try JSONSerialization.data(withJSONObject: [
            "outcome": "authenticated",
            "session_token": "new-token-that-should-be-discarded",
            "expires_at": "2026-09-30T00:00:00Z",
            "authenticated_at": "2026-09-29T00:00:00Z",
        ] as [String: Any])
        let transport = SuspendableFakeTransport(gatedPath: "parent-auth-complete", statusCode: 200, body: authenticatedBody)
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let handshake = PendingSiwaHandshake(nonceId: "nonce-id", hashedNonceHex: "hash")

        let completeTask = Task {
            try await service.completeSignIn(
                handshake: handshake,
                credential: AppleIdentityCredential(identityToken: "identity-token")
            )
        }
        await transport.waitUntilStarted()

        // completeSignIn() is now suspended on its own network await,
        // already holding a freshly-authenticated response it intends
        // to persist once released — sign out (of nothing, in this
        // first-time-sign-in scenario) while it's stuck there.
        let signedOut = await service.signOut()
        #expect(signedOut == true)

        await transport.release()
        let outcome = try await completeTask.value

        #expect(outcome == .authenticationFailed)
        #expect(sessionStore.currentToken == nil, "the in-flight completion must not resurrect a session after signOut()")
        #expect(sessionStore.savedTokens.isEmpty)
    }

    // MARK: - Existing-workspace enrollment redemption

    private static let workspace = EnrollableWorkspace(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, displayName: "Jonas's Training")

    @Test("redeemEnrollment() throws .notSignedIn and sends no request when no session token is stored")
    func redeemEnrollmentThrowsNotSignedInWithNoToken() async {
        let (service, transport, _) = makeService()

        await #expect(throws: ParentAuthenticationError.notSignedIn) {
            try await service.redeemEnrollment(workspace: Self.workspace, code: "CODE123")
        }
        #expect(transport.sentRequests.isEmpty)
    }

    @Test("redeemEnrollment() sends the session header and the workspace id exactly as given, alongside the code exactly as entered")
    func redeemEnrollmentSendsWorkspaceIdAndCodeExactly() async throws {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "workspace-enrollment-redeem", statusCode: 200, json: [
            "outcome": "bound",
            "owner_binding_id": "22222222-2222-2222-2222-222222222222",
        ])

        _ = try await service.redeemEnrollment(workspace: Self.workspace, code: "  CODE-With-Case  ")

        let sent = transport.sentRequests[0]
        #expect(sent.value(forHTTPHeaderField: "X-Voxtr-Parent-Session") == "live-session-token")
        let body = try requestBodyJSON(sent)
        #expect(body["workspace_id"] as? String == Self.workspace.id.uuidString)
        #expect(body["code"] as? String == "  CODE-With-Case  ")
    }

    @Test("redeemEnrollment() maps every 200 outcome to the matching RedemptionOutcome case, with owner_binding_id present only where the contract requires it")
    func redeemEnrollmentMapsAllSuccessOutcomes() async throws {
        let bindingId = "22222222-2222-2222-2222-222222222222"
        let cases: [(wire: String, expected: RedemptionOutcome)] = [
            ("bound", .bound(ownerBindingId: UUID(uuidString: bindingId)!)),
            ("already_redeemed_same_parent", .alreadyRedeemedBySameParent(ownerBindingId: UUID(uuidString: bindingId)!)),
            ("binding_revoked", .bindingRevoked(ownerBindingId: UUID(uuidString: bindingId)!)),
            ("authorization_already_redeemed", .authorizationAlreadyRedeemed),
            ("workspace_already_bound", .workspaceAlreadyBound),
            ("inconsistent_state", .inconsistentState),
            ("authorization_not_available", .authorizationNotAvailable),
        ]

        for testCase in cases {
            let (service, transport, sessionStore) = makeService()
            sessionStore.currentToken = "live-session-token"
            let needsBindingId = ["bound", "already_redeemed_same_parent", "binding_revoked"].contains(testCase.wire)
            transport.enqueue(path: "workspace-enrollment-redeem", statusCode: 200, json: [
                "outcome": testCase.wire,
                "owner_binding_id": needsBindingId ? bindingId : nil,
            ])

            let outcome = try await service.redeemEnrollment(workspace: Self.workspace, code: "CODE")

            #expect(outcome == testCase.expected, "wire outcome: \(testCase.wire)")
        }
    }

    @Test("redeemEnrollment() throws .malformedResponse when a binding-carrying outcome is missing owner_binding_id")
    func redeemEnrollmentMalformedWhenBindingIdMissing() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "workspace-enrollment-redeem", statusCode: 200, json: ["outcome": "bound"])

        await #expect(throws: ParentAuthenticationError.malformedResponse) {
            try await service.redeemEnrollment(workspace: Self.workspace, code: "CODE")
        }
    }

    @Test("redeemEnrollment() maps session_invalid to .sessionInvalid and clears the stored token")
    func redeemEnrollmentSessionInvalidClearsToken() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "workspace-enrollment-redeem", statusCode: 401, json: ["error": "session_invalid"])

        await #expect(throws: ParentAuthenticationError.sessionInvalid) {
            try await service.redeemEnrollment(workspace: Self.workspace, code: "CODE")
        }
        #expect(sessionStore.currentToken == nil)
    }

    @Test("redeemEnrollment() maps session_expired to .sessionExpired and clears the stored token")
    func redeemEnrollmentSessionExpiredClearsToken() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "workspace-enrollment-redeem", statusCode: 401, json: ["error": "session_expired"])

        await #expect(throws: ParentAuthenticationError.sessionExpired) {
            try await service.redeemEnrollment(workspace: Self.workspace, code: "CODE")
        }
        #expect(sessionStore.currentToken == nil)
    }

    @Test("redeemEnrollment() maps reauthentication_required to .reauthenticationRequired WITHOUT clearing the stored token — only a fresh SIWA handshake, never this, can satisfy freshness")
    func redeemEnrollmentReauthenticationRequiredLeavesTokenInPlace() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "workspace-enrollment-redeem", statusCode: 401, json: ["error": "reauthentication_required"])

        await #expect(throws: ParentAuthenticationError.reauthenticationRequired) {
            try await service.redeemEnrollment(workspace: Self.workspace, code: "CODE")
        }
        #expect(sessionStore.currentToken == "live-session-token")
        #expect(sessionStore.deleteCallCount == 0)
    }

    @Test("redeemEnrollment() fails closed — an unrecognized 401 error (e.g. unauthenticated) clears the token and throws .sessionInvalid")
    func redeemEnrollmentUnrecognized401FailsClosed() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "workspace-enrollment-redeem", statusCode: 401, json: ["error": "unauthenticated"])

        await #expect(throws: ParentAuthenticationError.sessionInvalid) {
            try await service.redeemEnrollment(workspace: Self.workspace, code: "CODE")
        }
        #expect(sessionStore.currentToken == nil)
    }

    @Test("redeemEnrollment() throws .network for a non-200/401 response")
    func redeemEnrollmentThrowsNetworkOnUnexpectedStatus() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "workspace-enrollment-redeem", statusCode: 500, json: [:])

        await #expect(throws: ParentAuthenticationError.network) {
            try await service.redeemEnrollment(workspace: Self.workspace, code: "CODE")
        }
    }

    // MARK: - Athlete Connection V1 (backend device authorization):
    // createConnectionInvitation / listConnectionRequests /
    // decideConnectionRequest

    private static let invitationId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let workspaceId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let participantId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let athleteId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private static let requestId = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    @Test("createConnectionInvitation() sends the session header and all three ids exactly as given")
    func createConnectionInvitationSendsIdsExactly() async throws {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "connection-invitation-create", statusCode: 200, json: [
            "outcome": "created",
            "invitation_id": Self.invitationId.uuidString,
            "expires_at": "2026-10-01T00:15:00Z",
        ])

        let outcome = try await service.createConnectionInvitation(
            workspaceId: Self.workspaceId,
            participantId: Self.participantId,
            athleteId: Self.athleteId
        )

        #expect(outcome == .created(invitationId: Self.invitationId, expiresAt: Self.date("2026-10-01T00:15:00Z")))
        let sent = transport.sentRequests[0]
        #expect(sent.value(forHTTPHeaderField: "X-Voxtr-Parent-Session") == "live-session-token")
        let body = try requestBodyJSON(sent)
        #expect(body["workspace_id"] as? String == Self.workspaceId.uuidString)
        #expect(body["participant_id"] as? String == Self.participantId.uuidString)
        #expect(body["athlete_id"] as? String == Self.athleteId.uuidString)
    }

    @Test("createConnectionInvitation() maps owner_binding_not_active")
    func createConnectionInvitationMapsOwnerBindingNotActive() async throws {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "connection-invitation-create", statusCode: 200, json: ["outcome": "owner_binding_not_active"])

        let outcome = try await service.createConnectionInvitation(
            workspaceId: Self.workspaceId,
            participantId: Self.participantId,
            athleteId: Self.athleteId
        )

        #expect(outcome == .ownerBindingNotActive)
    }

    @Test("createConnectionInvitation() maps reauthentication_required WITHOUT clearing the stored token — a SENSITIVE operation")
    func createConnectionInvitationReauthenticationRequiredLeavesTokenInPlace() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "connection-invitation-create", statusCode: 401, json: ["error": "reauthentication_required"])

        await #expect(throws: ParentAuthenticationError.reauthenticationRequired) {
            try await service.createConnectionInvitation(workspaceId: Self.workspaceId, participantId: Self.participantId, athleteId: Self.athleteId)
        }
        #expect(sessionStore.currentToken == "live-session-token")
    }

    @Test("listConnectionRequests() sends only invitation_id and maps a real requests array")
    func listConnectionRequestsMapsOkOutcome() async throws {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "connection-request-list", statusCode: 200, json: [
            "outcome": "ok",
            "requests": [
                [
                    "id": Self.requestId.uuidString,
                    "display_code": "A1B2C3",
                    "status": "pending",
                    "created_at": "2026-10-01T00:10:00Z",
                ],
            ],
        ])

        let outcome = try await service.listConnectionRequests(invitationId: Self.invitationId)

        guard case .ok(let requests) = outcome else {
            Issue.record("expected .ok, got \(outcome)")
            return
        }
        #expect(requests == [
            ConnectionRequestSummary(id: Self.requestId, displayCode: "A1B2C3", status: .pending, createdAt: Self.date("2026-10-01T00:10:00Z")),
        ])
        let body = try requestBodyJSON(transport.sentRequests[0])
        #expect(body.count == 1)
        #expect(body["invitation_id"] as? String == Self.invitationId.uuidString)
    }

    @Test("listConnectionRequests() never surfaces .reauthenticationRequired — ORDINARY operation, so an unrecognized 401 fails closed as .sessionInvalid")
    func listConnectionRequestsUnrecognized401FailsClosed() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "connection-request-list", statusCode: 401, json: ["error": "reauthentication_required"])

        await #expect(throws: ParentAuthenticationError.sessionInvalid) {
            try await service.listConnectionRequests(invitationId: Self.invitationId)
        }
        #expect(sessionStore.currentToken == nil)
    }

    @Test("decideConnectionRequest() sends invitation_id, connection_request_id, decision, and display_code exactly as given")
    func decideConnectionRequestSendsFieldsExactly() async throws {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "connection-request-decide", statusCode: 200, json: ["outcome": "approved"])

        let outcome = try await service.decideConnectionRequest(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId,
            decision: .approved,
            displayCode: "A1B2C3"
        )

        #expect(outcome == .approved)
        let body = try requestBodyJSON(transport.sentRequests[0])
        #expect(body["invitation_id"] as? String == Self.invitationId.uuidString)
        #expect(body["connection_request_id"] as? String == Self.requestId.uuidString)
        #expect(body["decision"] as? String == "approved")
        #expect(body["display_code"] as? String == "A1B2C3")
    }

    @Test("decideConnectionRequest() maps every documented business outcome")
    func decideConnectionRequestMapsAllBusinessOutcomes() async throws {
        let cases: [(wire: String, expected: ConnectionRequestDecisionOutcome)] = [
            ("approved", .approved),
            ("rejected", .rejected),
            ("invitation_not_found", .invitationNotFound),
            ("request_not_found", .requestNotFound),
            ("owner_binding_not_active", .ownerBindingNotActive),
            ("code_mismatch", .codeMismatch),
            ("request_claimed", .requestClaimed),
            ("already_decided", .alreadyDecided),
            ("invitation_expired", .invitationExpired),
            ("invitation_consumed", .invitationConsumed),
            ("invitation_already_has_approved_request", .invitationAlreadyHasApprovedRequest),
        ]

        for testCase in cases {
            let (service, transport, sessionStore) = makeService()
            sessionStore.currentToken = "live-session-token"
            transport.enqueue(path: "connection-request-decide", statusCode: 200, json: ["outcome": testCase.wire])

            let outcome = try await service.decideConnectionRequest(
                invitationId: Self.invitationId,
                connectionRequestId: Self.requestId,
                decision: .rejected,
                displayCode: "A1B2C3"
            )

            #expect(outcome == testCase.expected, "wire outcome: \(testCase.wire)")
        }
    }

    // MARK: - Parent hydration-upload integration: uploadHydration()

    private static let connectionRequestId = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private static let parentId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    private static let ownerParticipantId = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    @Test("uploadHydration() sends connection_request_id and all 11 fields, flat and exactly as given, via POST to hydration-upload with the session header")
    func uploadHydrationSendsAllFieldsExactly() async throws {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "hydration-upload", statusCode: 200, json: ["outcome": "staged"])

        let outcome = try await service.uploadHydration(
            connectionRequestId: Self.connectionRequestId,
            workspaceId: Self.workspaceId,
            intendedParticipantId: Self.participantId,
            intendedAthleteId: Self.athleteId,
            parentId: Self.parentId,
            parentGivenName: "Kari",
            workspaceDisplayName: "Hansen Family",
            ownerParticipantId: Self.ownerParticipantId,
            athleteGivenName: "Jonas",
            athleteBirthDateIso: "2012-04-10",
            athleteTimeZoneId: "Europe/Oslo",
            athleteDevelopmentStage: "parentLed"
        )

        #expect(outcome == .staged)
        let sent = try #require(transport.sentRequests.first)
        #expect(sent.value(forHTTPHeaderField: "X-Voxtr-Parent-Session") == "live-session-token")
        let body = try requestBodyJSON(sent)
        #expect(body.count == 12)
        #expect(body["connection_request_id"] as? String == Self.connectionRequestId.uuidString)
        #expect(body["workspace_id"] as? String == Self.workspaceId.uuidString)
        #expect(body["intended_participant_id"] as? String == Self.participantId.uuidString)
        #expect(body["intended_athlete_id"] as? String == Self.athleteId.uuidString)
        #expect(body["parent_id"] as? String == Self.parentId.uuidString)
        #expect(body["parent_given_name"] as? String == "Kari")
        #expect(body["workspace_display_name"] as? String == "Hansen Family")
        #expect(body["owner_participant_id"] as? String == Self.ownerParticipantId.uuidString)
        #expect(body["athlete_given_name"] as? String == "Jonas")
        #expect(body["athlete_birth_date_iso"] as? String == "2012-04-10")
        #expect(body["athlete_time_zone_id"] as? String == "Europe/Oslo")
        #expect(body["athlete_development_stage"] as? String == "parentLed")
    }

    @Test("uploadHydration() maps every documented backend outcome from authz.hydration_upload")
    func uploadHydrationMapsAllBusinessOutcomes() async throws {
        let cases: [(wire: String, expected: HydrationUploadOutcome)] = [
            ("staged", .staged),
            ("uploaded", .uploaded),
            ("upload_rejected", .uploadRejected),
            ("already_completed", .alreadyCompleted),
            ("deadline_passed", .deadlinePassed),
            ("grant_revoked", .grantRevoked),
            ("payload_mismatch", .payloadMismatch),
            ("request_not_found", .requestNotFound),
            ("invitation_not_found", .invitationNotFound),
            ("owner_binding_not_active", .ownerBindingNotActive),
            ("not_yet_approved", .notYetApproved),
        ]

        for testCase in cases {
            let (service, transport, sessionStore) = makeService()
            sessionStore.currentToken = "live-session-token"
            transport.enqueue(path: "hydration-upload", statusCode: 200, json: ["outcome": testCase.wire])

            let outcome = try await service.uploadHydration(
                connectionRequestId: Self.connectionRequestId,
                workspaceId: Self.workspaceId,
                intendedParticipantId: Self.participantId,
                intendedAthleteId: Self.athleteId,
                parentId: Self.parentId,
                parentGivenName: "Kari",
                workspaceDisplayName: "Hansen Family",
                ownerParticipantId: Self.ownerParticipantId,
                athleteGivenName: "Jonas",
                athleteBirthDateIso: "2012-04-10",
                athleteTimeZoneId: "Europe/Oslo",
                athleteDevelopmentStage: "parentLed"
            )

            #expect(outcome == testCase.expected, "wire outcome: \(testCase.wire)")
        }
    }

    @Test("uploadHydration() maps reauthentication_required WITHOUT clearing the stored token — a SENSITIVE operation, same shape as createConnectionInvitation/decideConnectionRequest")
    func uploadHydrationReauthenticationRequiredLeavesTokenInPlace() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "live-session-token"
        transport.enqueue(path: "hydration-upload", statusCode: 401, json: ["error": "reauthentication_required"])

        await #expect(throws: ParentAuthenticationError.reauthenticationRequired) {
            try await service.uploadHydration(
                connectionRequestId: Self.connectionRequestId,
                workspaceId: Self.workspaceId,
                intendedParticipantId: Self.participantId,
                intendedAthleteId: Self.athleteId,
                parentId: Self.parentId,
                parentGivenName: "Kari",
                workspaceDisplayName: "Hansen Family",
                ownerParticipantId: Self.ownerParticipantId,
                athleteGivenName: "Jonas",
                athleteBirthDateIso: "2012-04-10",
                athleteTimeZoneId: "Europe/Oslo",
                athleteDevelopmentStage: "parentLed"
            )
        }
        #expect(sessionStore.currentToken == "live-session-token")
    }

    @Test("uploadHydration() maps session_invalid and session_expired, clearing the stored token for each")
    func uploadHydrationMapsSessionInvalidAndExpired() async {
        for (wire, expected) in [("session_invalid", ParentAuthenticationError.sessionInvalid), ("session_expired", ParentAuthenticationError.sessionExpired)] {
            let (service, transport, sessionStore) = makeService()
            sessionStore.currentToken = "live-session-token"
            transport.enqueue(path: "hydration-upload", statusCode: 401, json: ["error": wire])

            await #expect(throws: expected) {
                try await service.uploadHydration(
                    connectionRequestId: Self.connectionRequestId,
                    workspaceId: Self.workspaceId,
                    intendedParticipantId: Self.participantId,
                    intendedAthleteId: Self.athleteId,
                    parentId: Self.parentId,
                    parentGivenName: "Kari",
                    workspaceDisplayName: "Hansen Family",
                    ownerParticipantId: Self.ownerParticipantId,
                    athleteGivenName: "Jonas",
                    athleteBirthDateIso: "2012-04-10",
                    athleteTimeZoneId: "Europe/Oslo",
                    athleteDevelopmentStage: "parentLed"
                )
            }
            #expect(sessionStore.currentToken == nil, "wire error: \(wire)")
        }
    }

    @Test("uploadHydration() with no stored session throws .notSignedIn locally, without sending any network request")
    func uploadHydrationWithNoSessionThrowsNotSignedInWithoutNetworkCall() async {
        let (service, transport, _) = makeService()

        await #expect(throws: ParentAuthenticationError.notSignedIn) {
            try await service.uploadHydration(
                connectionRequestId: Self.connectionRequestId,
                workspaceId: Self.workspaceId,
                intendedParticipantId: Self.participantId,
                intendedAthleteId: Self.athleteId,
                parentId: Self.parentId,
                parentGivenName: "Kari",
                workspaceDisplayName: "Hansen Family",
                ownerParticipantId: Self.ownerParticipantId,
                athleteGivenName: "Jonas",
                athleteBirthDateIso: "2012-04-10",
                athleteTimeZoneId: "Europe/Oslo",
                athleteDevelopmentStage: "parentLed"
            )
        }
        #expect(transport.sentRequests.isEmpty)
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - Keychain round trip (real Keychain-backed store)

    // NOTE: like the other platform-framework-backed tests in this suite
    // (see `AthleteSessionActivationServiceTests.swift`'s own header
    // note on its SwiftData-backed test), this exercises the real
    // Security framework Keychain APIs and requires the Xcode/iOS
    // Simulator runtime — written but not executed in this sandbox.
    @Test("KeychainParentSessionStore save/load/delete round-trips correctly and atomically replaces an existing token")
    func keychainStoreRoundTrips() throws {
        let store = KeychainParentSessionStore(
            service: "com.voxtr.parent.session.tests",
            account: "parent-session-token-test-\(UUID().uuidString)"
        )
        defer { store.deleteToken() }

        #expect(store.loadToken() == nil)

        try store.saveToken("first-token")
        #expect(store.loadToken() == "first-token")

        // Atomic replace: a second save while a token already exists
        // must fully replace it, never leave a stale/duplicate value.
        try store.saveToken("second-token")
        #expect(store.loadToken() == "second-token")

        store.deleteToken()
        #expect(store.loadToken() == nil)
    }
}
