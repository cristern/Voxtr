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
        /// R1 (ChatGPT review 6056376095): fires synchronously the
        /// moment THIS specific stub is consumed, before `send(_:)`
        /// returns it — deterministically simulates "something else
        /// (an explicit sign-out, or the session manager's own
        /// clear-on-failure) happened while this exact network call was
        /// in flight," without needing a real suspend/resume barrier:
        /// from the caller's side, an awaited call whose result reflects
        /// a state change that occurred before it returned is
        /// indistinguishable from one where that change happened mid-
        /// flight for real.
        let onConsumed: (() -> Void)?
    }

    private var stubsByPath: [String: [Stub]] = [:]
    private(set) var sentRequests: [URLRequest] = []

    struct NoStubConfigured: Error {}

    func enqueue(path: String, statusCode: Int, json: [String: Any?], onConsumed: (() -> Void)? = nil) {
        let cleaned = json.compactMapValues { $0 }
        let body = try! JSONSerialization.data(withJSONObject: cleaned)
        stubsByPath[path, default: []].append(Stub(statusCode: statusCode, body: body, onConsumed: onConsumed))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sentRequests.append(request)
        let path = request.url!.lastPathComponent
        guard var stubs = stubsByPath[path], !stubs.isEmpty else {
            throw NoStubConfigured()
        }
        let stub = stubs.removeFirst()
        stubsByPath[path] = stubs
        stub.onConsumed?()
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
        let sessionManager: AthleteDeviceAuthorizationSessionManager
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
            sessionManager: sessionManager,
            parentWorkspaceRepository: parentWorkspaceRepository,
            athleteRepository: athleteRepository,
            athleteAccessGrantRepository: athleteAccessGrantRepository
        )
    }

    private func enqueueIssuedChallenge(_ transport: FakeAdapterTransport, onConsumed: (() -> Void)? = nil) {
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": UUID().uuidString,
            "nonce": AthleteDeviceAuthorizationSessionService.base64UrlEncode(Self.wellFormedNonce),
            "expires_at": "2026-10-01T00:01:00Z",
        ], onConsumed: onConsumed)
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

    private func enqueueHydrationGetSuccess(
        _ transport: FakeAdapterTransport,
        fields: AthleteDeviceAuthorizationHydrationFields = Self.wellFormedHydrationFields,
        challengeOnConsumed: (() -> Void)? = nil,
        submitOnConsumed: (() -> Void)? = nil
    ) {
        enqueueIssuedChallenge(transport, onConsumed: challengeOnConsumed)
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
        ], onConsumed: submitOnConsumed)
    }

    private func enqueueHydrationGetTerminal(_ transport: FakeAdapterTransport, wireOutcome: String) {
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": wireOutcome])
    }

    private func enqueueHydrationAck(
        _ transport: FakeAdapterTransport, wireOutcome: String, challengeOnConsumed: (() -> Void)? = nil
    ) {
        enqueueIssuedChallenge(transport, onConsumed: challengeOnConsumed)
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
        let ownerParticipant = participants.first { $0.id == fields.ownerParticipantId }
        #expect(ownerParticipant?.role == .workspaceOwner)
        #expect(ownerParticipant?.workspaceId == fields.workspaceId)
        // The owner is hydrated directly as .active (AthleteIdentityHydrationService
        // .hydrateOwnerParticipant's own behavior) — never left .invited.
        #expect(ownerParticipant?.state == .active)
        let athleteParticipant = participants.first { $0.id == fields.intendedParticipantId }
        #expect(athleteParticipant?.role == .athlete)
        #expect(athleteParticipant?.linkedAthleteId == fields.intendedAthleteId)
        #expect(athleteParticipant?.workspaceId == fields.workspaceId)
        // R3 (ChatGPT review 6056376095): the intended athlete participant
        // must still be .invited — this adapter NEVER activates membership
        // itself (§2.4, §5; this type's own "NEVER activates" doc comment).
        #expect(athleteParticipant?.state == .invited)

        let athletes = try fixture.athleteRepository.fetchAllAthletes()
        #expect(athletes.count == 1)
        #expect(athletes.first?.id == fields.intendedAthleteId)
        #expect(athletes.first?.workspaceId == fields.workspaceId)
        #expect(athletes.first?.givenName == fields.athleteGivenName)
        // R3: all 11 fields, not just the 8 already asserted above.
        #expect(athletes.first?.birthDate.isoString == fields.athleteBirthDateISO)
        #expect(athletes.first?.timeZoneId.rawValue == fields.athleteTimeZoneId)
        #expect(athletes.first?.developmentStage.rawValue == fields.athleteDevelopmentStage)

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

    // MARK: - R1 (ChatGPT review 6056376095): session staleness/cancellation across awaits
    //
    // Each test below uses a stub's `onConsumed` hook to call
    // `sessionManager.clearStoredSession()` the moment a SPECIFIC
    // network call is answered — deterministically simulating "a sign-
    // out (or the manager's own clear-on-failure) happened while this
    // exact call was in flight" without a real suspend/resume barrier
    // (see `FakeAdapterTransport.Stub.onConsumed`'s own doc comment for
    // why this is equivalent from the production code's point of view).
    //
    // "ACK session acquisition" (clear while `ensureActiveSession`
    // itself is mid-network-call) is deliberately NOT re-tested here:
    // that exact window is `AthleteDeviceAuthorizationSessionManager`'s
    // own `checkNotCleared` guard, already covered by
    // `AthleteDeviceAuthorizationSessionManagerTests.swift`'s own R6
    // regression suite — this adapter adds nothing new to re-verify
    // there.

    @Test("hydrate(deviceGrantId:) throws .sessionInvalidatedOrCancelled and never sends the hydration_get submit when the session is cleared right after the GET challenge resolves")
    func clearDuringGetChallengeSeamStopsBeforeSubmit() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport, challengeOnConsumed: {
            fixture.sessionManager.clearStoredSession()
        })

        await #expect(throws: AthleteBackendHydrationError.sessionInvalidatedOrCancelled) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        // session-issue (2) + hydration-get CHALLENGE only (1) — its
        // submit must never be sent once checkNotCancelled sees the
        // generation has moved.
        #expect(fixture.transport.sentRequests.count == 3)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) throws .sessionInvalidatedOrCancelled and never persists when the session is cleared during the hydration_get submit's own network call")
    func clearDuringGetSubmitStopsBeforePersistence() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport, submitOnConsumed: {
            fixture.sessionManager.clearStoredSession()
        })

        await #expect(throws: AthleteBackendHydrationError.sessionInvalidatedOrCancelled) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        // getHydration() itself returns normally (it has no idea the
        // generation changed) — the adapter's OWN post-return check
        // catches it, before ever calling identityHydrationService
        // .hydrate(_:). session-issue (2) + hydration-get (2) only.
        #expect(fixture.transport.sentRequests.count == 4)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
        #expect(try fixture.athleteRepository.fetchAllAthletes().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) throws .sessionInvalidatedOrCancelled and never sends the hydration_ack submit when the session is cleared right after the ACK challenge resolves — local rows already committed by GET stay")
    func clearDuringAckChallengeSeamStopsBeforeSubmitButKeepsLocalRows() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked", challengeOnConsumed: {
            fixture.sessionManager.clearStoredSession()
        })

        await #expect(throws: AthleteBackendHydrationError.sessionInvalidatedOrCancelled) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        // session-issue (2) + hydration-get (2) + hydration-ack
        // CHALLENGE only (1) — its submit must never be sent.
        #expect(fixture.transport.sentRequests.count == 5)
        // The local upsert from the successful GET above already
        // committed real rows — NEVER rolled back just because the
        // later ack attempt detected staleness (this adapter's own
        // "never destructive" doc comment).
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == 1)
    }

    @Test("hydrate(deviceGrantId:) throws CancellationError and never sends the hydration_get submit if this Task is already cancelled when the GET challenge resolves")
    func cancelledTaskStopsBeforeGetSubmit() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked")

        let task = Task {
            try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        // session-issue (2) + hydration-get CHALLENGE only (1) — the
        // cancellation must be observed before the GET submit is ever
        // sent, and never "handled" by starting a fresh session.
        #expect(fixture.transport.sentRequests.count == 3)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
    }

    // MARK: - R2 (ChatGPT review 6056376095): malformed field VALUES are rejected before any local upsert

    @Test("hydrate(deviceGrantId:) throws .malformedHydrationPayload(field: \"athleteBirthDateISO\") and persists nothing when the GET response's birth date does not parse as a LocalDate, on a completely fresh device")
    func malformedBirthDateOnFreshDeviceIsRejectedBeforeUpsert() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        let malformed = AthleteDeviceAuthorizationHydrationFields(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            intendedParticipantId: Self.wellFormedHydrationFields.intendedParticipantId,
            intendedAthleteId: Self.wellFormedHydrationFields.intendedAthleteId,
            parentId: Self.wellFormedHydrationFields.parentId,
            parentGivenName: Self.wellFormedHydrationFields.parentGivenName,
            workspaceDisplayName: Self.wellFormedHydrationFields.workspaceDisplayName,
            ownerParticipantId: Self.wellFormedHydrationFields.ownerParticipantId,
            athleteGivenName: Self.wellFormedHydrationFields.athleteGivenName,
            athleteBirthDateISO: "not-a-date",
            athleteTimeZoneId: Self.wellFormedHydrationFields.athleteTimeZoneId,
            athleteDevelopmentStage: Self.wellFormedHydrationFields.athleteDevelopmentStage
        )
        enqueueHydrationGetSuccess(fixture.transport, fields: malformed)

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteBirthDateISO")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        #expect(fixture.transport.sentRequests.count == 4, "no ack request must ever be sent for a malformed payload")
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
        #expect(try fixture.athleteRepository.fetchAllAthletes().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) throws .malformedHydrationPayload(field: \"athleteDevelopmentStage\") and persists nothing when the GET response's development stage matches no known case, on a completely fresh device")
    func malformedDevelopmentStageOnFreshDeviceIsRejectedBeforeUpsert() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        let malformed = AthleteDeviceAuthorizationHydrationFields(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            intendedParticipantId: Self.wellFormedHydrationFields.intendedParticipantId,
            intendedAthleteId: Self.wellFormedHydrationFields.intendedAthleteId,
            parentId: Self.wellFormedHydrationFields.parentId,
            parentGivenName: Self.wellFormedHydrationFields.parentGivenName,
            workspaceDisplayName: Self.wellFormedHydrationFields.workspaceDisplayName,
            ownerParticipantId: Self.wellFormedHydrationFields.ownerParticipantId,
            athleteGivenName: Self.wellFormedHydrationFields.athleteGivenName,
            athleteBirthDateISO: Self.wellFormedHydrationFields.athleteBirthDateISO,
            athleteTimeZoneId: Self.wellFormedHydrationFields.athleteTimeZoneId,
            athleteDevelopmentStage: "not-a-real-stage"
        )
        enqueueHydrationGetSuccess(fixture.transport, fields: malformed)

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteDevelopmentStage")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        #expect(fixture.transport.sentRequests.count == 4)
        #expect(try fixture.athleteRepository.fetchAllAthletes().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) throws .malformedHydrationPayload(field: \"athleteTimeZoneId\") and persists nothing when the GET response's timezone identifier is unrecognized, on a completely fresh device")
    func malformedTimeZoneOnFreshDeviceIsRejectedBeforeUpsert() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        let malformed = AthleteDeviceAuthorizationHydrationFields(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            intendedParticipantId: Self.wellFormedHydrationFields.intendedParticipantId,
            intendedAthleteId: Self.wellFormedHydrationFields.intendedAthleteId,
            parentId: Self.wellFormedHydrationFields.parentId,
            parentGivenName: Self.wellFormedHydrationFields.parentGivenName,
            workspaceDisplayName: Self.wellFormedHydrationFields.workspaceDisplayName,
            ownerParticipantId: Self.wellFormedHydrationFields.ownerParticipantId,
            athleteGivenName: Self.wellFormedHydrationFields.athleteGivenName,
            athleteBirthDateISO: Self.wellFormedHydrationFields.athleteBirthDateISO,
            athleteTimeZoneId: "Not/A_Real_Zone",
            athleteDevelopmentStage: Self.wellFormedHydrationFields.athleteDevelopmentStage
        )
        enqueueHydrationGetSuccess(fixture.transport, fields: malformed)

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteTimeZoneId")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        #expect(fixture.transport.sentRequests.count == 4)
        #expect(try fixture.athleteRepository.fetchAllAthletes().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) rejects a malformed birth date even when a PRE-EXISTING, same-workspace athlete profile already exists locally — AthleteIdentityHydrationService's own early-return for an existing profile must never let this bypass validation")
    func malformedBirthDateIsRejectedEvenWithPreExistingMatchingAthleteProfile() async throws {
        let fixture = try makeFixture()

        // A real, pre-existing AthleteProfile matching the SAME id and
        // workspaceId the incoming (malformed) payload names —
        // `AthleteIdentityHydrationService.hydrateAthleteProfile` would
        // find this and return early WITHOUT ever parsing birthDate/
        // developmentStage, which is exactly the gap R2 describes.
        let existingAthlete = AthleteProfile(
            id: AthleteId(rawValue: Self.wellFormedHydrationFields.intendedAthleteId),
            workspaceId: WorkspaceId(rawValue: Self.wellFormedHydrationFields.workspaceId),
            givenName: "Jonas",
            birthDate: LocalDate(year: 2012, month: 4, day: 10),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
        fixture.container.mainContext.insert(existingAthlete)
        try fixture.container.mainContext.save()

        enqueueSessionIssueSuccess(fixture.transport)
        let malformed = AthleteDeviceAuthorizationHydrationFields(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            intendedParticipantId: Self.wellFormedHydrationFields.intendedParticipantId,
            intendedAthleteId: Self.wellFormedHydrationFields.intendedAthleteId,
            parentId: Self.wellFormedHydrationFields.parentId,
            parentGivenName: Self.wellFormedHydrationFields.parentGivenName,
            workspaceDisplayName: Self.wellFormedHydrationFields.workspaceDisplayName,
            ownerParticipantId: Self.wellFormedHydrationFields.ownerParticipantId,
            athleteGivenName: Self.wellFormedHydrationFields.athleteGivenName,
            athleteBirthDateISO: "invalid",
            athleteTimeZoneId: Self.wellFormedHydrationFields.athleteTimeZoneId,
            athleteDevelopmentStage: Self.wellFormedHydrationFields.athleteDevelopmentStage
        )
        enqueueHydrationGetSuccess(fixture.transport, fields: malformed)

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteBirthDateISO")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        #expect(fixture.transport.sentRequests.count == 4, "no ack request must ever be sent for a malformed payload")
        // No NEW rows beyond the one pre-existing athlete — never
        // acked, never let through by the existing-profile short-circuit.
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == 1)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
    }

    // MARK: - R3 (ChatGPT review 6056376095): remaining named conflicts, transport failure, lost-ACK retry

    @Test("hydrate(deviceGrantId:) propagates AthleteIdentityHydrationService's own ownerParticipantConflict, never attempting an ack")
    func ownerParticipantConflictStopsChainBeforeAck() async throws {
        let fixture = try makeFixture()

        // A pre-existing .workspaceOwner participant for a COMPLETELY
        // different workspace/id than the incoming payload names —
        // parent/workspace tables stay empty, so steps 1-2 succeed by
        // CREATING fresh rows for the new payload; step 3
        // (hydrateOwnerParticipant) then finds this mismatched owner.
        let unrelatedOwner = WorkspaceParticipant(
            workspaceId: WorkspaceId(rawValue: UUID()),
            accountId: .pending,
            role: .workspaceOwner,
            state: .active
        )
        fixture.container.mainContext.insert(unrelatedOwner)
        try fixture.container.mainContext.save()

        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)

        do {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
            Issue.record("Expected hydrate(deviceGrantId:) to throw")
        } catch let error as AthleteIdentityHydrationError {
            guard case .ownerParticipantConflict = error else {
                Issue.record("Expected .ownerParticipantConflict, got \(error)")
                return
            }
        }

        #expect(fixture.transport.sentRequests.count == 4, "no ack request must ever be sent once local hydration itself fails")
    }

    @Test("hydrate(deviceGrantId:) propagates AthleteIdentityHydrationService's own athleteParticipantConflict, never attempting an ack")
    func athleteParticipantConflictStopsChainBeforeAck() async throws {
        let fixture = try makeFixture()

        // A pre-existing participant with the SAME id as the incoming
        // payload's intendedParticipantId, but the WRONG role (never
        // .athlete) — parent/workspace/owner all stay fresh/empty so
        // steps 1-3 succeed; step 5 (hydrateAthleteParticipant) then
        // finds this identity-mismatched row.
        let wrongRoleParticipant = WorkspaceParticipant(
            id: Self.wellFormedHydrationFields.intendedParticipantId,
            workspaceId: WorkspaceId(rawValue: UUID()),
            accountId: .pending,
            role: .guardianEditor,
            state: .active
        )
        fixture.container.mainContext.insert(wrongRoleParticipant)
        try fixture.container.mainContext.save()

        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)

        do {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
            Issue.record("Expected hydrate(deviceGrantId:) to throw")
        } catch let error as AthleteIdentityHydrationError {
            guard case .athleteParticipantConflict = error else {
                Issue.record("Expected .athleteParticipantConflict, got \(error)")
                return
            }
        }

        #expect(fixture.transport.sentRequests.count == 4)
    }

    @Test("hydrate(deviceGrantId:) propagates AthleteIdentityHydrationService's own athleteProfileConflict, never attempting an ack")
    func athleteProfileConflictStopsChainBeforeAck() async throws {
        let fixture = try makeFixture()

        // A pre-existing AthleteProfile with the SAME id as the
        // incoming payload's intendedAthleteId, but a DIFFERENT
        // workspaceId — steps 1-3 succeed fresh; step 4
        // (hydrateAthleteProfile) then finds this workspace mismatch.
        let mismatchedAthlete = AthleteProfile(
            id: AthleteId(rawValue: Self.wellFormedHydrationFields.intendedAthleteId),
            workspaceId: WorkspaceId(rawValue: UUID()),
            givenName: "SomeoneElse",
            birthDate: LocalDate(year: 2010, month: 1, day: 1),
            timeZoneId: TimeZoneId(rawValue: "Europe/Oslo"),
            developmentStage: .parentLed
        )
        fixture.container.mainContext.insert(mismatchedAthlete)
        try fixture.container.mainContext.save()

        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)

        do {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
            Issue.record("Expected hydrate(deviceGrantId:) to throw")
        } catch let error as AthleteIdentityHydrationError {
            guard case .athleteProfileConflict = error else {
                Issue.record("Expected .athleteProfileConflict, got \(error)")
                return
            }
        }

        #expect(fixture.transport.sentRequests.count == 4)
    }

    @Test("hydrate(deviceGrantId:) propagates a transport-level network failure from hydration_get untouched, persisting nothing and never attempting an ack")
    func transportFailureDuringGetPropagatesWithNoAck() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        fixture.transport.enqueue(path: "device-session-challenge", statusCode: 500, json: [:])

        await #expect(throws: AthleteDeviceAuthorizationSessionError.network) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        #expect(fixture.transport.sentRequests.count == 3, "session-issue (2) + the failed hydration-get challenge (1) only")
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
    }

    @Test("A retry after an ACK that never actually committed server-side (same hydrated payload replayed) re-runs hydrate(_:) as a safe no-op and then acks successfully — no duplicate rows")
    func retryAfterAckNeverCommittedReplaysSamePayloadIdempotently() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "not_available")

        await #expect(throws: AthleteBackendHydrationError.ackNotConfirmed(.notAvailable)) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        let parentCountAfterFirst = try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count
        let athleteCountAfterFirst = try fixture.athleteRepository.fetchAllAthletes().count
        #expect(parentCountAfterFirst == 1)
        #expect(athleteCountAfterFirst == 1)

        // Retry: the backend's permanent marker is STILL nil (the ack
        // never actually committed), so it replays the SAME hydrated
        // payload rather than reporting already_completed.
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked")

        let secondOutcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        #expect(secondOutcome == .hydratedAndAcked)

        // Re-running hydrate(_:) against the identical payload is a
        // pure no-op — no duplicate rows.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == parentCountAfterFirst)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == athleteCountAfterFirst)
    }
}
