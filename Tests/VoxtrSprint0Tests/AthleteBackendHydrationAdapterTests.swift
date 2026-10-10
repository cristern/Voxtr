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

/// `@MainActor`-isolated (matching `AthleteDeviceAuthorizationSessionManagerTests
/// .FakeManagerTransport`'s own established fix exactly — build 246's
/// crash there was a real data race from a bare `@unchecked Sendable`
/// mutable dictionary read/written across actor boundaries while a
/// suspended `send(_:)` call was parked mid-flight; pinning to
/// `@MainActor` makes every access run on the same actor as the test
/// body driving it).
@MainActor
private final class FakeAdapterTransport: ParentAuthenticationTransport, @unchecked Sendable {
    private enum StubOutcome {
        case response(statusCode: Int, body: Data)
        case failure
    }
    struct SimulatedNetworkFailure: Error {}
    struct NoStubConfigured: Error {}

    private struct Stub {
        let outcome: StubOutcome
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

    /// R1 follow-up (ChatGPT review 6056790695): a REAL suspend/resume
    /// barrier for the one window `onConsumed` genuinely cannot reach —
    /// proving the adapter's post-acquisition check is what stops a
    /// stale/cancelled attempt even when `ensureActiveSession()`'s own
    /// renewal is suspended on an actual (not synchronously-simulated)
    /// network await when the clear/cancel happens. Mirrors
    /// `AthleteDeviceAuthorizationSessionManagerTests.FakeManagerTransport`'s
    /// own identical mechanism (pure `Task.yield()` polling, never
    /// `withCheckedContinuation` — no continuation-contract risk to get
    /// wrong blind).
    private var pendingSuspensionCountByPath: [String: Int] = [:]
    private var activeSuspensionCountByPath: [String: Int] = [:]
    private var releaseCountByPath: [String: Int] = [:]

    func enqueue(path: String, statusCode: Int, json: [String: Any?], onConsumed: (() -> Void)? = nil) {
        let cleaned = json.compactMapValues { $0 }
        let body = try! JSONSerialization.data(withJSONObject: cleaned)
        stubsByPath[path, default: []].append(Stub(outcome: .response(statusCode: statusCode, body: body), onConsumed: onConsumed))
    }

    /// Simulates a genuine transport-level failure (connection dropped,
    /// response never arrived) — distinct from a clean non-200 HTTP
    /// status: this makes `transport.send(_:)` itself THROW, exactly
    /// like `FakeManagerTransport.enqueueFailure` does.
    func enqueueFailure(path: String, onConsumed: (() -> Void)? = nil) {
        stubsByPath[path, default: []].append(Stub(outcome: .failure, onConsumed: onConsumed))
    }

    func suspendNextResponse(path: String) {
        pendingSuspensionCountByPath[path, default: 0] += 1
    }

    /// Polls until at least `count` calls to `send(_:)` for `path` have
    /// reserved their own stub and parked.
    func waitUntilSuspended(path: String, count: Int = 1) async {
        while (activeSuspensionCountByPath[path] ?? 0) < count {
            await Task.yield()
        }
    }

    /// Releases the OLDEST still-parked call for `path` (FIFO).
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
        stub.onConsumed?()
        switch stub.outcome {
        case .failure:
            throw SimulatedNetworkFailure()
        case .response(let statusCode, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
    }
}

private final class FakeAdapterSigningKeyStore: AthleteDeviceSigningKeyStoring, @unchecked Sendable {
    let fixedPublicKey = Data([0x04] + Array(repeating: 0xAB, count: 64))
    let fixedSignature = Data(Array(repeating: 0xCD, count: 64))
    /// Tracks the exact message bytes signed on every call — lets a
    /// test prove a RETRY signs a genuinely fresh challenge/nonce
    /// rather than reusing a prior attempt's proof (R3 follow-up,
    /// ChatGPT review 6056631618).
    private(set) var signedMessages: [Data] = []

    func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey { makeKey() }
    func loadExistingSigningKey() throws -> AthleteDeviceSigningKey { makeKey() }

    private func makeKey() -> AthleteDeviceSigningKey {
        AthleteDeviceSigningKey(fixedPublicKey: fixedPublicKey, fixedSignature: fixedSignature) { [weak self] message in
            self?.signedMessages.append(message)
        }
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
        let signingKeyStore: FakeAdapterSigningKeyStore
        let clock: FakeAdapterClock
        let sessionManager: AthleteDeviceAuthorizationSessionManager
        let identityHydrationService: AthleteIdentityHydrationService
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
            signingKeyStore: signingKeyStore,
            clock: clock,
            sessionManager: sessionManager,
            identityHydrationService: identityHydrationService,
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

    /// `Self.wellFormedHydrationFields` with one field overridden —
    /// keeps the malformed-field tests focused on the ONE value under
    /// test rather than repeating all 11 fields each time.
    private static func fields(
        birthDateISO: String? = nil, timeZoneId: String? = nil, developmentStage: String? = nil
    ) -> AthleteDeviceAuthorizationHydrationFields {
        let base = Self.wellFormedHydrationFields
        return AthleteDeviceAuthorizationHydrationFields(
            workspaceId: base.workspaceId,
            intendedParticipantId: base.intendedParticipantId,
            intendedAthleteId: base.intendedAthleteId,
            parentId: base.parentId,
            parentGivenName: base.parentGivenName,
            workspaceDisplayName: base.workspaceDisplayName,
            ownerParticipantId: base.ownerParticipantId,
            athleteGivenName: base.athleteGivenName,
            athleteBirthDateISO: birthDateISO ?? base.athleteBirthDateISO,
            athleteTimeZoneId: timeZoneId ?? base.athleteTimeZoneId,
            athleteDevelopmentStage: developmentStage ?? base.athleteDevelopmentStage
        )
    }

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
        _ transport: FakeAdapterTransport, wireOutcome: String,
        challengeOnConsumed: (() -> Void)? = nil, submitOnConsumed: (() -> Void)? = nil
    ) {
        enqueueIssuedChallenge(transport, onConsumed: challengeOnConsumed)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": wireOutcome], onConsumed: submitOnConsumed)
    }

    // MARK: - Full success path, exact 11-field mapping (issue #111 acceptance matrix)

    @Test("hydrate(deviceGrantId:) on a fresh device: issues a session, gets hydration, feeds the unchanged AthleteIdentityHydrationService.hydrate(_:), acks only after that succeeds, and persists exactly the 11 mapped fields")
    func fullSuccessPathHydratesAndAcksWithExactFieldMapping() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked")

        let outcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .hydratedAndAcked(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            participantId: Self.wellFormedHydrationFields.intendedParticipantId,
            athleteId: Self.wellFormedHydrationFields.intendedAthleteId
        ))
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
        #expect(firstOutcome == .hydratedAndAcked(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            participantId: Self.wellFormedHydrationFields.intendedParticipantId,
            athleteId: Self.wellFormedHydrationFields.intendedAthleteId
        ))

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

    @Test("hydrate(deviceGrantId:) throws .sessionInvalidatedOrCancelled when the session is cleared right as the hydration_ack SUBMIT response itself arrives — a 'late' ack confirmation the backend genuinely committed, but this caller must not report as success once staleness is detected after the fact")
    func clearAsAckSubmitResponseArrivesIsNeverReportedAsSuccess() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked", submitOnConsumed: {
            fixture.sessionManager.clearStoredSession()
        })

        await #expect(throws: AthleteBackendHydrationError.sessionInvalidatedOrCancelled) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        // session-issue (2) + hydration-get (2) + hydration-ack (2) — the
        // ack SUBMIT itself was sent and the backend's own response says
        // "acked" (ackHydration() returns normally; it has no idea the
        // generation changed), but the adapter's OWN post-return check
        // catches the staleness before ever reporting success.
        #expect(fixture.transport.sentRequests.count == 6)
        // The local upsert from the successful GET above already
        // committed real rows — never rolled back.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == 1)
    }

    @Test("hydrate(deviceGrantId:) throws CancellationError and sends NO request at all if this Task is already cancelled before it starts")
    func cancelledTaskSendsNoRequestsAtAll() async throws {
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

        // The ENTRY check (R1 follow-up, ChatGPT review 6056631618)
        // catches this before ever calling ensureActiveSession() —
        // not even the session-issue challenge is sent.
        #expect(fixture.transport.sentRequests.isEmpty)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) throws CancellationError and never sends the hydration_get challenge if cancelled during ensureActiveSession()'s own (uncancellable-by-us) session-issue network call")
    func cancelledDuringSessionAcquisitionStopsBeforeGetChallenge() async throws {
        let fixture = try makeFixture()
        var task: Task<AthleteBackendHydrationOutcome, Error>?
        enqueueIssuedChallenge(fixture.transport)
        fixture.transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "issued",
            "session_token": "session-token",
            "expires_at": Self.sessionExpiresAt,
            "absolute_expires_at": Self.sessionAbsoluteExpiresAt,
        ], onConsumed: {
            // Fires the moment ensureActiveSession()'s OWN submit
            // resolves — simulating cancellation landing exactly in
            // that window. ensureActiveSession() itself does not
            // observe this (it is an unstructured Task — the whole
            // point of this regression), so session issuance still
            // completes and is persisted; the adapter's own check
            // right after ensureActiveSession() returns must be what
            // actually stops the attempt.
            task?.cancel()
        })
        enqueueHydrationGetSuccess(fixture.transport)

        task = Task {
            try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task!.value
        }

        // session-issue (2) only — the hydration-get challenge must
        // never be sent once the post-acquisition check observes the
        // cancellation.
        #expect(fixture.transport.sentRequests.count == 2)
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

    // MARK: - R2 follow-up (ChatGPT review 6056631618): LocalDate.init?(isoString:)
    // has no calendar/canonical-format validation of its own — exercised directly here.

    @Test("hydrate(deviceGrantId:) rejects a non-canonical birth date string (\"2012-4-10\", not zero-padded) even though LocalDate.init?(isoString:) itself parses it")
    func nonCanonicalBirthDateFormatIsRejected() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport, fields: Self.fields(birthDateISO: "2012-4-10"))

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteBirthDateISO")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }
        #expect(try fixture.athleteRepository.fetchAllAthletes().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) rejects a calendar-invalid birth date (\"2012-02-30\", February has no 30th) even though LocalDate.init?(isoString:) itself parses it")
    func calendarInvalidDayIsRejected() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport, fields: Self.fields(birthDateISO: "2012-02-30"))

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteBirthDateISO")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }
        #expect(try fixture.athleteRepository.fetchAllAthletes().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) rejects a calendar-invalid birth date (\"2012-13-01\", month 13 does not exist) even though LocalDate.init?(isoString:) itself parses it")
    func calendarInvalidMonthIsRejected() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport, fields: Self.fields(birthDateISO: "2012-13-01"))

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteBirthDateISO")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }
        #expect(try fixture.athleteRepository.fetchAllAthletes().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) rejects February 29th on a non-leap year (\"2023-02-29\") but accepts it on a real leap year (\"2024-02-29\") — the leap-day boundary")
    func leapDayBoundaryIsValidatedCorrectly() async throws {
        let rejectingFixture = try makeFixture()
        enqueueSessionIssueSuccess(rejectingFixture.transport)
        enqueueHydrationGetSuccess(rejectingFixture.transport, fields: Self.fields(birthDateISO: "2023-02-29"))

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteBirthDateISO")) {
            _ = try await rejectingFixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        let acceptingFixture = try makeFixture()
        enqueueSessionIssueSuccess(acceptingFixture.transport)
        enqueueHydrationGetSuccess(acceptingFixture.transport, fields: Self.fields(birthDateISO: "2024-02-29"))
        enqueueHydrationAck(acceptingFixture.transport, wireOutcome: "acked")

        let outcome = try await acceptingFixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        #expect(outcome == .hydratedAndAcked(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            participantId: Self.wellFormedHydrationFields.intendedParticipantId,
            athleteId: Self.wellFormedHydrationFields.intendedAthleteId
        ))
        #expect(try acceptingFixture.athleteRepository.fetchAllAthletes().first?.birthDate.isoString == "2024-02-29")
    }

    @Test("hydrate(deviceGrantId:) rejects a malformed development stage even with a PRE-EXISTING, same-workspace athlete profile already persisted locally")
    func malformedStageIsRejectedEvenWithPreExistingMatchingAthleteProfile() async throws {
        let fixture = try makeFixture()
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
        enqueueHydrationGetSuccess(fixture.transport, fields: Self.fields(developmentStage: "not-a-real-stage"))

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteDevelopmentStage")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == 1)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().isEmpty)
    }

    @Test("hydrate(deviceGrantId:) rejects a malformed timezone even with a PRE-EXISTING, same-workspace athlete profile already persisted locally")
    func malformedTimeZoneIsRejectedEvenWithPreExistingMatchingAthleteProfile() async throws {
        let fixture = try makeFixture()
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
        enqueueHydrationGetSuccess(fixture.transport, fields: Self.fields(timeZoneId: "Not/A_Real_Zone"))

        await #expect(throws: AthleteBackendHydrationError.malformedHydrationPayload(field: "athleteTimeZoneId")) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }
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
        #expect(secondOutcome == .hydratedAndAcked(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            participantId: Self.wellFormedHydrationFields.intendedParticipantId,
            athleteId: Self.wellFormedHydrationFields.intendedAthleteId
        ))

        // Re-running hydrate(_:) against the identical payload is a
        // pure no-op — no duplicate rows.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == parentCountAfterFirst)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == athleteCountAfterFirst)
    }

    // MARK: - R3 follow-up (ChatGPT review 6056631618): a GENUINE lost
    // response (transport failure, not a confirmed wire outcome) and a
    // genuinely partially-saved local graph.

    @Test("A retry after a genuine ACK transport-level failure (not a confirmed wire outcome) replays the same hydrated payload idempotently and signs a FRESH ACK proof — never reusing the failed attempt's own challenge/signature")
    func retryAfterGenuineAckTransportFailureUsesFreshProof() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        // The ACK challenge succeeds, but its SUBMIT fails at the
        // transport level — genuinely ambiguous: unlike a clean
        // "not_available" wire outcome, we have NO idea whether the
        // backend actually committed this ack before the response was
        // lost.
        enqueueIssuedChallenge(fixture.transport)
        fixture.transport.enqueue(path: "device-session-submit", statusCode: 500, json: [:])

        await #expect(throws: AthleteDeviceAuthorizationSessionError.network) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        let parentCountAfterFirst = try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count
        #expect(parentCountAfterFirst == 1, "the local upsert from the successful GET already committed")

        func ackSignedMessages() -> [Data] {
            fixture.signingKeyStore.signedMessages.filter { String(decoding: $0, as: UTF8.self).contains("hydration-ack") }
        }
        #expect(ackSignedMessages().count == 1, "the first attempt's own ACK challenge was signed exactly once before its submit failed")

        // Retry: this test's OWN fixture chooses to have the backend
        // report the ack as NEVER having committed (it replays the SAME
        // hydrated payload rather than already_completed) — but a lost
        // response genuinely does NOT tell the client which of the two
        // real outcomes happened (ChatGPT review 6056790695: "lack of a
        // confirmed response does not imply the permanent marker is
        // nil"). The OTHER real outcome — the ack DID commit, response
        // merely lost — is covered separately by
        // `retryAfterGenuineAckTransportFailureWhereAckDidCommit` below.
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked")

        let secondOutcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        #expect(secondOutcome == .hydratedAndAcked(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            participantId: Self.wellFormedHydrationFields.intendedParticipantId,
            athleteId: Self.wellFormedHydrationFields.intendedAthleteId
        ))

        let signedAfterRetry = ackSignedMessages()
        #expect(signedAfterRetry.count == 2, "the retry signed its OWN new ACK challenge rather than skipping straight to a (nonexistent) cached proof")
        #expect(signedAfterRetry[0] != signedAfterRetry[1], "the retry's ack proof is a FRESH signature over a fresh challenge, never a byte-for-byte replay of the failed attempt's own proof")

        // Re-running hydrate(_:) against the identical payload is a
        // pure no-op — no duplicate rows.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == parentCountAfterFirst)
    }

    @Test("A retry after a genuine ACK transport-level failure where the ack HAD actually committed server-side (retry GET reports already_completed) accepts that as success without re-hydrating or re-acking")
    func retryAfterGenuineAckTransportFailureWhereAckDidCommit() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        // The ACK challenge succeeds, but its SUBMIT fails at the
        // transport level — this is the OTHER real possibility a lost
        // response leaves open: the backend actually committed the ack
        // before the response was lost. The client has no way to tell
        // the two apart from this failure alone; only a subsequent GET
        // reveals which actually happened.
        enqueueIssuedChallenge(fixture.transport)
        fixture.transport.enqueueFailure(path: "device-session-submit")

        await #expect(throws: AthleteDeviceAuthorizationSessionError.network) {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        let parentCountAfterFirst = try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count
        let athleteCountAfterFirst = try fixture.athleteRepository.fetchAllAthletes().count
        #expect(parentCountAfterFirst == 1)

        // Retry: the ack actually DID commit server-side — the
        // permanent marker now reads 'acked'.
        enqueueHydrationGetTerminal(fixture.transport, wireOutcome: "already_completed")

        let secondOutcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        #expect(secondOutcome == .alreadyCompleted)

        // No second local hydration, no second ack attempt — the
        // existing rows from the first attempt's own successful GET are
        // untouched, never duplicated or re-activated.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == parentCountAfterFirst)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == athleteCountAfterFirst)
    }

    // MARK: - R3 follow-up (ChatGPT review 6056790695/6056950649/6057405952,
    // Product Owner approval confirmed directly by the user on PR #117):
    // an injected persistence-boundary failure, mapped through the real
    // AthleteIdentityHydrationError.persistenceFailed error path, via
    // AthleteIdentityHydrationService's own internal, @testable-only,
    // defaulted-nil fault seam at the access-grant persistence boundary
    // — never a change to its public constructor/hydrate(_:) signature,
    // normal upsert/conflict behavior, or any repository's access level.

    @Test("An injected persistence-boundary failure at the access-grant step (the LAST of hydrate(_:)'s upsert steps), mapped through the real AthleteIdentityHydrationError.persistenceFailed error path, is never acked and retains every earlier step's already-committed rows; disarming the fault and retrying resumes to .hydratedAndAcked without duplicating any identity")
    func persistenceFailureAtAccessGrantBoundaryThrowsWithNoAckThenRetryCompletesWithoutDuplicates() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)

        struct InjectedPersistenceFailure: Error {}
        fixture.identityHydrationService.accessGrantPersistenceFaultForTesting = {
            throw InjectedPersistenceFailure()
        }

        do {
            _ = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
            Issue.record("Expected hydrate(deviceGrantId:) to throw")
        } catch let error as AthleteIdentityHydrationError {
            guard case .persistenceFailed = error else {
                Issue.record("Expected .persistenceFailed, got \(error)")
                return
            }
        }

        // No ack was ever attempted — session-issue (2) + hydration-get
        // (2) only; identityHydrationService.hydrate(_:) throwing stops
        // the adapter before it ever reaches the ACK-side ensureActiveSession().
        #expect(fixture.transport.sentRequests.count == 4, "no ack request must ever be sent once local hydration itself fails")
        // Every earlier upsert step (parent, workspace, owner
        // participant, athlete profile, athlete participant) already
        // committed real rows before the injected failure at the LAST
        // step — never rolled back (this service's own NOT ATOMIC
        // ACROSS ALL [FIVE/SIX] ENTITIES doc comment).
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count == 1)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParticipants().count == 2)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == 1)
        // The step whose fault was injected — never created.
        #expect(try fixture.athleteAccessGrantRepository.fetchAllGrants().isEmpty)

        // Disarm the fault and retry: the cached session token is still
        // valid (within the sliding window), so only a fresh
        // hydration_get + hydration_ack are sent; the five already-
        // committed steps are reused untouched (find-by-ID-or-create),
        // and only the access grant — the step that actually failed —
        // is created fresh.
        fixture.identityHydrationService.accessGrantPersistenceFaultForTesting = nil
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked")

        let secondOutcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        #expect(secondOutcome == .hydratedAndAcked(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            participantId: Self.wellFormedHydrationFields.intendedParticipantId,
            athleteId: Self.wellFormedHydrationFields.intendedAthleteId
        ))

        // 4 (first attempt) + hydration-get (2) + hydration-ack (2) = 8
        // — no further session-issue, since the cached token is reused.
        #expect(fixture.transport.sentRequests.count == 8)
        // No duplicate identities anywhere — every earlier step's row
        // count is unchanged, and the access grant now exists exactly once.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count == 1)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParticipants().count == 2)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == 1)
        #expect(try fixture.athleteAccessGrantRepository.fetchAllGrants().count == 1)
    }

    // MARK: - R1 follow-up (ChatGPT review 6056790695): a REAL suspend/
    // resume barrier for cancellation during ACK-side session
    // RENEWAL — the one window a synchronous onConsumed hook cannot
    // reach, since ensureActiveSession()'s own renewal genuinely
    // suspends on a live network await here (forced via advancing the
    // injected clock into the sliding-window renewal lead time), not a
    // synchronously-simulated one.

    @Test("hydrate(deviceGrantId:) throws CancellationError and never sends the ACK challenge if cancelled while the ACK-side ensureActiveSession() is genuinely suspended mid-RENEWAL (forced via clock advance) — the manager's own renewal completes regardless (it only guards against clearStoredSession(), never caller cancellation), so this adapter's own post-acquisition check is what actually stops it")
    func cancelledDuringGenuineAckRenewalSuspensionStopsBeforeAckChallenge() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)

        // Advance "now" into the sliding-window renewal lead time
        // (Self.sessionExpiresAt is 2026-10-08; the lead time is 24h) —
        // so the ACK-side ensureActiveSession() call below cannot take
        // its cached-token fast path and must genuinely renew.
        fixture.clock.currentTime = ISO8601DateFormatter().date(from: "2026-10-07T12:00:00Z")!
        enqueueIssuedChallenge(fixture.transport)
        fixture.transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "renewed",
            "expires_at": "2026-10-15T00:00:00Z",
            "absolute_expires_at": Self.sessionAbsoluteExpiresAt,
        ])
        // THREE calls will post to "device-session-submit" in this one
        // attempt (session-issue's own, hydration-get's own, and the
        // renewal's own) — pre-arm a suspension for EACH, so the
        // FIFO slot mechanism (`waitUntilSuspended`/`resumeSuspendedResponse`,
        // identical to `AthleteDeviceAuthorizationSessionManagerTests
        // .FakeManagerTransport`'s own established pattern) lets this
        // test release the first two immediately and genuinely park
        // the renewal's own submit specifically, rather than racing to
        // guess when it alone has been reached.
        fixture.transport.suspendNextResponse(path: "device-session-submit")
        fixture.transport.suspendNextResponse(path: "device-session-submit")
        fixture.transport.suspendNextResponse(path: "device-session-submit")

        let task = Task {
            try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        await fixture.transport.waitUntilSuspended(path: "device-session-submit", count: 1)
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit") // session-issue's own submit proceeds

        await fixture.transport.waitUntilSuspended(path: "device-session-submit", count: 2)
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit") // hydration-get's own submit proceeds

        // The renewal's own submit is NOW genuinely parked, mid-await,
        // inside ensureActiveSession()'s own unstructured Task — cancel
        // THIS caller's task right here, before releasing it.
        await fixture.transport.waitUntilSuspended(path: "device-session-submit", count: 3)
        task.cancel()
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit") // the renewal itself still completes — it never observed the cancellation

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        // session-issue (2) + hydration-get (2) + the renewal's own
        // challenge+submit (2) = 6 — the renewal itself completes (the
        // manager's own generation guard never fired, since nothing
        // cleared the session; only cancellation happened, which the
        // manager does not check) and genuinely renews the session, but
        // the ACK challenge itself must never be sent once this
        // adapter's own post-acquisition check observes the
        // cancellation.
        #expect(fixture.transport.sentRequests.count == 6)
        // The local upsert from the successful GET above already
        // committed — never rolled back.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
    }

    @Test("hydrate(deviceGrantId:) throws the MANAGER's own SessionFailure.sessionCleared (never this adapter's own .sessionInvalidatedOrCancelled) when clearStoredSession() runs while the ACK-side ensureActiveSession() is genuinely suspended mid-RENEWAL — the manager's own checkNotCleared guard fires INSIDE attemptRenew, before ever persisting the renewed session or returning to this adapter at all")
    func clearDuringGenuineAckRenewalSuspensionThrowsManagerOwnSessionCleared() async throws {
        let fixture = try makeFixture()
        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)

        // Same forced-renewal setup as `cancelledDuringGenuineAckRenewalSuspensionStopsBeforeAckChallenge`
        // above — only the final action (clear vs. cancel) differs.
        fixture.clock.currentTime = ISO8601DateFormatter().date(from: "2026-10-07T12:00:00Z")!
        enqueueIssuedChallenge(fixture.transport)
        fixture.transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "renewed",
            "expires_at": "2026-10-15T00:00:00Z",
            "absolute_expires_at": Self.sessionAbsoluteExpiresAt,
        ])
        fixture.transport.suspendNextResponse(path: "device-session-submit")
        fixture.transport.suspendNextResponse(path: "device-session-submit")
        fixture.transport.suspendNextResponse(path: "device-session-submit")

        let task = Task {
            try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        }

        await fixture.transport.waitUntilSuspended(path: "device-session-submit", count: 1)
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit") // session-issue's own submit proceeds

        await fixture.transport.waitUntilSuspended(path: "device-session-submit", count: 2)
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit") // hydration-get's own submit proceeds

        // The renewal's own submit is NOW genuinely parked — clear
        // (rather than cancel) right here, before releasing it. Unlike
        // cancellation, the MANAGER's own `checkNotCleared` guard (R6,
        // PR #116) DOES observe this: `attemptRenew` checks it
        // immediately after the submit resolves, BEFORE ever switching
        // on the outcome or persisting — so the renewed session is
        // never written to storage, and the thrown failure is the
        // manager's OWN `SessionFailure.sessionCleared`, surfacing
        // straight out of `ensureActiveSession()` before this adapter's
        // own post-acquisition `checkSessionStillValid` is ever reached.
        await fixture.transport.waitUntilSuspended(path: "device-session-submit", count: 3)
        fixture.sessionManager.clearStoredSession()
        fixture.transport.resumeSuspendedResponse(path: "device-session-submit")

        await #expect(throws: AthleteDeviceAuthorizationSessionManager.SessionFailure.sessionCleared) {
            _ = try await task.value
        }

        // session-issue (2) + hydration-get (2) + the renewal's own
        // challenge+submit (2) = 6 — the renewal's network round trip
        // still happened in full; only its RESULT is discarded.
        #expect(fixture.transport.sentRequests.count == 6)
        // The local upsert from the successful GET above already
        // committed — never rolled back.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
    }

    @Test("hydrate(deviceGrantId:) resumes a genuinely partially-saved local graph (parent/workspace/owner already persisted from an earlier interrupted attempt) and completes the remaining steps without duplicating what already exists")
    func resumesPartiallySavedGraphWithoutDuplicating() async throws {
        let fixture = try makeFixture()
        let fields = Self.wellFormedHydrationFields

        // Simulates a PRIOR attempt that got through hydrateParent/
        // hydrateWorkspace/hydrateOwnerParticipant and then was
        // interrupted (app killed, crash, etc.) before
        // hydrateAthleteProfile ever ran — AthleteIdentityHydrationService
        // .hydrate(_:)'s own NOT-ATOMIC-ACROSS-ALL-FIVE-ENTITIES design
        // means this is a real, reachable local state, not a
        // hypothetical one.
        let existingParent = ParentProfile(id: fields.parentId, accountId: .pending, givenName: fields.parentGivenName)
        fixture.container.mainContext.insert(existingParent)
        let existingWorkspace = FamilyWorkspace(
            id: WorkspaceId(rawValue: fields.workspaceId), displayName: fields.workspaceDisplayName, technicalOwnerAccountId: .pending
        )
        fixture.container.mainContext.insert(existingWorkspace)
        let existingOwner = WorkspaceParticipant(
            id: fields.ownerParticipantId, workspaceId: WorkspaceId(rawValue: fields.workspaceId),
            accountId: .pending, role: .workspaceOwner, state: .active
        )
        fixture.container.mainContext.insert(existingOwner)
        try fixture.container.mainContext.save()

        enqueueSessionIssueSuccess(fixture.transport)
        enqueueHydrationGetSuccess(fixture.transport)
        enqueueHydrationAck(fixture.transport, wireOutcome: "acked")

        let outcome = try await fixture.adapter.hydrate(deviceGrantId: Self.deviceGrantId)
        #expect(outcome == .hydratedAndAcked(
            workspaceId: Self.wellFormedHydrationFields.workspaceId,
            participantId: Self.wellFormedHydrationFields.intendedParticipantId,
            athleteId: Self.wellFormedHydrationFields.intendedAthleteId
        ))

        // Exactly one of each: the pre-existing parent/workspace/owner
        // were reused (never duplicated), and the three remaining steps
        // (athlete profile, athlete participant, access grant) were
        // completed fresh by this resumed call.
        #expect(try fixture.parentWorkspaceRepository.fetchAllParentProfiles().count == 1)
        #expect(try fixture.parentWorkspaceRepository.fetchAllWorkspaces().count == 1)
        #expect(try fixture.parentWorkspaceRepository.fetchAllParticipants().count == 2)
        #expect(try fixture.athleteRepository.fetchAllAthletes().count == 1)
        #expect(try fixture.athleteAccessGrantRepository.fetchAllGrants().count == 1)
    }
}
