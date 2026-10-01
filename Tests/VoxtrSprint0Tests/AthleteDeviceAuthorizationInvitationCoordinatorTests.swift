import Testing
import Foundation
import SwiftData
import VoxtrCoreContracts
import VoxtrParentAuthentication
import VoxtrParentDomain
import VoxtrAthleteDomain
@testable import VoxtrAppShell
@testable import VoxtrCore

// Athlete Connection V1 (backend device authorization, review round 2).
// Exercises `AthleteDeviceAuthorizationInvitationCoordinator` — the
// ParentApp-side state machine — against a REAL `ParentWorkspaceRepository`
// backed by an in-memory `ModelContainer` (this codebase's own established
// convention for repository-dependent orchestration tests; see
// `AthleteConnectionLifecycleServiceTests.swift`) and a REAL
// `AthleteDeviceAuthorizationInvitationService`/`ParentAuthenticationService`
// wired to a fake transport at the network boundary only (the SAME
// "real service + fake network" approach `ParentAuthenticationServiceTests
// .swift` and `AthleteDeviceAuthorizationPairingCoordinatorTests.swift`
// already established for their own sibling services/coordinators) — per
// this task's own explicit instruction, "existing sibling service
// conventions do not exempt new orchestration from testing," rather than
// introducing a speculative new protocol seam this codebase does not
// otherwise use for `ParentWorkspaceRepository`/`ParentAuthenticationService`.
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

    private var stubsByPath: [String: [Stub]] = [:]
    private(set) var sentPaths: [String] = []
    private(set) var sentRequests: [URLRequest] = []

    struct NoStubConfigured: Error {}

    func enqueue(path: String, statusCode: Int, json: [String: Any?]) {
        let cleaned = json.compactMapValues { $0 }
        let body = try! JSONSerialization.data(withJSONObject: cleaned)
        stubsByPath[path, default: []].append(Stub(statusCode: statusCode, body: body))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.lastPathComponent
        sentPaths.append(path)
        sentRequests.append(request)
        guard var stubs = stubsByPath[path], !stubs.isEmpty else {
            throw NoStubConfigured()
        }
        let stub = stubs.removeFirst()
        stubsByPath[path] = stubs
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode, httpVersion: nil, headerFields: nil)!
        return (stub.body, response)
    }
}

private final class FakeSessionStore: ParentSessionStoring, @unchecked Sendable {
    var currentToken: String?
    func loadToken() -> String? { currentToken }
    func saveToken(_ token: String) throws { currentToken = token }
    func deleteToken() { currentToken = nil }
}

/// Mirrors `AthleteDeviceAuthorizationPairingCoordinatorTests
/// .GatedSubmitTransport`'s own continuation-based pattern exactly: a
/// `send(_:)` call for ONE specific path suspends indefinitely until the
/// test releases it, so a concurrent `start`/`stop` can be driven against
/// a genuinely in-flight network await without any timing guess.
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

private final class GatedTransport: ParentAuthenticationTransport, @unchecked Sendable {
    private let gate: SuspensionGate
    private let gatedPath: String
    private let fallback: FakeTransport
    private let gatedStatusCode: Int
    private let gatedResponseJSON: [String: Any]

    /// `gatedResponseJSON` defaults to a `connection-request-list` "ok,
    /// no requests" shape (the most common gated path across this file's
    /// tests) — pass an explicit shape matching whichever path is
    /// actually gated when it differs.
    init(
        gate: SuspensionGate,
        gatedPath: String,
        fallback: FakeTransport,
        gatedStatusCode: Int = 200,
        gatedResponseJSON: [String: Any] = ["outcome": "ok", "requests": [] as [Any]]
    ) {
        self.gate = gate
        self.gatedPath = gatedPath
        self.fallback = fallback
        self.gatedStatusCode = gatedStatusCode
        self.gatedResponseJSON = gatedResponseJSON
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.lastPathComponent == gatedPath else {
            return try await fallback.send(request)
        }
        await gate.markEntered()
        await gate.waitForRelease()
        let body = try! JSONSerialization.data(withJSONObject: gatedResponseJSON)
        let response = HTTPURLResponse(url: request.url!, statusCode: gatedStatusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

@Suite("AthleteDeviceAuthorizationInvitationCoordinator (Athlete Connection V1, backend device authorization, review round 2)", .serialized)
@MainActor
struct AthleteDeviceAuthorizationInvitationCoordinatorTests {

    private static let baseURL = URL(string: "https://parent-auth.invalid/functions/v1")!

    private struct Fixture {
        let container: ModelContainer
        let coordinator: AthleteDeviceAuthorizationInvitationCoordinator
        let transport: FakeTransport
        let sessionStore: FakeSessionStore
        let clock: FakePollingClock
        let athleteId: AthleteId
        let workspaceId: WorkspaceId
        let invitedBy: ActorId
    }

    private static func makeFixture(
        transport: FakeTransport = FakeTransport(),
        signedIn: Bool = true
    ) throws -> Fixture {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let onboardingCoordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
        let created = try onboardingCoordinator.createFamily(
            parentGivenName: "Kari",
            athleteGivenName: "Jonas",
            athleteBirthDate: LocalDate(year: 2012, month: 4, day: 10),
            athleteTimeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            athleteDevelopmentStage: .parentLed
        )
        let invitedBy = ActorId(rawValue: created.participant.id)

        let sessionStore = FakeSessionStore()
        if signedIn {
            sessionStore.currentToken = "live-session-token"
        }
        let parentAuthenticationService = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: baseURL),
            transport: transport,
            sessionStore: sessionStore
        )
        let invitationService = AthleteDeviceAuthorizationInvitationService(
            parentWorkspaceRepository: parentWorkspaceRepository,
            parentAuthenticationService: parentAuthenticationService
        )
        let clock = FakePollingClock()
        let coordinator = AthleteDeviceAuthorizationInvitationCoordinator(
            invitationService: invitationService,
            parentAuthenticationService: parentAuthenticationService,
            clock: clock
        )
        return Fixture(
            container: container,
            coordinator: coordinator,
            transport: transport,
            sessionStore: sessionStore,
            clock: clock,
            athleteId: created.athlete.athleteId,
            workspaceId: created.workspace.workspaceId,
            invitedBy: invitedBy
        )
    }

    /// `start`/`decide` are themselves `async` and only return once their
    /// own top-level work has settled for THIS call — unlike the Athlete
    /// side's synchronous `beginPairing`, so no `waitForSettled` polling
    /// loop is needed for those calls directly. Only the background poll
    /// loop `start` leaves running needs this: a short, bounded,
    /// real-sleep-based wait for a NEW `state` to appear after a poll
    /// tick, mirroring `AthleteDeviceAuthorizationPairingCoordinatorTests
    /// .waitForSettled`'s own bounded-window convention.
    private func waitUntil(
        _ coordinator: AthleteDeviceAuthorizationInvitationCoordinator,
        timeoutMS: Int = 2000,
        _ predicate: (AthleteDeviceAuthorizationInvitationCoordinator.State) -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMS))
        while ContinuousClock.now < deadline {
            if predicate(coordinator.state) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - start()

    @Test("start() creates a real invitation via the real ParentWorkspaceRepository/ParentAuthenticationService, moves to .awaitingRequests, and begins polling connection-request-list")
    func startSuccessfullyCreatesInvitationAndBeginsPolling() async throws {
        let fixture = try Self.makeFixture()
        let invitationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let requestId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        fixture.transport.enqueue(path: "connection-invitation-create", statusCode: 200, json: [
            "outcome": "created",
            "invitation_id": invitationId.uuidString,
            "expires_at": "2026-10-01T00:15:00Z",
        ])
        fixture.transport.enqueue(path: "connection-request-list", statusCode: 200, json: [
            "outcome": "ok",
            "requests": [
                ["id": requestId.uuidString, "display_code": "A1B2C3", "status": "pending", "created_at": "2026-10-01T00:10:00Z"],
            ],
        ])

        await fixture.coordinator.start(forAthlete: fixture.athleteId, workspaceId: fixture.workspaceId, invitedBy: fixture.invitedBy)

        guard case .awaitingRequests(let invitation, _) = fixture.coordinator.state else {
            Issue.record("expected .awaitingRequests immediately after start(), got \(fixture.coordinator.state)")
            return
        }
        #expect(invitation.invitationId == invitationId)
        #expect(fixture.transport.sentPaths == ["connection-invitation-create"])

        await waitUntil(fixture.coordinator) { state in
            if case .awaitingRequests(_, let requests) = state { return !requests.isEmpty }
            return false
        }
        guard case .awaitingRequests(_, let requests) = fixture.coordinator.state else {
            Issue.record("expected .awaitingRequests with requests after a poll tick, got \(fixture.coordinator.state)")
            return
        }
        #expect(requests.map(\.id) == [requestId])
        #expect(fixture.transport.sentPaths == ["connection-invitation-create", "connection-request-list"])
    }

    @Test("start() with no stored session throws .notSignedIn locally, sends no network request, and surfaces .authenticationRequired(.notSignedIn) while preserving the exact athlete/workspace/invitedBy for retry")
    func startWithNoSessionMapsNotSignedInWithoutAnyNetworkCall() async throws {
        let fixture = try Self.makeFixture(signedIn: false)

        await fixture.coordinator.start(forAthlete: fixture.athleteId, workspaceId: fixture.workspaceId, invitedBy: fixture.invitedBy)

        #expect(fixture.coordinator.state == .authenticationRequired(.notSignedIn))
        #expect(fixture.transport.sentPaths.isEmpty)

        // retryAfterReauthentication() resumes the EXACT original start()
        // call, now that the Parent has (simulated) signed back in.
        fixture.sessionStore.currentToken = "fresh-session-token"
        let invitationId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        fixture.transport.enqueue(path: "connection-invitation-create", statusCode: 200, json: [
            "outcome": "created",
            "invitation_id": invitationId.uuidString,
            "expires_at": "2026-10-01T00:15:00Z",
        ])

        await fixture.coordinator.retryAfterReauthentication()

        guard case .awaitingRequests(let invitation, _) = fixture.coordinator.state else {
            Issue.record("expected .awaitingRequests after retryAfterReauthentication(), got \(fixture.coordinator.state)")
            return
        }
        #expect(invitation.invitationId == invitationId)
        let sent = try #require(fixture.transport.sentRequests.last)
        let body = try #require(sent.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["athlete_id"] as? String == fixture.athleteId.rawValue.uuidString)
        #expect(json["workspace_id"] as? String == fixture.workspaceId.rawValue.uuidString)
    }

    @Test("start() maps every other distinct ParentAuthenticationError (sessionInvalid, sessionExpired, reauthenticationRequired) to its own .authenticationRequired case, never flattened to a generic failure")
    func startMapsEachRemainingAuthenticationRequirement() async throws {
        let cases: [(wireError: String, expected: AthleteParentAuthenticationRequirement)] = [
            ("session_invalid", .sessionInvalid),
            ("session_expired", .sessionExpired),
            ("reauthentication_required", .reauthenticationRequired),
        ]
        for testCase in cases {
            let fixture = try Self.makeFixture()
            fixture.transport.enqueue(path: "connection-invitation-create", statusCode: 401, json: ["error": testCase.wireError])

            await fixture.coordinator.start(forAthlete: fixture.athleteId, workspaceId: fixture.workspaceId, invitedBy: fixture.invitedBy)

            #expect(fixture.coordinator.state == .authenticationRequired(testCase.expected), "wire error: \(testCase.wireError)")
        }
    }

    @Test("start() never sends a plain network/malformedResponse failure to .authenticationRequired — it surfaces as an ordinary .failed message instead")
    func startWithPlainNetworkFailureIsNotTreatedAsAnAuthenticationRequirement() async throws {
        let fixture = try Self.makeFixture()
        // No stub configured for connection-invitation-create at all —
        // the fake transport throws NoStubConfigured, which
        // ParentAuthenticationService's transport-error catch maps to a
        // plain, non-auth-shaped failure.
        await fixture.coordinator.start(forAthlete: fixture.athleteId, workspaceId: fixture.workspaceId, invitedBy: fixture.invitedBy)

        guard case .failed = fixture.coordinator.state else {
            Issue.record("expected .failed, got \(fixture.coordinator.state)")
            return
        }
    }

    @Test("Polling ends locally once the invitation's own expiresAt has passed, without ever calling connection-request-list")
    func pollingEndsWhenInvitationExpiresWithoutAnyFurtherNetworkCall() async throws {
        let fixture = try Self.makeFixture()
        fixture.transport.enqueue(path: "connection-invitation-create", statusCode: 200, json: [
            "outcome": "created",
            "invitation_id": UUID().uuidString,
            // Already expired the instant start() returns.
            "expires_at": "2000-01-01T00:00:00Z",
        ])

        await fixture.coordinator.start(forAthlete: fixture.athleteId, workspaceId: fixture.workspaceId, invitedBy: fixture.invitedBy)
        await waitUntil(fixture.coordinator) { state in
            if case .failed = state { return true }
            return false
        }

        guard case .failed(let message) = fixture.coordinator.state else {
            Issue.record("expected .failed, got \(fixture.coordinator.state)")
            return
        }
        #expect(message.lowercased().contains("expired"))
        #expect(fixture.transport.sentPaths == ["connection-invitation-create"])
    }

    // MARK: - decide()

    @Test("decide() sends invitation/request/decision/displayCode exactly as given and moves to .decided")
    func decideSendsFieldsExactlyAndTransitionsToDecided() async throws {
        let fixture = try Self.makeFixture()
        let invitation = AthleteDeviceAuthorizationInvitation(
            invitationId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            expiresAt: Date().addingTimeInterval(900),
            participantId: UUID(),
            athleteId: fixture.athleteId
        )
        let requestId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        fixture.transport.enqueue(path: "connection-request-decide", statusCode: 200, json: ["outcome": "approved"])

        await fixture.coordinator.decide(invitation: invitation, requestId: requestId, decision: .approved, displayCode: "A1B2C3")

        #expect(fixture.coordinator.state == .decided(.approved))
        let sent = try #require(fixture.transport.sentRequests.first)
        let body = try #require(sent.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["invitation_id"] as? String == invitation.invitationId.uuidString)
        #expect(json["connection_request_id"] as? String == requestId.uuidString)
        #expect(json["decision"] as? String == "approved")
        #expect(json["display_code"] as? String == "A1B2C3")
    }

    @Test("decide() failing with an authentication requirement preserves the EXACT invitation/request/decision/displayCode, and retryAfterReauthentication() resends them unchanged")
    func decideAuthenticationFailurePreservesExactPendingOperation() async throws {
        let fixture = try Self.makeFixture()
        let invitation = AthleteDeviceAuthorizationInvitation(
            invitationId: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            expiresAt: Date().addingTimeInterval(900),
            participantId: UUID(),
            athleteId: fixture.athleteId
        )
        let requestId = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        fixture.transport.enqueue(path: "connection-request-decide", statusCode: 401, json: ["error": "reauthentication_required"])

        await fixture.coordinator.decide(invitation: invitation, requestId: requestId, decision: .rejected, displayCode: "Z9Y8X7")

        #expect(fixture.coordinator.state == .authenticationRequired(.reauthenticationRequired))

        fixture.transport.enqueue(path: "connection-request-decide", statusCode: 200, json: ["outcome": "rejected"])
        await fixture.coordinator.retryAfterReauthentication()

        #expect(fixture.coordinator.state == .decided(.rejected))
        let sent = try #require(fixture.transport.sentRequests.last)
        let body = try #require(sent.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["invitation_id"] as? String == invitation.invitationId.uuidString)
        #expect(json["connection_request_id"] as? String == requestId.uuidString)
        #expect(json["decision"] as? String == "rejected")
        #expect(json["display_code"] as? String == "Z9Y8X7")
    }

    @Test("decide() is single-flight: a second overlapping call is ignored while the first is still suspended on its own network await")
    func decideIsSingleFlightAndIgnoresAnOverlappingCall() async throws {
        let fixture = try Self.makeFixture()
        let invitation = AthleteDeviceAuthorizationInvitation(
            invitationId: UUID(),
            expiresAt: Date().addingTimeInterval(900),
            participantId: UUID(),
            athleteId: fixture.athleteId
        )
        let requestId = UUID()
        let gate = SuspensionGate()
        let gatedTransport = GatedTransport(
            gate: gate,
            gatedPath: "connection-request-decide",
            fallback: fixture.transport,
            gatedResponseJSON: ["outcome": "approved"]
        )
        let sessionStore = FakeSessionStore()
        sessionStore.currentToken = "live-session-token"
        let parentAuthenticationService = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: gatedTransport,
            sessionStore: sessionStore
        )
        let invitationService = AthleteDeviceAuthorizationInvitationService(
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: fixture.container.mainContext),
            parentAuthenticationService: parentAuthenticationService
        )
        let coordinator = AthleteDeviceAuthorizationInvitationCoordinator(
            invitationService: invitationService,
            parentAuthenticationService: parentAuthenticationService,
            clock: fixture.clock
        )

        let firstDecision = Task {
            await coordinator.decide(invitation: invitation, requestId: requestId, decision: .approved, displayCode: "A1B2C3")
        }
        await gate.waitUntilEntered()
        #expect(coordinator.isDecisionPending == true)

        // Ignored outright — the first call owns this decision.
        await coordinator.decide(invitation: invitation, requestId: requestId, decision: .rejected, displayCode: "A1B2C3")
        #expect(coordinator.isDecisionPending == true)

        await gate.release()
        await firstDecision.value

        #expect(coordinator.isDecisionPending == false)
        #expect(coordinator.state == .decided(.approved))
    }

    // MARK: - Coordinator-owned cancellation / generations (review round 2, Fix 3)

    @Test("stop() cancels the owned poll Task — a connection-request-list response that arrives after stop() must never overwrite state")
    func stopCancelsPollingSoALateResponseIsDiscarded() async throws {
        let gate = SuspensionGate()
        let fixture = try Self.makeFixture()
        fixture.transport.enqueue(path: "connection-invitation-create", statusCode: 200, json: [
            "outcome": "created",
            "invitation_id": UUID().uuidString,
            "expires_at": "2026-10-01T00:15:00Z",
        ])
        let gatedTransport = GatedTransport(gate: gate, gatedPath: "connection-request-list", fallback: fixture.transport)
        let sessionStore = FakeSessionStore()
        sessionStore.currentToken = "live-session-token"
        let parentAuthenticationService = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: gatedTransport,
            sessionStore: sessionStore
        )
        let invitationService = AthleteDeviceAuthorizationInvitationService(
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: fixture.container.mainContext),
            parentAuthenticationService: parentAuthenticationService
        )
        let coordinator = AthleteDeviceAuthorizationInvitationCoordinator(
            invitationService: invitationService,
            parentAuthenticationService: parentAuthenticationService,
            clock: fixture.clock
        )

        await coordinator.start(forAthlete: fixture.athleteId, workspaceId: fixture.workspaceId, invitedBy: fixture.invitedBy)
        guard case .awaitingRequests(let invitation, _) = coordinator.state else {
            Issue.record("expected .awaitingRequests, got \(coordinator.state)")
            return
        }
        // The poll loop's own connection-request-list call is now gated
        // in flight.
        await gate.waitUntilEntered()

        coordinator.stop()
        let stateAfterStop = coordinator.state
        #expect(stateAfterStop == .awaitingRequests(invitation: invitation, requests: []))

        // Release the now-stale, cancelled poll's gated response and
        // re-check across a short bounded real-time window — the SAME
        // negative-invariant convention `AthleteDeviceAuthorizationPairingCoordinatorTests
        // .newerScanCancelsOlderInFlightAttempt` already established,
        // since the stale Task resuming and this check running are both
        // MainActor-serialized and their exact relative order on a given
        // tick is unspecified.
        await gate.release()
        for _ in 0..<10 {
            #expect(coordinator.state == stateAfterStop)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("A second, newer start() call while the first is still suspended on its own network await cancels the first — the stale invitation it eventually returns must never overwrite the newer one's state")
    func newerStartCancelsOlderInFlightStart() async throws {
        let fixture = try Self.makeFixture()
        let gate = SuspensionGate()
        let gatedTransport = GatedTransport(
            gate: gate,
            gatedPath: "connection-invitation-create",
            fallback: fixture.transport,
            gatedResponseJSON: ["outcome": "created", "invitation_id": UUID().uuidString, "expires_at": "2026-10-01T00:15:00Z"]
        )
        let sessionStore = FakeSessionStore()
        sessionStore.currentToken = "live-session-token"
        let parentAuthenticationService = ParentAuthenticationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: gatedTransport,
            sessionStore: sessionStore
        )
        let repository = ParentWorkspaceRepository(modelContext: fixture.container.mainContext)
        let invitationService = AthleteDeviceAuthorizationInvitationService(
            parentWorkspaceRepository: repository,
            parentAuthenticationService: parentAuthenticationService
        )
        let coordinator = AthleteDeviceAuthorizationInvitationCoordinator(
            invitationService: invitationService,
            parentAuthenticationService: parentAuthenticationService,
            clock: fixture.clock
        )

        let firstStart = Task {
            await coordinator.start(forAthlete: fixture.athleteId, workspaceId: fixture.workspaceId, invitedBy: fixture.invitedBy)
        }
        // The first call's own participant resolution/creation (pure,
        // synchronous, no network) has already run by the time its
        // network call reaches the gate — exactly ONE athlete
        // WorkspaceParticipant now exists for this athlete/workspace.
        await gate.waitUntilEntered()

        // Force the SECOND start() to fail synchronously, BEFORE it ever
        // reaches the network: inserting a SECOND WorkspaceParticipant
        // for the SAME athlete/workspace makes
        // `AthleteConnectionOwnerHandoffService.matchingAthleteParticipants`
        // return `.duplicate`, which `prepareInvitation` surfaces as
        // `.duplicateAthleteParticipant` without ever awaiting a network
        // call — so this test exercises cancellation/generation
        // ordering deterministically, with no second gate wait needed.
        _ = try repository.createInvitedAthleteParticipant(
            workspaceId: fixture.workspaceId,
            linkedAthleteId: fixture.athleteId,
            invitedBy: fixture.invitedBy
        )

        // A second, newer start() — issued directly on the MainActor
        // while the first is still suspended on the gate, exactly as
        // `AthleteDeviceAuthorizationPairingCoordinatorTests
        // .newerScanCancelsOlderInFlightAttempt` exercises for the
        // Athlete-side coordinator's own cancellation guard.
        await coordinator.start(forAthlete: fixture.athleteId, workspaceId: fixture.workspaceId, invitedBy: fixture.invitedBy)
        let stateAfterSecondStart = coordinator.state
        guard case .failed = stateAfterSecondStart else {
            Issue.record("expected the second, newer start() to settle as .failed, got \(stateAfterSecondStart)")
            return
        }

        // Release the now-stale first attempt's gated network call — it
        // would otherwise report a (fictitious) created invitation — and
        // re-check across a short bounded real-time window, the same
        // negative-invariant convention used elsewhere in this file.
        await gate.release()
        _ = await firstStart.value

        for _ in 0..<10 {
            #expect(coordinator.state == stateAfterSecondStart)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
