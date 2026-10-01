import Testing
import Foundation
@testable import VoxtrAppShell

// Athlete Connection V1 (backend device authorization):
// `AthleteDeviceAuthorizationQRPayload.validate(_:)`/`encode(invitationId:)`
// are pure — no network I/O — so fully unit-testable here, mirroring
// `AthleteConnectionQRCodeTests`'s own established pattern for the
// sibling, unmodified CKShare payload type. Validation is strict by
// design (review round 2): explicit version, no duplicate/unknown query
// items, no unexpected userinfo/port/path/fragment.
@Suite("AthleteDeviceAuthorizationQRPayload (Athlete Connection V1, backend device authorization)")
struct AthleteDeviceAuthorizationQRPayloadTests {

    private static let invitationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test("encode(invitationId:) round-trips through validate(_:) to the exact same invitation id")
    func encodeThenValidateRoundTrips() {
        let url = AthleteDeviceAuthorizationQRPayload.encode(invitationId: Self.invitationId)

        switch AthleteDeviceAuthorizationQRPayload.validate(url.absoluteString) {
        case .success(let decoded):
            #expect(decoded == Self.invitationId)
        case .failure(let error):
            Issue.record("Expected success, got \(error)")
        }
    }

    @Test("encode(invitationId:) always lowercases the invitation id and includes the current version")
    func encodeLowercasesInvitationIdAndIncludesVersion() {
        let mixedCase = UUID(uuidString: "AABBCCDD-EEFF-0011-2233-445566778899")!
        let url = AthleteDeviceAuthorizationQRPayload.encode(invitationId: mixedCase)
        #expect(url.absoluteString.contains(mixedCase.uuidString.lowercased()))
        #expect(!url.absoluteString.contains(mixedCase.uuidString))
        #expect(url.absoluteString.contains("v=1"))
    }

    @Test("Leading/trailing whitespace (a common QR-scan artifact) is trimmed before validation")
    func whitespaceIsTrimmed() {
        let raw = "  voxtr-connect://invite?v=1&invitation_id=\(Self.invitationId.uuidString) \n"
        switch AthleteDeviceAuthorizationQRPayload.validate(raw) {
        case .success(let decoded):
            #expect(decoded == Self.invitationId)
        case .failure(let error):
            Issue.record("Expected success, got \(error)")
        }
    }

    @Test("Arbitrary non-URL scanned text is rejected with .notAURL")
    func arbitraryTextIsRejected() {
        #expect(AthleteDeviceAuthorizationQRPayload.validate("not a url at all") == .failure(.notAURL))
    }

    @Test("A well-formed CKShare QR (the existing, unmodified sibling flow's own payload) is rejected with .unsupportedScheme — the two payload shapes never collide")
    func existingCKShareQRIsRejected() {
        let outcome = AthleteDeviceAuthorizationQRPayload.validate("https://www.icloud.com/share/abc")
        #expect(outcome == .failure(.unsupportedScheme))
    }

    @Test("The correct scheme but wrong host is rejected with .unsupportedHost")
    func wrongHostIsRejected() {
        let outcome = AthleteDeviceAuthorizationQRPayload.validate("voxtr-connect://wrong-host?v=1&invitation_id=\(Self.invitationId.uuidString)")
        #expect(outcome == .failure(.unsupportedHost))
    }

    @Test("A userinfo, port, non-empty path, or fragment is rejected with .unexpectedURLStructure — the real payload never carries any of these")
    func unexpectedURLStructureIsRejected() {
        let candidates = [
            "voxtr-connect://user:pass@invite?v=1&invitation_id=\(Self.invitationId.uuidString)",
            "voxtr-connect://invite:8080?v=1&invitation_id=\(Self.invitationId.uuidString)",
            "voxtr-connect://invite/extra?v=1&invitation_id=\(Self.invitationId.uuidString)",
            "voxtr-connect://invite?v=1&invitation_id=\(Self.invitationId.uuidString)#fragment",
        ]
        for candidate in candidates {
            #expect(AthleteDeviceAuthorizationQRPayload.validate(candidate) == .failure(.unexpectedURLStructure), "candidate: \(candidate)")
        }
    }

    @Test("No query items at all is rejected with .missingQueryItems")
    func missingQueryItemsIsRejected() {
        #expect(AthleteDeviceAuthorizationQRPayload.validate("voxtr-connect://invite") == .failure(.missingQueryItems))
    }

    @Test("An unrecognized query item name is rejected with .unknownQueryItem")
    func unknownQueryItemIsRejected() {
        let outcome = AthleteDeviceAuthorizationQRPayload.validate(
            "voxtr-connect://invite?v=1&invitation_id=\(Self.invitationId.uuidString)&extra=1"
        )
        #expect(outcome == .failure(.unknownQueryItem))
    }

    @Test("A duplicate query item (even with the same value) is rejected with .duplicateQueryItem")
    func duplicateQueryItemIsRejected() {
        let outcome = AthleteDeviceAuthorizationQRPayload.validate(
            "voxtr-connect://invite?v=1&v=1&invitation_id=\(Self.invitationId.uuidString)"
        )
        #expect(outcome == .failure(.duplicateQueryItem))
    }

    @Test("A missing version query item is rejected with .missingVersion")
    func missingVersionIsRejected() {
        let outcome = AthleteDeviceAuthorizationQRPayload.validate("voxtr-connect://invite?invitation_id=\(Self.invitationId.uuidString)")
        #expect(outcome == .failure(.missingVersion))
    }

    @Test("An unsupported version is rejected with .unsupportedVersion, never silently accepted as the current version")
    func unsupportedVersionIsRejected() {
        let outcome = AthleteDeviceAuthorizationQRPayload.validate(
            "voxtr-connect://invite?v=2&invitation_id=\(Self.invitationId.uuidString)"
        )
        #expect(outcome == .failure(.unsupportedVersion))
    }

    @Test("A missing invitation_id query item is rejected with .missingInvitationId")
    func missingInvitationIdIsRejected() {
        let outcome = AthleteDeviceAuthorizationQRPayload.validate("voxtr-connect://invite?v=1")
        #expect(outcome == .failure(.missingInvitationId))
    }

    @Test("A malformed (non-UUID) invitation_id value is rejected with .malformedInvitationId")
    func malformedInvitationIdIsRejected() {
        let outcome = AthleteDeviceAuthorizationQRPayload.validate("voxtr-connect://invite?v=1&invitation_id=not-a-uuid")
        #expect(outcome == .failure(.malformedInvitationId))
    }

    @Test("validate(_:) never exposes a URL or host — only the decoded invitation id — so nothing downstream can derive a backend destination from scanned input")
    func validateNeverExposesURLStructure() {
        // Structural: `Result<UUID, ValidationError>` is the ENTIRE
        // success type — there is no way for a caller of this function
        // to reach anything beyond the UUID even if it tried. This test
        // documents that invariant at the call site.
        let outcome = AthleteDeviceAuthorizationQRPayload.validate(
            AthleteDeviceAuthorizationQRPayload.encode(invitationId: Self.invitationId).absoluteString
        )
        switch outcome {
        case .success(let decoded):
            #expect(decoded == Self.invitationId)
        case .failure(let error):
            Issue.record("Expected success, got \(error)")
        }
    }

    @Test("validate(_:) is stateless — a failed attempt never affects a subsequent independent attempt")
    func statelessAcrossRepeatedCalls() {
        let first = AthleteDeviceAuthorizationQRPayload.validate("garbage")
        let second = AthleteDeviceAuthorizationQRPayload.validate(
            AthleteDeviceAuthorizationQRPayload.encode(invitationId: Self.invitationId).absoluteString
        )
        let third = AthleteDeviceAuthorizationQRPayload.validate("garbage")

        #expect(first == .failure(.notAURL))
        if case .success(let decoded) = second {
            #expect(decoded == Self.invitationId)
        } else {
            Issue.record("Expected the second, valid attempt to succeed independently of the first failure")
        }
        #expect(third == .failure(.notAURL))
    }
}
