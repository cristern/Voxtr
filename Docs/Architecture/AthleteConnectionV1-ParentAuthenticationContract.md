# Athlete Connection V1 — Parent authentication and existing-workspace enrollment contract

Status: **reviewed engineering contract for Parent Sign in with Apple authentication, Parent sessions, and existing-workspace Internal Alpha enrollment, submitted for Product/Architecture review.** It builds on, and does not reopen, the Product Owner-approved D1–D4 outcomes in [the decision ledger](AthleteConnectionV1-DecisionReview.md) and the security outcomes in [the normative contract](AthleteConnectionV1-NormativeSecurityContract.md). Where a specific number, an operational-process choice, or a security posture below is not already covered by an approved decision, it is explicitly marked **PROPOSED** and requires separate Product Owner sign-off before implementation — this document does not grant that approval itself. It corrects specific technical weaknesses identified in an earlier, unreviewed pseudocode draft produced during discovery for [issue #100](https://github.com/cristern/Voxtr/issues/100); those corrections are noted inline. This document does not modify product philosophy, does not supersede the Product Constitution, and does not introduce an owner-transfer or account-recovery policy.

Backend milestones this document builds on, verified directly against `cristern/Voxtr-Backend` `develop` at `271ba976683f97981d6283785fe35daeecc552a8`: Stage B (private `authz` schema — `parents`, `workspace_enrollment_authorizations`, `workspace_owner_bindings`, `invitations`, `connection_requests`, `claim_challenges`, `device_grants`, `audit_events`), Stage C (`authz.claim_device_grant`), Stage D (P-256 claim-proof handlers), and PR #5 (the independent SIWA ID-token verifier, `supabase/functions/_shared/siwaVerifier.ts`, `createAppleIdTokenVerifier({expectedAudience,...}).verify(idToken, expectedNonce)`). No new database function, migration, or Edge Function described below exists yet — this is a contract for implementation, not a report of implemented state.

`cristern/Voxtr` `develop` at `4a7ac5a52869f76947266c2937c082b2e179c2c5` — the iOS repository is unchanged since the discovery round this document finalizes; every iOS finding below is carried forward from that verified inspection (`ParentEntities.swift`, `ParentWorkspaceRepository.swift`, `AthleteIdentityHydrationService.swift`, `Package.swift`), not re-derived.

[`cristern/Voxtr#99`](https://github.com/cristern/Voxtr/pull/99) remains open and unmerged as of this writing and is treated as proposed documentation, not canonical. This document does not modify or merge it. It touches `AthleteConnectionV1-NormativeSecurityContract.md` and `AthleteConnectionV1-ProjectStatus-2026-09-21.md`; this document deliberately does not edit either file, to keep the two PRs' diffs disjoint and reconcilable independently.

## Evidence note on external documentation

Apple's own `developer.apple.com` reference pages for `ASAuthorizationAppleIDRequest`/`ASAuthorizationAppleIDCredential` returned only page titles to this session's fetch tooling (likely client-rendered content not captured by a non-browser fetch) — they could not be quoted directly. The nonce-hashing behavior below is instead corroborated by two independent secondary sources describing the same concrete, real-world behavior: a Google Cloud Identity Platform / Firebase integration guide, and a live open-source bug report ([better-auth#8870](https://github.com/better-auth/better-auth/pull/8870)) describing and fixing exactly this behavior in a production auth library. Both agree precisely. `supabase.com` itself was blocked outright by this session's network egress policy; Supabase's API-key transition is instead corroborated via [a Supabase-maintained GitHub Discussion](https://github.com/orgs/supabase/discussions/29260) quoting the platform's own stated migration language directly. Neither substitute is Apple's or Supabase's own page — this is disclosed rather than presented as primary-source confirmation.

---

## 1. Apple authentication contract

### 1.1 Verified native SIWA nonce behavior

Native `ASAuthorizationAppleIDRequest` on iOS requires the **caller** to SHA-256 hash a raw nonce before assigning it to the request's `nonce` property; Apple does **not** hash it again. The resulting identity token's `nonce` claim contains that same **hashed** value, verbatim — never the raw value. This is confirmed by two independent sources describing identical behavior (see evidence note above), including a real bug report where an auth library initially compared the token's `nonce` claim against a *raw* value and had to add hashed-value comparison to fix rejected native-iOS tokens. **Do not assume Apple hashes on your behalf, and do not compare a raw value against the token's `nonce` claim.**

### 1.2 Server-issued nonce handshake — exact contract

| Step | Actor | Value | Encoding |
|---|---|---|---|
| 1 | Backend generates | `raw_nonce_bytes` — 32 bytes, CSPRNG (`crypto.getRandomValues`, matching the existing `claim-challenge` nonce convention exactly) | raw bytes, not yet encoded |
| 2 | Backend encodes | `raw_nonce_b64url = base64url(raw_nonce_bytes)` (no padding) | `encodeBase64Url`, `_shared/base64url.ts` — reuse, do not reimplement |
| 3 | Backend computes and stores | `hashed_nonce_hex = lowercase_hex(SHA-256(UTF-8 bytes of raw_nonce_b64url))` — **the hash input is the transmitted base64url string's UTF-8 bytes, never the original 32 raw bytes** | hex-encoded (lowercase), stored as `TEXT` |
| 4 | Backend returns to device | `{ nonce_id, nonce: raw_nonce_b64url, expires_at }` | HTTP JSON |
| 5 | Device computes | `client_hashed_nonce_hex = lowercase_hex(SHA-256(UTF-8 bytes of the received raw_nonce_b64url string, exactly as received — no re-decoding to bytes first))` | same hash input as step 3, byte-for-byte — see 1.3 |
| 6 | Device sets | `ASAuthorizationAppleIDRequest.nonce = client_hashed_nonce_hex` | hex string (Apple's API accepts a `String`) |
| 7 | Apple returns | `identityToken` whose JWT `nonce` claim `== client_hashed_nonce_hex` | — |
| 8 | Device sends to backend | `{ nonce_id, apple_identity_token }` | HTTP JSON — **the device never sends `raw_nonce_b64url` or any hash back**, and never supplies any value the backend will treat as its expected nonce (see 1.4) |
| 9 | Backend | looks up `hashed_nonce_hex` for `nonce_id` (never derived from anything the device supplies at this step) and passes it as `expectedNonce` to `siwaVerifier.verify(apple_identity_token, hashed_nonce_hex)` | exact string equality inside the existing, unmodified verifier |

One representation throughout: **SHA-256 of the UTF-8 bytes of the base64url-encoded nonce string, rendered as lowercase hex.** Nothing in this contract ever hashes the raw 32 bytes directly, and nothing compares a raw (unhashed) value against the token's `nonce` claim.

### 1.3 Freezing the exact hash representation and proving iOS ↔ backend agreement

**This corrects an earlier draft of this document, which stated step 3 as hashing the raw 32 bytes while step 5 hashed the transmitted base64url string — two different digests that would never match.** The single frozen contract, restated precisely: the backend generates 32 random bytes, immediately base64url-encodes them (no padding) into `raw_nonce_b64url`, and computes `SHA-256` over the **UTF-8 bytes of that base64url string** — not the 32 underlying random bytes, not a re-decoded byte array. The device, upon receiving `raw_nonce_b64url`, must hash the identical UTF-8 bytes of that exact string it received, unmodified. Both sides render the digest as lowercase hex. This precise framing exists to avoid a "hash the string form vs. hash the decoded bytes" mismatch class of bug — the exact failure mode the better-auth report (§ evidence note) demonstrates can silently break real native tokens when conflated.

**Fixed test vector** (independently verified across three implementations — Python `hashlib`, `openssl dgst -sha256`, and Deno's `crypto.subtle.digest`, all producing an identical result, before being recorded here):

```
raw_nonce_b64url = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
SHA-256(UTF-8 bytes of raw_nonce_b64url), lowercase hex =
  "eb9f16800c9029ffca85695763d23c3ace71011cf40e9354acd810205e250f87"
```

(The underlying 32 raw bytes this string encodes are `0x01..0x20` in sequence — an arbitrary, fixed, reproducible choice for a test vector, not a value with any other significance.)

**Required before this contract is trusted for real interoperability**: this same test vector, computed via (a) Deno's `crypto.subtle.digest("SHA-256", ...)` in a backend test, and (b) `CryptoKit.SHA256.hash(data: Data(rawNonceB64url.utf8))` in an iOS unit test, must independently produce this exact hex string on **both** platforms. Neither test exists yet. **Real iOS/Apple interoperability remains entirely unverified until both of those tests exist and pass, and further, until an actual live device completes a real Sign in with Apple round trip against this handshake** — this document's own three-way cross-check (Python/openssl/Deno) proves the arithmetic is self-consistent, not that CryptoKit produces the same digest for the same input, and proves nothing whatsoever about Apple's live service. This is the same evidentiary standard this codebase already holds P-256 wire bytes to (verified directly against `crypto.subtle` before being relied on, per `p256.ts`'s own header comment) — proposed and internally verified, not yet proven end-to-end.

### 1.4 Preventing the client from choosing or replacing the expected nonce

The Edge Function's request body for step 8 above is `{ nonce_id, apple_identity_token }` **only**. There is no field for a client-supplied nonce or hash of any kind. The backend's `expectedNonce` value is looked up server-side from `authz.parent_auth_nonces` by `nonce_id` and is never read from, or influenced by, any other part of the request. This closes the exact class of vulnerability the task description warns against: a client cannot supply its own "expected" value to satisfy the verifier, because the verifier's second argument never originates from client input at all.

### 1.5 Storage, expiration, single-use consumption — and a deliberate divergence from the claim-challenge pattern

New table `authz.parent_auth_nonces (id UUID PK DEFAULT gen_random_uuid(), hashed_nonce TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), expires_at TIMESTAMPTZ NOT NULL, used_at TIMESTAMPTZ)`, same derivation-CHECK + immutable-`created_at`-trigger pattern as every other timed table in this schema. TTL: **PROPOSED 60 seconds**, matching the existing claim-challenge TTL exactly (identical threat shape: a short-lived, single-use, server-bound value) — a Product Owner/security-review number, not decided here.

**Consumption happens eagerly** — `authz.consume_parent_auth_nonce(p_nonce_id) RETURNS (outcome, hashed_nonce)`, a single conditional `UPDATE authz.parent_auth_nonces SET used_at = clock_timestamp() WHERE id = p_nonce_id AND used_at IS NULL AND expires_at >= clock_timestamp() RETURNING hashed_nonce` — called **before** the Apple token is even verified, not after (as `claim-submit` does for the P-256 challenge). This is a considered divergence, not an inconsistency: `claim-submit` defers burning until after a successful signature check specifically so a caller whose HTTP response was lost can retry with the *same, already-scarce, hard-to-re-obtain* challenge state. An auth nonce protects nothing scarce — requesting a fresh one costs nothing — so eager, single-step consumption is simpler, avoids a peek-then-consume TOCTOU window entirely, and is the more conservative choice for a value that exists purely to prevent replay.

### 1.6 Concurrent authentication attempts

Two concurrent calls presenting the **same** `nonce_id` race on the same conditional `UPDATE`; exactly one returns a row, the other returns zero rows → generic rejection, no re-verification attempted, no nonce left in an ambiguous state. Two concurrent authentications using **different** nonce IDs for the **same** `siwa_subject` are independent and both may succeed, each producing its own session — this is intentional (a Parent signing in on two devices is legitimate) and requires no special handling beyond the ordinary `authz.parents` upsert being idempotent (`INSERT ... ON CONFLICT (siwa_subject) DO UPDATE`).

### 1.7 Error handling and retry

Every rejection at every step (nonce not found/expired/already used; Apple signature/issuer/audience/expiry/nonce-mismatch failure) returns one generic outcome family (`authentication_failed`) with no distinction visible to the caller between "bad nonce" and "bad Apple token" — anti-enumeration, matching this codebase's established posture (`issue_claim_challenge`'s own generic `request_not_available`). A rejected attempt is always safely retryable by requesting a brand-new nonce; there is no failure mode that leaves the system in a state requiring anything other than "start over."

### 1.8 Reuse of the existing verifier — no second implementation

`parent-auth-complete` calls `createAppleIdTokenVerifier({ expectedAudience: <from env, never hardcoded> }).verify(apple_identity_token, hashed_nonce)` from `supabase/functions/_shared/siwaVerifier.ts` **unmodified**. No new JWT parsing, JWKS fetching, or signature verification code is introduced anywhere in this contract.

---

## 2. Parent session contract

### 2.1 Category confirmed, specific numbers still open

The previously proposed **opaque, backend-issued, short-lived, Keychain-stored session** is the right category — it matches the already-approved contract language and requires no new cryptographic machinery (no Parent-side device key, no JWT-based session). What is evaluated here, and remains **PROPOSED**, is the exact lifetime numbers and the freshness-check mechanism in §2.6.

### 2.2 Generation and storage

Session token: 256-bit CSPRNG value (Deno `crypto.getRandomValues`), base64url-encoded for transport. Only its SHA-256 hex hash is ever persisted, in a new table `authz.parent_sessions (id UUID PK, parent_id UUID NOT NULL REFERENCES authz.parents(id), token_hash TEXT UNIQUE NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), expires_at TIMESTAMPTZ NOT NULL, authenticated_at TIMESTAMPTZ NOT NULL, absolute_expires_at TIMESTAMPTZ NOT NULL, revoked_at TIMESTAMPTZ)`.

**`authenticated_at` is per-session, never derived from `authz.parents.last_authenticated_at`.** This corrects an earlier draft, which copied the *parent's* global `last_authenticated_at` onto the session at issuance/rotation time — a real flaw: since that global column is shared across every session a Parent has ever created, a fresh SIWA handshake on device A would silently "refresh" the freshness eligibility of an unrelated, already-issued session on device B the next time B's session happened to rotate, without device B itself ever re-proving live Apple access. `authz.parents.last_authenticated_at` remains a parent-wide bookkeeping column (useful for observability — "when did this Apple account last complete any handshake, on any device") but is never read by any freshness check. The rule, precisely:

- `authenticated_at` is set **exactly once, at session creation**, inside `authz.upsert_parent_and_issue_session`, to a fresh `clock_timestamp()` local to that function call — never copied from `authz.parents`.
- Session **rotation** (§2.4) carries `authenticated_at` forward **unchanged** from the session being rotated onto its replacement — rotation never bumps it, regardless of what may have happened to the Parent's other sessions or global record in the meantime.
- A **new** SIWA handshake (§1) always creates a **new, distinct** session row via the same `upsert_parent_and_issue_session` path, with its own fresh `authenticated_at` — it never reaches into, upgrades, or otherwise touches any other existing session row. There is no "upgrade an existing session in place" operation in this contract; a Parent regaining freshness for a stale session simply ends up holding a different, newer session, and discards the old one client-side. This deliberately avoids needing any additional trusted-lineage or cross-session transaction machinery.
- Every freshness check (§2.6) evaluates `authenticated_at` on **the specific session row presented with that exact request** — never any other session, never the parent-wide column.

**`absolute_expires_at` closes a real gap: without it, repeated rotation could extend a session indefinitely, contradicting the proposed 30-day ceiling in §2.3.** Session `expires_at` is a *sliding* window that rotation is allowed to push forward; `absolute_expires_at` is a *hard* ceiling that rotation must never push forward. Both are timestamps, both matter, and they answer different questions: "is this specific credential still valid right now" (`expires_at`) versus "has this entire chain of rotations, starting from one real SIWA handshake, run for longer than is ever permitted" (`absolute_expires_at`). Distinct again from `authenticated_at` (freshness): a session can be simultaneously non-expired, within its absolute lifetime, and still stale for freshness purposes — the three concepts are independent axes, not substitutes for one another. The rule, precisely, mirroring `authenticated_at`'s own treatment:

- `absolute_expires_at` is computed **exactly once, at session creation**, inside `authz.upsert_parent_and_issue_session`, as `clock_timestamp() + ABSOLUTE_MAX_LIFETIME` (**PROPOSED: 30 days**, §2.3) — a database-time computation local to that function call, never a client-supplied timestamp of any kind.
- Session **rotation** (§2.4) carries `absolute_expires_at` forward **verbatim, unchanged**, from the session being rotated onto its replacement — rotation never recomputes or extends it, no matter how many times a chain has already been rotated.
- The replacement session's own sliding `expires_at` is capped at rotation time so it **can never exceed the inherited `absolute_expires_at`** — see §2.4 for the exact computation. This is the specific mechanism that makes the 30-day ceiling actually enforceable across arbitrarily many rotations, rather than merely stated as an intention.
- A **new** SIWA handshake (§1) always creates a **new, distinct** session row with its **own fresh** `absolute_expires_at` — exactly the same "always mint a new chain, never upgrade one in place" rule already established for `authenticated_at` above, so no separate session-family/lineage model is needed: the column itself, carried forward by value, is sufficient to enforce the ceiling.
- `authz.validate_parent_session` and `authz.rotate_parent_session` both reject a session where `clock_timestamp() >= absolute_expires_at`, in addition to the ordinary `clock_timestamp() >= expires_at` check — checked explicitly and separately, as defense-in-depth against a capping computation ever being wrong, consistent with this schema's established layered-enforcement pattern (e.g. the enrollment transaction's `EXISTS` pre-check plus unique-index backstop, §5.4) rather than relying on a single point of correctness.

All of the above — `authenticated_at`, `absolute_expires_at`, and ordinary `expires_at` alike — are computed and checked using `clock_timestamp()` (authoritative database time), exactly matching the derivation pattern already used for `invitations.expires_at`, `claim_challenges.expires_at`, and `device_grants.recovery_deadline` elsewhere in this schema. **No expiration-related value in this contract is ever computed from, or validated against, a client-supplied timestamp.**

Hash-based lookup (not constant-time raw comparison) is appropriate here: the token is high-entropy CSPRNG output, so an indexed hash-equality lookup carries no exploitable timing signal about the secret itself — the same reasoning already applies to `redemption_code_hash` lookups elsewhere in this schema.

### 2.3 Lifetime — PROPOSED, with justification

**PROPOSED: 24-hour sliding session, 30-day absolute maximum, refresh rotates the token and extends up to — but never past — that ceiling.** Rationale: Parent interactions here are low-frequency and checkpoint-style (review a request, revoke a grant) rather than continuous; the bare 10-minute figure floated in the earlier technical review would force re-authentication mid-interruption for an ordinary phone call, which is a real usability cost the approved contract never asked for. The **blast radius of session possession alone is bounded** by §2.6's freshness gate on the operations that actually matter (approve/revoke) — a longer sliding window for *low-stakes* reads (list pending requests) does not by itself increase what a stolen token can accomplish, provided §2.6 is implemented. This is a security/usability trade-off requiring explicit sign-off, presented with its reasoning rather than asserted as already decided.

These are two independent numbers with two independent jobs: 24 hours bounds how long any *single* credential is valid before it must rotate; 30 days bounds how long a Parent can keep extending access to one continuous chain of rotations without ever repeating the full SIWA handshake. **Only the mechanism that makes the second number actually enforceable — `absolute_expires_at`, carried forward unchanged across every rotation and used to cap each rotation's new `expires_at` — is specified as settled engineering design in §2.2/§2.4 below; the exact 24-hour and 30-day figures themselves remain PROPOSED, pending the same Product Owner sign-off as before.** Fixing the enforcement gap does not itself decide the numbers.

### 2.4 Renewal and rotation, including lost-response recovery

`authz.rotate_parent_session(p_old_token_hash, p_new_token_hash) RETURNS (outcome, session_id, expires_at)`.

**Correction from an earlier draft**: the function signature previously also took `p_new_expires_at` as a caller-supplied parameter — wrong, because it let the *caller* (Edge Function code) decide the new expiry rather than the database computing and enforcing it from authoritative time. The corrected function computes `expires_at` itself, entirely server-side:

```sql
-- Illustrative body, not final DDL — the exact SQL belongs in the
-- implementation task, not this contract. Behavior specified precisely:
SELECT * INTO v_old FROM authz.parent_sessions
  WHERE token_hash = p_old_token_hash FOR UPDATE;

IF NOT FOUND OR v_old.revoked_at IS NOT NULL THEN
    outcome := 'session_invalid';                    -- generic: unknown or already-rotated/revoked
ELSIF clock_timestamp() >= v_old.absolute_expires_at THEN
    outcome := 'absolute_lifetime_exceeded';          -- this chain's hard ceiling is reached; only a full
                                                       -- new SIWA handshake (§1) can produce a usable session
ELSIF clock_timestamp() >= v_old.expires_at THEN
    outcome := 'session_expired';                     -- ordinary sliding-window expiry
ELSE
    v_new_expires_at := LEAST(
        clock_timestamp() + SLIDING_WINDOW_INTERVAL,  -- PROPOSED 24h, §2.3
        v_old.absolute_expires_at                     -- inherited, unchanged, the actual enforcement
    );
    INSERT INTO authz.parent_sessions
      (parent_id, token_hash, expires_at, authenticated_at, absolute_expires_at)
      VALUES (v_old.parent_id, p_new_token_hash, v_new_expires_at,
              v_old.authenticated_at,        -- copied verbatim — never clock_timestamp(), never authz.parents
              v_old.absolute_expires_at)     -- copied verbatim — never recomputed, never extended
      RETURNING id INTO v_new_id;
    UPDATE authz.parent_sessions SET revoked_at = clock_timestamp() WHERE id = v_old.id;
    outcome := 'rotated';
END IF;
```

The `LEAST(...)` computation is the entire enforcement mechanism the earlier draft was missing: it is what makes rotation able to *extend the sliding window up to, but never past,* the inherited absolute ceiling. Its behavior across repeated rotations, stated explicitly per the acceptance criteria:

- **Repeated rotations approaching the absolute deadline** produce naturally *shrinking* windows, not a constant 24 hours forever: with, say, 10 hours left before `absolute_expires_at`, `LEAST(now + 24h, absolute_expires_at)` evaluates to `now + 10h`, not `now + 24h`. Each subsequent rotation's window shrinks further as the ceiling approaches, converging to zero rather than ever crossing it.
- **A rotation request after absolute expiration** is rejected outright with the distinct `absolute_lifetime_exceeded` outcome, checked *before* the ordinary `expires_at` check (both would normally agree, since `expires_at` is always capped at issuance/rotation, but they are checked as two separate, explicit conditions rather than collapsed into one, per this schema's established layered-defense convention).
- **A sliding expiration that would otherwise exceed the absolute deadline** — i.e. the exact bug this correction closes — cannot occur: the `LEAST(...)` computation is the only place `expires_at` is ever produced for a rotated session, so there is no code path that assigns a value larger than `absolute_expires_at`.
- The **new session row is a genuinely new database row** (a new `id`, a new `token_hash`) — rotation has never claimed otherwise — but it belongs to the same enforceable chain as its predecessor specifically *because* `absolute_expires_at` (and `authenticated_at`) are copied forward by value, not because any new "session family" identifier or separate persistent model is introduced. This satisfies the correctness requirement (an enforceable, non-extendable ceiling across arbitrarily many rotated rows) without adding a new modeling concept.

Rotation extends *how long the session credential itself remains valid, within the inherited ceiling* (`expires_at`, now correctly bounded); it never changes *how recently that session's lineage last completed a real SIWA handshake* (`authenticated_at`) and never changes *the hard ceiling itself* (`absolute_expires_at`) — three independent, explicitly preserved distinctions: session expiration, authentication freshness, and absolute session lifetime.

**Lost-response recovery, unaffected by this correction, restated to confirm it remains fail-closed**: if the HTTP response carrying the new token is lost after the database transaction commits, the device still holds the *old* (now-revoked) token and has no way to retrieve the new one — the device must detect a `session_invalid`/`401` outcome on its next call and fall back to a full re-authentication (§1), which correctly starts an entirely new chain with its own fresh `absolute_expires_at` rather than attempting to resurrect the old one. This is a real, disclosed limitation, not silently glossed over: an opaque rotation scheme has no idempotent "give me the same new token again" recovery path the way `claim_device_grant`'s grant-retrieval does, because unlike a device grant (tied to an immutable device key the caller can re-prove possession of), a session rotation has no re-provable identity binding *at the point of the lost response* other than the now-consumed old token. Mitigating this fully would require either a short grace window where the old token remains valid alongside the new one (weakens rotation's guarantee) or a client-generated idempotency key on the refresh call — flagged as an **open technical question**, not resolved here; the safe default (old token immediately revoked, no idempotency key) is recommended for v1 given a lost response here only costs a fresh sign-in, not a lost approval.

### 2.5 Concurrent refresh requests

Two concurrent `rotate_parent_session` calls presenting the *same* old token: the old-token validation and `revoked_at` update should be done via a `SELECT ... FOR UPDATE` on the session row before proceeding, so the two callers serialize; only the first to acquire the lock succeeds and revokes the old row, the second then finds it already revoked and returns a generic `session_invalid` rejection (forcing that caller to re-authenticate) rather than both minting a valid new session from one old token. This same lock also serializes the absolute-lifetime check (§2.4): both callers read `clock_timestamp()` and `v_old.absolute_expires_at` only after acquiring the lock, one at a time, so there is no window in which two concurrent rotations near the ceiling could each compute a different, inconsistent `LEAST(...)` result from a stale read of the old row.

### 2.6 Fresh authentication for sensitive operations — the direct answer to the stolen-session threat

**Threat, stated concretely**: a stolen Parent session bearer token grants everything a live SIWA-authenticated Parent can do for that Parent's workspaces — creating an invitation, and, critically, **approving a connection request**, which is the single action that actually confers device access to a specific child's profile. An attacker holding a stolen session does not need physical proximity, the QR code, or the visual display-code comparison at all: they can call the approve endpoint directly. **Session rotation does not mitigate this** — rotation only shortens the window during which an *already-superseded* copy of a token remains dangerous; it does nothing to a *currently valid* stolen token during its live window, which is exactly when this attack happens.

**Mitigation adopted for v1 (PROPOSED) — and precisely what it does and does not achieve**: distinguish **ordinary** operations (list pending requests, view workspace enrollment status — session validity alone suffices) from **sensitive** operations (approve/reject a connection request, revoke a device grant, redeem an enrollment authorization). Every sensitive operation additionally requires, evaluated **server-side, at the moment that specific sensitive operation executes** — never inferred from an earlier UI screen, an earlier successful call, or the mere fact that some login happened recently on some device — `now() - session.authenticated_at < FRESHNESS_WINDOW` (**PROPOSED: 10–15 minutes**), read from the **exact session row presented with that request** (§2.2); if stale, the backend returns a distinct `reauthentication_required` outcome, and the iOS app must run the **full** SIWA nonce-handshake again (§1), producing a **new** session (§2.2) — before the sensitive call can succeed.

**This is corrected from an earlier draft that overstated it.** The freshness gate does **not** make a stolen session incapable of performing a sensitive action — it **limits the window** during which a stolen, currently-valid bearer token remains usable for one. Concretely: if an attacker steals the session bearer token itself *while it is still within its freshness window* (e.g., immediately after the real Parent's own genuine sign-in), that stolen token **can** successfully call the sensitive operation for as long as the window remains open — freshness constrains *how long* a theft stays dangerous, it does not detect or prevent the theft, and it does not require the attacker to possess anything beyond the bearer token itself during that window. **A session refresh does not renew this freshness** — §2.2/§2.4 establish that rotation carries `authenticated_at` forward unchanged, precisely so that merely keeping a stolen session alive via refresh can never manufacture new freshness. The genuine security value this gate provides is bounding the *duration* of exposure to something much shorter than the session's own lifetime (§2.3), and forcing an attacker who wants access *outside* that narrow window to also compromise a live Apple ID sign-in (Face ID/biometric-gated, on the real device) — a materially harder bar than holding a copied bearer string, but not one this document claims eliminates the risk during the window itself.

**Explicitly evaluated and deferred, not implemented or silently approved here**: two stronger options exist to close the in-window replay gap described above, each requiring its own separate architectural and Product Owner review before being built. (1) **Action-bound reauthentication** — requiring a fresh, per-action SIWA/biometric proof bound to the specific request being authorized (e.g. the actual `requestId` being approved), rather than a time-window check against session-level freshness — would eliminate the window entirely for that action, at the cost of a live-Apple round trip on every sensitive call. (2) **Device-key possession**, binding the session to a device-specific credential (e.g. `DeviceCheck`, or a Parent-side signing key mirroring the Athlete's P-256 device key), would let the backend verify continued physical device possession without a full SIWA round trip each time, but introduces a new persistent per-device identity concept on the Parent side that does not exist today. Both are materially larger, currently-undemonstrated additions the task's own scope discipline asks to avoid building without a demonstrated requirement — recorded here as **documented future hardening steps**, not decided or built now.

**Also recommended, out of this task's scope, requiring its own decision**: an out-of-band notification (push/email) to the Parent whenever a connection request is approved under their account — genuine defense-in-depth against this exact threat, but a separate feature requiring notification infrastructure that doesn't exist yet.

**Explicitly not a mitigation for this threat, stated to avoid a false sense of coverage**: the visual display-code comparison UX protects against a *different* threat (an inattentive real Parent approving a forwarded QR / wrong physical device) — it does nothing against an attacker calling the approve API directly with a stolen session, since that path never goes through the app's own UI at all. The two threats need the two separate mitigations described here, not one assumed to cover both.

### 2.7 Logout / server-side invalidation

`authz.revoke_parent_session(p_token_hash) RETURNS (outcome)` — sets `revoked_at`, checked by every subsequent `validate_parent_session` call. A "sign out everywhere" (revoke all sessions for a `parent_id`) is a reasonable v1.1 addition, not required for the first slice.

### 2.8 iOS Keychain storage

`ThisDeviceOnly` accessibility class (matches the already-approved contract language: "client stores token in `ThisDeviceOnly` Keychain"), never `UserDefaults`, never synced via iCloud Keychain (a session token is device-specific by design — syncing it would let a token minted on one device silently work on another, undermining the whole "device possesses a live session" framing this section relies on).

---

## 3. Supabase admission and authorization — keeping four layers distinct

### 3.1 Verified: Supabase's key-format transition materially affects this design

Supabase is transitioning from legacy JWT-format `anon`/`service_role` keys to opaque, non-JWT `sb_publishable_`/`sb_secret_` keys; both work simultaneously today, with legacy keys slated for full removal in **late 2026 (unconfirmed exact date)**. Critically — quoting the source directly — **"It is no longer possible to use a publishable or secret key inside the `Authorization` header — because they are not a JWT."** This means any design relying on `verify_jwt=true` being satisfied by presenting a project API key in the `Authorization` header is implicitly coupling to the *legacy* key format specifically, and that coupling has a disclosed, non-hypothetical expiry date.

### 3.2 Recommendation: `verify_jwt=false` for every new Parent-facing function, matching `health`'s already-established pattern

Every new function in this contract (`auth-nonce`, `parent-auth-complete`, `parent-session-refresh`, `parent-session-revoke`, the enrollment redemption endpoint) sets `verify_jwt = false` explicitly in `supabase/config.toml`, exactly as `health` already does, and performs its **own** independent authentication inside the handler — never inferring anything about identity from Supabase's own gate. This avoids the legacy-key coupling entirely: the gateway-level `apikey` header check (a separate Kong-level concern from JWT signature verification, per Supabase's documented key architecture) still applies and accepts either key format, but no function here depends on that header meaning anything about *who* is calling — only the four layers below do.

### 3.3 The four layers, explicitly never conflated

| Layer | Mechanism | Proves |
|---|---|---|
| 1. Supabase gateway admission | `apikey` header (any valid project key, new or legacy format) | This is a legitimate request to *this Supabase project* — nothing about caller identity |
| 2. Apple identity | `siwaVerifier.verify(...)`, independent of layer 1 | This specific Apple account authenticated, at this specific moment, bound to this specific nonce |
| 3. Vǫxtr Parent session | `X-Voxtr-Parent-Session: <opaque token>` custom header, validated against `authz.parent_sessions` | This specific `parent_id` currently holds a live, backend-issued session |
| 4. Workspace authorization | `authz.workspace_owner_bindings` lookup for `(parent_id, workspace_id)` | This Parent may act for this specific workspace |

No endpoint ever infers layer 2, 3, or 4 from layer 1. `parent-auth-complete` performs layer 2 and issues the layer-3 credential; every other protected endpoint requires layer 3 and then separately checks layer 4 per the specific workspace named in its request.

### 3.4 Secret handling and fail-closed behavior

`APPLE_SIWA_AUDIENCE` (or a comma-separated equivalent for multiple permitted audiences) is read from an Edge Function environment variable, never a source literal — matching `siwaVerifier.ts`'s own existing design. No secret from any layer is ever logged; a missing/misconfigured audience environment variable causes `createAppleIdTokenVerifier` to throw synchronously at cold-start (already-implemented behavior in the merged verifier), which is the correct fail-closed posture — a misconfigured function should fail to even start serving traffic, not silently accept every audience.

---

## 4. Existing-workspace operator preauthorization

### 4.1 Recommendation: Option B — a dedicated, operator-secret-gated Edge Function

Reassessed against operational complexity, credential exposure, auditability, code-delivery, and recovery:

| | A. Dashboard SQL editor | **B. `operator-issue-enrollment` Edge Function (recommended)** | C. Operator CLI script via cloud shell |
|---|---|---|---|
| Operational complexity | Lowest to build, highest per-use manual burden | Low — one function, same shape as the four existing bridges | Low-moderate — a script, no deployment |
| Credential exposure | Dashboard SQL access ≈ full service-role power, far broader than the one action | A narrow, independently rotatable operator secret — **never** the service-role key, never in iOS | Requires the actual service-role key in the operator's shell for the run's duration |
| Auditability | Depends entirely on operator discipline (manual audit-row insert, easily skipped) | Every issuance automatically writes its own `audit_events` row — cannot be forgotten | Same as B if the script is written to always audit; still human-run, no enforced discipline beyond the code |
| Code delivery | None — reviewed and tested crypto never happens | Real CSPRNG + real SHA-256 in tested, reviewed code | Same tested-code correctness as B |
| Recovery | Manual ad hoc SQL | A small paired "cancel" function gives a real, typed recovery path | Second script invocation |
| Works with no Mac, browser-only | Yes | Yes (Dashboard's function-invoke UI, or `curl`/Postman) | Yes (Codespaces/cloud shell) |

**B is recommended**: it is not a new service — it's the fourth Edge Function of the same kind as the three already **implemented and merged** to `develop` (`health`, `claim-challenge`, `claim-submit`; **none of the three is deployed to the hosted `voxtr-auth-dev` project** — merged source, verified by isolated CI and local Supabase/PostgREST integration tests only, is not the same claim as hosted deployment, and this document makes none about hosted status for any function, existing or proposed). It keeps the service-role key's blast radius completely undisturbed, and it moves every correctness-sensitive operation into tested code rather than operator hand-entry. **C remains a documented, acceptable fallback** if even one more function, once actually deployed, is judged unwarranted for a low-frequency Alpha-only action.

### 4.2 Who authorizes, and how the credential reaches the Parent

**PROPOSED, requires explicit confirmation**: the repository owner is the sole operator for Internal Alpha (no multi-operator tooling is being built). The operator calls `operator-issue-enrollment { workspace_id, ttl_minutes }` (gated by a static `OPERATOR_SECRET` header, independent of Apple/session auth entirely — a different trust mechanism, not layered into §3's four layers), receives the plaintext redemption code exactly once in the response, and relays it to the genuine Parent through **an already-trusted, pre-existing communication channel the operator personally controls** (e.g., a direct message or call to someone they already know is the real Parent) — never a new, unauthenticated channel invented for this purpose. The exact channel is an operational choice for the Product Owner to confirm, not a technical one this document can settle.

### 4.3 Preserving the accepted limited-trust model

Nothing here upgrades SIWA-plus-display-name confirmation into cryptographic ownership proof. The redemption code's existence, not the workspace ID or display name, is what gates enrollment — exactly the already-approved posture. Section 4 does not reintroduce or rely on the CloudKit Web Auth Token spike (§ Ownership Verification Spike's own conclusion — NOT VERIFIED/NOT FEASIBLE as a cryptographic binding — stands unchanged).

---

## 5. Enrollment transaction contract (corrected)

### 5.1 Corrections to the prior draft, stated explicitly

The earlier discovery-round pseudocode had three weaknesses, corrected here:

1. **`p_parent_id` was not explicitly pinned to server-derived origin.** Corrected: this is now a **hard, stated invariant** — `p_parent_id` is *never* a value the Edge Function reads from request JSON; it is exclusively the output of `authz.validate_parent_session` on the caller's own session header, for every single call including the idempotent-retry branch. Without this invariant stated as non-negotiable, a careless future refactor that accepted `parent_id` "for convenience" from the request body would let anyone who merely learned a *previously redeemed* `(redemption_code_hash, parent_id)` pair — e.g. via a log leak — replay it and receive a "success" response confirming binding details, without ever having authenticated as that Parent. Pinning `p_parent_id` to the session closes this regardless of what the request body claims.
2. **Ambiguous outcome for a legitimately-revoked binding replaying its original authorization.** The prior draft returned `inconsistent_state` (implying a genuine invariant violation) when a since-revoked binding's original authorization was replayed by its original Parent — but a revoked binding coexisting with a redeemed authorization is normal after a legitimate revocation, not an error. Corrected below to a distinct, honest outcome.
3. **Cancellation was unaddressed.** Corrected by adding an additive `cancelled_at` column and folding it into the same anti-enumeration failure bucket as expiry/not-found for the Parent-facing path (an authenticated Parent probing many codes for a workspace they already know the ID of should not learn *which* specific reason a code failed).

### 5.2 Additive migration (does not modify any merged migration)

```sql
ALTER TABLE authz.workspace_enrollment_authorizations
  ADD COLUMN cancelled_at TIMESTAMPTZ;
-- authz.workspace_owner_bindings.revoked_at already exists (Stage B) — no change needed there.
```

### 5.3 `authz.redeem_workspace_enrollment_authorization`

```sql
CREATE OR REPLACE FUNCTION authz.redeem_workspace_enrollment_authorization(
    p_workspace_id UUID,
    p_redemption_code_hash TEXT,
    p_parent_id UUID              -- INVARIANT: caller MUST derive this from
                                   -- authz.validate_parent_session(...) on
                                   -- every call. Never accept it from an
                                   -- HTTP request body.
) RETURNS TABLE (outcome TEXT, owner_binding_id UUID)
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
    v_auth authz.workspace_enrollment_authorizations%ROWTYPE;
    v_binding_id UUID;
BEGIN
    -- Lock the ONE authorization row this exact code claims to redeem.
    -- Serializes every caller presenting the SAME code; does NOT by
    -- itself serialize against a DIFFERENT, concurrently-redeemed
    -- authorization for the same workspace_id — see the exception
    -- handler below for that case, and the deadlock analysis in 5.4.
    SELECT * INTO v_auth FROM authz.workspace_enrollment_authorizations AS wea
      WHERE wea.workspace_id = p_workspace_id
        AND wea.redemption_code_hash = p_redemption_code_hash
      FOR UPDATE;

    -- Folds not-found, expired, and cancelled into ONE generic outcome:
    -- an authenticated Parent probing codes for a workspace they
    -- already know the id of should not learn which specific reason a
    -- guess failed.
    IF NOT FOUND OR v_auth.cancelled_at IS NOT NULL
       OR v_auth.expires_at < clock_timestamp() THEN
        outcome := 'authorization_not_available';
        RETURN NEXT; RETURN;
    END IF;

    IF v_auth.redeemed_at IS NOT NULL THEN
        IF v_auth.redeemed_by_parent_id = p_parent_id THEN
            -- Idempotent retry after a lost HTTP response — the SAME
            -- session-authenticated parent_id as before.
            SELECT id INTO v_binding_id FROM authz.workspace_owner_bindings
              WHERE enrollment_authorization_id = v_auth.id;
            IF v_binding_id IS NULL THEN
                outcome := 'inconsistent_state';           -- genuine invariant violation: redeemed but no binding row at all ever existed
            ELSIF EXISTS (SELECT 1 FROM authz.workspace_owner_bindings
                          WHERE id = v_binding_id AND revoked_at IS NULL) THEN
                outcome := 'already_redeemed_same_parent';  -- true idempotent-retry success
            ELSE
                outcome := 'binding_revoked';                -- CORRECTED: no longer misreported as inconsistent_state
            END IF;
            owner_binding_id := v_binding_id;
            RETURN NEXT; RETURN;
        ELSE
            outcome := 'authorization_already_redeemed';    -- burned by a DIFFERENT (session-authenticated) parent_id
            RETURN NEXT; RETURN;
        END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM authz.workspace_owner_bindings
               WHERE workspace_id = p_workspace_id AND revoked_at IS NULL) THEN
        outcome := 'workspace_already_bound';               -- fast-path conflict check
        RETURN NEXT; RETURN;
    END IF;

    UPDATE authz.workspace_enrollment_authorizations
      SET redeemed_at = clock_timestamp(), redeemed_by_parent_id = p_parent_id
      WHERE id = v_auth.id;

    BEGIN
        INSERT INTO authz.workspace_owner_bindings
          (workspace_id, parent_id, binding_source, enrollment_authorization_id)
          VALUES (p_workspace_id, p_parent_id, 'alpha_enrollment', v_auth.id)
          RETURNING id INTO v_binding_id;
    EXCEPTION WHEN unique_violation THEN
        -- Lost a genuine race against a DIFFERENT authorization's
        -- concurrent redemption for the same workspace_id (see 5.4).
        -- Un-burn this authorization: nothing was actually granted.
        UPDATE authz.workspace_enrollment_authorizations
          SET redeemed_at = NULL, redeemed_by_parent_id = NULL
          WHERE id = v_auth.id;
        outcome := 'workspace_already_bound';
        RETURN NEXT; RETURN;
    END;

    INSERT INTO authz.audit_events
      (event_type, workspace_id, enrollment_authorization_id, owner_binding_id, detail)
      VALUES ('workspace_owner_binding.created', p_workspace_id, v_auth.id, v_binding_id,
              jsonb_build_object('binding_source', 'alpha_enrollment'));

    outcome := 'bound';
    owner_binding_id := v_binding_id;
    RETURN NEXT;
END;
$$;
```

Paired narrow bridge `public.authz_redeem_workspace_enrollment_authorization`, `REVOKE ALL`, `GRANT EXECUTE TO service_role` only — identical shape to the four existing bridges.

### 5.4 Lock ordering, uniqueness violations, rollback — stated explicitly, as required

- **Same-authorization concurrency**: serialized by the `FOR UPDATE` row lock; no deadlock risk since only one row is ever locked by this function.
- **Different-authorization concurrency for the same workspace**: two transactions locking two *different* authorization rows never contend on those locks (no shared resource, no cycle) — they only contend later, at `INSERT`, on `wob_active_workspace_uk`. Postgres resolves this deterministically: the second inserter blocks until the first's transaction resolves (commit or rollback), then either proceeds (if the first rolled back) or raises `unique_violation` (if the first committed) — this is a wait with a guaranteed resolution, not a deadlock, because neither transaction ever needs a lock the other is holding.
- **Rollback**: the `EXCEPTION WHEN unique_violation` block is the only case this function catches; every other error propagates and rolls back the entire function invocation via ordinary Postgres transaction semantics. The caught case explicitly un-burns the losing authorization rather than leaving it permanently wasted with no resulting binding.

### 5.5 Authorization cancellation

`authz.cancel_workspace_enrollment_authorization(p_authorization_id, p_reason) RETURNS (outcome)` — operator-invoked (same `OPERATOR_SECRET` gate as issuance), sets `cancelled_at` if not already redeemed/cancelled/expired, writes its own audit event. An operator correcting a mistake calls this, never a raw `UPDATE`.

### 5.6 Binding revocation — the plumbing only, not a recovery policy

`authz.revoke_workspace_owner_binding(p_owner_binding_id, p_reason) RETURNS (outcome)` — operator-invoked, sets `revoked_at`, writes an audit event. This is deliberately **only the primitive**. Recovery from a lost/compromised Parent identity is: an operator revokes the stale binding, then issues a fresh `workspace_enrollment_authorizations` row through the ordinary flow above for the (possibly different) real Parent to redeem — reusing the existing mechanism rather than inventing a second one. **Who decides to invoke revocation, and under what evidentiary standard, remains an explicit outstanding Product Owner decision** (§8) — this document supplies the mechanism, not the policy.

---

## 6. iOS integration and domain ownership

One new, minimal Swift package target owns exactly: the SIWA handshake (`ASAuthorizationAppleIDProvider` + the nonce round trip), Keychain session storage, and the redemption/session HTTP calls — justified because **no existing target performs any networking today** (confirmed: no `URLSession` anywhere in `Sources/`), so this is a demonstrated new boundary, not speculative complexity, and keeps `VoxtrParentDomain` a pure SwiftData repository as it is today.

**No new SwiftData model.** `authz.workspace_owner_bindings` remains the sole ownership authority; the app queries backend enrollment state live via the session rather than caching a redundant local copy — this is what "no competing ownership authority" means concretely.

**`FamilyWorkspace.technicalOwnerAccountId` is untouched by this flow, deliberately.** It remains `AccountId.pending` after successful enrollment, exactly as before — this task does not migrate or reinterpret that field. The existing `ParentWorkspaceRepository.fetchAllWorkspaces()` already supplies the Parent's workspace picker; nothing new is needed there. New-workspace creation sequencing is untouched — this design only operates on a `workspace_id` the Parent already possesses locally from an *existing* `FamilyWorkspace`, so no dependency on that separate, still-open decision is created or discovered.

---

## 7. Verification requirements

| Tier | Covers |
|---|---|
| **Deterministic Deno tests** (no network) | Nonce hash-representation cross-check (§1.3, real `crypto.subtle`, synthetic values); handler request/response shaping with a faked bridge, following `claimChallengeHandler.test.ts`'s pattern |
| **Real PostgreSQL tests** (`tests/schema/`) | Every branch in §5.3 including both concurrency shapes (§5.4); nonce single-use/expiry/concurrent-consumption; session validate/rotate (including concurrent refresh, §2.5, and that rotation carries `authenticated_at` AND `absolute_expires_at` forward unchanged, §2.4)/revoke; the per-session freshness isolation invariant (§2.2) — a fresh SIWA handshake creating a session for device A must leave every other existing session's own `authenticated_at` completely untouched; the absolute-lifetime enforcement chain (§2.4) across repeated simulated rotations (using an injected/advanced clock, not real 30-day waits); privilege tests (anon/authenticated denied on every new function and bridge) |
| **Local Supabase/PostgREST integration** (`postgrest-bridge-integration`-style) | The real `siwaVerifier.ts` reached through the real bridge end-to-end with a synthetic RSA-signed token, exactly as already proven for the claim-proof handlers |
| **Requires live Apple** (cannot run in CI) | A real device signing in with a real Apple ID against `parent-auth-complete` — the one thing no synthetic test can substitute for; **synthetic cryptographic tests above establish that the *mechanism* is correct, not that it interoperates live with Apple** — stated explicitly per this task's own instruction not to conflate the two |
| **Codemagic** | Swift compile gate for the new iOS module |
| **Two-iPhone TestFlight** | Full journey: real enrollment, stolen-session freshness-gate behavior (§2.6) observed live, revocation |

**Required negative tests, explicitly**: a session whose `authenticated_at` is *outside* the freshness window attempting a sensitive action is rejected with `reauthentication_required` (confirms the gate rejects stale freshness); conversely, a session whose `authenticated_at` is still *inside* the freshness window succeeding at a sensitive action even though the request did not originate from the device that actually performed that SIWA handshake — this is not a bug to fix, it is a **confirmation test** that the disclosed residual risk in §2.6 is exactly as documented, not silently better or worse than stated; a fresh SIWA handshake on device A does **not** alter the `authenticated_at` of an existing, separate session on device B (the corrected per-session isolation invariant, §2.2); a rotated session's `authenticated_at` is unchanged from before rotation, never reset to the rotation time; nonce replay (same `nonce_id` twice); concurrent session refresh (§2.5); enrollment attempt with an unauthenticated or wrong-workspace session; two different authorizations racing for the same workspace (§5.4); a different Parent attempting to redeem an already-redeemed code; approval attempted by a Parent session lacking a `workspace_owner_bindings` row for the target workspace.

**Required tests for absolute session lifetime enforcement (§2.4), explicitly**: repeated rotations performed as the simulated clock approaches `absolute_expires_at` each produce a strictly non-increasing `expires_at` (never a constant sliding window all the way to the ceiling); a rotation attempted after `clock_timestamp() >= absolute_expires_at` is rejected with `absolute_lifetime_exceeded`, distinctly from ordinary `session_expired`; a rotation computed under an injected clock where the ordinary `now + 24h` sliding calculation would land past `absolute_expires_at` produces the capped value instead, never the uncapped one; two concurrent rotations of the same session near the absolute ceiling serialize correctly (§2.5) and never produce two divergent `expires_at` values from a stale read; `authenticated_at` is confirmed unchanged after a rotation that also exercises the absolute-lifetime cap, proving the two mechanisms don't interfere with each other; a rotation immediately after a lost-response scenario (§2.4) still fails closed — the caller must fall back to a full new SIWA handshake, which correctly establishes a brand-new `absolute_expires_at`, never an extension of the old chain's. **No real family or child data in any fixture, anywhere in this test matrix.**

This document does not redesign or retest the already-merged claim-proof functionality (`issue_claim_challenge`/`load_claim_verification_context`/`consume_claim_challenge`/`claim_device_grant`) — those remain exactly as verified in Stage D.

---

## 8. Outstanding Product Owner decisions

Separated explicitly from the technical choices this document does settle:

1. Session lifetime numbers (§2.3: 24h sliding / 30-day max) and the sensitive-operation freshness window (§2.6: 10–15 min) — only the numbers remain open; the mechanism that makes the 30-day figure actually enforceable across repeated rotations (`absolute_expires_at`, §2.2/§2.4) is settled engineering design, not itself a pending decision.
2. Operator-preauthorization approach: confirm B over C (§4.1).
3. Who acts as operator, and the exact out-of-band channel for relaying redemption codes (§4.2).
4. Who is authorized to invoke binding revocation, and under what evidentiary standard (§5.6) — explicitly not decided here.
5. Whether device-bound Parent sessions (§2.6's deferred option) are ever required, and on what timeline.
6. Whether an out-of-band "connection approved" notification is worth building as a follow-up (§2.6).

Technical choices made in this document, open to review but not requiring product-level sign-off: SHA-256 for all hashing; eager nonce consumption (§1.5); the four-layer header separation (§3.3); `verify_jwt=false` for every new function (§3.2); no new SwiftData model (§6); enforcing absolute session lifetime by carrying `absolute_expires_at` forward by value across rotations and capping each rotation's `expires_at` at that inherited ceiling, server-computed from `clock_timestamp()` only, rather than introducing a separate session-family/lineage model (§2.2/§2.4).

---

## 9. Implementation sequence

| Slice | Scope | Depends on |
|---|---|---|
| A | Parent authentication: `parent_auth_nonces`, `parent_sessions`, their functions, `auth-nonce`/`parent-auth-complete`/`refresh`/`revoke` functions | SIWA verifier (done) |
| B | Enrollment redemption transaction (§5) + `cancelled_at`/binding-revocation functions | A |
| C | Operator issuance mechanism (§4) | B |
| D | iOS: new auth module, SIWA UI, Keychain, redemption call | A–C |

---

## 10. Cross-references

See [the authorization architecture](AthleteConnectionV1-Authorization.md) for the outer approved boundaries this document operates inside, [the decision ledger](AthleteConnectionV1-DecisionReview.md) for D1–D4, and [the technical protocol review](AthleteConnectionV1-TechnicalProtocolReview.md) for the pieces of the original engineering proposal (hydration, escrow, CloudKit revocation) this document does not touch. This document is the canonical, reviewed technical contract for Parent authentication and existing-workspace enrollment specifically — it does not claim to close any other gap tracked in [issue #98](https://github.com/cristern/Voxtr/issues/98).
