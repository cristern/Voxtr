import Testing
import Foundation
import VoxtrParentAuthentication
@testable import VoxtrAppShell

// Athlete Connection V1 device-authorization session contract (§3.3–
// §3.5, §8 step 4). Exercises `AthleteDeviceAuthorizationSessionManager`'s
// policy — sliding/absolute transitions, automatic reissue, bounded
// retry on ambiguous network failures, concurrent-call coalescing, and
// reinstall/missing-key handling — against the REAL
// `AthleteDeviceAuthorizationSessionService` driven by a fake transport
// and fake signing-key store, matching
// `AthleteDeviceAuthorizationPairingCoordinatorTests.swift`'s own
// established "exercise the coordinator through the real service" shape
// for the sibling claim-proof coordinator. A separate, in-memory fake
// `AthleteDeviceAuthorizationSessionStoring` gives these policy tests a
// deterministic, fast persistence seam; the REAL Keychain-backed store
// is exercised directly in its own round-trip test below, matching
// `ParentAuthenticationServiceTests.swift`'s own "Keychain round trip"
// precedent.

/// `@MainActor`-isolated (ChatGPT review 6035314336, build 246): this
/// fake's mutable dictionaries were previously synchronized by nothing
/// but `@unchecked Sendable` itself — a bare assertion, not real
/// synchronization. `send(_:)` is `async` and, being on an unisolated
/// type, could genuinely resume on a different thread than the one
/// that called it; the test struct above is itself `@MainActor` and
/// calls `suspendNextResponse`/`resumeSuspendedResponse`/reads
/// `sentRequests` synchronously from its own test bodies while a
/// suspended `send(_:)` call is still parked mid-flight — true
/// concurrent mutable-dictionary access from two different threads,
/// a real data race (confirmed by build 246's crash stack: an
/// NSInvalidArgumentException inside `Dictionary` lookup from
/// `waitUntilSuspended`, not a production SwiftData/CloudKit defect —
/// the crashing frame is this fake's own lookup). Pinning the whole
/// type to `@MainActor` makes every one of its methods run on the
/// same actor as the test body that drives it, so no two accesses to
/// its state can ever overlap; `@unchecked Sendable` is kept only to
/// satisfy `ParentAuthenticationTransport: Sendable`'s conformance
/// requirement, now backed by genuine actor isolation rather than a
/// bare assertion.
@MainActor
private final class FakeManagerTransport: ParentAuthenticationTransport, @unchecked Sendable {
    private enum StubOutcome {
        case response(Int, Data)
        case failure
    }
    struct SimulatedNetworkFailure: Error {}
    struct NoStubConfigured: Error {}

    private var stubsByPath: [String: [StubOutcome]] = [:]
    private(set) var sentRequests: [URLRequest] = []

    /// R6 (ChatGPT review 6024820299/6025069937) deterministic-
    /// suspension support, pure polling (`Task.yield()`), deliberately
    /// NEVER `withCheckedContinuation` — no continuation-contract risk
    /// (double-resume, never-resumed leaks) to get wrong blind. Each
    /// armed suspension gets its own monotonic SLOT number (the
    /// current `activeSuspensionCountByPath[path]` at the moment it
    /// parks); `resumeSuspendedResponse` releases slots strictly in
    /// FIFO order by bumping `releaseCountByPath`, so multiple
    /// concurrent suspensions on the SAME path can be resumed one at a
    /// time, oldest first — needed to exercise an older, still-
    /// suspended task's deferred cleanup while a NEWER same-grant task
    /// is also suspended. `suspendNextResponse` arms exactly one more
    /// suspension per call (callable multiple times for multiple
    /// concurrent suspensions on the same path). The stub is popped
    /// BEFORE the suspension check so a later, un-suspended caller for
    /// the same path (e.g. a fresh post-clear attempt, once all armed
    /// suspensions are already consumed) can never steal an
    /// already-parked call's own reserved response.
    private var pendingSuspensionCountByPath: [String: Int] = [:]
    private var activeSuspensionCountByPath: [String: Int] = [:]
    private var releaseCountByPath: [String: Int] = [:]

    func enqueue(path: String, statusCode: Int, json: [String: Any?]) {
        let cleaned = json.compactMapValues { $0 }
        let body = try! JSONSerialization.data(withJSONObject: cleaned)
        stubsByPath[path, default: []].append(.response(statusCode, body))
    }

    func enqueueFailure(path: String) {
        stubsByPath[path, default: []].append(.failure)
    }

    func suspendNextResponse(path: String) {
        pendingSuspensionCountByPath[path, default: 0] += 1
    }

    /// Polls (cooperative `Task.yield()`, never a real timer) until at
    /// least `count` calls to `send(_:)` for `path` have reserved their
    /// own stub and parked — deterministic: it only returns once that
    /// specific state is true, however many yields it takes.
    func waitUntilSuspended(path: String, count: Int = 1) async {
        while (activeSuspensionCountByPath[path] ?? 0) < count {
            await Task.yield()
        }
    }

    /// Releases the OLDEST still-parked call for `path` (FIFO). A call
    /// resumes once `releaseCountByPath[path]` exceeds its own slot
    /// number, so releasing in order here always frees slot 0, then 1,
    /// then 2, regardless of how many are concurrently parked.
    func resumeSuspendedResponse(path: String) {
        releaseCountByPath[path, default: 0] += 1
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sentRequests.append(request)
        let path = request.url!.lastPathComponent
        guard var stubs = stubsByPath[path], !stubs.isEmpty else {
            throw NoStubConfigured()
        }
        let stub = stubs.removeFirst()
        stubsByPath[path] = stubs
        if let pending = pendingSuspensionCountByPath[path], pending > 0 {
            pendingSuspensionCountByPath[path] = pending - 1
            let mySlot = activeSuspensionCountByPath[path] ?? 0
            activeSuspensionCountByPath[path] = mySlot + 1
            while (releaseCountByPath[path] ?? 0) <= mySlot {
                await Task.yield()
            }
        }
        switch stub {
        case .failure:
            throw SimulatedNetworkFailure()
        case .response(let statusCode, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
    }
}

private final class FakeManagerSigningKeyStore: AthleteDeviceSigningKeyStoring, @unchecked Sendable {
    let fixedPublicKey = Data([0x04] + Array(repeating: 0xAB, count: 64))
    let fixedSignature = Data(Array(repeating: 0xCD, count: 64))
    private(set) var loadOrCreateCallCount = 0
    private(set) var loadExistingCallCount = 0
    var throwOnLoadExisting = false

    func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey {
        loadOrCreateCallCount += 1
        return makeKey()
    }

    func loadExistingSigningKey() throws -> AthleteDeviceSigningKey {
        loadExistingCallCount += 1
        if throwOnLoadExisting {
            throw AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation
        }
        return makeKey()
    }

    private func makeKey() -> AthleteDeviceSigningKey {
        AthleteDeviceSigningKey(fixedPublicKey: fixedPublicKey, fixedSignature: fixedSignature) { _ in }
    }
}

/// Deterministic, in-memory — never real Keychain I/O. Tracks call
/// counts so tests can assert exactly when the manager persists/clears.
private final class FakeManagerSessionStore: AthleteDeviceAuthorizationSessionStoring, @unchecked Sendable {
    var stored: AthleteDeviceAuthorizationSessionRecord?
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    func loadSession() -> AthleteDeviceAuthorizationSessionRecord? { stored }

    func saveSession(_ record: AthleteDeviceAuthorizationSessionRecord) throws {
        saveCallCount += 1
        stored = record
    }

    func clearSession() {
        clearCallCount += 1
        stored = nil
    }
}

/// Injectable, mutable "now" — CLAUDE.md §8: time-dependent tests must
/// never depend on `Date()`/CI run time for an exact asserted result.
private final class FakeManagerClock: AthleteDeviceAuthorizationSessionClock, @unchecked Sendable {
    var currentTime: Date
    init(currentTime: Date) { self.currentTime = currentTime }
    func now() -> Date { currentTime }
}

@Suite("AthleteDeviceAuthorizationSessionManager (Athlete Connection V1, device-authorization session policy)")
@MainActor
struct AthleteDeviceAuthorizationSessionManagerTests {

    private static let baseURL = URL(string: "https://device-auth.invalid/functions/v1")!
    private static let deviceGrantId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let otherDeviceGrantId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private static let anonKey = "test-anon-key"
    private static let wellFormedNonce = Data((0..<32).map { UInt8($0) })
    private static let referenceNow = ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")!

    private struct Fixture {
        let manager: AthleteDeviceAuthorizationSessionManager
        let transport: FakeManagerTransport
        let signingKeyStore: FakeManagerSigningKeyStore
        let store: FakeManagerSessionStore
        let clock: FakeManagerClock
    }

    private func makeFixture(now: Date = Self.referenceNow) -> Fixture {
        let transport = FakeManagerTransport()
        let signingKeyStore = FakeManagerSigningKeyStore()
        let service = AthleteDeviceAuthorizationSessionService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration(anonKey: Self.anonKey),
            transport: transport,
            signingKeyStore: signingKeyStore
        )
        let store = FakeManagerSessionStore()
        let clock = FakeManagerClock(currentTime: now)
        let manager = AthleteDeviceAuthorizationSessionManager(service: service, store: store, clock: clock)
        return Fixture(manager: manager, transport: transport, signingKeyStore: signingKeyStore, store: store, clock: clock)
    }

    private func enqueueIssueSuccess(_ transport: FakeManagerTransport, sessionToken: String, expiresAt: String, absoluteExpiresAt: String) {
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": UUID().uuidString,
            "nonce": AthleteDeviceAuthorizationSessionService.base64UrlEncode(Self.wellFormedNonce),
            "expires_at": "2026-10-05T00:01:00Z",
        ])
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "issued",
            "session_token": sessionToken,
            "expires_at": expiresAt,
            "absolute_expires_at": absoluteExpiresAt,
        ])
    }

    private func enqueueRenewSuccess(_ transport: FakeManagerTransport, expiresAt: String, absoluteExpiresAt: String) {
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": UUID().uuidString,
            "nonce": AthleteDeviceAuthorizationSessionService.base64UrlEncode(Self.wellFormedNonce),
            "expires_at": "2026-10-05T00:01:00Z",
        ])
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "renewed",
            "expires_at": expiresAt,
            "absolute_expires_at": absoluteExpiresAt,
        ])
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// R6 follow-up (ChatGPT review 6025279987: "five yields still do
    /// not establish a join barrier") — a REAL deterministic barrier,
    /// built on `joinCountForTesting` (an internal, `@testable`-only
    /// observability seam on the manager itself, bumped exactly when
    /// `ensureActiveSession()` joins an already-registered in-flight
    /// task) rather than trusting `Task.yield()` scheduling order.
    /// Polling never returns until a join has ACTUALLY been recorded
    /// past `countBefore` — proof, not a probabilistic guess.
    private func waitForJoin(_ manager: AthleteDeviceAuthorizationSessionManager, afterCount countBefore: Int) async {
        while manager.joinCountForTesting <= countBefore {
            await Task.yield()
        }
    }

    /// Compile fix (ChatGPT review 6025997463, build 245):
    /// `#expect(throws:)`'s own trailing closure cannot capture an
    /// `async let` binding at all — the Swift compiler rejects it
    /// outright ("capturing 'async let' variables is not supported"),
    /// which is what made every `async let`-based test below fail to
    /// COMPILE, not merely fail to pass. The suspiciously-fast CI
    /// failures across four prior pushes were this one compile
    /// diagnostic, never a real assertion or a deeper race. Every call
    /// site below instead `try await`s its async-let binding directly
    /// in its own `do`/`catch`, with no enclosing closure at all, and
    /// hands the already-materialized thrown `Error` to this ordinary
    /// (non-closure-capturing) helper.
    private func expectSessionCleared(_ error: Error) {
        guard let failure = error as? AthleteDeviceAuthorizationSessionManager.SessionFailure else {
            Issue.record("Expected SessionFailure.sessionCleared, got \(error)")
            return
        }
        #expect(failure == .sessionCleared, "Expected .sessionCleared, got \(failure)")
    }

    // MARK: - No stored session (first use after claim)

    @Test("ensureActiveSession() issues a brand-new session, using the existing installation key, when nothing is stored yet")
    func issuesFreshSessionWhenNothingStored() async throws {
        let fixture = makeFixture()
        enqueueIssueSuccess(fixture.transport, sessionToken: "brand-new-token", expiresAt: "2026-10-12T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "brand-new-token")
        #expect(fixture.signingKeyStore.loadExistingCallCount == 1)
        #expect(fixture.signingKeyStore.loadOrCreateCallCount == 0)
        #expect(fixture.store.saveCallCount == 1)
        #expect(fixture.store.stored?.sessionToken == "brand-new-token")
    }

    // MARK: - Sliding window still open

    @Test("ensureActiveSession() returns the stored token directly, with NO network call, while the sliding window is still open")
    func returnsStoredTokenWithoutNetworkCallWhileSlidingWindowOpen() async throws {
        let fixture = makeFixture(now: Self.date("2026-10-06T00:00:00Z"))
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId,
            sessionToken: "still-valid-token",
            expiresAt: Self.date("2026-10-12T00:00:00Z"),
            absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "still-valid-token")
        #expect(fixture.transport.sentRequests.isEmpty)
    }

    @Test("Relaunch continuity: a FRESH manager instance, given the same persisted record, returns it directly without any network call")
    func relaunchReusesPersistedSessionWithoutNetworkCall() async throws {
        let transport = FakeManagerTransport()
        let signingKeyStore = FakeManagerSigningKeyStore()
        let service = AthleteDeviceAuthorizationSessionService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration(anonKey: Self.anonKey),
            transport: transport, signingKeyStore: signingKeyStore
        )
        let sharedStore = FakeManagerSessionStore()
        sharedStore.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "surviving-relaunch-token",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        // A brand-new manager, as a relaunch would construct — only the
        // underlying store survives (Keychain's own real persistence);
        // nothing in this manager's own in-memory state does.
        let relaunchedManager = AthleteDeviceAuthorizationSessionManager(
            service: service, store: sharedStore, clock: FakeManagerClock(currentTime: Self.date("2026-10-06T00:00:00Z"))
        )

        let token = try await relaunchedManager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "surviving-relaunch-token")
        #expect(transport.sentRequests.isEmpty)
    }

    // MARK: - Within the renewal lead time, sliding window NOT YET lapsed: renew
    //
    // R4 (PR #116, ChatGPT review 6020919614): confirmed directly
    // against `authz.device_session_issue_challenge`/
    // `authz.device_session_submit`
    // (`20261004060000_authz_device_session_v1.sql`) that the real
    // backend only ever accepts `session_renew` while
    // `now < session.expires_at` — rejecting with
    // `session_invalid`/`not_available` once the sliding window has
    // already lapsed. These tests exercise renewal in the ONLY window
    // where that is possible: before `expiresAt`, within
    // `slidingWindowRenewalLeadTime` of it.

    @Test("ensureActiveSession() renews (fresh signature) proactively, within the renewal lead time but BEFORE the sliding window lapses, keeping the SAME token and persisting the rotated expiry")
    func renewsProactivelyWithinLeadTimeBeforeSlidingWindowLapses() async throws {
        let fixture = makeFixture(now: Self.date("2026-10-11T12:00:00Z"))
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "token-to-renew",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        enqueueRenewSuccess(fixture.transport, expiresAt: "2026-10-19T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "token-to-renew", "session_renew never rotates the bearer token itself")
        #expect(fixture.store.stored?.sessionToken == "token-to-renew")
        #expect(fixture.store.stored?.expiresAt == Self.date("2026-10-19T00:00:00Z"))
        let submitBody = try JSONSerialization.jsonObject(with: fixture.transport.sentRequests[1].httpBody!) as? [String: Any]
        #expect(submitBody?["session_token"] as? String == "token-to-renew")
    }

    @Test("ensureActiveSession() falls through to a fresh session_issue (same key, no re-pairing) when renewal (attempted BEFORE expiresAt) is cleanly rejected")
    func fallsThroughToFreshIssueWhenRenewalCleanlyRejected() async throws {
        let fixture = makeFixture(now: Self.date("2026-10-11T12:00:00Z"))
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "stale-token",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        // Renewal's challenge step reports session_invalid — a clean
        // rejection, not a transient network issue.
        fixture.transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "session_invalid"])
        enqueueIssueSuccess(fixture.transport, sessionToken: "freshly-issued-token", expiresAt: "2026-10-20T00:00:00Z", absoluteExpiresAt: "2027-01-11T00:00:00Z")

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "freshly-issued-token")
        #expect(fixture.signingKeyStore.loadOrCreateCallCount == 0, "a fresh chain still uses the SAME existing key — never mints a new one")
    }

    // MARK: - Sliding window ALREADY lapsed, absolute cap not yet reached: issue, never renew

    @Test("ensureActiveSession() issues a fresh chain rather than attempting renewal once the sliding window has already lapsed — the real backend always rejects a post-expiry renewal attempt (R4)")
    func issuesFreshChainRatherThanAttemptingRenewalOnceSlidingWindowHasLapsed() async throws {
        let fixture = makeFixture(now: Self.date("2026-10-13T00:00:00Z"))
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "token-past-sliding-window",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        // ONLY an issue-success stub — if the manager mistakenly
        // attempted session_renew first (as it did before this fix),
        // it would consume this stub's "issued" challenge response but
        // then fail to parse the submit response as a renewal, since
        // no renew-shaped stub exists at all here.
        enqueueIssueSuccess(fixture.transport, sessionToken: "new-chain-token", expiresAt: "2026-10-20T00:00:00Z", absoluteExpiresAt: "2027-01-11T00:00:00Z")

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "new-chain-token")
        #expect(fixture.signingKeyStore.loadOrCreateCallCount == 0)
        // Exactly one challenge+submit round trip — renewal was never
        // attempted once the sliding window had already lapsed.
        #expect(fixture.transport.sentRequests.count == 2)
    }

    // MARK: - Absolute cap reached: automatic reissue, no Parent re-pairing

    @Test("ensureActiveSession() automatically issues a brand-new chain once the absolute cap has elapsed — never attempting renewal, never requiring Parent re-pairing")
    func automaticallyReissuesAfterAbsoluteCapWithoutRepairing() async throws {
        let fixture = makeFixture(now: Self.date("2027-01-04T00:00:00Z"))
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "expired-chain-token",
            expiresAt: Self.date("2026-12-28T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        enqueueIssueSuccess(fixture.transport, sessionToken: "new-chain-token", expiresAt: "2027-01-11T00:00:00Z", absoluteExpiresAt: "2027-04-04T00:00:00Z")

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "new-chain-token")
        #expect(fixture.signingKeyStore.loadOrCreateCallCount == 0)
        // Exactly one challenge+submit round trip — renewal was never
        // attempted once the absolute cap had already elapsed.
        #expect(fixture.transport.sentRequests.count == 2)
    }

    // MARK: - Boundary (CLAUDE.md §8: exact, deterministic, clock-injected)

    @Test("At the exact expiresAt instant, the sliding window is treated as lapsed (now < expiresAt is false) — a fresh session_issue, never a renewal attempt, since renewal is no longer backend-legal at that exact instant either")
    func exactExpiresAtBoundaryIsTreatedAsLapsed() async throws {
        let boundary = Self.date("2026-10-12T00:00:00Z")
        let fixture = makeFixture(now: boundary)
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "boundary-token",
            expiresAt: boundary, absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        enqueueIssueSuccess(fixture.transport, sessionToken: "new-token-after-boundary", expiresAt: "2026-10-19T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "new-token-after-boundary")
        #expect(!fixture.transport.sentRequests.isEmpty, "exactly-at-expiry must trigger a fresh network round trip, never be treated as still valid")
    }

    @Test("At the exact renewal-lead-time boundary (expiresAt minus slidingWindowRenewalLeadTime), renewal is triggered, not the no-network fast path")
    func exactLeadTimeBoundaryTriggersRenewalNotFastPath() async throws {
        let expiresAt = Self.date("2026-10-12T00:00:00Z")
        let boundary = expiresAt.addingTimeInterval(-AthleteDeviceAuthorizationSessionManager.slidingWindowRenewalLeadTime)
        let fixture = makeFixture(now: boundary)
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "lead-time-boundary-token",
            expiresAt: expiresAt, absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        enqueueRenewSuccess(fixture.transport, expiresAt: "2026-10-19T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "lead-time-boundary-token", "session_renew never rotates the bearer token itself")
        #expect(!fixture.transport.sentRequests.isEmpty, "exactly at the lead-time boundary must trigger renewal, never be treated as comfortably within the window")
    }

    // MARK: - ensureFreshlyVerifiedSession(deviceGrantId:) (Athlete hydration/activation integration slice, §5.2)

    @Test("ensureFreshlyVerifiedSession(deviceGrantId:) performs a genuine session_renew round trip even while the stored token is COMFORTABLY within the sliding window — the one thing ensureActiveSession()'s own intentional fast path would skip")
    func ensureFreshlyVerifiedSessionNeverTakesTheCachedFastPath() async throws {
        let fixture = makeFixture()
        // Comfortably within the window: far more than
        // `slidingWindowRenewalLeadTime` remains — `ensureActiveSession()`
        // would return this cached token with ZERO network calls.
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "comfortably-cached-token",
            expiresAt: Self.referenceNow.addingTimeInterval(6 * 24 * 60 * 60), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        enqueueRenewSuccess(fixture.transport, expiresAt: "2026-10-19T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        let token = try await fixture.manager.ensureFreshlyVerifiedSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "comfortably-cached-token", "session_renew never rotates the bearer token itself")
        #expect(fixture.transport.sentRequests.count == 2, "a real challenge+submit round trip must occur despite the comfortably-unexpired cached token")
    }

    @Test("ensureFreshlyVerifiedSession(deviceGrantId:) issues a brand-new chain when no session is stored at all — same automatic-reissue policy as ensureActiveSession()")
    func ensureFreshlyVerifiedSessionIssuesFreshChainWhenNoneStored() async throws {
        let fixture = makeFixture()
        enqueueIssueSuccess(fixture.transport, sessionToken: "freshly-issued-token", expiresAt: "2026-10-19T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        let token = try await fixture.manager.ensureFreshlyVerifiedSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "freshly-issued-token")
        #expect(fixture.store.saveCallCount == 1)
    }

    @Test("ensureFreshlyVerifiedSession(deviceGrantId:) still reports .grantUnavailable and clears the stored session when the backend reports the grant is gone — same denial policy as ensureActiveSession()")
    func ensureFreshlyVerifiedSessionReportsGrantUnavailable() async throws {
        let fixture = makeFixture()
        // No stored session at all: `ensureFreshlyVerifiedSession` goes
        // straight to `attemptIssue`, whose own `.grantNotAvailable`
        // branch throws `.grantUnavailable` directly (unlike
        // `attemptRenew`'s own `.grantNotAvailable`, which instead
        // falls through to a fresh issue attempt).
        fixture.transport.enqueue(path: "device-session-challenge", statusCode: 200, json: [
            "outcome": "issued", "challenge_id": UUID().uuidString,
            "nonce": AthleteDeviceAuthorizationSessionService.base64UrlEncode(Self.wellFormedNonce),
            "expires_at": "2026-10-05T00:01:00Z",
        ])
        fixture.transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": "grant_not_available"])

        await #expect(throws: AthleteDeviceAuthorizationSessionManager.SessionFailure.grantUnavailable) {
            _ = try await fixture.manager.ensureFreshlyVerifiedSession(deviceGrantId: Self.deviceGrantId)
        }
        #expect(fixture.store.clearCallCount == 1)
    }

    // MARK: - Reinstall / missing installation key

    @Test("ensureActiveSession() throws .installationKeyUnavailable and clears any stored session when the installation key is missing (reinstall) — never minting a replacement, and never even attempting a network call")
    func clearsStoredSessionAndThrowsOnMissingInstallationKey() async throws {
        let fixture = makeFixture()
        fixture.signingKeyStore.throwOnLoadExisting = true
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "orphaned-token",
            expiresAt: Self.date("2026-10-01T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        // R5 (PR #116, ChatGPT review 6020919614): the installation-key
        // check now happens LOCALLY, before any network attempt, for
        // ANY stored session regardless of its expiry state — no
        // challenge/submit stub is needed or consumed here at all.
        await #expect(throws: AthleteDeviceAuthorizationSessionManager.SessionFailure.installationKeyUnavailable) {
            try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        }
        #expect(fixture.store.clearCallCount == 1)
        #expect(fixture.store.stored == nil)
        #expect(fixture.signingKeyStore.loadOrCreateCallCount == 0)
        #expect(fixture.transport.sentRequests.isEmpty, "the signing-key check is purely local — a lost/orphaned key must never cost a network round trip")
    }

    @Test("ensureActiveSession() throws .installationKeyUnavailable for an UNEXPIRED cached session too (R4/R5, ChatGPT review 6020919614) — a reinstalled app's surviving Keychain session is never trusted just because its sliding window still looks open")
    func installationKeyCheckAppliesEvenWhileSlidingWindowIsComfortablyOpen() async throws {
        let fixture = makeFixture(now: Self.date("2026-10-06T00:00:00Z"))
        fixture.signingKeyStore.throwOnLoadExisting = true
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "surviving-reinstall-token",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )

        await #expect(throws: AthleteDeviceAuthorizationSessionManager.SessionFailure.installationKeyUnavailable) {
            try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        }
        #expect(fixture.store.clearCallCount == 1)
        #expect(fixture.store.stored == nil, "the stale, reinstall-surviving session must be discarded, never handed back as if it were still this installation's own")
        #expect(fixture.transport.sentRequests.isEmpty)
    }

    // MARK: - Explicit clear racing an in-flight operation (R6, ChatGPT review 6024820299)
    //
    // clearStoredSession() only cleared the store, with no generation
    // tracking and no invalidation of inFlightTasks. A deterministic
    // sequence — start issue/renew, suspend the transport before the
    // successful submit response returns, call clearStoredSession(),
    // resume the response — let attemptRenew/attemptIssue
    // unconditionally persist and return the pre-clear result,
    // resurrecting the session the caller just explicitly cleared; a
    // subsequent caller could also join that same doomed task. Fixed
    // with a sessionGeneration counter (mirroring
    // ParentAuthenticationService's own established guard) checked
    // right before persisting, plus eviction of inFlightTasks on
    // clear so a new caller never joins a pre-clear operation.

    @Test("clearStoredSession() mid-flight: a renewal already past its backend submit cannot resurrect the session afterward")
    func clearDuringSuspendedRenewalNeverResurrectsSession() async throws {
        let fixture = makeFixture(now: Self.date("2026-10-11T12:00:00Z"))
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "token-to-renew",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        enqueueRenewSuccess(fixture.transport, expiresAt: "2026-10-19T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")
        fixture.transport.suspendNextResponse(path: "device-session-submit")

        async let resultToken = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-submit")

        // The caller explicitly clears while the renewal is still
        // suspended, having already been told by the backend (not yet
        // delivered locally) that it succeeded.
        fixture.manager.clearStoredSession()
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit")

        do {
            _ = try await resultToken
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }
        #expect(fixture.store.stored == nil, "the backend's successful renewal must never be written back after an explicit clear")
        #expect(fixture.store.saveCallCount == 0)
    }

    @Test("clearStoredSession() mid-flight: a coalesced waiter and the original caller BOTH receive the failure, never a stale successful token")
    func clearDuringSuspendedRenewalFailsAllCoalescedWaiters() async throws {
        let fixture = makeFixture(now: Self.date("2026-10-11T12:00:00Z"))
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "token-to-renew",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        enqueueRenewSuccess(fixture.transport, expiresAt: "2026-10-19T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")
        fixture.transport.suspendNextResponse(path: "device-session-submit")

        async let first = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-submit")
        // Joins the SAME in-flight attempt — registered while still
        // suspended, before the clear below.
        let joinCountBeforeSecond = fixture.manager.joinCountForTesting
        async let second = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        // Real barrier (R6 follow-up, ChatGPT review 6025279987): waits
        // until second's own join has ACTUALLY been recorded, not a
        // guessed number of scheduling turns.
        await waitForJoin(fixture.manager, afterCount: joinCountBeforeSecond)

        fixture.manager.clearStoredSession()
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit")

        do {
            _ = try await first
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }
        do {
            _ = try await second
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }
        #expect(fixture.transport.sentRequests.count == 2, "the second caller coalesced onto the first's attempt — never its own independent round trip")
        #expect(fixture.store.saveCallCount == 0)
    }

    @Test("A new ensureActiveSession() call after clearStoredSession() never joins the doomed pre-clear attempt — it runs its own fresh, independent, successful round trip, and the resumed pre-clear attempt cannot overwrite it")
    func newAttemptAfterClearNeverJoinsDoomedPreClearOperation() async throws {
        // No stored session — the pre-clear attempt is a fresh session_issue.
        let fixture = makeFixture()
        enqueueIssueSuccess(fixture.transport, sessionToken: "doomed-pre-clear-token", expiresAt: "2026-10-12T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")
        fixture.transport.suspendNextResponse(path: "device-session-submit")

        async let preClearResult = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-submit")

        fixture.manager.clearStoredSession()

        // A genuinely NEW attempt for the SAME grant, with its own
        // fresh challenge+submit queued separately below, must not be
        // blocked on or coalesced with the still-suspended pre-clear
        // attempt — it runs to completion entirely on its own.
        enqueueIssueSuccess(fixture.transport, sessionToken: "fresh-post-clear-token", expiresAt: "2026-10-20T00:00:00Z", absoluteExpiresAt: "2027-01-11T00:00:00Z")
        let postClearToken = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(postClearToken == "fresh-post-clear-token")
        #expect(fixture.store.stored?.sessionToken == "fresh-post-clear-token")

        fixture.transport.resumeSuspendedResponse(path: "device-session-submit")
        do {
            _ = try await preClearResult
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }

        // The resumed, doomed pre-clear attempt must never overwrite
        // the fresh post-clear session once it finally completes.
        #expect(fixture.store.stored?.sessionToken == "fresh-post-clear-token")
        #expect(fixture.transport.sentRequests.count == 4, "two fully independent challenge+submit round trips — the post-clear attempt was never coalesced with the pre-clear one")
    }

    // MARK: - R6 follow-up (ChatGPT review 6025069937): invalidation
    // checked after EVERY resumed outcome/error, not only before the
    // final persist
    //
    // The generation guard above was originally checked only in the
    // `.issued`/`.renewed` success branches. A stale pre-clear
    // operation resuming with ANY other outcome (a clean rejection, an
    // error) would still run that branch's own side effect
    // (`store.clearSession()`, deleting a genuinely newer post-clear
    // session) or start a further network attempt (a `.network`
    // retry, or falling through from a rejected renewal to a fresh
    // `session_issue` — which has a REAL server-side effect, revoking
    // the grant's current active session, regardless of whether the
    // stale operation's own eventual local result is later discarded).
    // Fixed by checking invalidation immediately after every resumed
    // result, before any of that call's own branches run.

    @Test("A stale pre-clear issue's challenge resuming with grantNotAvailable must not clear a newer post-clear session")
    func staleGrantNotAvailableNeverClearsNewerPostClearSession() async throws {
        let fixture = makeFixture()
        fixture.transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "challenge_not_available"])
        fixture.transport.suspendNextResponse(path: "device-session-challenge")

        async let preClearResult = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-challenge")

        fixture.manager.clearStoredSession()

        enqueueIssueSuccess(fixture.transport, sessionToken: "fresh-post-clear-token", expiresAt: "2026-10-20T00:00:00Z", absoluteExpiresAt: "2027-01-11T00:00:00Z")
        let postClearToken = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        #expect(postClearToken == "fresh-post-clear-token")
        #expect(fixture.store.stored?.sessionToken == "fresh-post-clear-token")

        fixture.transport.resumeSuspendedResponse(path: "device-session-challenge")
        do {
            _ = try await preClearResult
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }

        // The resumed, stale grantNotAvailable outcome must never have
        // cleared the newer post-clear session — it must survive intact.
        #expect(fixture.store.stored?.sessionToken == "fresh-post-clear-token")
        #expect(fixture.store.clearCallCount == 1, "exactly the ORIGINAL clearStoredSession() call — the stale grantNotAvailable branch's own store.clearSession() must never run")
    }

    @Test("A stale pre-clear operation's network error must not be retried — it throws sessionCleared immediately instead")
    func staleNetworkErrorNeverRetries() async throws {
        let fixture = makeFixture()
        fixture.transport.enqueueFailure(path: "device-session-challenge")
        fixture.transport.suspendNextResponse(path: "device-session-challenge")

        async let preClearResult = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-challenge")

        fixture.manager.clearStoredSession()
        fixture.transport.resumeSuspendedResponse(path: "device-session-challenge")

        do {
            _ = try await preClearResult
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }
        #expect(fixture.transport.sentRequests.count == 1, "a stale network error must not be retried with a fresh challenge")
    }

    @Test("A stale pre-clear renewal's clean rejection (session_invalid at the challenge step) must not fall through to a fresh session_issue — that fallback has a REAL server-side effect (revoking the grant's current active session) a merely-discarded local result cannot undo")
    func staleRejectedRenewalNeverFallsThroughToFreshIssue() async throws {
        // R6 follow-up test correction (ChatGPT review 6025279987):
        // "session_invalid" is only a valid CHALLENGE-step outcome —
        // mapSubmitOutcome rejects it as malformed if it ever appeared
        // on the submit step instead (it never does on the real wire).
        // The clean-rejection path this test exercises belongs entirely
        // to the challenge step, matching
        // fallsThroughToFreshIssueWhenRenewalCleanlyRejected's own
        // already-correct pattern above.
        let fixture = makeFixture(now: Self.date("2026-10-11T12:00:00Z"))
        fixture.store.stored = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "stale-token",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        fixture.transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "session_invalid"])
        fixture.transport.suspendNextResponse(path: "device-session-challenge")

        async let preClearResult = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-challenge")

        fixture.manager.clearStoredSession()
        fixture.transport.resumeSuspendedResponse(path: "device-session-challenge")

        do {
            _ = try await preClearResult
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }
        // Exactly one challenge — session_invalid at the challenge
        // step never reaches submit, and no fallback session_issue was
        // ever attempted for this stale, cleanly-rejected renewal.
        #expect(fixture.transport.sentRequests.count == 1)
    }

    @Test("A stale pre-clear issue's successful CHALLENGE, suspended before its own submit, must never submit once resumed after a post-clear issue already completed — invalidation is checked between challenge and submit, not only after the whole service call returns")
    func staleIssueNeverSubmitsAfterChallengeSuspendedThroughAClear() async throws {
        // Test correction (ChatGPT review 6025489857): only the old
        // operation's own CHALLENGE stub is queued here — never its
        // submit stub too. The old operation is suspended at the
        // challenge step and never reaches submit until (if the guard
        // were broken) after the post-clear issue below has already
        // run its own challenge+submit pair; an old submit stub sitting
        // unconsumed in the queue would be wrongly popped (FIFO, by
        // path) by the POST-CLEAR issue's own submit call instead,
        // making this test fail on stub cross-contamination rather than
        // on the actual invariant under test. No stub at all for the
        // old submit means: if it is ever wrongly attempted, it fails
        // loudly with NoStubConfigured (still caught by the assertions
        // below) rather than silently stealing the wrong response.
        let fixture = makeFixture()
        fixture.transport.enqueue(path: "device-session-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": UUID().uuidString,
            "nonce": AthleteDeviceAuthorizationSessionService.base64UrlEncode(Self.wellFormedNonce),
            "expires_at": "2026-10-05T00:01:00Z",
        ])
        fixture.transport.suspendNextResponse(path: "device-session-challenge")

        async let preClearResult = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-challenge")

        fixture.manager.clearStoredSession()

        enqueueIssueSuccess(fixture.transport, sessionToken: "fresh-post-clear-token", expiresAt: "2026-10-20T00:00:00Z", absoluteExpiresAt: "2027-01-11T00:00:00Z")
        let postClearToken = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        #expect(postClearToken == "fresh-post-clear-token")
        #expect(fixture.store.stored?.sessionToken == "fresh-post-clear-token")

        fixture.transport.resumeSuspendedResponse(path: "device-session-challenge")
        do {
            _ = try await preClearResult
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }

        // The stale operation's challenge succeeded (consuming its own
        // stub), but it must never have gone on to submit. If it had,
        // this would be 4 (its own challenge+submit, plus the
        // post-clear pair) instead of 3.
        #expect(fixture.transport.sentRequests.count == 3, "the stale operation's own submit must never be sent once invalidated between challenge and submit")
        #expect(fixture.store.stored?.sessionToken == "fresh-post-clear-token", "the stale operation's submit, had it wrongly been sent, would have revoked this server-side session even though its own local result is discarded")
    }

    @Test("An older same-grant task's deferred cleanup never clobbers a NEWER task's registration — a caller that joins strictly AFTER the older task's cleanup has already run still correctly coalesces onto the newer, still-suspended task")
    func olderTaskCleanupNeverClobbersNewerRegistrationAndThirdCallerCoalescesOntoIt() async throws {
        // No stored session — the stale pre-clear attempt is a fresh session_issue.
        let fixture = makeFixture()
        enqueueIssueSuccess(fixture.transport, sessionToken: "doomed-pre-clear-token", expiresAt: "2026-10-12T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")
        fixture.transport.suspendNextResponse(path: "device-session-submit")

        async let a = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-submit", count: 1)

        fixture.manager.clearStoredSession()

        enqueueIssueSuccess(fixture.transport, sessionToken: "fresh-post-clear-token", expiresAt: "2026-10-20T00:00:00Z", absoluteExpiresAt: "2027-01-11T00:00:00Z")
        fixture.transport.suspendNextResponse(path: "device-session-submit")

        async let b = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await fixture.transport.waitUntilSuspended(path: "device-session-submit", count: 2)

        // R6 follow-up test correction (ChatGPT review 6025279987):
        // release A — the OLDEST suspended call — and let its failure,
        // AND its own deferred cleanup, run to completion BEFORE
        // creating any further caller. This proves the next caller's
        // coalescing is observed strictly AFTER that cleanup ran, not
        // merely before it.
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit")
        do {
            _ = try await a
            Issue.record("Expected SessionFailure.sessionCleared to be thrown, but the operation succeeded")
        } catch {
            expectSessionCleared(error)
        }
        #expect(fixture.store.stored == nil, "B has not yet resumed/persisted")

        // A THIRD caller for the SAME grant, created only NOW —
        // strictly AFTER A's own deferred cleanup has already run —
        // while B (the newer task) is STILL suspended. If A's cleanup
        // had wrongly cleared B's registration, this caller would
        // instead start its own independent attempt, for which no
        // further stub is queued.
        //
        // Test correction (ChatGPT review 6037955977): the mid-test
        // count here is 4, not 3 — A has already sent its own
        // challenge+submit (2) and B has already sent its own
        // challenge+submit (2, recorded in sentRequests BEFORE send()
        // parks at the suspension gate) by this point; C has not yet
        // sent anything of its own. Captured immediately before C and
        // asserted unchanged after the join barrier, so a regression
        // that made C send its own request would be caught either way.
        let sentRequestsCountBeforeC = fixture.transport.sentRequests.count
        let joinCountBeforeC = fixture.manager.joinCountForTesting
        async let c = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        await waitForJoin(fixture.manager, afterCount: joinCountBeforeC)
        #expect(sentRequestsCountBeforeC == 4, "A's challenge+submit, B's challenge+submit were already sent before C was ever created")
        #expect(fixture.transport.sentRequests.count == sentRequestsCountBeforeC, "C must have coalesced onto B without sending its own challenge")

        fixture.transport.resumeSuspendedResponse(path: "device-session-submit")
        let (tokenB, tokenC) = try await (b, c)

        #expect(tokenB == "fresh-post-clear-token")
        #expect(tokenC == "fresh-post-clear-token")
        #expect(fixture.store.stored?.sessionToken == "fresh-post-clear-token")
        #expect(fixture.transport.sentRequests.count == 4, "A's challenge+submit, B's challenge+submit — C coalesced onto B, never its own independent round trip")
    }

    // MARK: - Grant revoked / unavailable

    @Test("ensureActiveSession() throws .grantUnavailable and clears any stored session when a fresh session_issue reports the grant unavailable")
    func clearsStoredSessionAndThrowsOnGrantUnavailable() async throws {
        let fixture = makeFixture()
        fixture.transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "challenge_not_available"])

        await #expect(throws: AthleteDeviceAuthorizationSessionManager.SessionFailure.grantUnavailable) {
            try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        }
        #expect(fixture.store.clearCallCount == 1)
    }

    // MARK: - Lost-response retry (bounded)

    @Test("A single lost-response (simulated network failure) during session_issue is retried with a fresh challenge and succeeds")
    func retriesOnceAfterLostResponseThenSucceeds() async throws {
        let fixture = makeFixture()
        fixture.transport.enqueueFailure(path: "device-session-challenge")
        enqueueIssueSuccess(fixture.transport, sessionToken: "token-after-retry", expiresAt: "2026-10-12T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        let token = try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)

        #expect(token == "token-after-retry")
        // Failed challenge attempt + successful challenge + successful
        // submit = 3 requests total.
        #expect(fixture.transport.sentRequests.count == 3)
    }

    @Test("Retries are bounded — persistent network failure throws .network rather than looping forever")
    func boundedRetriesEventuallyThrowNetwork() async throws {
        let fixture = makeFixture()
        for _ in 0..<AthleteDeviceAuthorizationSessionManager.maxAttemptsPerCall {
            fixture.transport.enqueueFailure(path: "device-session-challenge")
        }

        await #expect(throws: AthleteDeviceAuthorizationSessionManager.SessionFailure.network) {
            try await fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        }
        #expect(fixture.transport.sentRequests.count == AthleteDeviceAuthorizationSessionManager.maxAttemptsPerCall)
    }

    // MARK: - Concurrent calls coalesce

    @Test("Two concurrent ensureActiveSession() calls for the SAME deviceGrantId share one in-flight attempt — exactly one network round trip, both callers receive the same token")
    func concurrentCallsForSameGrantCoalesce() async throws {
        let fixture = makeFixture()
        enqueueIssueSuccess(fixture.transport, sessionToken: "coalesced-token", expiresAt: "2026-10-12T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        async let first = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        async let second = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        let (tokenA, tokenB) = try await (first, second)

        #expect(tokenA == "coalesced-token")
        #expect(tokenB == "coalesced-token")
        #expect(fixture.transport.sentRequests.count == 2, "exactly one challenge + one submit — never two independent round trips")
        #expect(fixture.store.saveCallCount == 1)
    }

    @Test("Concurrent calls for DIFFERENT deviceGrantId values never coalesce — each gets its own attempt")
    func concurrentCallsForDifferentGrantsDoNotCoalesce() async throws {
        let fixture = makeFixture()
        enqueueIssueSuccess(fixture.transport, sessionToken: "token-for-first-grant", expiresAt: "2026-10-12T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")
        enqueueIssueSuccess(fixture.transport, sessionToken: "token-for-second-grant", expiresAt: "2026-10-12T00:00:00Z", absoluteExpiresAt: "2027-01-03T00:00:00Z")

        async let first = fixture.manager.ensureActiveSession(deviceGrantId: Self.deviceGrantId)
        async let second = fixture.manager.ensureActiveSession(deviceGrantId: Self.otherDeviceGrantId)
        let (tokenA, tokenB) = try await (first, second)

        // Both attempts genuinely ran independently (no coalescing
        // across different grants) and each received a real,
        // successfully-issued token — which physical network call's
        // response landed on which grant is not itself under test,
        // since nothing client-side cross-checks a response against
        // the grant that requested it.
        #expect(Set([tokenA, tokenB]) == Set(["token-for-first-grant", "token-for-second-grant"]))
        #expect(fixture.transport.sentRequests.count == 4)
        #expect(fixture.store.saveCallCount == 2)
    }

    // MARK: - Real Keychain round trip (device-only persistence)

    // NOTE: like `ParentAuthenticationServiceTests.swift`'s own
    // "Keychain round trip" test, this exercises the real Security
    // framework Keychain APIs.
    //
    // This test (the first real-Keychain round trip of its family ever
    // actually wired into and executed by the native `VoxtrSprint0Tests`
    // target) surfaced that the target's `xcodebuild test` invocation in
    // `codemagic.yaml` originally passed `CODE_SIGNING_ALLOWED=NO` on
    // the command line, which overrides anything set in
    // `project.pbxproj`. An entirely unsigned process has no
    // application-identifier/keychain-access-group entitlement, so
    // `SecItemAdd` cannot resolve a default access group and fails with
    // `errSecMissingEntitlement` (-34018).
    //
    // STATUS (PR #116 R3, resolved): switching that command line to ad
    // hoc signing (`CODE_SIGN_IDENTITY=-`) was NOT sufficient on its
    // own — Codemagic build #228 confirmed the ad hoc signature itself
    // succeeds ("Sign to Run Locally"), but this test still failed with
    // the same `errSecMissingEntitlement` (-34018). The actual fix was
    // giving `VoxtrSprint0Tests` a real `TEST_HOST`/`BUNDLE_LOADER`
    // (set in `project.pbxproj`, scoped to that target) pointing at
    // AthleteApp, plus a genuine `PBXTargetDependency` so Xcode builds
    // it first — a bare `.xctest` bundle, ad hoc signed or not, has no
    // resolvable keychain-access-group entitlement on its own. Build
    // #239/#240 confirmed this test genuinely passes hosted this way.
    // Keep this test ENABLED — do not disable or swallow a future
    // failure here; it must either pass for real or keep surfacing a
    // genuine gap.
    @Test("KeychainAthleteDeviceAuthorizationSessionStore save/load/clear round-trips correctly and atomically replaces an existing record")
    func keychainStoreRoundTrips() throws {
        let store = KeychainAthleteDeviceAuthorizationSessionStore(
            service: "com.voxtr.athlete.deviceAuthorizationSession.tests",
            account: "device-authorization-session-test-\(UUID().uuidString)"
        )
        defer { store.clearSession() }

        #expect(store.loadSession() == nil)

        let first = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "first-token",
            expiresAt: Self.date("2026-10-12T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        try store.saveSession(first)
        #expect(store.loadSession() == first)

        // Atomic replace: a second save while a record already exists
        // must fully replace it, never leave a stale/duplicate value.
        let second = AthleteDeviceAuthorizationSessionRecord(
            deviceGrantId: Self.deviceGrantId, sessionToken: "second-token",
            expiresAt: Self.date("2026-10-19T00:00:00Z"), absoluteExpiresAt: Self.date("2027-01-03T00:00:00Z")
        )
        try store.saveSession(second)
        #expect(store.loadSession() == second)

        store.clearSession()
        #expect(store.loadSession() == nil)
    }
}
