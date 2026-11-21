import Testing
import Foundation
@testable import VoxtrAppShell

// T1 (issue #122): every case below calls
// `HostedBackendConfigurationResolver.resolve(rawBaseURL:rawAnonKey:)`
// directly with deliberately injected fake strings — never
// `Bundle.main`/`resolveFromMainBundle()` — so this suite needs no live
// credentials, no real app bundle, and no Xcode/macOS runtime beyond
// plain Foundation `URL`/`String`, matching this task's own "Simulator/
// CI tests must still run without live credentials" requirement.
@Suite("HostedBackendConfigurationResolver (T1, issue #122)")
struct HostedBackendConfigurationResolverTests {

    private static let validURL = "https://pxbjctflgcxwjsaablkf.supabase.co/functions/v1"
    // Three non-empty, base64url-shaped, dot-separated segments — the
    // same JWT SHAPE the three Athlete-facing `verify_jwt=true`
    // functions require (issue #122 §3). Not a real/signed token of any
    // kind; this suite only validates shape, never signature or claims.
    private static let validAnonKey = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.c2lnbmF0dXJlLXBsYWNlaG9sZGVy"

    // MARK: - Success

    @Test("A well-formed https base URL and legacy-JWT-shaped key both resolve")
    func validInputsResolve() throws {
        let result = HostedBackendConfigurationResolver.resolve(rawBaseURL: Self.validURL, rawAnonKey: Self.validAnonKey)
        let values = try result.get()
        #expect(values.baseURL == URL(string: Self.validURL))
        #expect(values.anonKey == Self.validAnonKey)
    }

    @Test("Surrounding whitespace/newlines on otherwise-valid inputs are trimmed, not rejected")
    func surroundingWhitespaceIsTrimmed() throws {
        let result = HostedBackendConfigurationResolver.resolve(
            rawBaseURL: "  \(Self.validURL)\n",
            rawAnonKey: "\n\(Self.validAnonKey)  "
        )
        let values = try result.get()
        #expect(values.baseURL == URL(string: Self.validURL))
        #expect(values.anonKey == Self.validAnonKey)
    }

    // MARK: - Base URL failures

    @Test("A missing or empty base URL fails closed as missingBaseURL", arguments: [nil, "", "   "] as [String?])
    func missingBaseURLFailsClosed(raw: String?) {
        #expect(throws: HostedBackendConfigurationError.missingBaseURL) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: raw, rawAnonKey: Self.validAnonKey).get()
        }
    }

    @Test(
        "A plain-http, localhost, or loopback base URL fails closed as insecureBaseURL",
        arguments: [
            "http://pxbjctflgcxwjsaablkf.supabase.co/functions/v1",
            "https://localhost/functions/v1",
            "https://127.0.0.1/functions/v1",
            "https://LOCALHOST/functions/v1",
        ]
    )
    func insecureBaseURLFailsClosed(raw: String) {
        #expect(throws: HostedBackendConfigurationError.insecureBaseURL) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: raw, rawAnonKey: Self.validAnonKey).get()
        }
    }

    @Test(
        "A malformed, wrong-suffix, or trailing-slash base URL fails closed as malformedBaseURL",
        arguments: [
            "not a url",
            "https://pxbjctflgcxwjsaablkf.supabase.co/functions/v1/",
            "https://pxbjctflgcxwjsaablkf.supabase.co/wrong-path",
            "https://pxbjctflgcxwjsaablkf.supabase.co",
        ]
    )
    func malformedBaseURLFailsClosed(raw: String) {
        #expect(throws: HostedBackendConfigurationError.malformedBaseURL) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: raw, rawAnonKey: Self.validAnonKey).get()
        }
    }

    // ChatGPT review (PR #123, R1): the original rule accepted ANY
    // well-formed, non-loopback https host whose path ended in
    // `/functions/v1` — including an attacker-controlled domain, a
    // lookalike suffix host, or a different, otherwise-valid Supabase
    // project that simply isn't the one T1 approved. These cases prove
    // the resolver now pins to that one approved host instead.
    @Test(
        "A well-formed, non-loopback https URL whose host is not the approved T1 project fails closed as untrustedBaseURLHost",
        arguments: [
            "https://attacker.example/functions/v1",
            "https://pxbjctflgcxwjsaablkf.supabase.co.evil.example/functions/v1",
            "https://otherproject123456.supabase.co/functions/v1",
        ]
    )
    func untrustedBaseURLHostFailsClosed(raw: String) {
        #expect(throws: HostedBackendConfigurationError.untrustedBaseURLHost) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: raw, rawAnonKey: Self.validAnonKey).get()
        }
    }

    // ChatGPT review (PR #123, R1): the original `hasSuffix`-only path
    // check would have accepted an unreviewed path prefix
    // (`/extra/functions/v1` ends with `/functions/v1` too); these
    // prove the approved-host URL is now rejected for ANY additional
    // component — path prefix, query, fragment, userinfo, or port —
    // not just a wrong host.
    @Test(
        "An approved-host https URL carrying a path prefix, query, fragment, userinfo, or port fails closed as malformedBaseURL",
        arguments: [
            "https://pxbjctflgcxwjsaablkf.supabase.co/extra/functions/v1",
            "https://pxbjctflgcxwjsaablkf.supabase.co/functions/v1?foo=bar",
            "https://pxbjctflgcxwjsaablkf.supabase.co/functions/v1#fragment",
            "https://user:pass@pxbjctflgcxwjsaablkf.supabase.co/functions/v1",
            "https://pxbjctflgcxwjsaablkf.supabase.co:8443/functions/v1",
        ]
    )
    func unexpectedURLComponentsFailClosedAsMalformed(raw: String) {
        #expect(throws: HostedBackendConfigurationError.malformedBaseURL) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: raw, rawAnonKey: Self.validAnonKey).get()
        }
    }

    // MARK: - Anon key failures

    @Test("A missing or empty gateway key fails closed as missingAnonKey", arguments: [nil, "", "   "] as [String?])
    func missingAnonKeyFailsClosed(raw: String?) {
        #expect(throws: HostedBackendConfigurationError.missingAnonKey) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: Self.validURL, rawAnonKey: raw).get()
        }
    }

    @Test("The committed development placeholder key fails closed as placeholderAnonKey")
    func placeholderAnonKeyFailsClosed() {
        #expect(throws: HostedBackendConfigurationError.placeholderAnonKey) {
            try HostedBackendConfigurationResolver.resolve(
                rawBaseURL: Self.validURL,
                rawAnonKey: "REPLACE_WITH_SUPABASE_ANON_KEY"
            ).get()
        }
    }

    @Test(
        "A modern sb_publishable_/sb_secret_-shaped or otherwise non-JWT key fails closed as malformedAnonKeyFormat",
        arguments: [
            "sb_publishable_abcdefghijklmnopqrstuvwxyz0123456789",
            "sb_secret_abcdefghijklmnopqrstuvwxyz0123456789",
            "only-one-segment",
            "two.segments",
            "four.dot.separated.segments",
            "abc..xyz",
            "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.sig/with/slash",
        ]
    )
    func malformedAnonKeyFormatFailsClosed(raw: String) {
        #expect(throws: HostedBackendConfigurationError.malformedAnonKeyFormat) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: Self.validURL, rawAnonKey: raw).get()
        }
    }

    // MARK: - Precedence (base URL validated first)

    @Test("When both inputs are invalid, the base URL failure is reported first")
    func baseURLFailureTakesPrecedenceOverAnonKeyFailure() {
        #expect(throws: HostedBackendConfigurationError.missingBaseURL) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: nil, rawAnonKey: nil).get()
        }
    }

    // MARK: - Error messages never include raw input

    @Test("Every closed error case's description is fixed, reviewed text — never the raw input string")
    func errorDescriptionsNeverEchoRawInput() {
        let secretLookingInput = "sb_secret_should-never-appear-in-any-message"
        let allCases: [HostedBackendConfigurationError] = [
            .missingBaseURL, .malformedBaseURL, .insecureBaseURL, .untrustedBaseURLHost,
            .missingAnonKey, .placeholderAnonKey, .malformedAnonKeyFormat,
        ]
        for errorCase in allCases {
            #expect(!(errorCase.errorDescription ?? "").contains(secretLookingInput))
        }
        #expect(throws: HostedBackendConfigurationError.malformedAnonKeyFormat) {
            try HostedBackendConfigurationResolver.resolve(rawBaseURL: Self.validURL, rawAnonKey: secretLookingInput).get()
        }
    }
}
