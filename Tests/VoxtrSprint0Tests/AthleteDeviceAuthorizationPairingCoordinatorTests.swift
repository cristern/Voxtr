import Testing
import Foundation
import VoxtrParentAuthentication
@testable import VoxtrAppShell

// Athlete Connection V1 (backend device authorization). Exercises
// `AthleteDeviceAuthorizationPairingCoordinator` against a REAL
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

private final class FakeSigningKeyStore: AthleteDeviceSigningKeyStoring, @unchecked Sendable {
    func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey {
        makeKey()
    }

    func loadExistingSigningKey() throws -> AthleteDeviceSigningKey {
        makeKey()
    }

    private func makeKey() -> AthleteDeviceSigningKey {
        AthleteDeviceSigningKey(fixedPublicKey: Data([0x04] + Array(repeating: 0xAB, count: 64)), fixedSignature: Data(repeating: 0xCD, count: 64)) { _ in }
    }
}

private final class FakeReceiptStore: AthleteDeviceAuthorizationReceiptStoring, @unchecked Sendable {
    private(set) var savedReceipts: [AthleteDeviceAuthorizationReceipt] = []
    var storedReceipt: AthleteDeviceAuthorizationReceipt?
    private(set) var clearCallCount = 0

    func loadReceipt() -> AthleteDeviceAuthorizationReceipt? { storedReceipt }

    func saveReceipt(_ receipt: AthleteDeviceAuthorizationReceipt) throws {
        savedReceipts.append(receipt)
        storedReceipt = receipt
    }

    func clearReceipt() {
        clearCallCount += 1
        storedReceipt = nil
    }
}

@Suite("AthleteDeviceAuthorizationPairingCoordinator (Athlete Connection V1, backend device authorization)")
@MainActor
struct AthleteDeviceAuthorizationPairingCoordinatorTests {

    private static let baseURL = URL(string: "https://device-auth.invalid/functions/v1")!
    private static let invitationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let requestId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let qrText = AthleteDeviceAuthorizationQRPayload.encode(invitationId: invitationId).absoluteString

    private func makeCoordinator(
        transport: FakeTransport = FakeTransport(),
        receiptStore: FakeReceiptStore = FakeReceiptStore()
    ) -> (AthleteDeviceAuthorizationPairingCoordinator, FakeTransport, FakePollingClock, FakeReceiptStore) {
        let service = AthleteDeviceAuthorizationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration(anonKey: "test-anon-key"),
            transport: transport,
            signingKeyStore: FakeSigningKeyStore()
        )
        let clock = FakePollingClock()
        let coordinator = AthleteDeviceAuthorizationPairingCoordinator(service: service, clock: clock, receiptStore: receiptStore)
        return (coordinator, transport, clock, receiptStore)
    }

    /// `beginPairing`/`resumePendingAttemptIfAny` are synchronous — they
    /// own their own `Task` internally — so tests drive the coordinator
    /// to a settled terminal state by polling `coordinator.state` with a
    /// short real sleep between checks, bounded by a generous timeout.
    /// This is NOT a timing guess about WHEN the attempt settles (the
    /// fake clock never really sleeps, so every poll tick inside the
    /// coordinator itself runs essentially instantly) — it only waits
    /// for Swift's own task scheduler to run the already-ready
    /// continuation, which real `Task.sleep` calls are the standard way
    /// to yield for in these async tests.
    private func waitForSettled(_ coordinator: AthleteDeviceAuthorizationPairingCoordinator, timeoutMS: Int = 2000) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMS))
        while ContinuousClock.now < deadline {
            switch coordinator.state {
            case .idle, .resuming, .submitting, .awaitingApproval, .claiming:
                try? await Task.sleep(nanoseconds: 5_000_000)
            case .authorized, .failed:
                return
            }
        }
    }

    @Test("An invalid/unsupported scanned code is rejected with .failed, and no network request is ever sent")
    func invalidCodeNeverReachesTheNetwork() async {
        let (coordinator, transport, _, _) = makeCoordinator()

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
        let (coordinator, transport, _, receiptStore) = makeCoordinator()
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
        let (coordinator, transport, _, _) = makeCoordinator()
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
        let (coordinator, transport, _, _) = makeCoordinator()
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
        let (coordinator, transport, _, _) = makeCoordinator()
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

    @Test("resumePendingAttemptIfAny() with a receipt already recording a grant reports .authorized directly, without any network call")
    func resumeWithGrantedReceiptReportsAuthorizedDirectly() async {
        let receiptStore = FakeReceiptStore()
        let grantId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId,
            grantId: grantId,
            recoveryDeadline: Date().addingTimeInterval(3600)
        )
        let (coordinator, transport, _, _) = makeCoordinator(receiptStore: receiptStore)

        coordinator.resumePendingAttemptIfAny()
        await waitForSettled(coordinator)

        #expect(coordinator.state == .authorized(grantId: grantId))
        #expect(transport.sentPaths.isEmpty)
    }

    @Test("resumePendingAttemptIfAny() with a receipt that has NOT yet recorded a grant resumes polling claim-challenge for the SAME invitation/request — never re-submitting a connection request")
    func resumeWithoutGrantResumesPolling() async {
        let receiptStore = FakeReceiptStore()
        receiptStore.storedReceipt = AthleteDeviceAuthorizationReceipt(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId
        )
        let (coordinator, transport, _, _) = makeCoordinator(receiptStore: receiptStore)
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
