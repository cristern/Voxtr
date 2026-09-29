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
    var currentToken: String?
    private(set) var savedTokens: [String] = []
    private(set) var deleteCallCount = 0

    func loadToken() -> String? { currentToken }

    func saveToken(_ token: String) throws {
        currentToken = token
        savedTokens.append(token)
    }

    func deleteToken() {
        currentToken = nil
        deleteCallCount += 1
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

    // MARK: - Sign-out

    @Test("signOut() clears the local token even when the network revoke call fails outright")
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

        await service.signOut()

        #expect(sessionStore.currentToken == nil)
        #expect(sessionStore.deleteCallCount == 1)
    }

    @Test("signOut() attempts a real revoke call carrying the session header, then clears the local token")
    func signOutSendsRevokeThenClearsToken() async {
        let (service, transport, sessionStore) = makeService()
        sessionStore.currentToken = "token-to-revoke"
        transport.enqueue(path: "parent-session-revoke", statusCode: 200, json: ["outcome": "revoked"])

        await service.signOut()

        #expect(transport.sentRequests.count == 1)
        #expect(transport.sentRequests[0].value(forHTTPHeaderField: "X-Voxtr-Parent-Session") == "token-to-revoke")
        #expect(sessionStore.currentToken == nil)
    }

    @Test("signOut() with no stored token does nothing — no request sent, no spurious delete")
    func signOutWithNoStoredTokenIsANoOp() async {
        let (service, transport, sessionStore) = makeService()

        await service.signOut()

        #expect(transport.sentRequests.isEmpty)
        #expect(sessionStore.deleteCallCount == 0)
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
