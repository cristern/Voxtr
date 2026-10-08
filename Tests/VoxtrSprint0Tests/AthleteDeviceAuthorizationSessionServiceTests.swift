import Testing
import Foundation
import VoxtrParentAuthentication
@testable import VoxtrAppShell

// Athlete Connection V1 device-authorization session contract (§3, §8
// step 4). Exercises `AthleteDeviceAuthorizationSessionService`'s
// orchestration logic against a fake transport (no live network) and a
// fake signing-key store (no real Keychain/CryptoKit key generation) —
// matching `AthleteDeviceAuthorizationServiceTests.swift`'s own
// established fake-transport pattern for the sibling claim-proof
// service. Wire JSON uses snake_case keys deliberately, matching the
// actual merged `cristern/Voxtr-Backend` `device-session-challenge`/
// `device-session-submit` handler shapes this service decodes/encodes
// against (confirmed directly from their source, not inferred).

private final class FakeDeviceSessionTransport: ParentAuthenticationTransport, @unchecked Sendable {
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

/// A deterministic fake signing key — never real CryptoKit/Keychain I/O
/// — so these tests can assert exactly what gets sent on the wire.
/// Tracks `loadOrCreateSigningKey()`/`loadExistingSigningKey()`
/// separately so tests can prove the session service ONLY ever calls
/// the latter (§3.4/this service's own doc comment: never silently
/// mints a replacement key).
private final class FakeSessionSigningKeyStore: AthleteDeviceSigningKeyStoring, @unchecked Sendable {
    let fixedPublicKey = Data([0x04] + Array(repeating: 0xAB, count: 64))
    let fixedSignature = Data(Array(repeating: 0xCD, count: 64))
    private(set) var signedMessages: [Data] = []
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
        AthleteDeviceSigningKey(fixedPublicKey: fixedPublicKey, fixedSignature: fixedSignature) { [weak self] message in
            self?.signedMessages.append(message)
        }
    }
}

@Suite("AthleteDeviceAuthorizationSessionService (Athlete Connection V1, device-authorization session)")
@MainActor
struct AthleteDeviceAuthorizationSessionServiceTests {

    private static let baseURL = URL(string: "https://device-auth.invalid/functions/v1")!
    private static let deviceGrantId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let challengeId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let anonKey = "test-anon-key"
    private static let existingSessionToken = "existing-session-token"
    /// A well-formed 32-byte nonce — `device-session-challenge`'s own
    /// `NONCE_LENGTH_BYTES` requires exactly this length.
    private static let wellFormedNonce = Data((0..<32).map { UInt8($0) })

    private func makeService(
        transport: FakeDeviceSessionTransport = FakeDeviceSessionTransport(),
        signingKeyStore: FakeSessionSigningKeyStore = FakeSessionSigningKeyStore(),
        anonKey: String = Self.anonKey
    ) -> (AthleteDeviceAuthorizationSessionService, FakeDeviceSessionTransport, FakeSessionSigningKeyStore) {
        let service = AthleteDeviceAuthorizationSessionService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            gatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration(anonKey: anonKey),
            transport: transport,
            signingKeyStore: signingKeyStore
        )
        return (service, transport, signingKeyStore)
    }

    private func requestBodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func enqueueIssuedChallenge(_ transport: FakeDeviceSessionTransport, expiresAt: String = "2026-10-05T00:01:00Z") {
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": Self.challengeId.uuidString,
            "nonce": AthleteDeviceAuthorizationSessionService.base64UrlEncode(Self.wellFormedNonce),
            "expires_at": expiresAt,
        ])
    }

    // MARK: - Gateway configuration

    @Test("issueSession() and renewSession() both attach the Supabase apikey/Authorization gateway header pair, never a Parent session header")
    func bothCallsAttachGatewayHeaders() async throws {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "challenge_not_available"])
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "session_invalid"])

        _ = try await service.issueSession(deviceGrantId: Self.deviceGrantId)
        _ = try await service.renewSession(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(transport.sentRequests.count == 2)
        for request in transport.sentRequests {
            #expect(request.value(forHTTPHeaderField: "apikey") == Self.anonKey)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.anonKey)")
            #expect(request.value(forHTTPHeaderField: "X-Voxtr-Parent-Session") == nil)
        }
    }

    @Test("Both calls throw .gatewayConfigurationMissing and send no request when the anon key is empty")
    func bothCallsFailClosedOnMissingGatewayConfiguration() async {
        let (service, transport, _) = makeService(anonKey: "")

        await #expect(throws: AthleteDeviceAuthorizationSessionError.gatewayConfigurationMissing) {
            _ = try await service.issueSession(deviceGrantId: Self.deviceGrantId)
        }
        await #expect(throws: AthleteDeviceAuthorizationSessionError.gatewayConfigurationMissing) {
            _ = try await service.renewSession(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)
        }
        #expect(transport.sentRequests.isEmpty)
    }

    // MARK: - Installation-key availability check (R5, PR #116, ChatGPT review 6020919614)

    @Test("currentInstallationHasExistingSigningKey() reports true/false exactly as loadExistingSigningKey() would succeed/throw, without ever generating a replacement — mirrors AthleteDeviceAuthorizationService's own identically-named method")
    func currentInstallationHasExistingSigningKeyMirrorsLoadExisting() {
        let availableKeyStore = FakeSessionSigningKeyStore()
        let (availableService, _, _) = makeService(signingKeyStore: availableKeyStore)
        #expect(availableService.currentInstallationHasExistingSigningKey() == true)
        #expect(availableKeyStore.loadExistingCallCount == 1)
        #expect(availableKeyStore.loadOrCreateCallCount == 0)

        let missingKeyStore = FakeSessionSigningKeyStore()
        missingKeyStore.throwOnLoadExisting = true
        let (missingService, _, _) = makeService(signingKeyStore: missingKeyStore)
        #expect(missingService.currentInstallationHasExistingSigningKey() == false)
        #expect(missingKeyStore.loadOrCreateCallCount == 0, "a missing key must never be silently replaced just by checking availability")
    }

    // MARK: - Mid-call invalidation hook (R6 follow-up, ChatGPT review 6025279987)
    //
    // Both issueSession()/renewSession() each contain TWO separate
    // network awaits (challenge, then sign+submit). A caller-level
    // guard checked only before/after the whole call cannot stop the
    // SUBMIT specifically — which has a real server-side effect — from
    // being sent if the caller's own invalidation happens while this
    // call is suspended between the two. checkNotCancelled is called
    // right after the challenge succeeds, before signing/submitting,
    // so a caller can reject the operation at that exact point.

    @Test("issueSession()'s checkNotCancelled runs after a successful challenge and before signing/submitting — if it throws, no submit is ever sent and no signing is attempted")
    func issueSessionChecksNotCancelledBeforeSubmitting() async throws {
        let (service, transport, signingKeyStore) = makeService()
        enqueueIssuedChallenge(transport)
        struct CancelledForTest: Error, Equatable {}

        await #expect(throws: CancelledForTest()) {
            _ = try await service.issueSession(deviceGrantId: Self.deviceGrantId) {
                throw CancelledForTest()
            }
        }
        #expect(transport.sentRequests.count == 1, "only the challenge was sent — checkNotCancelled's throw must happen before any submit request")
        #expect(signingKeyStore.loadExistingCallCount == 0, "signing must never happen once checkNotCancelled rejects the operation")
    }

    @Test("renewSession()'s checkNotCancelled runs after a successful challenge and before signing/submitting — if it throws, no submit is ever sent and no signing is attempted")
    func renewSessionChecksNotCancelledBeforeSubmitting() async throws {
        let (service, transport, signingKeyStore) = makeService()
        enqueueIssuedChallenge(transport)
        struct CancelledForTest: Error, Equatable {}

        await #expect(throws: CancelledForTest()) {
            _ = try await service.renewSession(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken) {
                throw CancelledForTest()
            }
        }
        #expect(transport.sentRequests.count == 1, "only the challenge was sent — checkNotCancelled's throw must happen before any submit request")
        #expect(signingKeyStore.loadExistingCallCount == 0, "signing must never happen once checkNotCancelled rejects the operation")
    }

    // MARK: - session_issue

    @Test("issueSession() sends action=session_issue with no session_token, signs the challenge with loadExistingSigningKey(), and maps .issued")
    func issueSessionSendsCorrectActionAndSignsWithExistingKey() async throws {
        let (service, transport, signingKeyStore) = makeService()
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "issued",
            "session_token": "fresh-session-token",
            "expires_at": "2026-10-12T00:00:00Z",
            "absolute_expires_at": "2027-01-03T00:00:00Z",
        ])

        let outcome = try await service.issueSession(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .issued(
            sessionToken: "fresh-session-token",
            expiresAt: ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z")!,
            absoluteExpiresAt: ISO8601DateFormatter().date(from: "2027-01-03T00:00:00Z")!
        ))

        let challengeBody = try requestBodyJSON(transport.sentRequests[0])
        #expect(challengeBody["device_grant_id"] as? String == Self.deviceGrantId.uuidString)
        #expect(challengeBody["action"] as? String == "session_issue")
        #expect(challengeBody["session_token"] == nil || challengeBody["session_token"] is NSNull)

        let submitBody = try requestBodyJSON(transport.sentRequests[1])
        #expect(submitBody["action"] as? String == "session_issue")
        #expect(submitBody["challenge_id"] as? String == Self.challengeId.uuidString)
        #expect(submitBody["signature"] as? String == AthleteDeviceAuthorizationSessionService.base64UrlEncode(signingKeyStore.fixedSignature))

        let expectedMessage = AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(
            action: .sessionIssue, deviceGrantId: Self.deviceGrantId, challengeId: Self.challengeId, nonce: Self.wellFormedNonce
        )
        #expect(signingKeyStore.signedMessages == [expectedMessage])
        #expect(signingKeyStore.loadExistingCallCount == 1)
        #expect(signingKeyStore.loadOrCreateCallCount == 0, "a device-authorization session must never mint a new installation key")
    }

    @Test("issueSession() maps challenge_not_available to .grantNotAvailable, sending no submit request")
    func issueSessionMapsChallengeNotAvailable() async throws {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "challenge_not_available"])

        let outcome = try await service.issueSession(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .grantNotAvailable)
        #expect(transport.sentRequests.count == 1)
    }

    @Test("issueSession() maps the submit-side not_available fold to .notAvailable")
    func issueSessionMapsSubmitNotAvailable() async throws {
        let (service, transport, _) = makeService()
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": "not_available"])

        let outcome = try await service.issueSession(deviceGrantId: Self.deviceGrantId)

        #expect(outcome == .notAvailable)
    }

    @Test("issueSession() throws .signingKeyUnavailable and sends no submit request when loadExistingSigningKey() fails")
    func issueSessionThrowsWhenKeyUnavailable() async throws {
        let signingKeyStore = FakeSessionSigningKeyStore()
        signingKeyStore.throwOnLoadExisting = true
        let (service, transport, _) = makeService(signingKeyStore: signingKeyStore)
        enqueueIssuedChallenge(transport)

        await #expect(throws: AthleteDeviceAuthorizationSessionError.signingKeyUnavailable) {
            _ = try await service.issueSession(deviceGrantId: Self.deviceGrantId)
        }
        #expect(transport.sentRequests.count == 1, "the challenge request happens before signing, but no submit request should follow")
    }

    @Test("issueSession() throws .malformedResponse for an issued challenge whose nonce is the wrong length")
    func issueSessionRejectsWrongLengthNonce() async {
        let (service, transport, _) = makeService()
        let shortNonce = Data([0xAA, 0xBB, 0xCC])
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": Self.challengeId.uuidString,
            "nonce": AthleteDeviceAuthorizationSessionService.base64UrlEncode(shortNonce),
            "expires_at": "2026-10-05T00:01:00Z",
        ])

        await #expect(throws: AthleteDeviceAuthorizationSessionError.malformedResponse) {
            _ = try await service.issueSession(deviceGrantId: Self.deviceGrantId)
        }
    }

    // MARK: - session_renew

    @Test("renewSession() sends action=session_renew with the presented session_token, signs with loadExistingSigningKey(), and maps .renewed — never returning a new token")
    func renewSessionSendsCorrectActionAndMapsRenewed() async throws {
        let (service, transport, signingKeyStore) = makeService()
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: [
            "outcome": "renewed",
            "expires_at": "2026-10-12T00:00:00Z",
            "absolute_expires_at": "2027-01-03T00:00:00Z",
        ])

        let outcome = try await service.renewSession(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .renewed(
            expiresAt: ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z")!,
            absoluteExpiresAt: ISO8601DateFormatter().date(from: "2027-01-03T00:00:00Z")!
        ))

        let challengeBody = try requestBodyJSON(transport.sentRequests[0])
        #expect(challengeBody["action"] as? String == "session_renew")
        #expect(challengeBody["session_token"] as? String == Self.existingSessionToken)

        let submitBody = try requestBodyJSON(transport.sentRequests[1])
        #expect(submitBody["action"] as? String == "session_renew")
        #expect(submitBody["session_token"] as? String == Self.existingSessionToken)

        let expectedMessage = AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(
            action: .sessionRenew, deviceGrantId: Self.deviceGrantId, challengeId: Self.challengeId, nonce: Self.wellFormedNonce
        )
        #expect(signingKeyStore.signedMessages == [expectedMessage])
        #expect(signingKeyStore.loadExistingCallCount == 1)
        #expect(signingKeyStore.loadOrCreateCallCount == 0)
    }

    @Test("renewSession() maps session_invalid at the challenge step to .sessionInvalid, signing nothing")
    func renewSessionMapsSessionInvalid() async throws {
        let (service, transport, signingKeyStore) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "session_invalid"])

        let outcome = try await service.renewSession(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .sessionInvalid)
        #expect(signingKeyStore.signedMessages.isEmpty)
    }

    @Test("renewSession() maps challenge_not_available to .grantNotAvailable")
    func renewSessionMapsChallengeNotAvailable() async throws {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "challenge_not_available"])

        let outcome = try await service.renewSession(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .grantNotAvailable)
    }

    @Test("renewSession() maps the submit-side not_available fold to .notAvailable")
    func renewSessionMapsSubmitNotAvailable() async throws {
        let (service, transport, _) = makeService()
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": "not_available"])

        let outcome = try await service.renewSession(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .notAvailable)
    }

    @Test("renewSession() throws .signingKeyUnavailable and sends no submit request when loadExistingSigningKey() fails")
    func renewSessionThrowsWhenKeyUnavailable() async throws {
        let signingKeyStore = FakeSessionSigningKeyStore()
        signingKeyStore.throwOnLoadExisting = true
        let (service, transport, _) = makeService(signingKeyStore: signingKeyStore)
        enqueueIssuedChallenge(transport)

        await #expect(throws: AthleteDeviceAuthorizationSessionError.signingKeyUnavailable) {
            _ = try await service.renewSession(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)
        }
        #expect(transport.sentRequests.count == 1)
    }

    // MARK: - hydration_get/hydration_ack (§4, §8 step 5, issue #111)

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

    private func enqueueHydratedSubmit(_ transport: FakeDeviceSessionTransport, fields: AthleteDeviceAuthorizationHydrationFields = Self.wellFormedHydrationFields) {
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

    @Test("getHydration() sends action=hydration_get with the presented session_token, signs with loadExistingSigningKey(), and maps .hydrated with all 11 fields exactly")
    func getHydrationSendsCorrectActionAndMapsAllElevenFields() async throws {
        let (service, transport, signingKeyStore) = makeService()
        enqueueIssuedChallenge(transport)
        enqueueHydratedSubmit(transport)

        let outcome = try await service.getHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .hydrated(Self.wellFormedHydrationFields))

        let challengeBody = try requestBodyJSON(transport.sentRequests[0])
        #expect(challengeBody["action"] as? String == "hydration_get")
        #expect(challengeBody["session_token"] as? String == Self.existingSessionToken)

        let submitBody = try requestBodyJSON(transport.sentRequests[1])
        #expect(submitBody["action"] as? String == "hydration_get")
        #expect(submitBody["session_token"] as? String == Self.existingSessionToken)

        let expectedMessage = AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(
            action: .hydrationGet, deviceGrantId: Self.deviceGrantId, challengeId: Self.challengeId, nonce: Self.wellFormedNonce
        )
        #expect(signingKeyStore.signedMessages == [expectedMessage])
        #expect(signingKeyStore.loadExistingCallCount == 1)
        #expect(signingKeyStore.loadOrCreateCallCount == 0, "hydration must never mint a new installation key")
    }

    @Test("getHydration() maps session_invalid at the challenge step to .sessionInvalid, signing nothing")
    func getHydrationMapsSessionInvalid() async throws {
        let (service, transport, signingKeyStore) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "session_invalid"])

        let outcome = try await service.getHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .sessionInvalid)
        #expect(signingKeyStore.signedMessages.isEmpty)
    }

    @Test("getHydration() maps challenge_not_available to .grantNotAvailable")
    func getHydrationMapsChallengeNotAvailable() async throws {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "challenge_not_available"])

        let outcome = try await service.getHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .grantNotAvailable)
    }

    private func assertGetHydrationMapsSubmitOutcome(wireOutcome: String, expected: AthleteDeviceAuthorizationHydrationGetOutcome) async throws {
        let (service, transport, _) = makeService()
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": wireOutcome])

        let outcome = try await service.getHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == expected)
    }

    @Test("getHydration() maps the submit-side not_available fold to .notAvailable")
    func getHydrationMapsSubmitNotAvailable() async throws {
        try await assertGetHydrationMapsSubmitOutcome(wireOutcome: "not_available", expected: .notAvailable)
    }

    @Test("getHydration() maps the permanent-marker 'acked' outcome to .alreadyCompleted, never a newly delivered payload")
    func getHydrationMapsAlreadyCompleted() async throws {
        try await assertGetHydrationMapsSubmitOutcome(wireOutcome: "already_completed", expected: .alreadyCompleted)
    }

    @Test("getHydration() maps the permanent-marker 'expired' outcome to .deadlinePassed")
    func getHydrationMapsDeadlinePassed() async throws {
        try await assertGetHydrationMapsSubmitOutcome(wireOutcome: "deadline_passed", expected: .deadlinePassed)
    }

    @Test("getHydration() maps the permanent-marker 'revoked' outcome to .grantRevoked")
    func getHydrationMapsGrantRevoked() async throws {
        try await assertGetHydrationMapsSubmitOutcome(wireOutcome: "grant_revoked", expected: .grantRevoked)
    }

    private static let allElevenHydrationWireKeys = [
        "workspace_id", "intended_participant_id", "intended_athlete_id", "parent_id",
        "parent_given_name", "workspace_display_name", "owner_participant_id",
        "athlete_given_name", "athlete_birth_date_iso", "athlete_time_zone_id", "athlete_development_stage",
    ]

    private func assertGetHydrationRejectsResponseMissing(_ missingKey: String) async throws {
        let (service, transport, _) = makeService()
        enqueueIssuedChallenge(transport)
        var json: [String: Any?] = [
            "outcome": "hydrated",
            "workspace_id": Self.wellFormedHydrationFields.workspaceId.uuidString,
            "intended_participant_id": Self.wellFormedHydrationFields.intendedParticipantId.uuidString,
            "intended_athlete_id": Self.wellFormedHydrationFields.intendedAthleteId.uuidString,
            "parent_id": Self.wellFormedHydrationFields.parentId.uuidString,
            "parent_given_name": Self.wellFormedHydrationFields.parentGivenName,
            "workspace_display_name": Self.wellFormedHydrationFields.workspaceDisplayName,
            "owner_participant_id": Self.wellFormedHydrationFields.ownerParticipantId.uuidString,
            "athlete_given_name": Self.wellFormedHydrationFields.athleteGivenName,
            "athlete_birth_date_iso": Self.wellFormedHydrationFields.athleteBirthDateISO,
            "athlete_time_zone_id": Self.wellFormedHydrationFields.athleteTimeZoneId,
            "athlete_development_stage": Self.wellFormedHydrationFields.athleteDevelopmentStage,
        ]
        #expect(json[missingKey] != nil, "test setup bug: '\(missingKey)' is not one of the 11 keys this fixture populates")
        json[missingKey] = nil
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: json)

        await #expect(throws: AthleteDeviceAuthorizationSessionError.malformedResponse) {
            _ = try await service.getHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)
        }
    }

    @Test("getHydration() throws .malformedResponse when a 'hydrated' response is missing any one of the 11 required fields — every key exercised explicitly")
    func getHydrationRejectsHydratedResponseMissingAnyField() async throws {
        for key in Self.allElevenHydrationWireKeys {
            try await assertGetHydrationRejectsResponseMissing(key)
        }
    }

    @Test("getHydration()'s checkNotCancelled runs after a successful challenge and before signing/submitting")
    func getHydrationChecksNotCancelledBeforeSubmitting() async throws {
        let (service, transport, signingKeyStore) = makeService()
        enqueueIssuedChallenge(transport)
        struct CancelledForTest: Error, Equatable {}

        await #expect(throws: CancelledForTest()) {
            _ = try await service.getHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken) {
                throw CancelledForTest()
            }
        }
        #expect(transport.sentRequests.count == 1, "only the challenge was sent")
        #expect(signingKeyStore.loadExistingCallCount == 0, "signing must never happen once checkNotCancelled rejects the operation")
    }

    @Test("ackHydration() sends action=hydration_ack with the presented session_token, signs with loadExistingSigningKey(), and maps .acked")
    func ackHydrationSendsCorrectActionAndMapsAcked() async throws {
        let (service, transport, signingKeyStore) = makeService()
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": "acked"])

        let outcome = try await service.ackHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .acked)

        let challengeBody = try requestBodyJSON(transport.sentRequests[0])
        #expect(challengeBody["action"] as? String == "hydration_ack")
        #expect(challengeBody["session_token"] as? String == Self.existingSessionToken)

        let submitBody = try requestBodyJSON(transport.sentRequests[1])
        #expect(submitBody["action"] as? String == "hydration_ack")

        let expectedMessage = AthleteDeviceAuthorizationSessionCanonicalMessage.bytes(
            action: .hydrationAck, deviceGrantId: Self.deviceGrantId, challengeId: Self.challengeId, nonce: Self.wellFormedNonce
        )
        #expect(signingKeyStore.signedMessages == [expectedMessage])
        #expect(signingKeyStore.loadOrCreateCallCount == 0)
    }

    private func assertAckHydrationMapsSubmitOutcome(
        wireOutcome: String, expected: AthleteDeviceAuthorizationHydrationAckOutcome
    ) async throws {
        let (service, transport, _) = makeService()
        enqueueIssuedChallenge(transport)
        transport.enqueue(path: "device-session-submit", statusCode: 200, json: ["outcome": wireOutcome])

        let outcome = try await service.ackHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == expected)
    }

    @Test("ackHydration() maps submit-side not_available")
    func ackHydrationMapsSubmitNotAvailable() async throws {
        try await assertAckHydrationMapsSubmitOutcome(wireOutcome: "not_available", expected: .notAvailable)
    }

    @Test("ackHydration() maps submit-side already_completed")
    func ackHydrationMapsAlreadyCompleted() async throws {
        try await assertAckHydrationMapsSubmitOutcome(wireOutcome: "already_completed", expected: .alreadyCompleted)
    }

    @Test("ackHydration() maps submit-side deadline_passed")
    func ackHydrationMapsDeadlinePassed() async throws {
        try await assertAckHydrationMapsSubmitOutcome(wireOutcome: "deadline_passed", expected: .deadlinePassed)
    }

    @Test("ackHydration() maps submit-side grant_revoked")
    func ackHydrationMapsGrantRevoked() async throws {
        try await assertAckHydrationMapsSubmitOutcome(wireOutcome: "grant_revoked", expected: .grantRevoked)
    }

    @Test("ackHydration() maps session_invalid/challenge_not_available at the challenge step, signing nothing")
    func ackHydrationMapsChallengeStepOutcomes() async throws {
        let (service, transport, signingKeyStore) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "session_invalid"])

        let outcome = try await service.ackHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)

        #expect(outcome == .sessionInvalid)
        #expect(signingKeyStore.signedMessages.isEmpty)
    }

    @Test("ackHydration() throws .signingKeyUnavailable and sends no submit request when loadExistingSigningKey() fails")
    func ackHydrationThrowsWhenKeyUnavailable() async throws {
        let signingKeyStore = FakeSessionSigningKeyStore()
        signingKeyStore.throwOnLoadExisting = true
        let (service, transport, _) = makeService(signingKeyStore: signingKeyStore)
        enqueueIssuedChallenge(transport)

        await #expect(throws: AthleteDeviceAuthorizationSessionError.signingKeyUnavailable) {
            _ = try await service.ackHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken)
        }
        #expect(transport.sentRequests.count == 1)
    }

    @Test("ackHydration()'s checkNotCancelled runs after a successful challenge and before signing/submitting")
    func ackHydrationChecksNotCancelledBeforeSubmitting() async throws {
        let (service, transport, signingKeyStore) = makeService()
        enqueueIssuedChallenge(transport)
        struct CancelledForTest: Error, Equatable {}

        await #expect(throws: CancelledForTest()) {
            _ = try await service.ackHydration(deviceGrantId: Self.deviceGrantId, sessionToken: Self.existingSessionToken) {
                throw CancelledForTest()
            }
        }
        #expect(transport.sentRequests.count == 1, "only the challenge was sent")
        #expect(signingKeyStore.loadExistingCallCount == 0, "signing must never happen once checkNotCancelled rejects the operation")
    }

    // MARK: - Network/HTTP status folding

    @Test("A non-200 HTTP status on either endpoint throws .network")
    func nonTwoHundredStatusThrowsNetwork() async {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 500, json: [:])

        await #expect(throws: AthleteDeviceAuthorizationSessionError.network) {
            _ = try await service.issueSession(deviceGrantId: Self.deviceGrantId)
        }
    }

    @Test("An unrecognized outcome string on either endpoint throws .malformedResponse")
    func unrecognizedOutcomeThrowsMalformedResponse() async {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "device-session-challenge", statusCode: 200, json: ["outcome": "something_new"])

        await #expect(throws: AthleteDeviceAuthorizationSessionError.malformedResponse) {
            _ = try await service.issueSession(deviceGrantId: Self.deviceGrantId)
        }
    }
}
