# Athlete Connection V1 — runtime authentication and hydration contract

**Status: FINAL DOCUMENT APPROVED FOR INTERNAL ALPHA (2026-10-03).** Eight technical review rounds (§10) resolved the documented protocol findings; [round 8 verification](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969281956) found no further substantive defect. The Product Owner subsequently accepted §9.6's one-hour operational deletion target and explicitly approved merging this documentation-only PR ([decision record](https://github.com/cristern/Voxtr/pull/108#issuecomment-5971118947)). All six §9 choices are accepted. This is approval of the engineering document, not evidence of implementation, tests, migration or hosted deployment; implementation requires a separately authorized task.

## 0. What this document is and is not

- An accepted product direction for the next Athlete Connection V1 layer — how an already-approved installation (post-`claim-submit`, `.authorized(grantId:)`) subsequently proves it is still authorized, and how it receives the selected athlete's minimum bootstrap data. It is linked from the canonical documents below, not a second independently authoritative one.
- **Final document approval, documentation scope only.** The Product Owner accepted the direction (§9), then approved the final engineering document and merge on 2026-10-03 ([decision record](https://github.com/cristern/Voxtr/pull/108#issuecomment-5971118947)). The wire shapes, SQL design and test matrix remain design requirements; implementation, migration and deployment require separate authorization.
- Reuses the existing device-possession primitive (`KeychainAthleteDeviceSigningKeyStore`, P-256) and extends the existing backend canonical-message wire pattern (`_shared/canonicalMessage.ts`) rather than inventing a new device-identity mechanism.
- Does not re-litigate D1–D4, Parent authentication, or the approved 24-hour D2 recovery window — it reuses D2's existing clock rather than introducing a parallel one (§4.5).
- Keeps [issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates open; promises no physical backup erasure.
- Touches no legacy CloudKit pairing/acceptance screen, activates no athlete membership, removes no accepted `CKShare` — retirement is explicitly deferred (§5, §9.5).
- **Naming note:** this proposal's session concept is named **device-authorization session**, never "runtime session" — the existing, unrelated `AthleteRuntimeSession` class (`Sources/VoxtrAppShell/AthleteRuntimeSession.swift`, Foundation B2.5, the CKShare-acceptance runtime-presence holder) is a different, already-shipped concept this document does not touch.
- **Modifications to already-shipped functions/schema, flagged explicitly (four, all accepted per §9.4):** (1) `revoke_device_grant` gains one additional same-transaction statement tombstoning the matching `hydration_snapshots` row. (2) `decide_connection_request` gains one additional column write, capturing the approving owner-binding's id onto the `connection_requests` row at approval. (3) `claim_device_grant` gains one additional column copy, carrying that id onto the new `device_grants` row at claim, alongside the reverse hydration-snapshot association. (4) `revoke_device_grant`'s own owner-binding check moves from "any active binding for the workspace" to "the specific approving binding" — accepted for Internal Alpha, with the migration/backfill rule in §4.6.1.

## 1. Closed milestone — repository facts

| Repo | PR | Title | Merge state | SHA |
|---|---|---|---|---|
| `cristern/Voxtr-Backend` | [#10](https://github.com/cristern/Voxtr-Backend/pull/10) | Parent-authenticated device grant listing/revocation | merged to `develop` | `5cdac7d39aacc5e298ee06f62c3d06f18e8e88d9` |
| `cristern/Voxtr` | [#106](https://github.com/cristern/Voxtr/pull/106) | Athlete Connection iOS pairing | merged to `develop` | `4df62923549a3538cb81b66788f5777a19880579` |

Both SHAs independently confirmed via `git fetch`. Neither PR establishes device-authorization sessions, hydration, membership activation, or CloudKit revocation — that gap is exactly what this document fills.

## 2. Current-state inventory — repository facts, not proposals

### 2.1 Athlete device-possession primitive

`KeychainAthleteDeviceSigningKeyStore`: generates a fresh installation-specific P-256 signing key (Secure Enclave where supported, software fallback otherwise) on first use, stores it in Keychain, and writes a matching installation marker to `UserDefaults`. `loadOrCreateSigningKey()` starts a new pairing attempt; `loadExistingSigningKey()` continues one already bound to a specific key and throws rather than silently minting a replacement — distinguishing "same install, relaunch" from "reinstall, orphaned Keychain material." Public key: 65-byte uncompressed SEC1/X9.63 (`x963Representation`). Signature: 64-byte raw `r‖s` (P1363, `rawRepresentation`).

### 2.2 Backend wire pattern, confirmed schema, confirmed lock orders, and evidence layers

`supabase/functions/_shared/canonicalMessage.ts`: a frozen five-line `\n`-terminated UTF-8 canonical message for the claim-proof action — version line, then `challenge_id=`, `request_id=`, `invitation_id=`, `nonce=` (base64url). `AthleteDeviceAuthorizationService.swift`'s `canonicalMessageBytes(...)` reproduces this exactly client-side.

**Cross-implementation evidence — three distinct layers, kept separate:**

1. **Deno WebCrypto signs → real local Edge Function/Deno verification.** Covered end to end by `tests/integration/postgrest_bridge_integration.ts`, which generates its P-256 key pair and signs with `crypto.subtle.generateKey`/`crypto.subtle.sign` (Deno WebCrypto), then sends the proof through the real, unmodified local Edge Function/bridge/database stack.
2. **Deno-generated frozen bytes → Swift CryptoKit verification.** Covered by `Tests/VoxtrSprint0Tests/AthleteConnectionCrossImplementationFixtureTests.swift`: a fixed key pair/signature was generated once, interactively, in Deno; the backend's own unmodified `verifyP256Signature` confirmed it (`{ok:true}`); those frozen bytes are then checked against Swift CryptoKit on every test run.
3. **Swift CryptoKit signs (the real device key, the actual production direction) → Deno verification.** **Unproven by any cross-implementation fixture or device run that exists today.** There is no hosted deployment, so there is also no live daily traffic of any kind exercising this direction. This remains an explicit, open evidence gate.

Confirmed schema (`supabase/migrations/20260923060545_authz_schema_v1.sql`):
- `authz.connection_requests`: `id`, `invitation_id`, `device_public_key` (`BYTEA`), `display_code`, `status` (`pending|approved|rejected|claimed`), `created_at`, `decided_at`, `decided_by_parent_id`. Composite unique `(id, invitation_id, device_public_key)`.
- `authz.claim_challenges`: `id`, `connection_request_id`, `nonce` (`BYTEA`), `created_at`, `expires_at` (`= created_at + 60s`), `used_at`. Single-use, 60-second TTL, approved.
- `authz.device_grants`: `id`, `invitation_id` (`UNIQUE`), `connection_request_id`, `workspace_id`, `athlete_id`, `device_public_key`, `status` (`active|revoked`), `created_at`, `revoked_at`, `recovery_deadline` (`CHECK (recovery_deadline = created_at + interval '24 hours')`) — **this `created_at` is D2's canonical start event; `recovery_deadline` is derived from it once, at grant creation, never recomputed from any later event such as a hydration upload (§4.5).** Composite FKs `dg_request_invitation_devicekey_fk` and `dg_invitation_workspace_athlete_fk` structurally bind a grant to the exact device/request/invitation/workspace/athlete it descends from.
- `authz.parent_sessions` (`20260928100000_authz_parent_auth_session_v1.sql`): `token_hash`, `authenticated_at` (set once, carried forward unchanged by rotation), `expires_at` (24h sliding, `LEAST(clock_timestamp() + 24h, absolute_expires_at)`), `absolute_expires_at` (30-day hard ceiling, copied forward verbatim). This two-axis shape is the pattern §3 mirrors for the device-authorization session — not the same table, values, or approval.

**Confirmed lock orders, read from source:**
- `authz.claim_device_grant`: **first claim** locks only `authz.invitations` `FOR UPDATE` for its whole transaction, then `INSERT`s a brand-new `device_grants` row — there is no pre-existing `device_grants` row to lock on this path. Retry of an already-claimed request additionally locks the existing `device_grants` row.
- `authz.decide_connection_request`: `parent_sessions` → **the same `authz.invitations` row** `claim_device_grant`/`submit_connection_request` also lock (its own header comment states this explicitly) → plain read of `connection_requests` → `workspace_owner_bindings` row last, with every time-based outcome decided from one `clock_timestamp()` read taken after that last lock.
- `authz.revoke_device_grant`: `parent_sessions` → `authz.device_grants` row `FOR UPDATE` → (if found) `workspace_owner_bindings` row. **It never locks the invitation row.**
- `authz.issue_claim_challenge`: folds every non-issuable reason into one generic `request_not_available` outcome, "by construction" — the precedent §3.3 follows for the new challenge-issue step, and §4.6.2 follows for lock-order and anti-enumeration discipline generally.

`AthleteDeviceAuthorizationService.swift` confirms the gateway convention any new Athlete-facing endpoint follows: Supabase `apikey`/`Authorization: Bearer <anon key>` headers only (never a Parent-session header), snake_case wire encoding, single-vocabulary thrown-error surface.

### 2.3 Pairing handoff point

`AthleteDeviceAuthorizationPairingCoordinator`'s state machine ends a successful attempt at `.authorized(grantId: UUID)`. This document begins exactly there — it does not touch invitation, request, challenge, or claim semantics, all already approved and implemented.

### 2.4 Hydration pipeline — complete field inventory, types, requiredness, and source-to-destination mapping

`AthleteIdentityHydrationService.hydrate(_:)` (`Sources/VoxtrAppShell/`) is a `@MainActor` six-step, idempotent-per-step but **not atomic across steps** upsert pipeline: `hydrateParent` → `hydrateWorkspace` → `hydrateOwnerParticipant` → `hydrateAthleteProfile` → `hydrateAthleteParticipant` → `hydrateAccessGrant`, currently driven by the legacy CloudKit payload `AthleteConnectionInvitationCloudRecordPayload` (`Sources/VoxtrCore/CloudKit/AthleteConnectionInvitationCloudRecordMapping.swift`, 11 fields, all `Equatable`/`Sendable`).

**Accepted scope decision (2026-10-03, decision 2 of the [sessions/hydration/retention/CloudKit comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969141158)): the proposed backend hydration snapshot carries exactly these 11 fields — no more.** Training history, reflections, and unrelated family-member profiles are out of scope and stay out of scope; this was never proposed and remains excluded. The model's own genuinely optional `familyName`/`preferredName` fields (below) are **not** added to the snapshot — the accepted direction is "only the exact fields required by the existing bootstrap pipeline," and these two are not required by it.

| # | Field | Type | Required? | Destination (step → initializer parameter) | Why |
|---|---|---|---|---|---|
| 1 | `workspaceId` | `UUID` | Required | `hydrateWorkspace` → `FamilyWorkspace(id:)` | Stable ID; workspace is the membership root |
| 2 | `intendedParticipantId` | `UUID` | Required | `hydrateAthleteParticipant` → `WorkspaceParticipant(id:)`, role `.athlete`, `linkedAthleteId == intendedAthleteId` | The selected **athlete's own** existing participant row — never the owner's |
| 3 | `intendedAthleteId` | `UUID` | Required | `hydrateAthleteProfile`/`hydrateAthleteParticipant`/`hydrateAccessGrant` → `AthleteId(rawValue:)` | The one canonical `AthleteProfile.id` the whole flow binds to — never inferred from name/date |
| 4 | `parentId` | `UUID` | Required | `hydrateParent` → `ParentProfile(id:)` | Stable Parent identity, independent of SIWA subject |
| 5 | `parentGivenName` | `String` | **Required, non-empty, non-fabricable** | `hydrateParent` → `ParentProfile(givenName:)` — `ParentProfile.givenName: String` is a non-optional initializer parameter with no default | The payload's own doc comment: *"the Parent's own real, non-fabricated given name... a placeholder here would be invented content presented as truth."* |
| 6 | `workspaceDisplayName` | `String` | Required | `hydrateWorkspace` → `FamilyWorkspace(displayName:)` | Display, same non-fabrication reasoning |
| 7 | `ownerParticipantId` | `UUID` | Required | `hydrateOwnerParticipant` → `WorkspaceParticipant(id:)`, role `.workspaceOwner`; also reused as `hydrateAccessGrant`'s `AthleteAccessGrant(participantId:)` | The Parent's own existing participant row — distinct from the athlete's |
| 8 | `athleteGivenName` | `String` | Required | `hydrateAthleteProfile` → `AthleteRepository.stageAthlete(givenName:)`, required, no default | — |
| 9 | `athleteBirthDateISO` | `String` (ISO date) | Required | `stageAthlete(birthDate:)`, parsed via `LocalDate(isoString:)`; throws `AthleteIdentityHydrationError.invalidProjection` on parse failure | — |
| 10 | `athleteTimeZoneId` | `String` | Required | `stageAthlete(timeZoneId:)`, via `TimeZoneId(rawValue:)` | — |
| 11 | `athleteDevelopmentStage` | `String` (enum raw value) | Required | `stageAthlete(developmentStage:)`, via `DevelopmentStage(rawValue:)`; throws on an unrecognized value | — |

**Excluded by accepted decision, not a gap:** `AthleteRepository.stageAthlete(...)` also accepts optional `familyName: String? = nil` and `preferredName: String? = nil` (and `ParentProfile` has its own optional `familyName`/`preferredName`) — genuinely optional on the model, never supplied by the legacy payload, and **not added** by the accepted hydration-scope decision. Omitting them is a truthful "not provided," never a fabrication, and matches the existing payload's own documented scope discipline.

**`hydrateAccessGrant` — precise description, never conflated with device authorization.** It creates a local `AthleteAccessGrant(participantId: ownerParticipantId, athleteId: intendedAthleteId)` — a business-permission record (the owner participant has full access permission to this athlete's data), entirely local to the iOS domain. It says nothing about which device is acting and nothing about runtime/device authorization — it is not the backend's `authz.device_grants` row, and not this document's device-authorization session either.

**Membership-activation fact, stated precisely.** `hydrateOwnerParticipant` **does** create the owner's own `WorkspaceParticipant` directly as `.active` — existing, approved, already-shipped behavior, not a defect. What hydration must never do, and what §7's tests check, is transition the **athlete's** participant to `.active` — it is always created `.invited` (via the same canonical `ParentWorkspaceRepository.createInvitedAthleteParticipant` every other invitation-creation call site already uses) and left untouched if it already exists; the canonical `.invited → .active` transition remains exclusively `AcceptWorkspaceInvitationService`'s job, sequenced after hydration by `AthleteConnectionLifecycleService`.

`AthleteDeviceAuthorizationReceipt` (Keychain-backed) remains metadata-only — no challenge ID, nonce, or signature — and is never treated as proof of current authorization; §3 is what actually proves it.

## 3. Athlete device-authorization session contract — ACCEPTED for Internal Alpha, 2026-10-03

Decision 1 of the [sessions/hydration/retention/CloudKit comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969141158): "7-day sliding / 90-day absolute, automatic renewal requiring fresh device-key proof. A new proof-gated session chain may be issued after the absolute cap while the grant/key remain valid; no recurring Parent re-pairing solely because that cap elapsed." The design below implements that direction; the exact numbers (7/90) are the accepted Internal Alpha defaults, not yet exercised by any implementation.

### 3.1 What already exists and is reused unchanged

D2's fixed 24-hour `authz.device_grants.recovery_deadline` same-installation bootstrap-recovery window is unchanged by this document — it governs only whether the same proven device key may resume `claim-submit` and receive the same grant again within 24 hours of the grant's creation. It says nothing about ongoing access after that deadline, which is what this section defines.

### 3.2 Tables

- `authz.device_authorization_sessions`: `id`, `device_grant_id` (`NOT NULL REFERENCES authz.device_grants(id)`), `token_hash`, `created_at`, `authenticated_at` (set once at issuance from the signature-proof event that created the row, carried forward unchanged by every later renewal), `expires_at`, `absolute_expires_at`, `revoked_at`. At most one row with `revoked_at IS NULL AND absolute_expires_at > clock_timestamp()` per `device_grant_id` — enforced as a behavioral invariant by `session_issue` itself (§3.3), which always revokes any existing active session for the grant before creating a new one, inside the same transaction; not a static schema constraint, since expiry is time-dependent.
- `authz.device_session_challenges`: `id`, `device_grant_id`, `action` (`CHECK (action IN ('session_issue','session_renew','hydration_get','hydration_ack'))`), `session_id` (`REFERENCES authz.device_authorization_sessions(id)`, nullable only for `session_issue`), `nonce` (`BYTEA`), `created_at`, `expires_at` (`= created_at + 60s`), `used_at`.

Every operation re-verifies at query time: the target grant is `status = 'active' AND revoked_at IS NULL`; for session-bound actions, the presented session is itself unrevoked/unexpired **and** `session.device_grant_id = challenge.device_grant_id = <the grant named in the request>` (`session.grant == challenge.grant == target grant`). A revoked grant invalidates every session issued against it immediately, without touching session rows individually — the grant remains the root of trust.

### 3.3 Wire protocol

**Canonical message, per action** — extends, never replaces, the existing claim-proof pattern. **The version line is an explicit lookup table, never a literal template substitution of the `action` enum value (correcting a real inconsistency found at final review: the `action` column uses underscores — `session_issue` — while the signed version line uses hyphens — `session-issue` — so interpolating the enum directly would produce different, non-interoperable bytes):**

| `authz.device_session_challenges.action` | Canonical message version line |
|---|---|
| `session_issue` | `voxtr-athlete-session-issue-v1` |
| `session_renew` | `voxtr-athlete-session-renew-v1` |
| `hydration_get` | `voxtr-athlete-hydration-get-v1` |
| `hydration_ack` | `voxtr-athlete-hydration-ack-v1` |

Full message shape, with the resolved version line substituted via the table above, never computed from the enum string at runtime:

```
<version line, from the table above>
device_grant_id=<lowercase uuid>
challenge_id=<lowercase uuid>
nonce=<base64url, no padding>
```

No `method`/`path`/`body_sha256` field: none of the four actions carries mutable content beyond the identifiers already bound (`device_grant_id`, `challenge_id`, `nonce`, `action`), so there is nothing left for a body hash to protect, and a body-hash field that includes the signature inside the hashed body is circular by construction — the reason this field was removed rather than patched. Byte-exact rules: UTF-8; every line, including the last, terminated by one `\n`; no other separators; UUIDs lowercased regardless of input casing; nonce base64url per RFC 4648 §5, no padding. The verifier always recomputes the expected bytes server-side, from the table above, and never trusts a client-supplied canonical string. **Swift-signs → Deno-verifies fixtures for these exact bytes are required as the production-direction evidence gate** (§2.2 layer 3), alongside the already-described reverse-direction (Deno-signs → Swift-verifies) fixtures — neither exists yet.

**`device-session-challenge` (issue) — deliberately non-locking.** Request: `{device_grant_id, action, session_token}` — `session_token` present only for the three session-bound actions. This step only inserts a fresh challenge row; it takes **no `FOR UPDATE` lock** on `device_grants` or `device_authorization_sessions` — a plain, non-locking read is enough to decide the response, because nothing is mutated here and the real authoritative check happens again, under lock, in `device-session-submit` below. (This is also what removes challenge-issue entirely from the lock-ordering concern in finding 1 below — only `device-session-submit` and its action effects need an ordered lock sequence.) Response: `{outcome: "issued", challenge_id, nonce, expires_at}` | `{outcome: "challenge_not_available"}` (folding an unknown `device_grant_id`, an inactive/revoked grant, and any other non-issuable reason into one generic outcome, mirroring `authz.issue_claim_challenge`'s own anti-enumeration fold) | `{outcome: "session_invalid"}` for a session-bound action whose caller-presented `session_token` is missing/expired/revoked (kept distinct because it describes the caller's own credential, not an enumerable fact about another target).

**`device-session-submit` (consume + perform) — one atomic database transaction, with one consistent lock order across all four actions, and exactly one authoritative time check taken after every lock is held (corrects both a real deadlock and a real expiry-check gap found at final review, both below):**

1. Lock the challenge row `FOR UPDATE` by `challenge_id` (always first — nothing else in this schema ever locks a challenge row, so this introduces no ordering conflict).
2. **Preflight only, not authoritative:** reject immediately if `used_at IS NOT NULL` or `clock_timestamp() >= expires_at` — a fast-fail that avoids doing any further lock-acquisition work for an obviously-already-dead challenge, but not the gate that actually matters (step 6 below is).
3. Reject if the request's `action` doesn't match the challenge's own stored `action`.
4. Lock `device_grants` row (G) `FOR UPDATE`.
5. Lock the relevant `device_authorization_sessions` row (S) `FOR UPDATE`, if any: for a session-bound action, the row named by the presented `session_token`; for `session_issue`, whichever row (if any) currently satisfies §3.2's at-most-one-active invariant for this `device_grant_id`. For a session-bound action, reject unless that locked session's hash matches the presented `session_token` and its `device_grant_id` matches G. Verify the signature against `device_grants.device_public_key` for G over the recomputed canonical message (§3.3's table).
6. Lock the approving `workspace_owner_bindings` row (§4.6.1) `FOR UPDATE`, **then, for `hydration_get`/`hydration_ack`, also lock the `hydration_snapshots` row `FOR UPDATE` now — every lock this transaction will ever take is held by this point, for every action.**
7. **The one authoritative check, with a single fresh `clock_timestamp()` read taken only now, after step 6's lock:** reject — with **no** `used_at` write and **no** action effect — unless *all* of: the challenge's own `used_at IS NULL` **and** `now < challenge.expires_at` (re-checked here, not only at the step-2 preflight — this is the fix for the gap below); `device_grants.status = 'active' AND revoked_at IS NULL`; the approving binding's `revoked_at IS NULL`; the session (if session-bound) still valid; and, for a hydration action, the grant's `recovery_deadline`/`hydration_outcome` state still permits it (§4.3/§4.5).
8. Only if step 7 passes: mark the challenge's `used_at`, then perform the action's own effect using the locks already held — `session_issue` revokes the locked S (if one was found) and inserts a new row; `session_renew` rotates the locked S's `expires_at`; `hydration_get`/`hydration_ack` read/write the already-locked `hydration_snapshots` row.

All of this commits together or none of it does; a crash or lost connection at any point rolls back everything, so "challenge consumed but effect never performed" cannot exist as a committed fact.

**The expiry-check gap this fixes, stated explicitly:** an earlier revision of this document checked the challenge's expiry only at the step-2 preflight, immediately after locking the challenge row — but then still waited on the G, S, and binding locks (steps 4–6) before reaching any further check, and that later check named only grant/binding/session validity, never the challenge's own expiry again. A challenge that was still valid at the preflight could expire during those lock waits under real contention, and the literal sequence as previously written would still consume it and perform the action — violating the 60-second TTL exactly in the contended case that matters, and contradicting §4.6.2's own global "fresh clock after the last lock" rule, which this specific check had quietly not followed. Step 7 above is now the single place every freshness fact is checked together, after every lock, with no gap between "the last thing we checked" and "the last lock we took."

**Why this exact order (G, then S, then binding) and not the reverse — the deadlock finding 1 caught.** An earlier revision of this document had session-bound actions lock S before G (to validate the presented session first), while `session_issue`'s own action effect locked G and only reached S afterward (to revoke-then-replace it) — a genuine lock-order inversion: a session-bound call holding S and waiting for G, concurrent with a `session_issue` call holding G and waiting to update S, is a real deadlock, not merely unlucky request-arrival ordering, and relying on Postgres's deadlock detector to abort one side is not an acceptable substitute for a correct, deadlock-free order. The fix is the single rule stated above: **every call that touches both G and S locks G first, unconditionally** — a session-bound action locates its session row by the presented token but does not lock it until after G is already locked; `session_issue` already naturally wants G first. With G always first, there is no pair of calls that can hold one of {G, S} while waiting on the other in opposite orders.

**Lost-response retry.** If the caller's HTTP response is lost, it cannot tell locally whether the transaction committed. The uniform response is the same regardless: request a fresh challenge for the same action and retry. If the original committed, the old challenge is already consumed either way; the action's own idempotency (below; `hydration_ack`'s `already_completed` fold, §4.4) makes the retry safe whichever happened.

**`session_issue`, genuinely idempotent in effect.** Under the G-then-S lock order above, `session_issue` locates and locks any existing session matching §3.2's invariant for this `device_grant_id` and revokes it in the **same** transaction before inserting the new row. A lost-response retry converges to exactly one active session no matter how many times it is retried, and — because G is always locked first — never deadlocks against a concurrent renewal/get/ack on the same grant; the two simply serialize on G, one proceeding after the other releases it.

**The two session clocks, as two distinct, accepted properties.** `expires_at` (7-day sliding) bounds how long the session can go *without* a successful proof/renewal before it lapses on its own. `absolute_expires_at` (90-day hard cap) bounds the total lifetime of *one renewal chain* — the same session row, rotated forward by successive valid renewals — regardless of how many renewals succeeded; once reached, that chain ends. A fresh `session_issue` starts an entirely new chain, with its own fresh 90-day clock, requiring only the still-active grant and the still-held key — **this is the accepted property that there is no recurring Parent re-pairing solely because the absolute cap elapsed.** The only thing that bounds total access across any number of chains is the grant's own active status, ended solely by Parent revocation.

**Swift↔Deno vectors.** None of the four action-bound fixtures exist yet; this document does not claim otherwise. Each would be built the same way the existing claim-proof fixture was — a throwaway key signs in Deno, the backend's own verifier confirms it, the frozen bytes are then checked against Swift CryptoKit — which, per §2.2, proves only the verify-side direction, not the production-relevant sign-side direction.

### 3.4 Issuance/renewal flow

1. Issuance, renewal, get, and ack each go through `device-session-challenge`/`device-session-submit` with their own action.
2. Renewal, get, and ack additionally bind to the caller's exact presented session (`session.grant == challenge.grant == target grant`) — never bearer-token possession alone.
3. Storage: device-only Keychain, never UserDefaults. A reinstall or lost signing key is a new installation requiring full re-pairing, detected the same way `currentInstallationHasExistingSigningKey()` already detects it today.

### 3.5 Automatic technical renewal vs. genuine Parent re-pairing

**Automatic renewal** happens silently as long as the key and grant remain valid — the device signs its own fresh, action-bound challenge with a key it already holds; no Parent/user involvement, at any point, including long after D2's bootstrap deadline has passed. **Parent/user involvement is needed only when:** the grant is revoked; the signing key/installation is lost (reinstall, detected via the existing installation-marker mismatch); or this is a brand-new installation that never held a grant. After the absolute cap, renewal is simply replaced by a fresh `session_issue` (§3.3) — still fully automatic, still requiring no Parent action, as accepted.

**Stolen-bearer vs. stolen-key/device, stated precisely:** session/token expiry bounds exposure of a bearer token leaked *without* the key — such a token eventually stops working on its own, and cannot even be *renewed* without the key. It does not bound compromise of the actual device/key: an attacker who has the key can mint fresh sessions indefinitely via `session_issue`, regardless of any TTL, until the Parent revokes the grant.

## 4. Hydration upload/get/ack lifecycle

### 4.1 Why upload must be Parent-pushed, not backend-pulled

The backend stores none of §2.4's 11 fields today — `authz.invitations`/`connection_requests`/`device_grants` carry only opaque workspace/athlete UUIDs. Per D1/NormativeSecurityContract §3 ("no profile duplication as permanent backend truth"), the backend cannot independently source this data; only the already-authenticated Parent, at approval time, can supply it.

### 4.2 Upload/association model — lock before deciding, never decide-then-lock

**Why a plain "stage before claim, associate at claim" ordering is not enough on its own:** `decide_connection_request` (approval) and `claim_device_grant` (claim) already serialize against each other through the shared invitation-row lock (§2.2), but that alone does not prevent a *check-then-act* race in `hydration-upload` itself if the branch decision (does a grant already exist for this `connection_request_id`?) is made from an unlocked read taken before any lock — a concurrent `claim_device_grant` could complete in the gap between that unlocked read and the subsequent lock acquisition, leaving a staged snapshot permanently orphaned (nothing ever associates it, since claim already passed its own association step).

**The design: one explicit ordering where the branch decision itself happens only after a lock is already held.**

1. Lock the Parent's `authz.parent_sessions` row, then **unconditionally** lock `authz.invitations` `FOR UPDATE` — the same resource `decide_connection_request`/`claim_device_grant`/`submit_connection_request` already lock, taken for *every* call regardless of which branch it turns out to be.
2. **Only now**, with that lock held, re-query whether a `device_grants` row exists for this `connection_request_id`. Because `claim_device_grant`'s first-claim path needs this exact same invitation lock to insert that row, there is no window left for a stale observation: either the grant already existed before this transaction started, or `claim_device_grant` is concurrently blocked on the same lock and only becomes visible after this transaction releases it.
3. **If a grant now exists:** additionally lock that exact `device_grants` row `FOR UPDATE` (the same row `revoke_device_grant` locks) → lock the exact approving binding (§4.6.1, sourced from `device_grants.approving_owner_binding_id`) → fresh clock check (`status = 'active' AND revoked_at IS NULL`) → write into `hydration_snapshots` keyed by `device_grant_id`, governed from this point by that grant's existing `recovery_deadline`.
4. **If no grant exists:** confirm `connection_requests.status = 'approved'` (if not yet, return `not_yet_approved` and stop) → lock the exact approving binding (sourced from `connection_requests.approving_owner_binding_id`, already written by `decide_connection_request` under this same invitation lock) → stage the row keyed by `connection_request_id`, governed until claim by the invitation's own existing 15-minute expiry. **This is a conservative engineering refinement within the accepted retention direction (§4.5) — reuse an existing deadline, introduce no new clock — not itself a Product Owner selection of "15 minutes" as a distinct retention number; the fixed D2 recovery clock the Product Owner did accept starts only once a grant exists (§4.5).**

Both branches hold the invitation lock continuously from before the branch decision until after the write — the decision and the action are the same critical section.

**Association at claim is symmetric and unaffected by the above**: `claim_device_grant`'s first-claim path inserts the new `device_grants` row and, in the same transaction, under the invitation lock it already holds for its whole transaction, associates any already-staged `hydration_snapshots` row for that `connection_request_id`. This needs no lock on a pre-existing grant row, because there is none on this path — the insert itself is the serialization point.

**Expired staged payload can never be associated or delivered, by construction, not by a separate check.** `claim_device_grant` already rejects claiming an invitation whose authoritative server-time expiry has passed (approved, existing, unchanged behavior) — it can never create a `device_grants` row for an expired invitation, and therefore can never reach the association step for a staged snapshot whose invitation has expired. There is also no path to *read* a staged (pre-association) snapshot directly: `hydration-get` requires a device-authorization session, which requires a `device_grant_id`, which requires a successful claim. A staged row belonging to an invitation that expired unclaimed is therefore unreachable through any read path from the moment it expires, and is removed by the scheduled purge under §9.6's accepted one-hour operational deletion target (non-PII tombstones have their separate §4.5 cleanup policy) — cleanup removes an already-unreachable row; it does not gate reachability.

**Interruption/retry/immutability.** A retried upload for a still-unclaimed, still-staged `connection_request_id` with the *same* payload bytes is an idempotent no-op; with *different* bytes, it is rejected (`payload_mismatch`), never a silent overwrite. Once a row is associated to a `device_grant_id` or tombstoned (§4.5), it is immutable — any further upload against that `connection_request_id` or `device_grant_id` is rejected outright.

### 4.3 Get and ack

Both go through `device-session-submit` with their own action (§3.3), requiring a valid, grant-active session **and** a fresh signature — never a bearer token alone. `hydration-get` denies with `deadline_passed` once `clock_timestamp() >= recovery_deadline` — the exact D2 deadline from §2.2, with its canonical start event (`device_grants.created_at`), never a clock re-derived from the upload event. `hydration-ack` is called only after `AthleteIdentityHydrationService.hydrate(...)` (§2.4) completes successfully end to end.

### 4.4 Idempotency

A second `ack` against an already-tombstoned grant returns `already_completed`, reusing `claim-submit`'s own `granted`/`already_granted` idempotency fold rather than a new shape for the same question.

### 4.5 Completion model, canonical deadline, and retention — ACCEPTED for Internal Alpha, 2026-10-03

Decision 3 of the [accepted directions](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969141158): use the existing D2 24-hour `recovery_deadline`, with its canonical start event (`device_grants.created_at`, §2.2) — never a new clock starting on upload; remove live payload on verified ack, deadline expiry, or revocation; retain non-PII tombstones for 30 days plus the permanent non-PII outcome marker. The design below is exactly that, already proposed and now accepted as the final answer rather than a default pending approval.

**Three triggers — but only two of them actually, synchronously delete the PII payload in their own transaction; the third only guarantees access is denied, stated honestly rather than conflated:**

1. **Verified ack** — synchronous and precise: the row's PII columns are cleared and replaced with a tombstone (`device_grant_id`, `completed_at`, `reason='acked'`) in the same transaction as the ack itself.
2. **Deadline passed** (`clock_timestamp() >= recovery_deadline`, the exact D2 clock from `device_grants.created_at`, never recomputed from upload time) — read access is synchronously denied from that instant forward by §4.3. A scheduled purge tombstones the row `reason='expired'` under §9.6's accepted **one-hour operational deletion target** after the deadline, with monitoring/alerting for overdue live PII and observable job failures. The same target applies after invitation expiry to unclaimed staged PII. This is an operational target, not guaranteed physical deletion through outages or provider backup/log retention. The accepted 30-day non-PII tombstone retention below governs a separate question.
3. **Grant revocation** — synchronous and precise, like ack: `revoke_device_grant`'s own transaction, in the same commit as the revocation itself, tombstones any matching `hydration_snapshots` row `reason='revoked'`.

**Permanent outcome marker, surviving tombstone deletion.** `authz.device_grants` carries `hydration_outcome` (`NULL | 'acked' | 'expired' | 'revoked'`), written in the same transaction as the tombstone. `hydration-get`/`hydration-ack` check this permanent column first, so correctness survives the tombstone row's own eventual deletion — `already_completed`/`deadline_passed`/`grant_revoked` answer correctly forever, whether or not the (already non-PII) tombstone row still physically exists.

**Retention: 30 days, accepted.** Tombstoned `hydration_snapshots` rows (already non-PII) are retained 30 days for audit/support purposes, then deleted by a best-effort cleanup job. Deletion changes nothing observable — `device_grants.hydration_outcome` and the immutability rule (§4.2) continue to answer and reject correctly regardless of whether the snapshot row survives.

### 4.6 Authorization and concurrency boundaries

**4.6.1 Owner-binding identity — ACCEPTED for Internal Alpha, 2026-10-03 ([decision](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969125531)).** `authz.connection_requests` gains an `approving_owner_binding_id` column (`REFERENCES authz.workspace_owner_bindings(id)`), written by `decide_connection_request` at approval from the exact `workspace_owner_bindings` row that function already locks and reads (`v_binding.id` is already in scope — one more column write, no new lookup). `authz.device_grants` gains the same column, copied from the approving `connection_requests` row by `claim_device_grant` at claim. Every owner-binding check in this document — issuance, renewal, get, ack, upload — means: *the specific binding named by `approving_owner_binding_id` is itself still `revoked_at IS NULL`*, never "some binding exists for the workspace." A different, newer active binding (an owner change) does not satisfy this check, because it is a different row.

`revoke_device_grant`'s own existing owner-binding check is accepted to move to this same stronger form, in the same implementation slice — not left on the weaker "any active binding" form it uses today.

**Migration/backfill, fail-closed — accepted; backfill rule corrected post-merge, 2026-10-03 ([decision](https://github.com/cristern/Voxtr/issues/107#issuecomment-5972055089)).** The migration adding these columns must backfill existing `connection_requests` rows created before it: for a given historical, decided (`approved`/`claimed`) row, backfill from whichever `workspace_owner_bindings` row was temporally active at that row's own recorded `decided_at` **and** owned by that row's own recorded `decided_by_parent_id` — both axes at once, never from the row's `created_at` (submission time, an anonymous pre-Parent-identity event, not a decision fact). `device_grants` rows are **never independently backfilled**: each strictly inherits its own `connection_requests` row's (already-backfilled) value, exactly mirroring how `claim_device_grant` itself copies that value forward for every new claim going forward — a grant's own `created_at` (claim time) is claim-time plumbing, never approval evidence, and is never consulted for this. Where the `connection_requests` candidate is ambiguous (zero or more than one row satisfying both axes) or otherwise unresolvable, **the accepted rule is to fail closed**: `approving_owner_binding_id` is left `NULL`, and — because `device_grants` strictly inherits — that propagates to every descending grant, with no separate ambiguity case of its own to get wrong. A `NULL` grant's dependent operations (issuance, renewal, get, ack) are denied until the Parent explicitly re-approves (a real re-pairing, not an automatic re-enrollment) — never silently preserving an unverifiable old-owner authorization. The compatibility alternative (treat `NULL` provenance as passing) is rejected for Internal Alpha; the "any active binding" status quo is kept only as rejected history, not a live option. *Historical: this paragraph originally read "backfill from whichever `workspace_owner_bindings` row was active at that row's own `created_at`" for both tables independently — superseded by the corrected rule above, which `cristern/Voxtr-Backend` implements exactly (migration `20261003070000_authz_owner_binding_provenance_v1.sql`).*

**4.6.2 Lock order, per function — corrected to a single global order after a real deadlock was found at final review (§3.3):**

| Function | Lock order |
|---|---|
| `device-session-challenge` (all four actions) | **No `FOR UPDATE` lock at all** — a plain, non-locking read of `device_grants` (and, for session-bound actions, `device_authorization_sessions`) decides the response; the challenge row is a fresh `INSERT`. Authoritative validation happens under lock in `device-session-submit`. |
| `device-session-submit` (all four actions) | `device_session_challenges` row → **`device_grants` row (G), always first among the shared resources, every action** → **`device_authorization_sessions` row (S), if relevant — the presented session for a session-bound action, or the grant's existing active session (if any) for `session_issue`** → approving `workspace_owner_bindings` row → **`hydration_snapshots` row, for `hydration_get`/`hydration_ack` only — this is the true last lock the function ever takes, held *before*, not after, the single authoritative time check (§3.3 step 7)** → action effect, using the locks already held |
| `hydration-upload` | `parent_sessions` row → `authz.invitations` row (unconditional, §4.2) → [`device_grants` row, only if one now exists] → approving `workspace_owner_bindings` row → `hydration_snapshots` row |

**Why G is locked before S, unconditionally, in every path that touches both:** a session-bound action (renewal/get/ack) needs to validate the presented session against its grant; `session_issue` needs to revoke any existing session for the grant it is issuing against. An earlier revision of this document had these two kinds of calls take the opposite order from each other — session-bound calls locked S first and then needed G, while `session_issue` locked G first and then needed to update S — which is a genuine lock-order inversion: one call holding S and waiting on G, concurrent with another holding G and waiting to update S, deadlocks, and that is not an acceptable outcome to leave to Postgres's deadlock detector as "normal" renewal behavior. Locking G first, always, removes the inversion: every call that needs both resources now wants them in the same order, so the two simply serialize on G.

**Fresh-clock rule, now a single step, not scattered across the sequence:** every time-based outcome — challenge expiry, grant/binding/session validity, and (for hydration) `recovery_deadline`/`hydration_outcome` — is decided together from one `clock_timestamp()` read taken after the **true last lock** in that function's own order above (§3.3 step 7), never at an earlier point and never split across more than one check. An earlier revision checked challenge expiry only once, right after the challenge lock, and separately re-checked grant/binding/session validity later after further lock waits — a real gap, since a challenge valid at the first check could expire during those later waits and still be consumed. Folding every freshness fact into the one post-last-lock check closes that gap, and is the same discipline `decide_connection_request`'s own implementation already uses for its own single check.

**Target-independent public errors and privileges:** anti-enumeration ordering mirrors `revoke_device_grant`'s own round-1 fix (session-only outcomes decided before any target lookup); all three new tables are private `authz` schema, no direct `anon`/`authenticated` access.

**Serialization boundary, stated by lock-acquisition/commit order, not request-arrival order:** this is ordinary MVCC row-locking. An operation whose relevant lock acquisition happens *after* a revocation's commit will observe the revoked state and must fail; an operation that acquired that lock and read the pre-revocation state *before* the revocation's commit may legitimately complete, regardless of which HTTP request nominally arrived first in wall-clock terms.

## 5. CloudKit / legacy pairing boundary — retirement timing ACCEPTED (deferred), 2026-10-03

**Record types.** Exactly two Vǫxtr-**defined** `CKRecord` `recordType` values exist repo-wide — `FamilyWorkspace` and `AthleteConnectionInvitation` — confirmed by `CloudKitTransport.swift`'s own repo-wide-audit comment ("no `recordType` for `PlannedActivity`/`LoggedActivity`/etc. exists anywhere... Planning/Training/Reflection/etc. domain modules never import CloudKit at all") and independently re-confirmed by grep. `CKShare` itself is a separate, Apple-provided `CKRecord` subclass outside this count, present on both share roots below.

**Two distinct `CKShare` roots, one confirmed consumer.** `AthleteConnectionOwnerHandoffService.prepareInvitation` creates an independent, per-invitation `CKShare` rooted on the `AthleteConnectionInvitation` record. Its confirmed acceptance consumer is `FamilyWorkspaceParticipantShareCoordinator.resolveAcceptedShare(from:)`, which accepts/resolves the share, reads `metadata.hierarchicalRootRecordID`, and calls `database.record(for:)` directly against `CKContainer.sharedCloudDatabase`. Separately, `FamilyWorkspaceOwnerShareCoordinator` (B2.1) creates its own, independently reusable `FamilyWorkspace`-root share, documented as reserved "for whatever later, genuinely family-wide sharing scope needs"; no participant-side acceptance consumer for *that* share was found in this inventory (reported as "none found," not "none exists").

**Transport/database scope.** Two independent `CKSyncEngine` instances per device: `privateEngine` (→ `CKContainer.privateCloudDatabase`, an owner's own zone) and `sharedEngine` (→ `CKContainer.sharedCloudDatabase`, through which an Athlete device reaches the Parent-owned zone after share acceptance). `CloudKitTransport.ScopedDelegate.handleEvent` persists only `.stateUpdate` events and logs everything else as "not yet mapped"; `nextRecordZoneChangeBatch` always returns `nil`, honestly, because no local write path creates a `CKRecord` change yet — two running sync engines, by themselves, establish no business-data delivery.

**Exact enforceable boundary.** Backend revocation blocks new device-authorization-session issuance/renewal and both hydration calls; it does not retroactively invalidate `CKRecord`s already delivered via `sharedCloudDatabase`, recall offline bytes, activate/remove membership, or retire the legacy acceptance screen.

**Retirement timing — accepted (decision 4 of the [sessions/hydration/retention/CloudKit comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969141158)): deferred until the replacement flow is implemented and verified on two physical iPhones through TestFlight, covering connection, restart, network interruption, and revocation. Existing, already-accepted CloudKit access requires its own, separately reviewed revocation plan** — not something this document's backend-revocation boundary above substitutes for, and not something retired on this document's own authority. [Issue #98](https://github.com/cristern/Voxtr/issues/98) gate C stays open until that separate review.

**Domain-neutral hydration adapter, recommended for the implementation step, not this document:** a new adapter should translate a `hydration-get` response into the existing `AthleteConnectionInvitationCloudRecordPayload` shape, so `AthleteIdentityHydrationService.hydrate(_:)` itself needs no change and the legacy CKShare-sourced path remains intact until the retirement criteria above are met.

## 6. Normative-contract status pointers (historical, corrected)

Two paragraphs in [the normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) read as current but are dated: §6's "Swift CryptoKit ↔ Deno interoperability is not yet tested" is addressed by §2.2's layer 2 above (though, as stated there, that is the verify-side direction, not the production sign-side direction, which remains open). §7's "Backend PR #5 merged the independent SIWA verifier only; HTTP authentication, nonce/session storage and enrollment are not implemented" is superseded by the **separate** [project-status document](../AthleteConnectionV1-ProjectStatus-2026-09-21.md)'s later checkpoints (recording backend PR #6/#7), not by any later section of the normative contract itself, which has none. Both documents' historical text is preserved unedited; this paragraph exists only so a reader of either section in isolation is not misled.

## 7. Test and evidence gates

Distinguishing repository facts (exists today), CI evidence (a green run would demonstrate), unverified provider/hosted behavior (CI cannot demonstrate this), and product choices (now accepted per §9, not pending).

### 7.1 SQL
Structural `CHECK`s for `authz.device_authorization_sessions`/`authz.device_session_challenges`/`authz.hydration_snapshots`, mirroring existing patterns (`ps_authenticated_at_not_after_created_at`-style, `dg_recovery_deadline_derivation`-style). The existing 6-case unknown/own/foreign × 5-session-state regression-matrix pattern (`authz_device_grant_management_test.sql` Test 18), applied to the new functions. Single-active-session-per-grant enforcement under `session_issue` retry. `approving_owner_binding_id` denying a grant after an owner change while a *different* binding is active. **The accepted default policy test asserts fail-closed denial plus the Parent-re-approval repair path for backfill-left-`NULL` provenance** — the rejected compatibility alternative's allow-on-`NULL` test, if written at all, is an explicitly separate, non-default case, never in the unconditional matrix. `device_grants.hydration_outcome` answering correctly after the matching `hydration_snapshots` row is deleted. Wrong device key; stolen bearer with no signature; cross-action challenge replay; session/challenge/grant mismatch (§4.6); owner-binding revoked/replaced at each stage; the `>=` deadline-boundary at exact equality; private-bridge privilege denial for all three new tables. Sibling/foreign-family isolation, each relational-conflict case (`ownerParticipantConflict`, `athleteParticipantConflict`, `athleteProfileConflict`, `differentFamilyAlreadyExists`), partial-hydration-retry, and the athlete-only no-activation assertion (§2.4) that does not flag the owner's own `.active` creation as a defect. A staged snapshot whose invitation expired unclaimed is confirmed unreachable from every read path and never associated by a subsequent claim attempt (§4.2).

### 7.2 Concurrency
Session-renewal-under-contention; revoke-races-issuance/renewal/get/ack; both reachable upload/revoke interleavings from §4.2 — revoke's commit landing before upload's `device_grants`-row lock attempt (upload must then see `revoked`, write nothing), and upload's write committing before revoke's (revoke's same-transaction purge must still remove that PII) — under real contention (NOWAIT-probe style, matching this codebase's existing discipline), confirming no payload recreation after a revoked tombstone in either ordering. The reachable branch-decision race: `claim_device_grant` commits after upload's own prior unlocked preflight observation (if retained as a diagnostic) but strictly before upload acquires the invitation lock, and upload's authoritative post-lock re-query must then observe the grant and take the claimed branch; the reciprocal ordering (upload locks first, claim waits) is tested too, proving the serialization property in both directions. Recovery-deadline-boundary-during-contention. **New, from the final-review deadlock finding (§3.3/§4.6.2):** `session_issue` contending with a concurrent `session_renew`/`hydration_get`/`hydration_ack` on the same grant, from both starting orders, must never deadlock under the corrected G-then-S lock order, and must leave exactly one live session after the dust settles — proven under real contention (NOWAIT-probe style), not merely argued from the lock table. **New, from the challenge-expiry gap finding (§3.3 step 7):** a challenge that is still valid when `device-session-submit` acquires it, but whose `expires_at` passes while that same call is waiting on the G, S, or binding lock, must be denied once those locks are finally acquired and the single authoritative check runs — exercised under real contention (hold a competing lock long enough, via the existing NOWAIT-probe pattern, for the challenge's 60-second TTL to elapse during the wait) for all four actions, confirming no `used_at` write and no effect on that denied attempt.

### 7.3 HTTP / live integration
Full issue → renew (fresh signature) → revalidate → revoke → denied flow. Full upload-before-claim and claim-before-upload flows (§4.2), get → ack (`already_completed` on repeat), get-after-deadline-denied. Collapsed pre-proof challenge-issue vocabulary confirmed non-enumerating across all four actions. A lost-response retry of `session_issue` confirmed to leave exactly one active session. No sensitive value in any non-2xx diagnostic body.

### 7.4 iOS
Device-authorization-session persistence and reinstall detection via the existing installation-marker mechanism; hydration retry-idempotency across the staging model; no time-dependent test relies on `Date.now`/locale/CI time (CLAUDE.md §8).

### 7.5 Hosted and two-iPhone TestFlight
Two physical iPhones: Parent approves on device A; Athlete device B claims, receives a device-authorization session, hydrates via the adapter (§5), displays the selected athlete. Physical revoke-while-online and revoke-while-offline-then-reconnect scenarios (D3's honest "connection cannot be verified" state, then denial on reconnect). Reinstall-on-device-B. **Per §5's accepted retirement criteria, this gate additionally covers connection, restart, network interruption, and revocation specifically as the bar for CloudKit/legacy-screen retirement** — not merely as general release validation. None of this has occurred for this document; it does not exist yet.

## 8. Recommended bounded implementation sequence

1. Backend device-authorization-session migration (`authz.device_authorization_sessions`, `authz.device_session_challenges`) + bridge + the two Edge Functions (`device-session-challenge`, `device-session-submit`) + SQL/concurrency/integration tests, as its own reviewable slice, following the existing Slice A/B/C precedent.
2. The `approving_owner_binding_id` migration and its fail-closed backfill (§4.6.1) and the `revoke_device_grant` retrofit, as their own explicit, reviewable step — not an incidental detail of slice 1 or 3.
3. Backend hydration migration (`authz.hydration_snapshots`, the `hydration_outcome` column on `device_grants`) + the symmetric upload/get/ack functions (§4.2–4.5) + their own tests, as a separate slice from 1/2.
4. iOS device-authorization-session client, reusing `AthleteDeviceSigningKeyStore` and `AthleteDeviceAuthorizationService.swift`'s exact gateway/canonical-message pattern, named distinctly from `AthleteRuntimeSession` (§0).
5. The domain-neutral hydration adapter (§5), feeding `AthleteIdentityHydrationService.hydrate(_:)` unchanged.
6. The CloudKit/legacy-boundary integration review and the separately-reviewed existing-access revocation plan (§5), as their own gate — explicitly deferred, not bundled into 1–5.
7. Two-iPhone TestFlight evidence (§7.5), including the four named retirement-criterion scenarios.

**Alternative considered and not recommended:** combining slices 1–3 into one backend change. Rejected for the same reason as the existing small-slice precedent — no real coupling benefit, and the precedent has held up across six review rounds on this document and four on the prior backend slice.

## 9. Product Owner decisions — all six accepted for Internal Alpha

The five decisions originally listed as open in this document have been explicitly accepted by the Product Owner, across two decision comments: [owner-binding/fail-closed provenance](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969125531) and [sessions, hydration scope, retention, CloudKit deferral](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969141158). Each is restated below with its accepted answer; the alternatives considered during review are kept as labeled historical record, not live options. The final-review pass surfaced §9.6; the Product Owner subsequently accepted that target and approved final-document merge on 2026-10-03 ([decision record](https://github.com/cristern/Voxtr/pull/108#issuecomment-5971118947)).

### 9.1 Session renewal design — ACCEPTED

7-day sliding / 90-day absolute, mandatory fresh-signature renewal, automatic `session_issue` after the absolute cap with no recurring Parent re-pairing solely because that cap elapsed (§3.3, §3.5). *Historical: round 1's bearer-only "grant-bounded" alternative was rejected once §3.4 made fresh-signature renewal mandatory — it cannot coexist with that requirement.*

### 9.2 Hydration field set — ACCEPTED

Exactly §2.4's 11 fields; `familyName`/`preferredName` excluded; training/reflection/unrelated-family data out of scope and excluded.

### 9.3 Pre-grant staging retention — ACCEPTED

The accepted direction is **no new clock**: post-claim retention is bounded by D2's existing `recovery_deadline`, starting at `device_grants.created_at` (§4.5) — that specific number and start event is the Product Owner's accepted choice. Pre-claim staging being bounded by the invitation's existing 15-minute expiry (§4.2) is this document's own conservative engineering refinement in service of "no new clock" — the Product Owner accepted the *principle* (reuse an existing deadline, introduce none), not a distinct selection of "15 minutes" as its own retention number. Stated here precisely because an earlier revision's wording blurred that distinction.

### 9.4 Owner-binding identity on an existing grant — ACCEPTED

The exact approving-owner-binding provenance model, including the `revoke_device_grant` retrofit; fail-closed for ambiguous historical provenance until explicit Parent re-approval/re-pairing (§4.6.1). *Historical: the "any active binding" status quo, and "allow-on-`NULL`-provenance" compatibility alternative, were both considered and rejected for Internal Alpha.*

### 9.5 CloudKit/legacy screen retirement timing — ACCEPTED (deferred)

Deferred until the replacement flow is implemented and verified on two phones via TestFlight across connection, restart, network interruption, and revocation; existing accepted CloudKit access requires its own, separately reviewed revocation plan (§5).

### 9.6 Physical-deletion operational target for pre-claim and deadline-passage PII — ACCEPTED

The Product Owner accepted a scheduled purge with a **one-hour operational deletion target** after the applicable deadline: invitation expiry for unclaimed staged PII; the fixed D2 recovery deadline for associated PII. Monitoring and alerting must detect live PII still present past the target, and job failures must be observable. Provider backup/log retention must be documented separately before real family data, consistent with [issue #98](https://github.com/cristern/Voxtr/issues/98) gate B, which remains open.

Immediate read denial at the deadline remains mandatory independently of purge success. Ack and revocation delete PII synchronously in their transaction (§4.5). The one-hour policy is an operational target, not guaranteed physical erasure through infrastructure outages or provider-side retention. [Decision and documentation merge approval, 2026-10-03](https://github.com/cristern/Voxtr/pull/108#issuecomment-5971118947).

## 10. ChatGPT review — finding-to-change map, all eight rounds

### Round 1 (`a422ec3`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5967090837))
Device proof on hydration/renewal; identity facts (`intendedParticipantId`, access-grant description, `parentGivenName`); upload ordering/durability; authorization/concurrency boundaries; renewal vs. re-pairing; repository-grounded CloudKit evidence. All six carried forward and refined below.

### Round 2 (`7159c95`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5968416078))
Removed the circular `body_sha256` field and defined exact wire shapes; symmetric upload/association model (later found still incomplete, round 3); uniform owner-binding check (later found too weak, round 3); concrete 7/90-day TTL default; corrected (but still incomplete) fixture-direction claim; CloudKit inventory; fixed a misattributed cross-reference.

### Round 3 (`eb1e366`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969012187))
Closed the upload-vs-revoke race by locking the exact `device_grants` row `revoke_device_grant` locks (round 2 had relied on the invitation lock alone, which revoke never takes). Moved owner-binding to the provenance-based design via `approving_owner_binding_id`, with a migration/backfill step. Stated challenge-consumption/action-effect as one transaction; made `session_issue` genuinely idempotent. Collapsed the challenge-issue step's enumerating outcomes. Added the `hydration_outcome` permanent marker and a retention bound. Corrected the fixture-direction claim fully (Deno signs/verifies; Swift only verifies).

### Round 4 (`7af0817`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969063633))
Fixed a TOCTOU bug in round 3's own upload fix: the branch decision was an unlocked read taken before either lock, letting a concurrent claim commit in between and orphan a staged row — fixed by locking the invitation row unconditionally first and deciding only after. Caught a second instance of the same evidence overclaim (the local integration test signs with Deno WebCrypto, never Swift CryptoKit). Corrected the two session clocks' actual distinct properties. Flipped the historical-provenance backfill default to fail-closed.

### Round 5 (`f6ad4bd`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969097831))
Two test-matrix descriptions had drifted out of sync with contract fixes made earlier the same day: §7.1 still asserted the superseded allow-on-NULL behavior after round 4 flipped the recommendation; §7.2 described an interval that the shared invitation lock makes unreachable. Both corrected in place.

### Round 6 (`505a8c4`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969116873))
Found no further substantive contract defect; marked the document technically review-complete as documentation; listed the five §9 decisions for explicit Product Owner acceptance; one editorial fix (a stale round-count heading). All five were accepted the same day (§9), and this document was then consolidated into its current, final form reflecting that acceptance — replacing round-by-round "unchanged" placeholders with complete, self-contained text throughout.

### Round 7 (`f24256b`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969200582)) — bounded engineering/document correction against the already-accepted direction

| Finding | Change made |
|---|---|
| §1 Session-replacement vs. session-bound operations inverted locks | A genuine deadlock, not a request-ordering artifact: session-bound calls locked S (session) then needed G (grant), while `session_issue`'s own action effect locked G then needed to update S. §3.3/§4.6.2 now lock G unconditionally first in every path that touches both, remove any `FOR UPDATE` lock from the challenge-issue step entirely (a plain, non-locking read suffices there, with authoritative validation under lock in submit), and add real-contention tests proving no deadlock and exactly one live session survive. |
| §2 Canonical action representation inconsistent | The `action` column uses underscores (`session_issue`) while the signed version line uses hyphens (`session-issue`) — literal template interpolation of the enum would produce different, non-interoperable bytes. §3.3 now gives an explicit enum-to-version-line lookup table, never a substitution, and requires Swift-signs→Deno-verifies fixtures for these exact bytes as the production-direction evidence gate. |
| Retention clarification | §4.2's reuse of the invitation's 15-minute window is now labeled a conservative engineering refinement within the accepted direction, not itself a Product-Owner-selected "15 minutes." §4.5 now distinguishes, honestly, which of the three deletion triggers synchronously delete PII in their own transaction (ack, revocation) from the one that only synchronously denies read access while physical deletion remains best-effort and unbounded (deadline passage) — surfacing one genuinely new, bounded open item, §9.6. |

### Round 8 (`bb115ae`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969249244)) — verification of round 7, plus one new bounded finding

| Finding | Change made |
|---|---|
| Challenge-expiry re-check gap | Verified round 7's two fixes directly in the document (not inferred). Found a new, real gap: the authoritative post-lock check (§3.3 step 7, as it then stood) re-validated grant/binding/session but not the challenge's own `expires_at` — a challenge valid at the early, pre-lock preflight could expire during the G/S/binding lock waits and still be consumed. Folded challenge-expiry into the single authoritative check, taken only after every lock the function ever takes (including, for hydration actions, the `hydration_snapshots` lock, moved earlier so it precedes rather than follows that check); added a real-contention test exercising exactly this window for all four actions. |
| Retention: concrete proposal, not yet accepted | Recorded a proposed (not accepted) one-hour operational deletion target with monitoring/alerting and explicit failure handling, applying equally to pre-claim staged and post-claim expired PII, in §9.6 — explicitly a target for Product Owner consideration, not a guarantee through infrastructure failure, and not a substitute for the mandatory synchronous read-denial. |
| §9.3 / project-status wording drift | §9.3 and the project-status checkpoint both re-worded to match §4.2's own framing: the Product Owner accepted the D2-based "no new clock" principle and the 24-hour number; reusing the invitation's 15-minute window specifically is this document's own engineering refinement, not a separate accepted number. |
| §10 round-count heading | Corrected from "all six rounds" to "all eight," matching the entries actually listed. |

## 11. Source and precedence

Product Constitution → living Architecture → ADR → Domain & Data Model → Living PRD → lower documentation → implementation, per CLAUDE.md §1. Subordinate to, and never amending, the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md). [Issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates remain open; nothing here closes any of them. The Product Owner approved this final documentation contract and its merge on 2026-10-03 ([decision record](https://github.com/cristern/Voxtr/pull/108#issuecomment-5971118947)). Implementation, migration and deployment require a separately authorized task; documentation approval closes none of the evidence gates.
