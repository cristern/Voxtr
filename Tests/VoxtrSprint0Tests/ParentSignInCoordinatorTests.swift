import Testing
import Foundation
@testable import VoxtrParentAuthentication

// Athlete Connection V1 — deterministic tests for the sign-in ATTEMPT
// state machine extracted into `ParentSignInCoordinator`, covering the
// exact race its own doc comment describes: `configureAppleRequest`
// pinning a handshake at Apple request creation must be immune to a
// concurrent idle-nonce renewal, for the WHOLE lifetime of that attempt.
// `ParentSignInCoordinator`/`ParentSignInClock` are `internal` (not
// `private` to another file), so this file requires `@testable import
// VoxtrParentAuthentication`, matching this suite's own established
// pattern (see `ParentAuthenticationServiceTests.swift`'s own header).
//
// These tests exercise the coordinator against a REAL
// `ParentAuthenticationService`, wired to fakes at the transport/
// session-store boundary — the same "real service + fake network"
// approach every other test in this feature already uses — plus a
// controllable fake clock, so freshness is exercised deterministically
// (never `Date()`/real `Task.sleep`).

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

    func loadToken() -> String? { currentToken }
    func saveToken(_ token: String) throws { currentToken = token }
    func deleteToken() { currentToken = nil }
}

/// A controllable clock — tests advance `currentTime` directly rather
/// than depending on `Date()` or a real `Task.sleep`, per this task's
/// own explicit requirement.
private final class FakeParentSignInClock: ParentSignInClock, @unchecked Sendable {
    var currentTime: Date

    init(currentTime: Date = Date(timeIntervalSince1970: 1_767_312_000)) {
        self.currentTime = currentTime
    }

    func now() -> Date { currentTime }
}

/// A fake transport whose `send(_:)` call for ONE specific path
/// (`gatedPath`) suspends indefinitely until the test calls `release()`
/// — via real `CheckedContinuation` signaling, never a timing guess.
/// Every OTHER path responds immediately: `auth-nonce` with a freshly
/// numbered synthetic nonce (so a coordinator under test can freely
/// prime/renew its idle handshake around the gated call), anything else
/// with a generic 200 success. See
/// `ParentAuthenticationServiceTests.swift`'s own `SuspendableFakeTransport`
/// for the same continuation-based pattern applied to the service layer
/// directly; this is a separate, file-local type since this codebase's
/// own convention is no shared cross-file test helpers.
private actor SuspendableFakeTransport: ParentAuthenticationTransport {
    private let gatedPath: String
    private let gatedStatusCode: Int
    private let gatedBody: Data
    private var hasStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var shouldRelease = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var nonceCounter = 0

    init(gatedPath: String, statusCode: Int, body: Data) {
        self.gatedPath = gatedPath
        self.gatedStatusCode = statusCode
        self.gatedBody = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.lastPathComponent
        guard path == gatedPath else {
            if path == "auth-nonce" {
                nonceCounter += 1
                let body = try! JSONSerialization.data(withJSONObject: [
                    "nonce_id": "auto-nonce-\(nonceCounter)",
                    "nonce": "raw-auto-nonce-\(nonceCounter)",
                    "expires_at": "2026-09-30T00:00:00Z",
                ] as [String: Any])
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
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

@Suite("ParentSignInCoordinator (Athlete Connection V1, sign-in attempt state machine)", .serialized)
@MainActor
struct ParentSignInCoordinatorTests {

    private static let baseURL = URL(string: "https://parent-auth.invalid/functions/v1")!

    private func requestBodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 1. Pinned attempt survives idle renewal that would otherwise occur

    @Test("A pinned attempt's handshake is what gets submitted — even after the clock crosses the freshness bound and idle renewal would otherwise occur")
    func pinnedAttemptSurvivesClockCrossingFreshnessBound() async throws {
        let clock = FakeParentSignInClock()
        let transport = FakeParentAuthenticationTransport()
        let sessionStore = FakeParentSessionStore()
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service, clock: clock, freshnessBound: 45)

        transport.enqueue(path: "auth-nonce", statusCode: 200, json: [
            "nonce_id": "nonce-A",
            "nonce": "raw-nonce-a",
            "expires_at": "2026-09-30T00:00:00Z",
        ])
        await coordinator.fetchReadyHandshakeIfNeeded()

        let pinned = coordinator.beginAttempt()
        #expect(pinned?.nonceId == "nonce-A")

        // Advance the clock well past the freshness bound — if idle
        // renewal were consulted right now on its own, it WOULD
        // consider the (now long-vacated) idle slot due for a refetch.
        clock.currentTime = clock.currentTime.addingTimeInterval(1000)

        #expect(coordinator.shouldFetchReadyHandshake == false, "renewal must be refused outright while an attempt is active, regardless of elapsed time")
        await coordinator.fetchReadyHandshakeIfNeeded()
        let nonceRequestCount = transport.sentRequests.filter { $0.url?.lastPathComponent == "auth-nonce" }.count
        #expect(nonceRequestCount == 1, "a second auth-nonce call must never have been sent while the attempt was active")

        transport.enqueue(path: "parent-auth-complete", statusCode: 200, json: ["outcome": "authentication_failed"])
        await coordinator.completeActiveAttempt(identityToken: "identity-token")

        let completeRequest = try #require(transport.sentRequests.first { $0.url?.lastPathComponent == "parent-auth-complete" })
        let body = try requestBodyJSON(completeRequest)
        #expect(body["nonce_id"] as? String == "nonce-A", "completion must submit exactly the pinned attempt's nonce_id, never a would-be-renewed one")
    }

    // MARK: - 2. Attempt/button stay unavailable through a suspended backend completion

    @Test("canAttemptSignIn and activeAttempt stay unavailable for the entire duration of a suspended backend completion")
    func attemptStaysActiveDuringSuspendedCompletion() async throws {
        let sessionStore = FakeParentSessionStore()
        let authenticatedBody = try JSONSerialization.data(withJSONObject: [
            "outcome": "authenticated",
            "session_token": "new-session-token",
            "expires_at": "2026-09-30T00:00:00Z",
            "authenticated_at": "2026-09-29T00:00:00Z",
        ] as [String: Any])
        let transport = SuspendableFakeTransport(gatedPath: "parent-auth-complete", statusCode: 200, body: authenticatedBody)
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service)

        await coordinator.fetchReadyHandshakeIfNeeded()
        let pinned = coordinator.beginAttempt()
        #expect(pinned != nil)
        #expect(coordinator.canAttemptSignIn == false)
        #expect(coordinator.activeAttempt != nil)

        let completeTask = Task {
            await coordinator.completeActiveAttempt(identityToken: "identity-token")
        }
        await transport.waitUntilStarted()

        // Suspended on the backend network call right now — the attempt
        // must still read as active and the button must still be
        // unavailable, however long this takes.
        #expect(coordinator.activeAttempt != nil)
        #expect(coordinator.canAttemptSignIn == false)
        #expect(coordinator.shouldFetchReadyHandshake == false)

        // The background poll's own fetch call must be a no-op too.
        await coordinator.fetchReadyHandshakeIfNeeded()
        #expect(coordinator.activeAttempt != nil)

        await transport.release()
        await completeTask.value

        #expect(coordinator.activeAttempt == nil, "the attempt must end once completion resolves")
        #expect(coordinator.isSignedIn == true)
    }

    // MARK: - 3. Cancellation permits a new attempt

    @Test("cancelActiveAttempt() frees the coordinator to fetch and pin a brand-new attempt")
    func cancellationPermitsANewAttempt() async throws {
        let transport = FakeParentAuthenticationTransport()
        let sessionStore = FakeParentSessionStore()
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service)

        transport.enqueue(path: "auth-nonce", statusCode: 200, json: [
            "nonce_id": "nonce-A", "nonce": "raw-a", "expires_at": "2026-09-30T00:00:00Z",
        ])
        await coordinator.fetchReadyHandshakeIfNeeded()
        let firstPinned = coordinator.beginAttempt()
        #expect(firstPinned?.nonceId == "nonce-A")

        coordinator.cancelActiveAttempt()
        #expect(coordinator.activeAttempt == nil)
        #expect(coordinator.canAttemptSignIn == false, "no idle handshake exists yet right after cancellation")
        #expect(coordinator.shouldFetchReadyHandshake == true)

        transport.enqueue(path: "auth-nonce", statusCode: 200, json: [
            "nonce_id": "nonce-B", "nonce": "raw-b", "expires_at": "2026-09-30T00:01:00Z",
        ])
        await coordinator.fetchReadyHandshakeIfNeeded()
        #expect(coordinator.canAttemptSignIn == true)

        let secondPinned = coordinator.beginAttempt()
        #expect(secondPinned?.nonceId == "nonce-B", "a fresh attempt must be pinnable, and pin the newly-fetched handshake, after cancellation")
    }

    @Test("cancelActiveAttempt() is a safe no-op when no attempt is active")
    func cancellingWithNoActiveAttemptIsANoOp() {
        let transport = FakeParentAuthenticationTransport()
        let sessionStore = FakeParentSessionStore()
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service)

        coordinator.cancelActiveAttempt()

        #expect(coordinator.activeAttempt == nil)
        #expect(coordinator.statusMessage == nil)
    }

    // MARK: - 4. Sign-out UI state changes before a suspended revoke completes

    @Test("signOut() flips isSignedIn synchronously, before a suspended revoke call resolves")
    func signOutFlipsStateBeforeSuspendedRevokeResolves() async throws {
        let sessionStore = FakeParentSessionStore()
        sessionStore.currentToken = "existing-session-token"
        let revokeBody = try JSONSerialization.data(withJSONObject: ["outcome": "revoked"] as [String: Any])
        let transport = SuspendableFakeTransport(gatedPath: "parent-session-revoke", statusCode: 200, body: revokeBody)
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service)
        #expect(coordinator.isSignedIn == true)

        let revokeTask = coordinator.signOut()

        // No `await` at all needed to observe this — `signOut()` itself
        // is synchronous up to the point it hands back the revoke Task.
        #expect(coordinator.isSignedIn == false)
        #expect(coordinator.statusMessage == nil)

        await transport.waitUntilStarted()
        // Still suspended on the network call — local state already
        // reflects "signed out" regardless.
        #expect(coordinator.isSignedIn == false)

        await transport.release()
        await revokeTask.value

        // Confirmed server-side — no "couldn't confirm" message needed.
        #expect(coordinator.statusMessage == nil)
    }

    @Test("signOut() reports the truthful 'could not confirm' message once a suspended revoke resolves as a failure — never claiming success it can't confirm")
    func signOutReportsTruthfulMessageWhenRevokeFails() async throws {
        let sessionStore = FakeParentSessionStore()
        sessionStore.currentToken = "existing-session-token"
        let transport = SuspendableFakeTransport(gatedPath: "parent-session-revoke", statusCode: 500, body: Data())
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service)

        let revokeTask = coordinator.signOut()
        #expect(coordinator.isSignedIn == false)

        await transport.waitUntilStarted()
        await transport.release()
        await revokeTask.value

        #expect(coordinator.statusMessage == "Signed out on this device. We couldn't confirm your session was closed on the server.")
    }

    // MARK: - Supporting behavior

    @Test("forceSignedOut(statusMessage:) flips isSignedIn and sets the message atomically, without attempting any network call")
    func forceSignedOutSetsStateWithoutNetworkCall() {
        let transport = FakeParentAuthenticationTransport()
        let sessionStore = FakeParentSessionStore()
        sessionStore.currentToken = "existing-session-token"
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service)

        coordinator.forceSignedOut(statusMessage: "Your session has expired. Please sign in again.")

        #expect(coordinator.isSignedIn == false)
        #expect(coordinator.statusMessage == "Your session has expired. Please sign in again.")
        #expect(transport.sentRequests.isEmpty)
        // Unlike signOut(), the local token itself is left untouched —
        // this path exists for when the BACKEND already told us the
        // session is unusable, not for a fresh local revoke attempt.
        #expect(sessionStore.currentToken == "existing-session-token")
    }

    @Test("beginAttempt() returns nil and pins nothing when no idle handshake is available")
    func beginAttemptReturnsNilWithNoIdleHandshake() {
        let transport = FakeParentAuthenticationTransport()
        let sessionStore = FakeParentSessionStore()
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service)

        let pinned = coordinator.beginAttempt()

        #expect(pinned == nil)
        #expect(coordinator.activeAttempt == nil)
    }

    @Test("fetchReadyHandshakeIfNeeded() is a no-op while already signed in")
    func fetchIsANoOpWhileSignedIn() async {
        let transport = FakeParentAuthenticationTransport()
        let sessionStore = FakeParentSessionStore()
        sessionStore.currentToken = "existing-session-token"
        let service = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let coordinator = ParentSignInCoordinator(service: service)
        #expect(coordinator.isSignedIn == true)

        await coordinator.fetchReadyHandshakeIfNeeded()

        #expect(transport.sentRequests.isEmpty)
        #expect(coordinator.canAttemptSignIn == false)
    }
}
