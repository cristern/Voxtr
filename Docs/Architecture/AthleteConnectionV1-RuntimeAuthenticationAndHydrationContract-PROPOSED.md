# Athlete Connection V1 — proposed runtime authentication and hydration contract

**Status: PROPOSED ENGINEERING CONTRACT — NOT APPROVED. Documentation only.** Product Owner authorized bounded discovery and documentation of this dependency on 2026-10-03 (`cristern/Voxtr#107`, comment `issuecomment-5966620681`); that authorization covers writing this document, not implementing it. Two ChatGPT review rounds on PR #108 ([round 1](https://github.com/cristern/Voxtr/pull/108#issuecomment-5967090837), [round 2](https://github.com/cristern/Voxtr/pull/108#issuecomment-5968416078)) requested changes; this revision addresses every finding from both — see §10 for the finding-to-change map. This file does not supersede, compete with, or stand equal to the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) (D1–D4, approved) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md) (approved, merged). It proposes the **next**, currently undocumented layer. No code, migration, endpoint, hosted deployment, or merge follows from this document.

## 0. What this document is and is not

- A single, clearly marked proposed contract, linked from the canonical documents, not a second independently authoritative one.
- Reuses the existing device-possession primitive (`KeychainAthleteDeviceSigningKeyStore`, P-256) and extends, rather than replaces, the existing backend canonical-message wire pattern.
- Does not re-litigate D1–D4, Parent authentication, or the approved 24-hour D2 recovery window. Builds on top of the existing `authz.device_grants` row.
- Keeps [issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates open; promises no physical backup erasure.
- Touches no legacy CloudKit pairing/acceptance screen, activates no membership, removes no accepted `CKShare`.
- **Naming note:** this proposal's backend session concept is named **device-authorization session**, never "runtime session" — the existing, unrelated `AthleteRuntimeSession` class (`Sources/VoxtrAppShell/AthleteRuntimeSession.swift`, Foundation B2.5, the CKShare-acceptance runtime-presence holder) is a different, already-shipped thing this proposal does not touch.
- **Modifications to already-shipped functions, flagged explicitly where proposed.** Most of this proposal is purely additive (new tables, new functions). Two places (§4.2, §4.5) propose a small, explicitly-flagged additive change to an already-merged function's own body (`decide_connection_request` is explicitly *not* changed; `revoke_device_grant` is proposed to gain one additional same-transaction statement) — called out individually, not left implicit, since CLAUDE.md requires preserving previously accepted behavior unless a task explicitly changes it.

## 1. Closed milestone — repository facts

| Repo | PR | Title | Merge state | SHA |
|---|---|---|---|---|
| `cristern/Voxtr-Backend` | [#10](https://github.com/cristern/Voxtr-Backend/pull/10) | Parent-authenticated device grant listing/revocation | merged to `develop` | `5cdac7d39aacc5e298ee06f62c3d06f18e8e88d9` |
| `cristern/Voxtr` | [#106](https://github.com/cristern/Voxtr/pull/106) | Athlete Connection iOS pairing (QR scan → claim) | merged to `develop` | `4df62923549a3538cb81b66788f5777a19880579` |

Both SHAs independently confirmed via `git fetch origin develop`. Neither PR establishes device-authorization sessions, hydration, membership activation, or CloudKit revocation. Two other documentation PRs ([#104](https://github.com/cristern/Voxtr/pull/104), [#85](https://github.com/cristern/Voxtr/pull/85)) remain open/unmerged and are not reconciled here.

## 2. Current-state inventory — repository facts, not proposals

### 2.1 Athlete device-possession primitive (existing, reused)

`KeychainAthleteDeviceSigningKeyStore`: installation-specific P-256 key (Secure Enclave where supported), Keychain-stored, installation-marker-matched. `loadOrCreateSigningKey()` starts a new attempt; `loadExistingSigningKey()` continues one already bound to a key and throws rather than minting a replacement. Public key: 65-byte X9.63. Signature: 64-byte raw `r‖s`.

### 2.2 Backend wire pattern, confirmed schema, and confirmed lock orders (existing)

`_shared/canonicalMessage.ts`: a frozen five-line canonical message for claim-submit specifically (version line + `challenge_id=`/`request_id=`/`invitation_id=`/`nonce=`).

**Cross-implementation evidence — direction corrected (round 2 finding §5).** `Tests/VoxtrSprint0Tests/AthleteConnectionCrossImplementationFixtureTests.swift`'s own reproducible script, read again this round, shows: a throwaway P-256 key pair and signature are generated **in Deno** (`crypto.subtle.generateKey`/`crypto.subtle.sign`, WebCrypto), the backend's own unmodified `verifyP256Signature` confirms that signature (`{ok:true}`), and **only then** are those frozen bytes checked with Swift CryptoKit. The proven direction is **Deno signs → Deno verifies (self-check) → Swift verifies** — i.e. it establishes that Swift's *verification* is compatible with Deno's wire format and curve/encoding conventions for this one message shape. It does **not** establish the direction that actually matters in production — **Swift signs (via the real device key) → Deno verifies** — which `AthleteDeviceAuthorizationService.swift` performs every day against the live claim-submit function, but which is exercised only by real Docker-backed integration tests or physical TestFlight runs, never by this frozen unit-test fixture. Both directions share the same wire format, so the fixture is genuine partial evidence, but this document no longer overstates which half it covers.

Confirmed schema (`20260923060545_authz_schema_v1.sql`):
- `authz.connection_requests`, `authz.claim_challenges`, `authz.device_grants` (`invitation_id` `UNIQUE`, composite FKs to request/invitation/device-key and to invitation/workspace/athlete) — as before.
- `authz.parent_sessions` — two-axis shape (`authenticated_at`/sliding `expires_at`/hard `absolute_expires_at`) this proposal's own session table mirrors.

**Confirmed lock orders, re-read from source this round (not assumed):**
- `authz.claim_device_grant`: **first claim** locks only `authz.invitations` row `FOR UPDATE` for its entire transaction, then `INSERT`s a brand-new `device_grants` row — there is **no** `device_grants` row to lock yet on this path (round 2 correction: round 1 incorrectly described first-claim as locking a grant row). **Retry of an already-claimed request** additionally locks the now-existing `device_grants` row `FOR UPDATE`, by id.
- `authz.decide_connection_request` (Parent approval/rejection): locks `authz.parent_sessions` row → **the SAME `authz.invitations` row** `FOR UPDATE` — its own header comment states this explicitly: *"the SAME resource `authz.claim_device_grant` and `authz.submit_connection_request` also lock"* — then a plain, non-locking read of the targeted `connection_requests` row, then `authz.workspace_owner_bindings` row `FOR UPDATE` last, with every time-based outcome decided from one `clock_timestamp()` read taken after that last lock.
- `authz.revoke_device_grant`: `authz.parent_sessions` row → session-only Gate 1 → `authz.device_grants` row `FOR UPDATE` → (only if found) `authz.workspace_owner_bindings` row `FOR UPDATE`.

The fact that `decide_connection_request` and `claim_device_grant` already serialize against each other through the **same** invitation-row lock is the mechanism §4.2 below builds on for the approval/staging/claim ordering problem — not a new lock this proposal invents.

`AthleteDeviceAuthorizationService.swift` confirms the gateway convention (Supabase `apikey`/anon-key headers, no Parent-session header, snake_case wire, single-vocabulary errors).

### 2.3 Pairing handoff point (existing)

`.authorized(grantId: UUID)` is where this proposal begins.

### 2.4 Hydration pipeline and bootstrap field inventory (existing, identity mapping corrected round 1, unchanged this round)

`AthleteIdentityHydrationService.hydrate(_:)`: six steps, `hydrateParent` → `hydrateWorkspace` → `hydrateOwnerParticipant` → `hydrateAthleteProfile` → `hydrateAthleteParticipant` → `hydrateAccessGrant`. `intendedParticipantId` is the selected **athlete's** own `WorkspaceParticipant.id` (role `.athlete`); `ownerParticipantId` is the Parent's. `hydrateAccessGrant` creates a local `AthleteAccessGrant(participantId: ownerParticipantId, athleteId: intendedAthleteId)` — a **business permission** record (owner participant → athlete), never device authorization. `parentGivenName` is required and non-fabricable (`ParentProfile.givenName: String`, non-optional). `familyName`/`preferredName` are genuinely optional and never supplied today.

**Membership-activation fact, stated precisely (round 2 finding §5):** `hydrateOwnerParticipant` **does** create the owner's own `WorkspaceParticipant` directly as `.active` — this is existing, approved, already-shipped behavior, not a defect. What must never happen, and what §6's tests actually check, is the **athlete's** own participant being created or transitioned to `.active` by hydration — it is always created `.invited`, left untouched if it already exists, and the canonical `.invited → .active` transition remains exclusively `AcceptWorkspaceInvitationService`'s job. "No unauthorized membership activation" in this document means athlete-participant activation specifically, not owner-participant creation.

`AthleteDeviceAuthorizationReceipt` remains metadata-only.

## 3. PROPOSED — Athlete device-authorization session contract

### 3.1 What already exists and is not re-proposed

D2's fixed 24-hour `authz.device_grants.recovery_deadline` same-installation recovery window is unchanged by this proposal.

### 3.2 Proposed tables

- `authz.device_authorization_sessions`: `id`, `device_grant_id` (`NOT NULL REFERENCES authz.device_grants(id)`), `token_hash`, `created_at`, `authenticated_at` (set once at issuance, carried forward unchanged by renewal), `expires_at`, `absolute_expires_at`, `revoked_at`. Mirrors `parent_sessions`' two-axis shape.
- `authz.device_session_challenges`: `id`, `device_grant_id`, `action` (`CHECK (action IN ('session_issue','session_renew','hydration_get','hydration_ack'))`), `session_id` (`REFERENCES authz.device_authorization_sessions(id)`, **nullable only for `session_issue`** — every other action binds to the exact presented session, closing round 2 finding §1's "bind renewal/get/ack proof to the exact presented session"), `nonce` (`BYTEA`), `created_at`, `expires_at` (`= created_at + 60s`), `used_at`.

Every operation re-verifies at query time: `device_grants.status = 'active' AND revoked_at IS NULL` for the target grant, and (for session-bound actions) that the presented session is itself unrevoked/unexpired **and** that `session.device_grant_id = challenge.device_grant_id = <the grant named in the request>` — i.e. `session.grant == challenge.grant == target grant`, exactly as round 2 requested.

### 3.3 Proposed wire protocol — made executable on paper (round 2 finding §1)

**The circularity round 2 caught, and why the fix is to drop the body-binding field rather than patch it:** round 1's canonical message included `body_sha256` ("hash of the exact request body bytes"), but the issuance submit call carries the signature *inside* that same JSON body — making the signature depend on a hash of a body that contains the signature itself. Rather than invent an unsigned-envelope scheme to rescue that field, this revision removes `method`/`path`/`body_sha256` entirely: **none of the four actions carry mutable business content beyond the identifiers already bound in the message** (`device_grant_id`, `challenge_id`, `nonce`, and now `action`) — there is nothing left for a body hash to protect that isn't already covered. This also matches the already-approved, already-shipped claim-submit precedent, which never bound method/path/body either. If a future action genuinely needs to bind variable content, that action's own message gets its own additional field at that time — not a generic field every action carries whether or not it means anything.

**Canonical message, per action** (extends, not replaces, the existing five-line pattern):

```
voxtr-athlete-<action>-v1
device_grant_id=<lowercase uuid>
challenge_id=<lowercase uuid>
nonce=<base64url, no padding>
```

Byte-exact rules, stated explicitly (mirroring `_shared/canonicalMessage.ts`'s own documented choices): UTF-8 encoding; every line, including the last, terminated by a single `\n`; no other separators; UUIDs lowercased regardless of input casing; nonce base64url per RFC 4648 §5 with no padding; the version line is one of exactly `voxtr-athlete-session-issue-v1` / `voxtr-athlete-session-renew-v1` / `voxtr-athlete-hydration-get-v1` / `voxtr-athlete-hydration-ack-v1`, never a fifth value. A message built with any other byte sequence (extra whitespace, missing final newline, uppercase UUID) is rejected by construction — the verifier recomputes the exact expected bytes server-side and never trusts a client-supplied canonical string.

**Two functions, mirroring claim-challenge/claim-submit's own existing separate-issue/separate-submit shape:**

- **`device-session-challenge`** (issue). Request: `{device_grant_id, action, session_token}` — `session_token` omitted only for `action = "session_issue"`. Response: `{outcome: "issued", challenge_id, nonce, expires_at}` | `{outcome: "grant_not_active"}` | `{outcome: "session_invalid"}` (covers missing/expired/revoked `session_token` when one was required).
- **`device-session-submit`** (consume + perform). Request: `{device_grant_id, challenge_id, action, signature, session_token}` (`session_token` omitted only for `session_issue`). Response is action-specific:
  - `session_issue`/`session_renew` → `{outcome: "issued"|"renewed", session_token, expires_at, absolute_expires_at}` | `{outcome: "challenge_invalid"}` | `{outcome: "grant_not_active"}`.
  - `hydration_get` → `{outcome: "available", <snapshot fields>}` | `{outcome: "not_yet_staged"}` | `{outcome: "already_completed"}` | `{outcome: "deadline_passed"}` | `{outcome: "grant_revoked"}`.
  - `hydration_ack` → `{outcome: "acknowledged"}` | `{outcome: "already_completed"}` | `{outcome: "deadline_passed"}` | `{outcome: "grant_revoked"}`.

**Verification/consumption ordering** (mirroring `claim-submit`'s own existing pattern): lock the `device_session_challenges` row `FOR UPDATE` by `challenge_id` → reject if `used_at IS NOT NULL` or `clock_timestamp() >= expires_at` (checked *after* this lock, not before) → reject if the request's `action` does not match the challenge's stored `action` → for a session-bound action, reject unless the presented `session_token`'s hash matches the challenge's `session_id` **and** that session's `device_grant_id` matches the request's `device_grant_id` → verify the signature against `device_grants.device_public_key` for that exact `device_grant_id` over the recomputed canonical message → mark `used_at` (consumption happens here, before the action's own effect, so a crash after consumption but before the effect fails closed rather than allowing a second attempt to redo the effect) → perform the action's own effect under the lock order in §4.6.

**Replay handling, defense in depth:** a consumed challenge is rejected by the `used_at` check alone; independently, replaying an old, still-valid signature against a *different*, unconsumed challenge fails signature verification itself, because that challenge's own fresh `nonce` is embedded in the new challenge's canonical message and will not match the signature produced over the old one. Neither check alone is relied on exclusively.

**Lost-response retry:** if the HTTP response to `device-session-submit` is dropped after the backend already consumed the challenge and performed the effect, the device cannot retry with the same (now-used) challenge — it requests a fresh one for the same action. `session_issue`/`session_renew`/`hydration_get` are safe to retry this way (idempotent net effect or pure read); `hydration_ack`'s retry lands on the existing `already_completed` outcome (§4.4), never re-performing or erroring.

**Swift↔Deno vectors — none exist yet, stated honestly (round 2 finding §1):** each of the four action-bound message shapes needs its own frozen fixture, built the same way as the existing one (§2.2) — a throwaway key signs in Deno, the backend's own verifier confirms it, the frozen bytes are then checked against Swift CryptoKit — **before** any of this is trusted as interoperable. None of these four fixtures exist today; this document does not claim otherwise.

### 3.4 Proposed issuance/renewal flow — device proof required on every sensitive call

1. **Issuance**: challenge for `(device_grant_id, action='session_issue')` (no session yet) → signed submit → verified against `device_grants.device_public_key` → session row created.
2. **Renewal**: challenge for `(device_grant_id, action='session_renew')`, **bound to the caller's current session** → signed submit, presenting both the current bearer token and the fresh signature → `expires_at` rotated via `LEAST(clock_timestamp() + <sliding>, absolute_expires_at)`, `authenticated_at` unchanged. Bearer-token-only renewal is not an option this document leaves open (§9.1).
3. **Hydration get/ack** (§4.3) use the same session-bound challenge/submit pair with their own actions — a stolen bearer token alone can neither read nor acknowledge/erase bootstrap data without the signing key.
4. **Storage**: device-only Keychain, never UserDefaults.

### 3.5 Automatic technical renewal vs. genuine Parent re-pairing, with concrete bounded defaults (round 2 finding §4)

**Automatic renewal** happens silently as long as the key and grant remain valid — the device signs its own fresh, action-bound challenge with a key it already holds; no Parent/user involvement, at any point, including long after D2's 24-hour deadline has passed. **Parent/user involvement is needed only when:** the grant is revoked; the signing key/installation is lost (reinstall, detected via the existing installation-marker mismatch); or this is a brand-new installation that never held a grant.

**Concrete bounded proposal (PROPOSED default, pending Product Owner approval — a specific number, not "measured in days"):** a 7-day sliding `expires_at`, renewed automatically whenever more than half the window has elapsed, and a 90-day hard `absolute_expires_at` ceiling from issuance. At the absolute ceiling, or on any renewal failure (lost bearer token, corrupted session row), the device does **not** attempt `session_renew` — it falls back to `session_issue` with a fresh signature from the **existing** installation key, which works at any time the grant remains active, including well after D2's deadline, and which never reopens, re-associates, or re-fetches the (by then tombstoned, §4.5) hydration snapshot and never revives the invitation. Hydration is a one-time bootstrap event, fully decoupled from ongoing session issuance/renewal.

**Only one design is proposed, not two.** Round 1's "Alternative B" (bearer-only renewal, no independent trust boundary) is removed as an eligible alternative — §3.4 already mandates fresh signature proof on every renewal, so a design that renews from the bearer token alone cannot coexist with it; keeping it as a nominal "alternative" was the self-contradiction round 2 flagged. §9.1 below keeps it only as rejected history, not a live choice.

**Stolen-bearer vs. stolen-key/device, stated precisely:** session/token expiry bounds exposure of a bearer token leaked *without* the key — such a token eventually stops working on its own, and in this design cannot even be *renewed* without the key (§3.4.2). It does not bound compromise of the actual device/key: an attacker who has the key can mint fresh sessions indefinitely via `session_issue`, regardless of any TTL, until the Parent revokes the grant. Automatic signing does not decide whether the grant itself persists — those are two independent facts, not one.

## 4. PROPOSED — hydration upload/get/ack lifecycle

### 4.1 Why upload must be Parent-pushed, not backend-pulled

Unchanged from round 1: the backend stores none of the business fields needed and cannot source them independently.

### 4.2 Proposed upload/association model — symmetric, race-closed (round 2 finding §2)

**What round 1 got wrong, and why a simple "stage before claim" ordering isn't enough on its own:** `decide_connection_request` (approval) and `claim_device_grant` (claim) already serialize against each other through the shared invitation-row lock (§2.2) — but that only prevents corruption from *concurrent* interleaving, not the *sequencing* problem round 2 raised: a Parent can approve, and the Athlete device can claim, **before** the Parent's own separate `hydration-upload` call ever lands — there is no database-enforced rule that staging must happen before claiming, because they are two independently-timed network calls from two different devices.

**The fix is symmetry, not ordering.** `hydration-upload` (proposed, Parent-session-authenticated — `X-Voxtr-Parent-Session`) is defined to work correctly **regardless of which happens first**:

1. **Lock the same shared resource everything else in this flow already locks**: `authz.invitations` row `FOR UPDATE`, by `invitation_id` — the identical resource `decide_connection_request`/`claim_device_grant`/`submit_connection_request` already lock, so `hydration-upload` is correctly serialized against concurrent approval, claim, and revocation on the exact same invitation, closing round 2's "competing upload replacement" and "expiry/revoke during contention" cases through the same mechanism every other writer here already uses — not a new one.
2. **Look up whether a `device_grants` row already exists** for this `connection_request_id` (it will, if claim already happened).
   - **If it exists** (claim-before-upload case): write directly into `authz.hydration_snapshots` keyed by `device_grant_id`, governed from the start by that grant's existing `recovery_deadline` — no staging step at all on this path.
   - **If it does not exist yet** (upload-before-claim case, the common one): stage the row keyed by `connection_request_id`, with a composite FK `(connection_request_id, invitation_id)` into `authz.connection_requests` (mirroring `device_grants`' own `dg_request_invitation_devicekey_fk` pattern). Pre-grant retention reuses the invitation's own existing 15-minute expiry — no new, separately-tracked deadline (open to a different Product Owner choice, §9.3).
3. **Association, symmetric on the other side too**: the moment `claim_device_grant` successfully `INSERT`s a new `device_grants` row, it also updates the matching `hydration_snapshots` row (if one was already staged for that `connection_request_id`) to carry the new `device_grant_id` — performed under the **same `authz.invitations` row lock `claim_device_grant` already holds for its entire transaction** (round 2 correction: not a `device_grants` row lock, which does not exist on the first-claim path — see §2.2). If no snapshot was staged yet, this step is simply a no-op; `hydration-upload`, when it eventually arrives, finds the `device_grants` row already present (step 2's first branch) and associates directly.
4. **`hydration-get` gets a genuine "not yet staged" outcome** (§3.3), not an error, for the gap where a device has an active grant but no snapshot has arrived yet — the device is expected to retry, exactly as it already polls for approval today. This, not a client-trusted call-order assumption, is what actually closes the race: there is no window in which the *absence* of a snapshot is treated as a hard failure instead of a recoverable, poll-able state.
5. **Interruption/retry, precisely:** a retried `hydration-upload` for a still-unclaimed, still-staged `connection_request_id` with the **same** payload bytes is accepted as a no-op; with **different** bytes, it is rejected (`payload_mismatch`) rather than silently replacing already-staged content — "idempotent replace" means safe retry of the identical attempt, not an open door to overwrite. Once a row is associated to a `device_grant_id` or tombstoned (§4.5), it is immutable: any further upload against that `connection_request_id` or `device_grant_id` is rejected outright, matching round 1's own immutability intent but now stated against the corrected, symmetric model.
6. **Parent interruption before any upload** (approves, then the app is killed before uploading): the snapshot never exists; `hydration-get` returns `not_yet_staged` until the invitation's 15-minute window (if unclaimed) or the grant's 24-hour `recovery_deadline` (if already claimed) passes, after which it is simply unavailable and the Parent must restart the connection.

### 4.3 Get and ack — both device-proof-gated

Both go through `device-session-submit` with their own action (§3.3), requiring a valid, grant-active session **and** a fresh signature — never a bearer token alone. `hydration-get` denies with `deadline_passed` once `clock_timestamp() >= recovery_deadline` (`>=`, matching `parent_sessions`' own boundary convention). `hydration-ack` is called only after `AthleteIdentityHydrationService.hydrate(...)` completes successfully end-to-end.

### 4.4 Idempotency

A second `ack` against an already-tombstoned grant returns `already_completed`, reusing `claim-submit`'s own `granted`/`already_granted` idempotency fold rather than a new shape for the same question.

### 4.5 Completion model and deletion triggers — three reasons, one mechanism, atomic with revocation (round 2 finding §3)

On completion, the row's PII columns are cleared and replaced with a non-PII tombstone: `device_grant_id`, `completed_at`, **`reason`** (`'acked'|'expired'|'revoked'`, new column added this round so the three triggers remain distinguishable afterward, per round 2's request). `hydration-get`/`hydration-ack` map `reason` to the matching outcome (`already_completed` only for `'acked'`; `deadline_passed` for `'expired'`; `grant_revoked` for `'revoked'`) — all three forbid any further upload or payload recreation identically.

Three triggers, stated without the round-1 confusion about locks surviving a commit:

1. **Verified ack** — the normal path, tombstoned `reason='acked'`.
2. **Deadline passed** — enforced synchronously by the read-denial in §4.3 regardless of cleanup-job timing; a best-effort job later tombstones the row `reason='expired'`.
3. **Grant revocation** — **proposed additive change to `revoke_device_grant`'s own function body** (flagged explicitly, per §0): add one more statement, inside the *same* transaction and under the *same* `device_grants` row lock that function already holds for its own purposes, that tombstones any matching `hydration_snapshots` row `reason='revoked'`. This is genuinely atomic with the revocation because it is the same commit — not, as round 1 imprecisely said, "an immediately-following step under the same row lock" (no lock survives past a commit; the fix is doing both writes in one transaction, not chaining two).

### 4.6 Authorization and concurrency boundaries — completed (round 2 finding §3)

**Owner-binding check, made uniform, with the exact open question separated out.** Round 1 checked `workspace_owner_bindings` is active only on `hydration-upload`; round 2 asked for it on issuance/renewal/get/ack too. This revision adds the identical check — `workspace_owner_bindings WHERE workspace_id = ... AND revoked_at IS NULL FOR UPDATE` — to every one of these operations, for consistency with `revoke_device_grant`'s own existing check. **What this check does *not* do, stated honestly:** `authz.device_grants` has no column recording *which* owner-binding approved it, only `workspace_id` — so this check (identical to the one `revoke_device_grant` already runs) confirms *some* binding is currently active for the workspace, not that it is the *same* binding that approved this specific grant. Whether an owner-account change should automatically invalidate pre-existing grants, or leave them valid under the new owner (today's status quo, unchanged by this proposal), is recorded as a genuinely open product question in §9.4 rather than decided here.

**Per-operation lock order** (every new function, confirmed never to reverse an existing pair from §2.2):

| Function | Lock order |
|---|---|
| `device-session-challenge` (`session_issue`) | `device_grants` row → `workspace_owner_bindings` row → insert challenge |
| `device-session-challenge` (other 3 actions) | `device_authorization_sessions` row (by token) → `device_grants` row → `workspace_owner_bindings` row → insert challenge |
| `device-session-submit` | `device_session_challenges` row → (`device_authorization_sessions` row, if session-bound) → `device_grants` row → `workspace_owner_bindings` row → action effect (session row insert/update, or `hydration_snapshots` row) |
| `hydration-upload` | `parent_sessions` row → `authz.invitations` row (shared resource, §4.2.1) → `workspace_owner_bindings` row → `hydration_snapshots` row |

**Fresh-clock rule, stated as a named rule, not left implicit:** every time-based outcome (expiry, deadline, challenge TTL) is decided from a single `clock_timestamp()` read taken **after the last lock in that function's own order above**, never an earlier one — the same discipline `decide_connection_request`'s own confirmed implementation already uses (§2.2).

**Target-independent public errors and privileges**: unchanged from round 1 — anti-enumeration ordering copied from `revoke_device_grant`'s own round-1 fix; all three new tables are private `authz` schema, no direct `anon`/`authenticated` access.

**Serialization boundary, restated precisely by lock-acquisition/commit order, not request-arrival order (round 2 correction):** this is ordinary MVCC row-locking. The property that actually holds is: an operation whose relevant lock acquisition on `device_grants` (or `workspace_owner_bindings`) happens **after** a revocation's commit will observe the revoked state and must fail; an operation that acquired that same lock and read the pre-revocation state **before** the revocation's commit may legitimately complete, regardless of which HTTP request nominally arrived first in wall-clock terms. The previous wording ("check sequence begins after commit") conflated request-arrival timing with lock-acquisition timing — this is the corrected, Postgres-accurate statement.

**Tests added for this section**: wrong device key; stolen bearer presented with no signature; a challenge issued for one action submitted against a different action; session presented whose `device_grant_id` does not match the request's own `device_grant_id` (closing the `session.grant == challenge.grant == target grant` requirement); owner-binding revoked/replaced between staging and association; owner-binding revoked between issuance and a device-side call that the status-quo check (above) correctly still allows (documenting, not hiding, the "any active binding" property); the `>=` deadline boundary at exact equality; revocation-purges-snapshot-in-the-same-transaction (no window where a revoked grant's snapshot is still readable); private-bridge privilege-denial checks for all three new tables.

## 5. CloudKit / legacy pairing boundary — repository-grounded inventory, corrected and completed (round 2 finding §5)

**Record types, qualified correctly.** Exactly two Vǫxtr-**defined** `CKRecord` `recordType` values exist repo-wide — `FamilyWorkspace` and `AthleteConnectionInvitation` — confirmed by grep and by `CloudKitTransport.swift`'s own repo-wide-audit comment ("no `recordType` for `PlannedActivity`/`LoggedActivity`/etc. exists anywhere... Planning/Training/Reflection/etc. domain modules never import CloudKit at all"). **Qualification added this round:** `CKShare` itself is a separate, Apple-provided `CKRecord` subclass that exists independently of this count — both the per-invitation share and the separate, reusable `FamilyWorkspace`-root share (below) are `CKShare` instances. "Exactly two record types" refers only to Vǫxtr's own domain mappings, not to the total count of CKRecord-family objects in play.

**Two distinct `CKShare` roots exist, with only one confirmed consumer found.** `AthleteConnectionOwnerHandoffService.prepareInvitation` creates one independent, per-invitation `CKShare` rooted on the `AthleteConnectionInvitation` record (§2.4) — its actual acceptance/resolution consumer is `FamilyWorkspaceParticipantShareCoordinator.resolveAcceptedShare(from:)`, which accepts (or resolves an already-accepted) share, reads `metadata.hierarchicalRootRecordID`, and calls `database.record(for:)` directly against `CKContainer.sharedCloudDatabase` to fetch that invitation record — exactly the pairing-only flow this proposal's device-authorization/hydration layer replaces the business-field *content* of (§5, adapter note below), not the transport mechanism itself. Separately, `FamilyWorkspaceOwnerShareCoordinator` (B2.1) creates its own, independently reusable, idempotent `FamilyWorkspace`-root share, documented in this codebase as reserved "for whatever later, genuinely family-wide sharing scope needs" — within this bounded inventory, no participant-side acceptance consumer for *that* specific share was found; this is reported as "none found in this grep-bounded pass," not asserted as "none exists."

**Transport/database scope, confirmed:** two independent `CKSyncEngine` instances — `privateEngine` (→ `CKContainer.privateCloudDatabase`, where an owner's own zone lives) and `sharedEngine` (→ `CKContainer.sharedCloudDatabase`, through which an Athlete device reaches the Parent-owned zone after share acceptance). **Sync-engine delegate behavior, confirmed from source:** `CloudKitTransport.ScopedDelegate.handleEvent` persists only `.stateUpdate` events and logs every other event type as "not yet mapped"; `nextRecordZoneChangeBatch` always returns `nil`, honestly, because no local write path creates a `CKRecord` change yet. Two running sync engines, by themselves, do not establish any actual business-data delivery — there is no outgoing batch logic and no handling for incoming record changes beyond state bookkeeping.

**Exact enforceable boundary under this proposal — unchanged in substance:** backend revocation blocks new device-authorization-session issuance/renewal and both hydration calls; it does not retroactively invalidate `CKRecord`s already delivered via `sharedCloudDatabase`, recall offline bytes, activate/remove membership, or retire the legacy acceptance screen. [Issue #98](https://github.com/cristern/Voxtr/issues/98) gate C, unchanged.

**Domain-neutral hydration adapter, unchanged recommendation:** a new adapter should translate a `hydration-get` response into the existing `AthleteConnectionInvitationCloudRecordPayload` shape, so `AthleteIdentityHydrationService.hydrate(_:)` itself needs no change and the legacy CKShare-sourced path remains intact.

## 6. Current, superseded status pointers — corrected attribution (round 2 finding §5)

**Round 2 correction:** this section previously claimed the normative security contract's own §7 ("Backend PR #5 merged the independent SIWA verifier only; HTTP authentication, nonce/session storage and enrollment are not implemented") was superseded by a *later section of that same document*. That is wrong — re-checked this round: [the normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) has no later internal section that updates §7's claim at all; the superseding information ("Backend Parent authentication and enrollment checkpoint — 2026-09-28" and later) lives entirely in the **separate** [project-status document](../AthleteConnectionV1-ProjectStatus-2026-09-21.md). Corrected pointer: §7 of the normative contract and §6's "Swift CryptoKit ↔ Deno interoperability is not yet tested" (both dated) are superseded by the separate project-status document's later checkpoints and by §2.2 above, not by anything else inside the normative contract itself. The normative contract's own §8 (added round 1) has been updated to carry this corrected pointer; neither §6 nor §7's historical text is edited.

## 7. Proposed test and evidence gates

Repository facts / CI evidence / unverified provider-hosted behavior / product choices, as before, with round 2's required additions folded in (marked **new**):

### 7.1 SQL
- Structural `CHECK`s for the three new tables, mirroring existing patterns; the 6-case unknown/own/foreign × 5-session-state matrix pattern applied to the new functions.
- **New**: wrong key; stolen bearer with no signature; cross-action replay; session/challenge/grant mismatch (§4.6); owner-binding revoked/replaced at each stage; `>=` boundary equality; revocation-purges-snapshot-same-transaction; private-bridge privilege denial for all three tables.
- iOS: sibling/foreign-family isolation, each relational-conflict case, partial-hydration-retry, and the corrected athlete-only no-activation assertion (§2.4) that explicitly does not flag the owner's own `.active` creation as a defect.

### 7.2 Concurrency
- Session-renewal-under-contention; revoke-races-issuance/renewal/get/ack; **upload-races-claim in both orderings** (§4.2, replacing round 1's one-directional version); recovery-deadline-boundary-during-contention.

### 7.3 HTTP / live integration
- Full issue → renew (fresh signature) → revalidate → revoke → denied flow.
- Full upload-before-claim and **claim-before-upload** flows (both symmetric paths, §4.2), get → ack (`already_completed` on repeat), get-after-deadline-denied.
- No sensitive value in any non-2xx diagnostic body.

### 7.4 iOS
- Session persistence/reinstall detection; hydration retry-idempotency across the corrected staging model; no time-dependent test relies on `Date.now`/locale/CI time.

### 7.5 Hosted and two-iPhone TestFlight
- Unchanged from round 1; none of it has occurred for this proposal.

## 8. Recommended bounded implementation sequence

Unchanged in shape from round 1: (1) backend device-authorization-session slice; (2) backend hydration staging/association/get/ack slice, now correctly specified as symmetric (§4.2) rather than ordered; (3) iOS device-authorization-session client; (4) the domain-neutral hydration adapter; (5) the CloudKit/legacy-boundary integration review (§5), as its own gate; (6) two-iPhone TestFlight evidence. Alternative (combining 1+2) still not recommended, for the same reason as before.

## 9. Genuinely unresolved Product Owner decisions

### 9.1 Session renewal design — one recommended design with concrete defaults, not an open A/B choice

§3.5 proposes session-bounded renewal with mandatory fresh-signature proof on every renewal, a 7-day sliding / 90-day absolute default (PROPOSED, pending approval), and automatic `session_issue` fallback after the absolute ceiling or any renewal failure. The round-1 "grant-bounded, bearer-only renewal" alternative is **not** carried forward as a live option — §3.4 already requires fresh proof on renewal, so it cannot coexist with that alternative; it is recorded here only as rejected history, not a current choice. What remains genuinely open is the exact day-counts (7/90 are this document's proposed defaults, not approved values) and whether Internal Alpha should start even more conservative.

### 9.2 Minimum hydration field list

Unchanged: `parentGivenName` is required, not optional (§2.4). The open question is only whether `familyName`/`preferredName` should be populated.

### 9.3 Pre-grant staging retention bound

Unchanged: §4.2 reuses the invitation's existing 15-minute expiry rather than a new, separately-tracked bound; whether the Product Owner wants a separate bound instead is open.

### 9.4 Owner-binding identity on an existing grant (new, round 2 finding §3)

§4.6's uniform owner-binding check confirms *some* binding is active for the workspace, not that it is the *same* binding that approved a specific, already-issued `device_grants` row — `device_grants` has no column recording which binding approved it. Whether an owner-account change should automatically invalidate every pre-existing device grant for that workspace, or leave them valid under the new owner (today's unchanged status quo), is a genuine product decision this document surfaces rather than invents an answer to.

### 9.5 CloudKit/legacy screen retirement timing

Unchanged: out of scope, confirmed open, issue #98 gate C.

## 10. ChatGPT review — finding-to-change map, both rounds

### Round 1 (reviewed HEAD `a422ec31d3a55bad1fd084687c55840c86c22487`)

| Finding | Change made |
|---|---|
| Device proof | Action-bound challenge/proof added; bearer-only renewal/get removed. |
| Identity facts | `intendedParticipantId`/access-grant/`parentGivenName` corrected against source. |
| Upload ordering/durability | Stage-at-approval/associate-at-claim chosen; tombstone model; `>` → `>=`. |
| Authorization/concurrency | Owner-binding, lock order, serialization statement added. |
| Renewal vs. re-pairing | Separated explicitly; stolen-bearer-vs-key distinction stated. |
| CloudKit/status evidence | Record-type/transport inventory added; naming collision flagged. |

### Round 2 (reviewed HEAD `7159c95976a5ecc6b7e67139fe53095d1ceebf96`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5968416078))

| Finding | Change made |
|---|---|
| §1 Executable proof protocol | Removed the circular `body_sha256` field (signature-in-body made it self-referential); defined exact two-function wire shapes, byte-exact canonical-message rules, session-binding on 3 of 4 actions, consumption/replay/retry ordering; stated plainly that no new fixtures exist yet. |
| §2 Approval→staging→claim race | Replaced the one-directional "stage before claim" assumption with a symmetric model: upload checks for an already-existing grant and associates directly, or stages under `connection_request_id` for claim-time association — closing the race without assuming either call happens first. Corrected the false claim that first-claim already holds a grant-row lock (it holds only the invitation-row lock). Added `not_yet_staged` as a genuine, non-error, poll-able outcome. |
| §3 Owner-binding/lock completeness | Owner-binding check now uniform across issuance/renewal/get/ack/upload, with the "any active binding, not necessarily the same one" property stated honestly and the real open question moved to §9.4. Added a per-function lock-order table and a named fresh-clock-after-last-lock rule. Restated the serialization boundary by lock-acquisition/commit order, not request-arrival order. Moved the revocation purge into `revoke_device_grant`'s own transaction (not "a following step under the same lock," which cannot survive a commit) and added a `reason` column so acked/expired/revoked tombstones stay distinguishable. |
| §4 Renewal recommendation | Supplied concrete proposed defaults (7-day sliding / 90-day absolute) instead of "measured in days"; removed bearer-only renewal as a live alternative, keeping it only as rejected history. |
| §5 Evidence/CloudKit completeness | Corrected the cross-implementation fixture's actual direction (Deno signs/verifies, Swift only verifies — the reverse, production-relevant direction is untested by this fixture). Added the `FamilyWorkspaceParticipantShareCoordinator`/`CloudKitTransport.ScopedDelegate` call-site facts, the two-CKShare-roots note, and the CKShare qualification on "two record types." Fixed the §8 misattribution (the superseding text is in the separate project-status document, not a later section of the same normative-contract file). Scoped the no-activation test claim to the athlete participant specifically, not the owner's own already-active creation. |

## 11. Source and precedence

Product Constitution → living Architecture → ADR → Domain & Data Model → Living PRD → lower documentation → implementation, per CLAUDE.md §1. Subordinate to, and never amending, the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md). [Issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates remain open; nothing here closes any of them.
