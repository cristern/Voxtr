import Testing
import Foundation
import SwiftData
import VoxtrParentAuthentication
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCore
import VoxtrParentDomain
import VoxtrAthleteDomain

// Athlete Connection V1 backend hydration adapter (§4, §5, §8 step 5,
// issue #111). Exercises `AthleteBackendHydrationAdapter` end to end
// against REAL collaborators: a real `AthleteDeviceAuthorizationSessionManager`
// + real `AthleteDeviceAuthorizationSessionService` (driven by a fake
// transport/signing-key store/session store/clock, matching
// `AthleteDeviceAuthorizationSessionManagerTests.swift`'s own
// established "exercise through the real service" shape) and a real
// `AthleteIdentityHydrationService` backed by a real, in-memory SwiftData
// store (matching `AthleteConnectionLifecycleServiceTests.swift`'s own
// fixture pattern). `AthleteIdentityHydrationService.hydrate(_:)` itself
// is NOT re-tested here — its own conflict/malformed/persistence
// semantics are already covered by its own test file; this file proves
// only the adapter's own three responsibilities: session reuse, wire-to-
// payload mapping, and ack-gating.
//
// Like the other persistence-backed tests in this suite, the tests that
// build a real SwiftData store exercise @Model types through actual
// SwiftData persistence and require the Xcode/macOS SwiftData runtime —
// written but not executed in this sandbox.

private final class FakeAdapterTransport: ParentAuthenticationTransport, @unchecked Sendable {
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

private final class FakeAdapterSigningKeyStore: AthleteDeviceSigningKeyStoring, @unchecked Sendable {
    let fixedPublicKey = Data([0x04] + Array(repeating: 0xAB, count: 64))
    let fixedSignature = Data(Array(repeating: 0xCD, count: 64))

    func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey { makeKey() }
    func loadExistingSigningKey() throws -> AthleteDeviceSigningKey { makeKey() }

    private func makeKey() -> AthleteDeviceSigningKey {
        AthleteDeviceSigningKey(fixedPublicKey: fixedPublicKey, fixedSignature: fixedSignature) { _ in }
    }
}

/// Deterministic, in-memory — never real Keychain I/O, matching
/// `AthleteDeviceAuthorizationSessionManagerTests.swift`'s own
/// `FakeManagerSessionStore`.
private final class FakeAdapterSessionStore: AthleteDeviceAuthorizationSessionStoring, @unchecked Sendable {
    var stored: AthleteDeviceAuthorizationSessionRecord?
    func loadSession() -> AthleteDeviceAuthorizationSessionRecord? { stored }
    func saveSession(_ record: AthleteDeviceAuthorizationSessionRecord) throws { stored = record }
    func clearSession() { stored = nil }
}

/// Injectable, mutable "now" — CLAUDE.md §8: time-dependent tests must
/// never depend on `Date()`/CI run time for an exact asserted result.
private final class FakeAdapterClock: AthleteDeviceAuthorizationSessionClock, @unchecked Sendable {
    var currentTime: Date
    init(currentTime: Date) { self.currentTime = currentTime }
    func now() -> Date { currentTime }
}

@Suite("AthleteBackendHydrationAdapter (Athlete Connection V1 backend hydration adapter, issue #111)", .serialized)
@MainActor
struct AthleteBackendHydrationAdapterTests {

    private static let baseURL = URL(string: "https://device-auth.invalid/functions/v1")!
    private static let deviceGrantId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let anonKey = "test-anon-key"
    private static let wellFormedNonce = Data((0..<32).map { UInt8($0) })
    /// Fixed reference time, well before the fixture's own issued
    /// session's sliding-window renewal lead time — so a SECOND
    /// `ensureActiveSession()` call within the same test (before
    /// `hydration_ack`) reuses the cached token with no further network
    /// call, exactly like `AthleteDeviceAuthorizationSessionManagerTests
    /// .issuesFreshSessionWhenNothingStored`'s own sibling "still within
    /// the sliding window" cases.
    private static let referenceNow = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
    private static let sessionExpiresAt = "2026-10-08T00:00:00Z"
    private static let sessionAbsoluteExpiresAt = "2027-01-01T00:00:00Z"

    private struct Fixture {
        // Retained for the fixture's entire lifetime — see
        // `AthleteConnectionLifecycleServiceTests.swift`'s own
        // established precedent.
        let container: ModelContainer
        let adapter: AthleteBackendHydrationAdapter
        let transport: FakeAdapterTransport
        let parentWorkspaceRepository: ParentWorkspaceRepository
        let athleteRepository: AthleteRepository
        let athleteAccessGrantRepository: AthleteAccessGrantRepository
    }

    private func makeFixture() throws -> Fixture {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let parentWorkspaceRepository = ParentWorkspaceRepository(modelContext: container.mainContext)
        let athleteRepository = AthleteRepository(modelContext: container.mainContext)
        let athleteAccessGrantRepository = AthleteAccessGrantRepository(modelContext: container.mainContext)
        let identityHydrationService = AthleteIdentityHydrationService(
            modelContext: container.mainContext,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )

        let transport = FakeAdapterTransport()
        let signingKeyStore = FakeAdapterSigningKeyStore()
        let sessionService = AthleteDeviceAuthorizationSessionService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration(anonKey: Self.anonKey),
            transport: transport,
            signingKeyStore: signingKeyStore
        )
        let sessionStore = FakeAdapterSessionStore()
        let clock = FakeAdapterClock(currentTime: Self.referenceNow)
        let sessionManager = AthleteDeviceAuthorizationSessionManager(service: sessionService, store: sessionStore, clock: clock)

        let adapter = AthleteBackendHydrationAdapter(
            sessionManager: sessionManager,
            sessionService: sessionService,
            identityHydrationService: identityHydrationService
        )

        return Fixture(
            container: container,
            adapter: adapter,
            transport: transport,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
    }

    private func enqueueIssuedChallenge(_ transport: FakeAdapterTransport) {
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": UUID().uuidString,
            "nonce": AthleteDeviceAuthorizationSessionService.base64UrlEncode(Self.wellFormedNonce),
            "expires_at": "2026-10-01T00:01:00Z",
        ])
    }

    /// Enqueues the challenge+submit pair for the adapter's FIRST
    /// `ensureActiveSession()` call (nothing stored yet, so the manager
    /// issues a fresh session). A second `ensureActiveSession()` call
    /// later in the same test (before `hydration_ack`) consumes no
    /// further stubs — see `Self.referenceNow`'s own doc comment.
    private func enqueueSessionIssueSuccess(_ transport: FakeAdapterTransport) {
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "issued",
            "session_token": "session-token",
            "expires_at": Self.sessionExpiresAt,
            "absolute_expires_at": Self.sessionAbsoluteExpiresAt,
        ])
    }

    private static let wellFormedHydrationFields = AthleteDeviceAuthorizationHydrationFields(
        workspaceId: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        intendedParticipantId: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
        intendedAthleteId: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
        parentId: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
        parentGivenName: "Kari",
        workspaceDisplayName: "Kari's family",
        ownerParticipantId: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
        athleteGivenName: "Jonas",
        athleteBirthDateISO: "2012-04-10",
        athleteTimeZoneId: "Europe/Oslo",
        athleteDevelopmentStage: "parentLed"
    )

    private func enqueueHydrationGetSuccess(_ transport: FakeAdapterTransport, fields: AthleteDeviceAuthorizationHydrationFields = Self.wellFormedHydrationFields) {
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "hydrated",
            "workspace_id": fields.workspaceId.uuidString,
            "intended_participant_id": fields.intendedParticipantId.uuidString,
            "intended_athlete_id": fields.intendedAthleteId.uuidString,
            "parent_id": fields.parentId.uuidString,
            "parent_given_name": fields.parentGivenName,
            "workspace_display_name": fields.workspaceDisplayName,
            "owner_participant_id": fields.ownerParticipantId.uuidString,
            "athlete_given_name": fields.athleteGivenName,
            "athlete_birth_date_iso": fields.athleteBirthDateISO,
            "athlete_time_zone_id": fields.athleteTimeZoneId,
            "athlete_development_stage": fields.athleteDevelopmentStage,
        ])
    }

    private func enqueueHydrationGetTerminal(_ transport: FakeAdapterTransport, wireOutcome: String) {
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": wireOutcome])
    }

    private func enqueueHydrationAck(_ transport: FakeAdapterTransport, wireOutcome: String) {
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": wireOutcome])
    }

    // MARK: - Full success path, exact 11-field mapping (issue #111 acceptance matrix)

    @Test("hydrate(deviceGrantId:) on a fresh device: issues a session, gets hydration, feeds the unchanged AthleteIdentityHydrationService.hydrate(_:), acks only after that succeeds, and persists exactly the 11 mapped fields")
    func fullSuccessPathHydratesAndAcksWithExactFieldMapping() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked")

        let outcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .hydratedAndAcked)
        #expect(fixture.transport.sentRequests.count == 6, "session-issue (2) + hydration-get (2) + hydration-ack (2), with the second ensureActiveSession() reusing the cached token")

        let fields = Self.wellFormedHydrationFields

        let parents = try fixture.parentWorkspaceRepository.fetchAllParentProfiles()
        #expect(parents.count == 1)
        #expect(parents.first?.id == fields.parentId)
        #expect(parents.first?.givenName == fields.parentGivenName)

        let workspaces = try fixture.parentWorkspaceRepository.fetchAllWorkspaces()
        #expect(workspaces.count == 1)
        #expect(workspaces.first?.id == fields.workspaceId)
        #expect(workspaces.first?.displayName == fields.workspaceDisplayName)

        let participants = try fixture.parentWorkspaceRepository.fetchAllParticipants()
        #expect(participants.count == 2)
        #expect(participants.contains { $0.id == fields.ownerParticipantId && $0.role == .workspaceOwner && $0.workspaceId == fields.workspaceId })
        #expect(participants.contains { $0.id == fields.intendedParticipantId && $0.role == .athlete && $0.linkedAthleteId == fields.intendedAthleteId })

        let athletes = try fixture.athleteRepository.fetchAllAthletes()
        #expect(athletes.count == 1)
        #expect(athletes.first?.id == fields.intendedAthleteId)
        #expect(athletes.first?.workspaceId == fields.workspaceId)
        #expect(athletes.first?.givenName == fields.athleteGivenName)

        let grants = try fixture.athleteAccessGrantRepository.fetchAllGrants()
        #expect(grants.count == 1)
        #expect(grants.first?.participantId == fields.ownerParticipantId)
        #expect(grants.first?.athleteId == fields.intendedAthleteId)
        #expect(grants.first?.workspaceId == fields.workspaceId)
    }

    // MARK: - Every get-side terminal outcome the adapter must fold without ever acking

    @Test("hydrate(deviceGrantId:) maps a not-yet-available hydration_get outcome to .notYetAvailable, never attempting an ack")
    func getNotAvailableMapsToNotYetAvailableWithNoAck() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetTerminal(fixture.transport, wireOutcome: "not_available")

        let outcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .notYetAvailable)
        #expect(fixture.transport.sentRequests.count == 4, "session-issue (2) + hydration-get (2) only — no ack attempted")
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) maps the permanent-marker 'acked' outcome to .alreadyCompleted, never attempting a local hydrate or an ack")
    func getAlreadyCompletedMapsWithNoLocalHydrateOrAck() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetTerminal(fixture.transport, wireOutcome: "already_completed")

        let outcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .alreadyCompleted)
        #expect(fixture.transport.sentRequests.count == 4)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) maps the permanent-marker 'expired' outcome to .deadlinePassed, never attempting an ack")
    func getDeadlinePassedMapsWithNoAck() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetTerminal(fixture.transport, wireOutcome: "deadline_passed")

        let outcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .deadlinePassed)
        #expect(fixture.transport.sentRequests.count == 4)
    }

    @Test("hydrate(deviceGrantId:) maps the permanent-marker 'revoked' outcome to .grantRevoked, never attempting an ack")
    func getGrantRevokedMapsWithNoAck() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetTerminal(fixture.transport, wireOutcome: "grant_revoked")

        let outcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .grantRevoked)
        #expect(fixture.transport.sentRequests.count == 4)
    }

    // MARK: - Ack-not-confirmed: local hydration already succeeded, but ack did not land

    @Test("hydrate(deviceGrantId:) throws .ackNotConfirmed when hydration_ack folds to a terminal non-acked outcome AFTER local hydration already succeeded — the local upsert is never rolled back")
    func ackNotConfirmedThrowsAfterSuccessfulLocalHydrate() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "deadline_passed")

        await #expect(throws: AthleteBackendHydrationError.ackNotConfirmed(.deadlinePassed)) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        // The local hydrate() call already ran and persisted real rows —
        // never rolled back just because the SEPARATE ack confirmation
        // did not land (§4.3; this adapter's own doc comment).
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == 1)
    }

    // MARK: - Ack-gating: a hydration conflict stops the chain before any ack is ever attempted

    @Test("hydrate(deviceGrantId:) propagates AthleteIdentityHydrationService's own differentFamilyAlreadyExists conflict, never attempting an ack, and mutating nothing beyond what already existed")
    func identityHydrationConflictStopsChainBeforeAck() async throws {
        let fixture = try makeFixture()

        // This device already has a real, different family hydrated —
        // matching AthleteConnectionLifecycleServiceTests's own
        // "a DIFFERENT family already exists" fixture shape.
        let existingParent = ParentProfile(id: UUID(), accountId: .pending, givenName: "Existing Parent")
        fixture.container.mainContext.insert(existingParent)
        try fixture.container.mainContext.save()

        let parentCountBefore = try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count
        #expect(parentCountBefore == 1)

        enqueueSessionIssueSuccess(fixture.transport)
        // A genuinely different family's hydration payload — this
        // device's existing ParentProfile.id does not match.
        enqueueHydrationGetSuccess(fixture.transport)

        do {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
            Issue.record("Expected hydrate(deviceGrantId:) to throw")
        } catch let error as AthleteIdentityHydrationError {
            guard case .differentFamilyAlreadyExists = error else {
                Issue.record("Expected .differentFamilyAlreadyExists, got \(error)")
                return
            }
        }

        // No ack was ever attempted — only session-issue (2) + hydration-get (2).
        #expect(fixture.transport.sentRequests.count == 4, "no ack request must ever be sent once local hydration itself fails")
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == parentCountBefore)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().isEmpty)
        #expect(try fixture.athleteRepository.fetchAllAthletes().isEmpty)
        #expect(try fixture.athleteAccessGrantRepository.fetchAllGrants().isEmpty)
    }

    // MARK: - Idempotent resumability: a second call after a lost ack response is a pure no-op locally

    @Test("A second hydrate(deviceGrantId:) call, after the backend's own permanent marker already reads 'acked' from an earlier attempt, returns .alreadyCompleted immediately — no second local hydrate attempt, no duplicate rows")
    func secondCallAfterAlreadyCompletedIsIdempotentNoOp() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked")

        let firstOutcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        #expect(firstOutcome == .hydratedAndAcked)

        let parentCountAfterFirst = try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count
        let workspaceCountAfterFirst = try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count
        let participantCountAfterFirst = try fixture.parentWorkspaceRepository.fetchAllParticipants().count
        let athleteCountAfterFirst = try fixture.athleteRepository.fetchAllAthletes().count
        let grantCountAfterFirst = try fixture.athleteAccessGrantRepository.fetchAllGrants().count

        // Second attempt — the cached session token is still valid
        // (within the sliding window), so only a fresh hydration_get is
        // sent; the backend's permanent marker now reads 'acked'.
        enqueueHydrationGetTerminal(fixture.transport, wireOutcome: "already_completed")

        let secondOutcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        #expect(secondOutcome == .alreadyCompleted)

        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == parentCountAfterFirst)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count == workspaceCountAfterFirst)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParticipants().count == participantCountAfterFirst)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == athleteCountAfterFirst)
        #expect(try fixture.athleteAccessGrantRepository.fetchAllGrants().count == grantCountAfterFirst)
    }
}
