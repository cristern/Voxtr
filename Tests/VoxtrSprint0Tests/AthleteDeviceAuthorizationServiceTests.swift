import Testing
import Foundation
import VoxtrParentAuthentication
@testable import VoxtrAppShell

// Athlete Connection V1 (backend device authorization). Exercises
// `AthleteDeviceAuthorizationService`'s orchestration logic against a
// fake transport (no live network) and a fake signing-key store (no real
// Keychain/CryptoKit key generation) — matching
// `ParentAuthenticationServiceTests.swift`'s own established fake-
// transport pattern for the sibling package. Wire JSON uses snake_case
// keys deliberately, matching the actual merged
// `cristern/Voxtr-Backend` handler shapes this service decodes/encodes
// against.

private final class FakeDeviceAuthorizationTransport: ParentAuthenticationTransport, @unchecked Sendable {
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
/// — so these tests can assert exactly what gets sent on the wire
/// without depending on a real generated key's own (correctly random,
/// hence unpredictable) bytes.
private final class FakeSigningKeyStore: AthleteDeviceSigningKeyStoring, @unchecked Sendable {
    let fixedPublicKey = Data([0x04] + Array(repeating: 0xAB, count: 64))
    let fixedSignature = Data(Array(repeating: 0xCD, count: 64))
    private(set) var signedMessages: [Data] = []
    var throwOnLoad = false

    func loadOrCreateSigningKey() throws -> AthleteDeviceSigningKey {
        if throwOnLoad {
            throw AthleteDeviceSigningKeyStoreError.keyReconstitutionFailed
        }
        return AthleteDeviceSigningKey(fixedPublicKey: fixedPublicKey, fixedSignature: fixedSignature) { [weak self] message in
            self?.signedMessages.append(message)
        }
    }
}

@Suite("AthleteDeviceAuthorizationService (Athlete Connection V1, backend device authorization)")
@MainActor
struct AthleteDeviceAuthorizationServiceTests {

    private static let baseURL = URL(string: "https://device-auth.invalid/functions/v1")!
    private static let invitationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let requestId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let challengeId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeService(
        transport: FakeDeviceAuthorizationTransport = FakeDeviceAuthorizationTransport(),
        signingKeyStore: FakeSigningKeyStore = FakeSigningKeyStore()
    ) -> (AthleteDeviceAuthorizationService, FakeDeviceAuthorizationTransport, FakeSigningKeyStore) {
        let service = AthleteDeviceAuthorizationService(
            configuration: ParentAuthenticationConfiguration(baseURL: Self.baseURL),
            transport: transport,
            signingKeyStore: signingKeyStore
        )
        return (service, transport, signingKeyStore)
    }

    private func requestBodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Canonical message (exact wire-format parity with
    // _shared/canonicalMessage.ts)

    @Test("canonicalMessageBytes(...) produces exactly five \\n-terminated lines, UUIDs lowercased, no other separators")
    func canonicalMessageBytesMatchesExactFormat() {
        let nonce = Data([0x01, 0x02, 0x03, 0x04])
        let bytes = AthleteDeviceAuthorizationService.canonicalMessageBytes(
            challengeId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            requestId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            invitationId: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!,
            nonce: nonce
        )
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(text == """
        voxtr-athlete-connection-claim-v1
        challenge_id=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        request_id=11111111-2222-3333-4444-555555555555
        invitation_id=66666666-7777-8888-9999-aaaaaaaaaaaa
        nonce=AQIDBA

        """)
    }

    @Test("base64UrlEncode/base64UrlDecode round-trip arbitrary bytes, and never emit '+', '/', or '=' (RFC 4648 §5)")
    func base64UrlRoundTrips() {
        let original = Data([0x00, 0xFF, 0x10, 0xAB, 0xCD, 0xEF, 0x01, 0x02, 0x03])
        let encoded = AthleteDeviceAuthorizationService.base64UrlEncode(original)

        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(AthleteDeviceAuthorizationService.base64UrlDecode(encoded) == original)
    }

    // MARK: - connection-request-submit

    @Test("submitConnectionRequest() sends the invitation id and the base64url-encoded x963 public key, and maps .submitted")
    func submitConnectionRequestSendsPublicKeyAndMapsSubmitted() async throws {
        let (service, transport, signingKeyStore) = makeService()
        transport.enqueue(path: "connection-request-submit", statusCode: 200, json: [
            "outcome": "submitted",
            "connection_request_id": Self.requestId.uuidString,
            "display_code": "A1B2C3",
        ])

        let outcome = try await service.submitConnectionRequest(invitationId: Self.invitationId)

        #expect(outcome == .submitted(connectionRequestId: Self.requestId, displayCode: "A1B2C3"))
        let body = try requestBodyJSON(transport.sentRequests[0])
        #expect(body["invitation_id"] as? String == Self.invitationId.uuidString)
        #expect(body["device_public_key"] as? String == AthleteDeviceAuthorizationService.base64UrlEncode(signingKeyStore.fixedPublicKey))
    }

    @Test("submitConnectionRequest() maps every documented non-success outcome")
    func submitConnectionRequestMapsAllOutcomes() async throws {
        let cases: [(wire: String, expected: ConnectionRequestSubmissionOutcome)] = [
            ("invitation_not_available", .invitationNotAvailable),
            ("invalid_device_key", .invalidDeviceKey),
            ("too_many_requests", .tooManyRequests),
            ("inconsistent_state", .inconsistentState),
        ]
        for testCase in cases {
            let (service, transport, _) = makeService()
            transport.enqueue(path: "connection-request-submit", statusCode: 200, json: ["outcome": testCase.wire])

            let outcome = try await service.submitConnectionRequest(invitationId: Self.invitationId)

            #expect(outcome == testCase.expected, "wire outcome: \(testCase.wire)")
        }
    }

    @Test("submitConnectionRequest() throws .signingKeyUnavailable, sending no request, when the key store fails")
    func submitConnectionRequestThrowsWhenKeyUnavailable() async {
        let signingKeyStore = FakeSigningKeyStore()
        signingKeyStore.throwOnLoad = true
        let (service, transport, _) = makeService(signingKeyStore: signingKeyStore)

        await #expect(throws: AthleteDeviceAuthorizationError.signingKeyUnavailable) {
            try await service.submitConnectionRequest(invitationId: Self.invitationId)
        }
        #expect(transport.sentRequests.isEmpty)
    }

    // MARK: - claim-challenge

    @Test("requestClaimChallenge() maps .issued, decoding the base64url nonce back to raw bytes")
    func requestClaimChallengeMapsIssued() async throws {
        let (service, transport, _) = makeService()
        let nonceBytes = Data([0xAA, 0xBB, 0xCC])
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: [
            "outcome": "issued",
            "challenge_id": Self.challengeId.uuidString,
            "nonce": AthleteDeviceAuthorizationService.base64UrlEncode(nonceBytes),
            "expires_at": "2026-10-01T00:01:00Z",
        ])

        let outcome = try await service.requestClaimChallenge(connectionRequestId: Self.requestId)

        guard case .issued(let challengeId, let nonce, _) = outcome else {
            Issue.record("expected .issued, got \(outcome)")
            return
        }
        #expect(challengeId == Self.challengeId)
        #expect(nonce == nonceBytes)
    }

    @Test("requestClaimChallenge() maps the anti-enumeration .requestNotAvailable fold")
    func requestClaimChallengeMapsRequestNotAvailable() async throws {
        let (service, transport, _) = makeService()
        transport.enqueue(path: "claim-challenge", statusCode: 200, json: ["outcome": "request_not_available"])

        let outcome = try await service.requestClaimChallenge(connectionRequestId: Self.requestId)

        #expect(outcome == .requestNotAvailable)
    }

    // MARK: - claim-submit

    @Test("submitClaim() signs the exact canonical message and sends the base64url-encoded signature")
    func submitClaimSignsCanonicalMessageAndSendsSignature() async throws {
        let (service, transport, signingKeyStore) = makeService()
        let nonce = Data([0x01, 0x02, 0x03])
        transport.enqueue(path: "claim-submit", statusCode: 200, json: [
            "outcome": "granted",
            "grant_id": "44444444-4444-4444-4444-444444444444",
            "recovery_deadline": "2026-10-02T00:00:00Z",
        ])

        let outcome = try await service.submitClaim(
            invitationId: Self.invitationId,
            connectionRequestId: Self.requestId,
            challengeId: Self.challengeId,
            nonce: nonce
        )

        #expect(outcome == .granted(
            grantId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            recoveryDeadline: ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z")!
        ))
        let expectedMessage = AthleteDeviceAuthorizationService.canonicalMessageBytes(
            challengeId: Self.challengeId,
            requestId: Self.requestId,
            invitationId: Self.invitationId,
            nonce: nonce
        )
        #expect(signingKeyStore.signedMessages == [expectedMessage])
        let body = try requestBodyJSON(transport.sentRequests[0])
        #expect(body["signature"] as? String == AthleteDeviceAuthorizationService.base64UrlEncode(signingKeyStore.fixedSignature))
    }

    @Test("submitClaim() maps every documented claim_device_grant outcome plus the anti-enumeration challenge_invalid fold")
    func submitClaimMapsAllOutcomes() async throws {
        let cases: [(wire: [String: Any?], expected: ClaimOutcome)] = [
            (["outcome": "already_granted", "grant_id": "44444444-4444-4444-4444-444444444444", "recovery_deadline": "2026-10-02T00:00:00Z"],
             .alreadyGranted(grantId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, recoveryDeadline: ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z")!)),
            (["outcome": "invitation_not_found"], .invitationNotFound),
            (["outcome": "request_not_found"], .requestNotFound),
            (["outcome": "request_not_approved"], .requestNotApproved),
            (["outcome": "invitation_expired"], .invitationExpired),
            (["outcome": "invitation_claimed_by_other_request"], .invitationClaimedByOtherRequest),
            (["outcome": "grant_revoked"], .grantRevoked),
            (["outcome": "recovery_window_expired"], .recoveryWindowExpired),
            (["outcome": "inconsistent_state"], .inconsistentState),
            (["outcome": "challenge_invalid"], .challengeInvalid),
        ]

        for testCase in cases {
            let (service, transport, _) = makeService()
            transport.enqueue(path: "claim-submit", statusCode: 200, json: testCase.wire)

            let outcome = try await service.submitClaim(
                invitationId: Self.invitationId,
                connectionRequestId: Self.requestId,
                challengeId: Self.challengeId,
                nonce: Data([0x01])
            )

            #expect(outcome == testCase.expected, "wire outcome: \(testCase.wire["outcome"] ?? "?")")
        }
    }
}
