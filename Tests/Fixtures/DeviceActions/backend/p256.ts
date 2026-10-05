// Vǫxtr Backend — P-256 (secp256r1) signature verification.
//
// WIRE CONTRACT (V1, frozen — see this repository's delivery report
// for the empirical verification this was checked against the real
// Deno Web Crypto runtime, not assumed from spec-reading alone):
//   - public key: uncompressed SEC1/X9.63 point, exactly 65 bytes,
//     first byte 0x04.
//   - signature: raw ECDSA r || s (IEEE P1363), exactly 64 bytes —
//     NOT a DER-encoded SEQUENCE.
//
// Confirmed directly against Deno 2.9.6's `crypto.subtle`:
// `exportKey("raw", ...)` on a generated P-256 key produces exactly
// this 65-byte form, and `sign({name:"ECDSA",hash:"SHA-256"}, ...)`
// produces exactly this 64-byte raw r||s form — Web Crypto's ECDSA
// sign/verify operations use the P1363 format by specification, and
// this was reproduced with a real generate/sign/export/import/verify
// round-trip before being relied on here. No DER<->raw conversion
// layer exists or is needed for V1.
//
// Length checks happen BEFORE any Web Crypto call: `importKey`/
// `verify` do not reliably reject a wrong-length input by throwing
// (confirmed: a truncated signature made `verify()` simply return
// `false`, not throw) — relying on that alone would make "malformed"
// and "cryptographically wrong" indistinguishable internally, so this
// module rejects malformed lengths explicitly and up front instead.

const P256_PUBLIC_KEY_LENGTH = 65;
const P256_PUBLIC_KEY_UNCOMPRESSED_PREFIX = 0x04;
/** Exported so callers can fail fast on an obviously-malformed
 * signature before making any network/database call at all — not
 * just before the Web Crypto call this module itself makes. */
export const P256_SIGNATURE_LENGTH = 64;

export type P256VerifyResult =
  | { readonly ok: true }
  | { readonly ok: false; readonly reason: "malformed_public_key" }
  | { readonly ok: false; readonly reason: "malformed_signature" }
  | { readonly ok: false; readonly reason: "signature_invalid" };

export type P256PublicKeyValidationResult =
  | { readonly ok: true }
  | { readonly ok: false; readonly reason: "malformed_public_key" };

/**
 * Validates ONLY that `publicKeyBytes` is a well-formed, importable
 * P-256 uncompressed public key (length, 0x04 prefix, and a real
 * `crypto.subtle.importKey` round trip to reject a length-correct but
 * off-curve point) — no signature is involved. Extracted from {@link
 * verifyP256Signature} (which now calls this internally) so a caller
 * that only needs to validate a submitted key BEFORE any signature
 * exists yet — Athlete Connection V1's connection-request-submit
 * handler — can reuse the exact same check rather than duplicating it.
 */
export async function validateP256PublicKey(
  publicKeyBytes: Uint8Array,
): Promise<P256PublicKeyValidationResult> {
  if (
    publicKeyBytes.length !== P256_PUBLIC_KEY_LENGTH ||
    publicKeyBytes[0] !== P256_PUBLIC_KEY_UNCOMPRESSED_PREFIX
  ) {
    return { ok: false, reason: "malformed_public_key" };
  }

  try {
    // .slice(): see verifyP256Signature's own note on why a fresh,
    // plain-ArrayBuffer-backed view is required here.
    await crypto.subtle.importKey(
      "raw",
      publicKeyBytes.slice(),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
  } catch {
    // A length-correct but otherwise invalid point (not on the curve).
    return { ok: false, reason: "malformed_public_key" };
  }

  return { ok: true };
}

/**
 * Verifies a raw r||s P-256/ECDSA/SHA-256 signature against a raw
 * uncompressed public key and message bytes. Never throws — every
 * failure mode (malformed key, malformed signature, or a
 * cryptographically invalid signature) is returned as a value.
 */
export async function verifyP256Signature(
  publicKeyBytes: Uint8Array,
  signatureBytes: Uint8Array,
  messageBytes: Uint8Array,
): Promise<P256VerifyResult> {
  const keyValidation = await validateP256PublicKey(publicKeyBytes);
  if (!keyValidation.ok) {
    return keyValidation;
  }
  if (signatureBytes.length !== P256_SIGNATURE_LENGTH) {
    return { ok: false, reason: "malformed_signature" };
  }

  // .slice() rather than passing the parameters straight through: it
  // guarantees a fresh, plain-ArrayBuffer-backed Uint8Array, which is
  // what Web Crypto's BufferSource-typed parameters require — the
  // caller-supplied views (e.g. from base64url decoding) are not
  // guaranteed to already have that exact backing.
  const key = await crypto.subtle.importKey(
    "raw",
    publicKeyBytes.slice(),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );

  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    signatureBytes.slice(),
    messageBytes.slice(),
  );

  return verified ? { ok: true } : { ok: false, reason: "signature_invalid" };
}
