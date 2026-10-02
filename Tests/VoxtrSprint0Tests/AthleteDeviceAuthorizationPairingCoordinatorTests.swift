import Testing
import Foundation
import VoxtrParentAuthentication
@testable import VoxtrAppShell

// Athlete Connection V1 (backend device authorization, review round 3).
// Exercises `AthleteDeviceAuthorizationPairingCoordinator` against a REAL
// `AthleteDeviceAuthorizationService`, wired to fakes at the transport/
// signing-key-store/receipt-store boundary, plus a controllable fake
// clock — the same "real service + fake network" approach
// `ParentSignInCoordinatorTests.swift` already established for the
// sibling Parent-side coordinator. Per this codebase's own convention,
// this file defines its own fakes rather than sharing them across files.
@MainActor
private final class FakePollingClock: AthleteDeviceAuthorizationPollingClock, @unchecked Sendable {
    private(set) var sleepCallCount = 0
    func sleep(for seconds: Double) async throws {
        sleepCallCount += 1
    }
}

private final class FakeTransport: ParentAuthenticationTransport, @unchecked Sendable {
    struct Stub {
        let statusCode: Int
        let body: Data
    }

    /// A QUEUE per path — `claim-challenge`/`claim-submit` can be
    /// called repeatedly across poll ticks, so a test can enqueue a
    /// whole sequence deterministically.
    private var stubsByPath: [String: [Stub]] = [:]
    private(set) var sentPaths: [String] = []

    struct NoStubConfigured: Error {}

    func enqueue(path: String, statusCode: Int, json: [String: Any?]) {
        let cleaned = json.compactMapValues { $0 }
        let body = try! JSONSerialization.data(withJSONObject: cleaned)
        stubsByPath[path, default: []].append(Stub(statusCode: statusCode, body: body))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.lastPathComponent
        sentPaths.append(path)
        guard var stubs = stubsByPath[path], !stubs.isEmpty else {
            throw NoStubConfigured()
        }
        let stub = stubs.removeFirst()
        stubsByPath[path] = stubs
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode, httpVersion: nil, headerFields: nil)!
        return (stub.body, response)
    }
}

/// Review round 3: `existingKeyAvailable` lets a test simulate a
/// reinstall/missing/corrupt key (whatever this installation's
/// `loadExistingSigningKey()` would report as absent) WITHOUT affecting
/// `loadOrCreateSigningKey()` at all — exactly mirroring the real
/// store's own two-tier contract (starting a new attempt vs continuing
/// one already bound to a specific key).
private final class FakeSigningKeyStore: AthleteDeviceSigningKeyStoring, @unchecked Sendable {
    var existingKeyAvailable = true
    private(set) var loadExistingCallCount = 0
    private(set) var loadOrCreateCallCount = 0

    func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey {
        loadOrCreateCallCount += 1
        return makeKey()
    }

    func loadExistingSigningKey() throws -> AthleteDeviceSigningKey {
        loadExistingCallCount += 1
        guard existingKeyAvailable else {
            throw AthleteDeviceSigningKeyStoreError.noKeyForCurrentInstallation
        }
        return makeKey()
    }

    private func makeKey() -> AthleteDeviceSigningKey {
        AthleteDeviceSigningKey(fixedPublicKey: Data([0x04] + Array(repeating: 0xAB, count: 64)), fixedSignature: Data(repeating: 0xCD, count: 64)) { _ in }
    }
}

private final class FakeReceiptStore: AthleteDeviceAuthorizationReceiptStoring, @unchecked Sendable {
    struct SaveFailure: Error {}

    private(set) var savedReceipts: [AthleteDeviceAuthorizationReceipt] = []
    var storedReceipt: AthleteDeviceAuthorizationReceipt?
    private(set) var clearCallCount = 0
    private(set) var saveCallCount = 0
    /// The 1-based `saveReceipt` call number that should fail, if any —
    /// a deterministic alternative to flipping a flag mid-flight (which
    /// would depend on exactly when a concurrently-running attempt
    /// happens to reach its own save call, a timing guess this task
    /// explicitly rules out). `nil` (the default) never fails.
    var failOnSaveCallNumber: Int?

    func loadReceipt() -> AthleteDeviceAuthorizationReceipt? { storedReceipt }

    func saveReceipt(_ receipt: AthleteDeviceAuthorizationReceipt) throws {
        saveCallCount += 1
        if saveCallCount == failOnSaveCallNumber {
            throw SaveFailure()
        }
        savedReceipts.append(receipt)
        storedReceipt = receipt
    }

    func clearReceipt() {
        clearCallCount += 1
        storedReceipt = nil
    }
}

@Suite("AthleteDeviceAuthorizationPairingCoordinator (Athlete Connection V1, backend device authorization, review round 3)")
@MainActor
struct AthleteDeviceAuthorizationPairingCoordinatorTests {

    private static let baseURL = URL(string: "https://device-auth.invalid/functions/v1")!
    private static let invitationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let requestId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let qrText = AthleteDeviceAuthorizationQRPayload.encode(invitationId: invitationId).absoluteString

    private func makeCoordinator(
        transport: FakeTransport = FakeTransport(),
        signingKeyStore: FakeSigningKeyStore = FakeSigningKeyStore(),
        receiptStore: FakeReceiptStore = FakeReceiptStore()
    ) -> (AthleteDeviceAuthorizationPairingCoordinator, FakeTransport, FakePollingClock, FakeReceiptStore, FakeSigningKeyStore) {
        let service = AthleteDeviceAuthorizationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration(anonKey: "test-anon-key"),
            transport: transport,
            signingKeyStore: signingKeyStore
        )
        let clock = FakePollingClock()
        let coordinator = AthleteDeviceAuthorizationPairingCoordinator(service: service, clock: clock, receiptStore: receiptStore)
        return (coordinator, transport, clock, receiptStore, signingKeyStore)
    }

    /// `beginPairing`/`resumePendingAttemptIfAny`/`continuePendingAttempt`
    /// are synchronous — they own their own `Task` internally — so tests
    /// drive the coordinator to a settled terminal state by polling
    /// `coordinator.state` with a short real sleep between checks,
    /// bounded by a generous timeout. This is NOT a timing guess about
    /// WHEN the attempt settles (the fake clock never really sleeps, so
    /// every poll tick inside the coordinator itself runs essentially
    /// instantly) — it only waits for Swift's own task scheduler to run
    /// the already-ready continuation, which real `Task.sleep` calls are
    /// the standard way to yield for in these async tests.
    private func waitForSettled(_ coordinator: AthleteDeviceAuthorizationPairingCoordinator, timeoutMS: Int = 2000) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMS))
        while ContinuousClock.now < deadline {
            switch coordinator.state {
            case .idle, .resuming, .reconfirmingPreviousGrant, .submitting, .awaitingApproval, .claiming:
                try? await Task.sleep(nanoseconds: 5_000_000)
            case .authorized, .failed, .interrupted:
                return
            }
        }
    }

    @Test("An invalid/unsupported scanned code is rejected with .failed, and no network request is ever sent")
    func invalidCodeNeverReachesTheNetwork() async {
        let (coordinator, transport, _, _, _) = makeCoordinator()

        coordinator.beginPairing(scannedText: "not a supported code")
        await waitForSettled(coordinator)

        guard case .failed = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
        #expect(transport.sentPaths.isEmpty)
    }

    @Test("A valid scan that is approved on the first poll tick completes end-to-end: submitted -> awaitingApproval -> issued -> claiming -> authorized, and the receipt records the grant")
    func happyPathReachesAuthorized() async {
        let (coordinator, transport, _, receiptStore, _) = makeCoordinator()
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: [
            "outcome": "submitted",
            "connection_request_id": Self.requestId.uuidString,
            "display_code": "A1B2C3",
        ])
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "33333333-3333-3333-3333-333333333333",
            "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "expires_at": "2026-10-01T00:01:00Z",
        ])
        transport.enqueue(path: "claim-submit", statusCode: 200, json: [
            "outcome": "granted",
            "grant_id": "44444444-4444-4444-4444-444444444444",
            "recovery_deadline": "2026-10-02T00:00:00Z",
        ])

        coordinator.beginPairing(scannedText: Self.qrText)
        await waitForSettled(coordinator)

        #expect(coordinator.state == .authorized(grantId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!))
        #expect(transport.sentPaths == ["connection-request-submit", "claim-challenge", "claim-submit"])
        #expect(receiptStore.storedReceipt?.grantId == UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
        #expect(receiptStore.storedReceipt?.invitationId == Self.invitationId)
        #expect(receiptStore.storedReceipt?.connectionRequestId == Self.requestId)
    }

    @Test("invitation_not_available on submission fails immediately without ever polling claim-challenge")
    func invitationNotAvailableFailsWithoutPolling() async {
        let (coordinator, transport, _, _, _) = makeCoordinator()
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: ["outcome": "invitation_not_available"])

        coordinator.beginPairing(scannedText: Self.qrText)
        await waitForSettled(coordinator)

        guard case .failed = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
        #expect(transport.sentPaths == ["connection-request-submit"])
    }

    @Test("too_many_requests tells the Athlete to ask for a NEW invitation, never to wait — the per-invitation cap does not reset by waiting")
    func tooManyRequestsMessageOffersNewInvitation() async {
        let (coordinator, transport, _, _, _) = makeCoordinator()
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: ["outcome": "too_many_requests"])

        coordinator.beginPairing(scannedText: Self.qrText)
        await waitForSettled(coordinator)

        guard case .failed(let message) = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
        #expect(!message.lowercased().contains("wait"))
        #expect(message.lowercased().contains("new"))
    }

    @Test("An ambiguous network failure during claim-submit retries with a FRESH challenge for the SAME request — it never resubmits connection-request-submit")
    func ambiguousClaimFailureRetriesWithFreshChallenge() async {
        let (coordinator, transport, _, _, _) = makeCoordinator()
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: [
            "outcome": "submitted",
            "connection_request_id": Self.requestId.uuidString,
            "display_code": "A1B2C3",
        ])
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "33333333-3333-3333-3333-333333333333",
            "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "expires_at": "2026-10-01T00:01:00Z",
        ])
        // claim-submit has NO stub configured for its first call — the
        // fake transport throws NoStubConfigured, which the service maps
        // to .network, exercising the "ambiguous failure" path.
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "55555555-5555-5555-5555-555555555555",
            "nonce": "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
            "expires_at": "2026-10-01T00:02:00Z",
        ])
        transport.enqueue(path: "claim-submit", statusCode: 200, json: [
            "outcome": "granted",
            "grant_id": "44444444-4444-4444-4444-444444444444",
            "recovery_deadline": "2026-10-02T00:00:00Z",
        ])

        coordinator.beginPairing(scannedText: Self.qrText)
        await waitForSettled(coordinator)

        #expect(coordinator.state == .authorized(grantId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!))
        // Exactly ONE connection-request-submit, TWO claim-challenge
        // calls (the second is the fresh-challenge retry), and the
        // second claim-submit succeeds.
        #expect(transport.sentPaths.filter { $0 == "connection-request-submit" }.count == 1)
        #expect(transport.sentPaths.filter { $0 == "claim-challenge" }.count == 2)
        #expect(transport.sentPaths.filter { $0 == "claim-submit" }.count == 1)
    }

    // MARK: - Review round 3: receipts are never proof of current authorization

    @Test("resumePendingAttemptIfAny() with a receipt already recording a grant reconfirms it with the backend (fresh challenge + signed claim, reported back as already_granted) BEFORE ever reporting .authorized — it never shortcuts straight there from the stored grantId alone")
    func resumeWithGrantedReceiptReconfirmsWithBackendFirst() async {
        let receiptStore = FakeReceiptStore()
        let grantId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId,
            displayCode: "A1B2C3",
            grantId: grantId,
            recoveryDeadline: Date().addingTimeInterval(3600)
        )
        let (coordinator, transport, _, _, signingKeyStore) = makeCoordinator(receiptStore: receiptStore)
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "55555555-5555-5555-5555-555555555555",
            "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "expires_at": "2026-10-01T00:01:00Z",
        ])
        transport.enqueue(path: "claim-submit", statusCode: 200, json: [
            "outcome": "already_granted",
            "grant_id": grantId.uuidString,
            "recovery_deadline": "2026-10-02T00:00:00Z",
        ])

        coordinator.resumePendingAttemptIfAny()
        await waitForSettled(coordinator)

        #expect(coordinator.state == .authorized(grantId: grantId))
        // The reconfirmation genuinely went over the network — this is
        // the entire point of the fix: a stored grantId alone is never
        // enough.
        #expect(transport.sentPaths == ["claim-challenge", "claim-submit"])
        // Continuing an attempt already bound to a key uses
        // loadExistingSigningKey() exclusively — never loadOrCreate,
        // which could silently mint a replacement key. Two calls: the
        // resume path's own pre-check plus the real signing call inside
        // submitClaim.
        #expect(signingKeyStore.loadExistingCallCount == 2)
        #expect(signingKeyStore.loadOrCreateCallCount == 0)
    }

    @Test("resumePendingAttemptIfAny() never uses a locally-stored recoveryDeadline as authorization proof — even an already-passed local deadline still goes through real backend reconfirmation rather than failing, or succeeding, locally")
    func resumeNeverTreatsLocalRecoveryDeadlineAsAuthority() async {
        let receiptStore = FakeReceiptStore()
        let grantId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId,
            grantId: grantId,
            // Already in the past, locally — must not, by itself, cause
            // either a local success or a local failure.
            recoveryDeadline: Date(timeIntervalSince1970: 0)
        )
        let (coordinator, transport, _, _, _) = makeCoordinator(receiptStore: receiptStore)
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "55555555-5555-5555-5555-555555555555",
            "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "expires_at": "2026-10-01T00:01:00Z",
        ])
        transport.enqueue(path: "claim-submit", statusCode: 200, json: ["outcome": "recovery_window_expired"])

        coordinator.resumePendingAttemptIfAny()
        await waitForSettled(coordinator)

        // The BACKEND's own rejection, not the local clock, is what
        // ultimately fails this — but it still had to be asked.
        #expect(transport.sentPaths == ["claim-challenge", "claim-submit"])
        guard case .failed = coordinator.state else {
            Issue.record("expected .failed (from the backend's own recovery_window_expired), got \(coordinator.state)")
            return
        }
    }

    @Test("A reinstalled/orphaned receipt — this installation's key no longer exists — is cleared and never authorizes or generates a replacement key, without any network call")
    func reinstalledKeyNeverAuthorizesOrphanedReceipt() async {
        let receiptStore = FakeReceiptStore()
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId,
            grantId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let signingKeyStore = FakeSigningKeyStore()
        signingKeyStore.existingKeyAvailable = false
        let (coordinator, transport, _, _, _) = makeCoordinator(signingKeyStore: signingKeyStore, receiptStore: receiptStore)

        coordinator.resumePendingAttemptIfAny()
        await waitForSettled(coordinator)

        guard case .failed = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
        #expect(transport.sentPaths.isEmpty, "a missing/orphaned key must never even attempt a network reconfirmation")
        #expect(receiptStore.clearCallCount == 1)
        #expect(signingKeyStore.loadOrCreateCallCount == 0, "must never generate a replacement key for an old request")
    }

    @Test("A missing key for a receipt with NO grant yet is handled identically — cleared, never authorized, never generates a replacement key")
    func reinstalledKeyNeverResumesPendingReceiptEither() async {
        let receiptStore = FakeReceiptStore()
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId
        )
        let signingKeyStore = FakeSigningKeyStore()
        signingKeyStore.existingKeyAvailable = false
        let (coordinator, transport, _, _, _) = makeCoordinator(signingKeyStore: signingKeyStore, receiptStore: receiptStore)

        coordinator.resumePendingAttemptIfAny()
        await waitForSettled(coordinator)

        guard case .failed = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
        #expect(transport.sentPaths.isEmpty)
        #expect(receiptStore.clearCallCount == 1)
        #expect(signingKeyStore.loadOrCreateCallCount == 0)
    }

    // MARK: - Review round 3: explicit saveReceipt handling

    @Test("A receipt save failure right after a successful submission stops the attempt BEFORE any claim is ever sent — never silently proceeding with a false promise of durable recovery")
    func pendingReceiptSaveFailureBlocksTheClaim() async {
        let receiptStore = FakeReceiptStore()
        receiptStore.failOnSaveCallNumber = 1
        let (coordinator, transport, _, _, _) = makeCoordinator(receiptStore: receiptStore)
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: [
            "outcome": "submitted",
            "connection_request_id": Self.requestId.uuidString,
            "display_code": "A1B2C3",
        ])
        // If the bug were still present, a claim-challenge/claim-submit
        // call would follow — deliberately no stubs configured for
        // either, so the test fails loudly (NoStubConfigured) if this
        // regresses.

        coordinator.beginPairing(scannedText: Self.qrText)
        await waitForSettled(coordinator)

        guard case .failed = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
        #expect(transport.sentPaths == ["connection-request-submit"], "claim-challenge/claim-submit must never be reached when the pending receipt couldn't be saved")
    }

    @Test("A receipt save failure AFTER the backend already confirmed the grant still reports .authorized truthfully, but sets an explicit warning that the local record couldn't be saved")
    func postGrantReceiptSaveFailureStillReportsAuthorizedWithWarning() async {
        let receiptStore = FakeReceiptStore()
        // Deterministic, not a timing guess: the FIRST saveReceipt call
        // (right after submission) must succeed — only the SECOND one
        // (after the grant) is made to fail.
        receiptStore.failOnSaveCallNumber = 2
        let (coordinator, transport, _, _, _) = makeCoordinator(receiptStore: receiptStore)
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: [
            "outcome": "submitted",
            "connection_request_id": Self.requestId.uuidString,
            "display_code": "A1B2C3",
        ])
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "33333333-3333-3333-3333-333333333333",
            "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "expires_at": "2026-10-01T00:01:00Z",
        ])
        transport.enqueue(path: "claim-submit", statusCode: 200, json: [
            "outcome": "granted",
            "grant_id": "44444444-4444-4444-4444-444444444444",
            "recovery_deadline": "2026-10-02T00:00:00Z",
        ])

        coordinator.beginPairing(scannedText: Self.qrText)
        await waitForSettled(coordinator)

        #expect(coordinator.state == .authorized(grantId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!), "the backend DID confirm this — it must be reported truthfully regardless of the local save outcome")
        #expect(coordinator.unpersistedAuthorizationWarning != nil, "the narrower local-persistence failure must be communicated, not silently discarded")
    }

    // MARK: - Review round 3: resumable interruption ("Continue connection")

    @Test("A transient network failure requesting a challenge is a resumable interruption, not a terminal failure — the stored display code is preserved, and continuePendingAttempt() resumes with a FRESH challenge for the SAME request/key, never resubmitting connection-request-submit")
    func transientFailureOffersContinueWithSameRequestAndFreshChallenge() async {
        let (coordinator, transport, _, receiptStore, signingKeyStore) = makeCoordinator()
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: [
            "outcome": "submitted",
            "connection_request_id": Self.requestId.uuidString,
            "display_code": "A1B2C3",
        ])
        // No claim-challenge stub for the first attempt at all —
        // NoStubConfigured maps to .network, the transient failure.

        coordinator.beginPairing(scannedText: Self.qrText)
        await waitForSettled(coordinator)

        guard case .interrupted(let displayCode) = coordinator.state else {
            Issue.record("expected .interrupted, got \(coordinator.state)")
            return
        }
        #expect(displayCode == "A1B2C3")
        #expect(receiptStore.storedReceipt != nil, "the receipt must still be intact after a transient interruption")

        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "55555555-5555-5555-5555-555555555555",
            "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "expires_at": "2026-10-01T00:01:00Z",
        ])
        transport.enqueue(path: "claim-submit", statusCode: 200, json: [
            "outcome": "granted",
            "grant_id": "44444444-4444-4444-4444-444444444444",
            "recovery_deadline": "2026-10-02T00:00:00Z",
        ])

        coordinator.continuePendingAttempt()
        await waitForSettled(coordinator)

        #expect(coordinator.state == .authorized(grantId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!))
        #expect(transport.sentPaths.filter { $0 == "connection-request-submit" }.count == 1, "continuing must never resubmit the connection request")
        #expect(signingKeyStore.loadOrCreateCallCount == 1, "only the ORIGINAL submission may have generated/loaded a key to start with")
        // Two calls: `continuePendingAttempt()`'s own pre-check
        // (`currentInstallationHasExistingSigningKey()`) plus the real
        // signing call inside `submitClaim` — never `loadOrCreate`.
        #expect(signingKeyStore.loadExistingCallCount == 2, "continuing uses the SAME already-established key, never a newly minted one")
    }

    @Test("Poll budget exhaustion is a resumable interruption, not a terminal failure, and preserves the stored display code")
    func pollBudgetExhaustionIsResumable() async {
        let receiptStore = FakeReceiptStore()
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId,
            displayCode: "Q1W2E3"
        )
        let (coordinator, transport, _, _, _) = makeCoordinator(receiptStore: receiptStore)
        // Every claim-challenge call reports .requestNotAvailable —
        // the loop must exhaust its own budget rather than hang.
        for _ in 0..<AthleteDeviceAuthorizationPairingCoordinator.maxPollAttempts {
            transport.enqueue(path: "claim-challenge", statusCode: 200, json: ["outcome": "request_not_available"])
        }

        coordinator.resumePendingAttemptIfAny()
        await waitForSettled(coordinator, timeoutMS: 5000)

        guard case .interrupted(let displayCode) = coordinator.state else {
            Issue.record("expected .interrupted, got \(coordinator.state)")
            return
        }
        #expect(displayCode == "Q1W2E3")
        #expect(transport.sentPaths.filter { $0 == "claim-challenge" }.count == AthleteDeviceAuthorizationPairingCoordinator.maxPollAttempts)
    }

    @Test("A permanent local failure (no usable signing key for claim-submit) stops the attempt immediately — it is never retried automatically up to the full poll budget")
    func permanentLocalFailureStopsWithoutAutomaticRetryLoop() async {
        let signingKeyStore = FakeSigningKeyStore()
        let (coordinator, transport, _, _, _) = makeCoordinator(signingKeyStore: signingKeyStore)
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: [
            "outcome": "submitted",
            "connection_request_id": Self.requestId.uuidString,
            "display_code": "A1B2C3",
        ])
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "33333333-3333-3333-3333-333333333333",
            "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "expires_at": "2026-10-01T00:01:00Z",
        ])
        // The key becomes unavailable only once claim-submit actually
        // needs it — submitConnectionRequest's own loadOrCreate is
        // unaffected, matching a real mid-attempt Keychain/Secure
        // Enclave failure.
        signingKeyStore.existingKeyAvailable = false

        coordinator.beginPairing(scannedText: Self.qrText)
        await waitForSettled(coordinator)

        guard case .interrupted = coordinator.state else {
            Issue.record("expected .interrupted, got \(coordinator.state)")
            return
        }
        #expect(transport.sentPaths.filter { $0 == "claim-challenge" }.count == 1, "a permanent local failure must stop immediately, never burn through the poll budget retrying something a network retry can never fix")
    }

    // MARK: - Resuming/continuing (existing behavior, re-verified against the new design)

    @Test("resumePendingAttemptIfAny() with a receipt that has NOT yet recorded a grant resumes polling claim-challenge for the SAME invitation/request — never re-submitting a connection request")
    func resumeWithoutGrantResumesPolling() async {
        let receiptStore = FakeReceiptStore()
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId
        )
        let (coordinator, transport, _, _, _) = makeCoordinator(receiptStore: receiptStore)
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": "33333333-3333-3333-3333-333333333333",
            "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "expires_at": "2026-10-01T00:01:00Z",
        ])
        transport.enqueue(path: "claim-submit", statusCode: 200, json: [
            "outcome": "granted",
            "grant_id": "44444444-4444-4444-4444-444444444444",
            "recovery_deadline": "2026-10-02T00:00:00Z",
        ])

        coordinator.resumePendingAttemptIfAny()
        await waitForSettled(coordinator)

        #expect(coordinator.state == .authorized(grantId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!))
        #expect(transport.sentPaths == ["claim-challenge", "claim-submit"])
    }

    @Test("reset() discards any stored receipt — the explicit 'Scan again' action starts a genuinely new attempt, never silently leaving a stale pending/interrupted receipt behind")
    func resetDiscardsStoredReceipt() async {
        let receiptStore = FakeReceiptStore()
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(invitationId: Self.invitationId, connectionRequestId: Self.requestId)
        let (coordinator, _, _, _, _) = makeCoordinator(receiptStore: receiptStore)

        coordinator.reset()

        #expect(receiptStore.clearCallCount == 1)
        #expect(coordinator.state == .idle)
    }

    @Test("A second overlapping beginPairing(_:) call while one is still suspended on its own network await cancels the first and starts the second — old work can never overwrite a newer scan's state")
    func newerScanCancelsOlderInFlightAttempt() async {
        let gate = SuspensionGate()
        let transport = GatedSubmitTransport(gate: gate)
        let service = AthleteDeviceAuthorizationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration(anonKey: "test-anon-key"),
            transport: transport,
            signingKeyStore: FakeSigningKeyStore()
        )
        let coordinator = AthleteDeviceAuthorizationPairingCoordinator(service: service, clock: FakePollingClock())

        coordinator.beginPairing(scannedText: Self.qrText)
        // Deterministic via real suspension signaling (never a timing
        // guess): wait until the FIRST call's own `connection-request-submit`
        // network await has genuinely started before issuing the second.
        await gate.waitUntilEntered()

        // A second, newer scan — this must win: it bumps the
        // coordinator's generation, so when the first call's gated
        // network response is eventually released, its own stale result
        // (gate.release() below delivers an .invitationNotAvailable
        // outcome) must be discarded rather than overwriting whatever
        // the second attempt produces.
        let expectedState = AthleteDeviceAuthorizationPairingCoordinator.State.failed("That code isn't a Vǫxtr device authorization code. Try scanning again.")
        coordinator.beginPairing(scannedText: "not a supported code")
        await waitForSettled(coordinator)
        #expect(coordinator.state == expectedState)

        // Release the now-stale first attempt's gated network call and
        // re-check repeatedly across a short real window — not a guess
        // about WHEN the stale continuation resumes (both it and this
        // test body are MainActor-serialized, so their exact relative
        // order on a single tick is unspecified), but a bounded,
        // repeated check that its late, discarded result never
        // overwrites the newer attempt's already-settled state at any
        // point after release.
        await gate.release()
        for _ in 0..<10 {
            #expect(coordinator.state == expectedState)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor SuspensionGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func markEntered() {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Suspends indefinitely on its one `connection-request-submit` call
/// until the test releases it — mirrors `ParentAuthenticationServiceTests
/// .SuspendableFakeTransport`'s own continuation-based pattern. Resolves
/// to a harmless, real business outcome on release (never a crash),
/// since the point of this fake is to prove the COORDINATOR discards a
/// late result, not to prove the transport itself fails.
private final class GatedSubmitTransport: ParentAuthenticationTransport, @unchecked Sendable {
    private let gate: SuspensionGate

    init(gate: SuspensionGate) {
        self.gate = gate
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await gate.markEntered()
        await gate.waitForRelease()
        let body = try! JSONSerialization.data(withJSONObject: ["outcome": "invitation_not_available"] as [String: Any])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}
