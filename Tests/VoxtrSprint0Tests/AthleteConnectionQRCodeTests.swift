import Testing
import Foundation
@testable import VoxtrAppShell

// Athlete Connection QR-first V1: `AthleteConnectionQRCode.validate(_:)` is
// pure — no CloudKit I/O, no persistence — so it is fully unit-testable
// here. `AthleteConnectionScanCoordinator`'s own production adapter,
// `handleScannedText(_:transport:session:)` (real CloudKit I/O), remains
// untested here, matching this repository's established B1/B2
// XCTEST-SAFETY convention — but PR #84's follow-up added a generic,
// injectable-closure overload of the same name that IS fully unit-tested,
// in `AthleteConnectionScanCoordinatorTests.swift`.
@Suite("AthleteConnectionQRCode (Athlete Connection QR-first V1)")
struct AthleteConnectionQRCodeTests {

    @Test("A well-formed CKShare-shaped icloud.com share URL validates successfully and round-trips unchanged")
    func validCKShareURLValidates() {
        let raw = "https://www.icloud.com/share/0abcXYZ123"
        switch AthleteConnectionQRCode.validate(raw) {
        case .success(let url):
            #expect(url.absoluteString == raw)
        case .failure(let error):
            Issue.record("Expected success, got \(error)")
        }
    }

    @Test("A bare icloud.com host (no www subdomain) also validates")
    func bareIcloudHostValidates() {
        switch AthleteConnectionQRCode.validate("https://icloud.com/share/abc") {
        case .success:
            break
        case .failure(let error):
            Issue.record("Expected success, got \(error)")
        }
    }

    @Test("Leading/trailing whitespace or a trailing newline (common QR-scan artifacts) is trimmed before validation")
    func whitespaceIsTrimmed() {
        switch AthleteConnectionQRCode.validate("  https://www.icloud.com/share/abc \n") {
        case .success(let url):
            #expect(url.absoluteString == "https://www.icloud.com/share/abc")
        case .failure(let error):
            Issue.record("Expected success, got \(error)")
        }
    }

    @Test("Arbitrary non-URL scanned text is rejected with .notAURL, never handed to the acceptance pipeline")
    func arbitraryTextIsRejected() {
        #expect(AthleteConnectionQRCode.validate("not a url at all") == .failure(.notAURL))
    }

    @Test("Empty scanned text is rejected with .notAURL")
    func emptyTextIsRejected() {
        #expect(AthleteConnectionQRCode.validate("") == .failure(.notAURL))
    }

    @Test("A non-https scheme (e.g. http) is rejected with .unsupportedScheme — a real CKShare.url is always https")
    func nonHTTPSSchemeIsRejected() {
        #expect(AthleteConnectionQRCode.validate("http://www.icloud.com/share/abc") == .failure(.unsupportedScheme))
    }

    @Test("An arbitrary non-Vǫxtr https URL (unrelated host) is rejected with .unsupportedHost, not silently accepted")
    func unrelatedHostIsRejected() {
        #expect(AthleteConnectionQRCode.validate("https://example.com/totally-unrelated") == .failure(.unsupportedHost))
    }

    @Test("A QR code encoding an arbitrary web page (a plausible real-world 'wrong QR code' scan) is rejected, not treated as a Vǫxtr connection code")
    func arbitraryWebQRIsRejected() {
        #expect(AthleteConnectionQRCode.validate("https://www.example.com/some/product/page") == .failure(.unsupportedHost))
    }

    @Test("validate(_:) never extracts or manufactures business identity — it returns the URL exactly as scanned, including any query string, opaque and unparsed")
    func doesNotManufactureBusinessIdentity() {
        let raw = "https://www.icloud.com/share/abc?athleteId=00000000-0000-0000-0000-000000000001&name=Someone"
        switch AthleteConnectionQRCode.validate(raw) {
        case .success(let url):
            // The ENTIRE string round-trips unchanged — proof this
            // function has no code path that reads, strips, or acts on
            // any embedded query parameter as identity.
            #expect(url.absoluteString == raw)
        case .failure(let error):
            Issue.record("Expected success, got \(error)")
        }
    }

    @Test("validate(_:) is stateless — a failed attempt never affects a subsequent attempt, so a recoverable scan failure always permits an independent retry")
    func statelessAcrossRepeatedCalls() {
        let firstResult = AthleteConnectionQRCode.validate("garbage")
        let secondResult = AthleteConnectionQRCode.validate("https://www.icloud.com/share/abc")
        let thirdResult = AthleteConnectionQRCode.validate("garbage")

        #expect(firstResult == .failure(.notAURL))
        if case .success = secondResult {} else {
            Issue.record("Expected the second, valid attempt to succeed independently of the first failure")
        }
        #expect(thirdResult == .failure(.notAURL))
    }
}
