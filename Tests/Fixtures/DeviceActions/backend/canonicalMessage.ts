// Vǫxtr Backend — the exact, versioned canonical bytes a device signs
// to prove possession of its connection_requests.device_public_key.
//
// This format is frozen for V1: five UTF-8 lines, each terminated by
// `\n` (including the last), concatenated with no other separators,
// normalization, or reordering. It is NOT JSON — deliberately, so
// there is exactly one byte sequence for a given (challenge, request,
// invitation, nonce) tuple, with no canonicalization ambiguity (key
// order, whitespace, numeric formatting) for a signer/verifier to
// disagree about.
//
// UUIDs are rendered lowercase (Postgres's own `uuid` text
// representation is already lowercase, so callers passing a value
// straight from the database need no extra normalization — but this
// module lowercases defensively regardless, since correctness here
// must not depend on that assumption holding forever).

import { encodeBase64Url } from "./base64url.ts";

export interface CanonicalMessageFields {
  readonly challengeId: string;
  readonly requestId: string;
  readonly invitationId: string;
  readonly nonce: Uint8Array;
}

const MESSAGE_VERSION_LINE = "voxtr-athlete-connection-claim-v1";

/** Builds the exact UTF-8 bytes a device must sign for a claim proof. */
export function buildCanonicalMessageBytes(
  fields: CanonicalMessageFields,
): Uint8Array {
  const lines = [
    MESSAGE_VERSION_LINE,
    `challenge_id=${fields.challengeId.toLowerCase()}`,
    `request_id=${fields.requestId.toLowerCase()}`,
    `invitation_id=${fields.invitationId.toLowerCase()}`,
    `nonce=${encodeBase64Url(fields.nonce)}`,
  ];
  // Every line, including the last, ends with \n — this is a
  // deliberate wire-format choice (see the module doc comment above),
  // not an accidental trailing join artifact.
  const text = lines.map((line) => line + "\n").join("");
  return new TextEncoder().encode(text);
}

// ============================================================
// Device-authorization session contract (§3 of the runtime-auth/
// hydration contract) — a SEPARATE, later-added canonical message
// format from the claim-proof one above. Four actions share one wire
// shape; only the version line differs per action.
// ============================================================

/** The four device-session-challenge actions (matches the
 * `authz.device_session_challenges.action` CHECK constraint exactly —
 * underscore-spelled, as stored in the database). */
export type DeviceSessionAction =
  | "session_issue"
  | "session_renew"
  | "hydration_get"
  | "hydration_ack";

/**
 * Explicit lookup table, never a literal template substitution of the
 * action value: the database's `action` enum is underscore-spelled
 * (`session_issue`) while the signed version line is hyphen-spelled
 * (`session-issue`) — interpolating the enum string directly would
 * produce different, non-interoperable bytes. This is the exact
 * inconsistency the runtime-auth/hydration contract's §3.3 calls out
 * and corrects; this table is that correction.
 */
const DEVICE_SESSION_VERSION_LINES: Record<DeviceSessionAction, string> = {
  session_issue: "voxtr-athlete-session-issue-v1",
  session_renew: "voxtr-athlete-session-renew-v1",
  hydration_get: "voxtr-athlete-hydration-get-v1",
  hydration_ack: "voxtr-athlete-hydration-ack-v1",
};

export interface DeviceSessionCanonicalMessageFields {
  readonly action: DeviceSessionAction;
  readonly deviceGrantId: string;
  readonly challengeId: string;
  readonly nonce: Uint8Array;
}

/**
 * Builds the exact UTF-8 bytes a device must sign for one of the four
 * device-session-challenge actions. No `method`/`path`/`body_sha256`
 * field: none of the four actions carries mutable content beyond the
 * identifiers already bound here, so there is nothing left for a body
 * hash to protect (see this contract's own §3.3 for why that field was
 * removed rather than patched when the claim-proof format was
 * extended to this one). Byte-exact rules, matching {@link
 * buildCanonicalMessageBytes}: UTF-8; every line, including the last,
 * terminated by one `\n`; no other separators; UUIDs lowercased
 * regardless of input casing; nonce base64url per RFC 4648 §5, no
 * padding.
 */
export function buildDeviceSessionCanonicalMessageBytes(
  fields: DeviceSessionCanonicalMessageFields,
): Uint8Array {
  const lines = [
    DEVICE_SESSION_VERSION_LINES[fields.action],
    `device_grant_id=${fields.deviceGrantId.toLowerCase()}`,
    `challenge_id=${fields.challengeId.toLowerCase()}`,
    `nonce=${encodeBase64Url(fields.nonce)}`,
  ];
  const text = lines.map((line) => line + "\n").join("");
  return new TextEncoder().encode(text);
}
