import Testing
import CryptoKit
import Foundation
@testable import VoxtrAppShell

// Athlete Connection V1 (backend device authorization, review round 2).
//
// `AthleteDeviceSigningKeyStoreTests` proves CryptoKit sign+self-verify
// round-trips — a useful self-test, but NOT Swift<->Deno interoperability:
// CryptoKit verifying its own signature proves nothing about whether the
// backend's own, unmodified canonical-message builder and P-256 verifier
// would accept the SAME bytes.
//
// This file closes that gap with a FIXED fixture, generated and
// independently confirmed against the REAL, UNMODIFIED
// `cristern/Voxtr-Backend` code (`_shared/canonicalMessage.ts`,
// `_shared/p256.ts`, `_shared/base64url.ts`) — not assumed, not
// re-derived from documentation. No backend repository change was made
// or is needed: the generation script below ran as a scratch file
// against the backend's own checked-out `develop` (HEAD
// 77a47a52f19e68c4518ddf6e1970577f9fb52a38) and was deleted immediately
// after, never committed there.
//
// REPRODUCIBLE ARTIFACT — the exact script that produced the fixture
// below (run with `deno run <path>.ts` from the backend repo root):
//
//   import { buildCanonicalMessageBytes } from "../../supabase/functions/_shared/canonicalMessage.ts";
//   import { verifyP256Signature } from "../../supabase/functions/_shared/p256.ts";
//   import { encodeBase64Url } from "../../supabase/functions/_shared/base64url.ts";
//
//   const challengeId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
//   const requestId = "11111111-2222-3333-4444-555555555555";
//   const invitationId = "66666666-7777-8888-9999-aaaaaaaaaaaa";
//   const nonce = new Uint8Array([
//     0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
//     16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
//   ]);
//   const message = buildCanonicalMessageBytes({ challengeId, requestId, invitationId, nonce });
//   const keyPair = await crypto.subtle.generateKey(
//     { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
//   ) as CryptoKeyPair;
//   const publicKeyBytes = new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey));
//   const signatureBytes = new Uint8Array(
//     await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keyPair.privateKey, message.slice()),
//   );
//   const verifyResult = await verifyP256Signature(publicKeyBytes, signatureBytes, message);
//   // ... print challengeId/requestId/invitationId/nonce/publicKeyBytes/
//   // signatureBytes/verifyResult as hex — see the literal values below.
//
// EXACT OUTPUT CAPTURED (Deno 2.9.6, the same version
// `_shared/p256.ts`'s own header comment cites as empirically verified
// against):
//
//   "messageUtf8": "voxtr-athlete-connection-claim-v1\nchallenge_id=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nrequest_id=11111111-2222-3333-4444-555555555555\ninvitation_id=66666666-7777-8888-9999-aaaaaaaaaaaa\nnonce=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8\n",
//   "publicKeyHex": "040db37c6825bffb2f714258e64cf03e0c3690dacfd30af72cf223eb242c36744f72eadf58d8d5bfbb776bac2d941af65efd5fc6a59835cc1b63afcaa4b999f23a",
//   "publicKeyLength": 65,
//   "signatureHex": "8ac7f1fb5d1a67fd778459356a19d5d09d023b25b315d155bbb82a44676cddbe85089277fb900af819247c9bcf5455a8bc0a2733eda971e35935aa04b07c84b7",
//   "signatureLength": 64,
//   "backendVerifyResult": { "ok": true }
//
// The `backendVerifyResult: { ok: true }` line is the actual, observed
// output of the backend's own unmodified `verifyP256Signature` accepting
// exactly these bytes — not an assumption. This test's own job is to
// confirm CryptoKit, working ONLY from the same public key/message/
// signature bytes (never from the private key, which never left Deno),
// reaches the SAME "valid" conclusion.
//
// HONEST SCOPE: this proves the WIRE FORMAT and VERIFICATION LOGIC are
// interoperable between Swift CryptoKit and the real backend Deno Web
// Crypto implementation, for this one fixed message/key/signature
// triple. It does NOT exercise a physical Secure Enclave key (CryptoKit
// `SecureEnclave.P256.Signing.PrivateKey` cannot be constructed from
// arbitrary bytes — by design, its key material never leaves the
// enclave) and does NOT exercise a real hosted network round trip
// against a deployed Supabase project. Both remain unverified until
// physical-device TestFlight testing.
@Suite("Athlete Connection V1 cross-implementation P-256 fixture (review round 2)")
struct AthleteConnectionCrossImplementationFixtureTests {

    private static let challengeId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let requestId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let invitationId = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
    private static let nonce = Data((0..<32).map { UInt8($0) })
    private static let publicKeyHex = "040db37c6825bffb2f714258e64cf03e0c3690dacfd30af72cf223eb242c36744f72eadf58d8d5bfbb776bac2d941af65efd5fc6a59835cc1b63afcaa4b999f23a"
    private static let signatureHex = "8ac7f1fb5d1a67fd778459356a19d5d09d023b25b315d155bbb82a44676cddbe85089277fb900af819247c9bcf5455a8bc0a2733eda971e35935aa04b07c84b7"

    private static func data(fromHex hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test("AthleteDeviceAuthorizationService.canonicalMessageBytes produces EXACTLY the UTF-8 bytes the backend's own buildCanonicalMessageBytes produced for the same fields")
    func canonicalMessageMatchesBackendOutputExactly() {
        let bytes = AthleteDeviceAuthorizationService.canonicalMessageBytes(
            challengeId: Self.challengeId,
            requestId: Self.requestId,
            invitationId: Self.invitationId,
            nonce: Self.nonce
        )
        let text = String(decoding: bytes, as: UTF8.self)
        let expected = """
        voxtr-athlete-connection-claim-v1
        challenge_id=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        request_id=11111111-2222-3333-4444-555555555555
        invitation_id=66666666-7777-8888-9999-aaaaaaaaaaaa
        nonce=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8

        """
        #expect(text == expected)
    }

    @Test("A real P-256 public key + signature pair, generated and confirmed valid by the backend's OWN unmodified verifier, also verifies with CryptoKit against the SAME canonical message bytes — the actual Swift<->Deno interop proof")
    func cryptoKitAcceptsTheSameFixtureTheBackendAccepted() throws {
        let publicKeyBytes = Self.data(fromHex: Self.publicKeyHex)
        let signatureBytes = Self.data(fromHex: Self.signatureHex)
        #expect(publicKeyBytes.count == 65)
        #expect(publicKeyBytes.first == 0x04)
        #expect(signatureBytes.count == 64)

        let message = AthleteDeviceAuthorizationService.canonicalMessageBytes(
            challengeId: Self.challengeId,
            requestId: Self.requestId,
            invitationId: Self.invitationId,
            nonce: Self.nonce
        )

        let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyBytes)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)

        #expect(publicKey.isValidSignature(signature, for: message))
    }

    @Test("The same signature does NOT verify against a differently-built message — proves this is a genuine signature check, not a tautology")
    func fixtureSignatureFailsAgainstAWrongMessage() throws {
        let publicKeyBytes = Self.data(fromHex: Self.publicKeyHex)
        let signatureBytes = Self.data(fromHex: Self.signatureHex)
        let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyBytes)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)

        let wrongMessage = AthleteDeviceAuthorizationService.canonicalMessageBytes(
            challengeId: UUID(),
            requestId: Self.requestId,
            invitationId: Self.invitationId,
            nonce: Self.nonce
        )

        #expect(!publicKey.isValidSignature(signature, for: wrongMessage))
    }

    @Test("base64UrlEncode(nonce) matches the EXACT string the backend's own encodeBase64Url produced for the same bytes")
    func base64UrlEncodingMatchesBackendOutputExactly() {
        let encoded = AthleteDeviceAuthorizationService.base64UrlEncode(Self.nonce)
        #expect(encoded == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    }
}
