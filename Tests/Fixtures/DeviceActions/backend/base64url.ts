// Vǫxtr Backend — base64url (RFC 4648 §5) encode/decode, no padding.
//
// Used for the claim-proof wire format: the challenge nonce (both in
// the canonical signed message and the HTTP JSON response) and the
// claim signature are both base64url-without-padding, never plain
// base64 (which uses `+`/`/` and `=` padding — unsafe/awkward in URLs
// and inconsistent with the one canonical encoding this protocol
// actually specifies for the nonce).

/** Encodes raw bytes as base64url with no `=` padding. */
export function encodeBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

/**
 * Decodes base64url (with or without padding) back to raw bytes.
 * Returns `null` — never throws — on malformed input, so callers can
 * treat a bad wire value as an ordinary rejection rather than an
 * uncaught exception.
 */
export function decodeBase64Url(value: string): Uint8Array | null {
  if (value.length === 0) return null;
  // Only the base64url alphabet is legal input; reject anything else
  // up front rather than relying on atob()'s own error behavior,
  // which varies by input shape.
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;

  const withPadding = value.replaceAll("-", "+").replaceAll("_", "/");
  const paddingNeeded = (4 - (withPadding.length % 4)) % 4;
  const padded = withPadding + "=".repeat(paddingNeeded);

  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    return null;
  }

  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}
