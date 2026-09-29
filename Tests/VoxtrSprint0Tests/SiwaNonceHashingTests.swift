import Testing
import Foundation
@testable import VoxtrParentAuthentication

// Athlete Connection V1 (Slice D) — the fixed contract test vector from
// Docs/Architecture/AthleteConnectionV1-ParentAuthenticationContract.md
// §1.2/§1.3: SHA-256 over the UTF-8 bytes of the exact base64url nonce
// string (never raw decoded bytes), rendered as lowercase hex.
// `SiwaNonceHashing` is `internal`, so this test requires `@testable
// import VoxtrParentAuthentication`.
@Suite("SiwaNonceHashing (Athlete Connection V1)")
struct SiwaNonceHashingTests {

    @Test("The contract's fixed nonce test vector hashes to the exact expected lowercase hex string")
    func fixedContractVectorMatches() {
        let rawNonce = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
        let expected = "eb9f16800c9029ffca85695763d23c3ace71011cf40e9354acd810205e250f87"

        let hashed = SiwaNonceHashing.hashedNonceHex(forRawNonce: rawNonce)

        #expect(hashed == expected)
    }

    @Test("The result is always exactly 64 lowercase hex characters, never uppercase or padded")
    func resultIsLowercaseHex64Characters() {
        let hashed = SiwaNonceHashing.hashedNonceHex(forRawNonce: "some-other-nonce-string")

        #expect(hashed.count == 64)
        #expect(hashed == hashed.lowercased())
        #expect(hashed.allSatisfy { $0.isHexDigit })
    }

    @Test("Hashing is deterministic — the same input always produces the same output")
    func hashingIsDeterministic() {
        let rawNonce = "deterministic-check-nonce"

        let first = SiwaNonceHashing.hashedNonceHex(forRawNonce: rawNonce)
        let second = SiwaNonceHashing.hashedNonceHex(forRawNonce: rawNonce)

        #expect(first == second)
    }

    @Test("Different nonce strings hash to different results")
    func differentInputsHashDifferently() {
        let first = SiwaNonceHashing.hashedNonceHex(forRawNonce: "nonce-a")
        let second = SiwaNonceHashing.hashedNonceHex(forRawNonce: "nonce-b")

        #expect(first != second)
    }
}
