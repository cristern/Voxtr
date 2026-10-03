# Athlete Connection V1 — proposed runtime authentication and hydration contract

**Status: PROPOSED ENGINEERING CONTRACT — NOT APPROVED. Documentation only.** Product Owner authorized bounded discovery and documentation of this dependency on 2026-10-03 (`cristern/Voxtr#107`, comment `issuecomment-5966620681`); that authorization covers writing this document, not implementing it. Five ChatGPT review rounds on PR #108 ([round 1](https://github.com/cristern/Voxtr/pull/108#issuecomment-5967090837), [round 2](https://github.com/cristern/Voxtr/pull/108#issuecomment-5968416078), [round 3](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969012187), [round 4](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969063633), [round 5](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969097831)) requested changes; this revision addresses every finding from all five — see §10. This file does not supersede, compete with, or stand equal to the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) (D1–D4, approved) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md) (approved, merged). No code, migration, endpoint, hosted deployment, or merge follows from this document.

## 0. What this document is and is not

- A single, clearly marked proposed contract, linked from the canonical documents, not a second independently authoritative one.
- Reuses the existing device-possession primitive and extends the existing canonical-message wire pattern.
- Does not re-litigate D1–D4, Parent authentication, or the approved 24-hour D2 recovery window.
- Keeps [issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates open; promises no physical backup erasure.
- Touches no legacy CloudKit pairing/acceptance screen, activates no membership, removes no accepted `CKShare`.
- **Naming note:** this proposal's session concept is named **device-authorization session**, never "runtime session" — avoids colliding with the existing, unrelated `AthleteRuntimeSession` class.
- **Modifications to already-shipped functions/schema, flagged explicitly (updated this round — now four, not two):** (1) `revoke_device_grant` gains one additional same-transaction statement tombstoning the matching `hydration_snapshots` row (round 2). (2) `decide_connection_request` gains one additional column write, capturing the approving owner-binding's id onto the `connection_requests` row at approval (round 3, §4.6.1). (3) `claim_device_grant` gains one additional column copy, carrying that id onto the new `device_grants` row at claim (round 3, §4.6.1), alongside the already-proposed reverse hydration-snapshot association (round 2, §4.2). (4) `revoke_device_grant`'s own owner-binding check is proposed, for consistency, to move from "any active binding for the workspace" to "the specific approving binding" (round 3, §4.6.2) — flagged as a further change to already-shipped logic, with its own migration/backfill implications (§8), not hidden inside "implementation."

## 1. Closed milestone — repository facts

| Repo | PR | Title | Merge state | SHA |
|---|---|---|---|---|
| `cristern/Voxtr-Backend` | [#10](https://github.com/cristern/Voxtr-Backend/pull/10) | Parent-authenticated device grant listing/revocation | merged to `develop` | `5cdac7d39aacc5e298ee06f62c3d06f18e8e88d9` |
| `cristern/Voxtr` | [#106](https://github.com/cristern/Voxtr/pull/106) | Athlete Connection iOS pairing | merged to `develop` | `4df62923549a3538cb81b66788f5777a19880579` |

Both SHAs independently confirmed via `git fetch`. Neither PR establishes device-authorization sessions, hydration, membership activation, or CloudKit revocation.

## 2. Current-state inventory — repository facts, not proposals

### 2.1 Athlete device-possession primitive (existing, reused)

`KeychainAthleteDeviceSigningKeyStore`: installation-specific P-256 key, Keychain-stored, installation-marker-matched. Public key: 65-byte X9.63. Signature: 64-byte raw `r‖s`.

### 2.2 Backend wire pattern, confirmed schema, and confirmed lock orders

`_shared/canonicalMessage.ts`: frozen five-line canonical message for claim-submit.

**Cross-implementation evidence — three distinct layers, stated separately (round 4 finding §2, correcting a second overclaim round 3 had left standing).** Re-read `tests/integration/postgrest_bridge_integration.ts` directly this round: it generates its P-256 key pair and signs the claim proof with **Deno WebCrypto** (`crypto.subtle.generateKey`/`crypto.subtle.sign`), then sends that proof through the real, unmodified local Edge Function/bridge/database. It never executes `AthleteDeviceAuthorizationService.swift` or produces a CryptoKit signature — round 3's own correction ("exercised today only by local Docker-backed integration tests") was still wrong in exactly the way round 2's was: conflating "a local integration test exists for this wire format" with "the Swift-signing path is tested." The three layers, kept separate from here on:

1. **Deno WebCrypto signs → real local Edge Function/Deno verification.** Covered end to end by `postgrest_bridge_integration.ts`.
2. **Deno-generated frozen bytes → Swift CryptoKit verification.** Covered by `AthleteConnectionCrossImplementationFixtureTests.swift`.
3. **Swift CryptoKit signs (the real device key, the real production direction) → Deno verification.** **Unproven by any cross-implementation fixture or device run that exists today.** This remains an explicit, open evidence gate — not something either existing test closes, and not something this document claims is closed.

Confirmed schema (`20260923060545_authz_schema_v1.sql`): `authz.connection_requests`, `authz.claim_challenges`, `authz.device_grants` (composite FKs to request/invitation/device-key and to invitation/workspace/athlete), `authz.parent_sessions` (two-axis shape).

**Confirmed lock orders, re-read from source, unchanged from round 2 but restated here since round 3's §4.2 fix depends on them precisely:**
- `authz.claim_device_grant`: **first claim** locks only `authz.invitations` `FOR UPDATE`, then `INSERT`s a brand-new `device_grants` row — **no `device_grants` row exists to lock yet on this path.** Retry of an already-claimed request additionally locks the existing `device_grants` row.
- `authz.decide_connection_request`: `parent_sessions` → **the same `authz.invitations` row** `claim_device_grant`/`submit_connection_request` also lock → plain read of `connection_requests` → `workspace_owner_bindings` row last.
- `authz.revoke_device_grant`: `parent_sessions` → **`authz.device_grants` row `FOR UPDATE`** → (if found) `workspace_owner_bindings` row. **It never locks the invitation row** — restated explicitly here because round 1/2's design of `hydration-upload`'s lock table incorrectly assumed sharing the invitation lock alone would serialize upload against revocation; it does not, since revocation never touches that row. §4.2 below corrects this.

`authz.issue_claim_challenge`'s own established anti-enumeration pattern — folding every non-issuable reason (not found, not yet approved, already claimed, etc.) into one generic `request_not_available` outcome, "by construction," reused identically by `authz.redeem_workspace_enrollment` — is the precedent §3.3 below now follows for the new challenge-issue step (round 3 finding §4a).

### 2.3 Pairing handoff point

`.authorized(grantId: UUID)` is where this proposal begins.

### 2.4 Hydration pipeline and bootstrap field inventory (unchanged since round 1's correction)

Six steps; `intendedParticipantId` is the athlete's own participant; `ownerParticipantId` is the Parent's; `hydrateAccessGrant` creates a business-permission record, never device authorization; `parentGivenName` is required and non-fabricable. `hydrateOwnerParticipant` creating the owner's own participant as `.active` is existing, approved behavior — "no unauthorized activation" means the **athlete's** participant specifically, never transitioned to `.active` by hydration.

## 3. PROPOSED — Athlete device-authorization session contract

### 3.1 Unchanged

D2's fixed 24-hour `recovery_deadline` is unchanged by this proposal.

### 3.2 Proposed tables

- `authz.device_authorization_sessions`: `id`, `device_grant_id`, `token_hash`, `created_at`, `authenticated_at`, `expires_at`, `absolute_expires_at`, `revoked_at`. **New constraint this round (closing round 3 finding §3's "parallel sessions" gap):** at most one row with `revoked_at IS NULL AND absolute_expires_at > clock_timestamp()` per `device_grant_id` — enforced not by a database constraint alone (expiry is time-dependent, not a static value a `CHECK`/unique index can express) but by `session_issue`'s own transaction (§3.4.1) always locking and revoking any existing active session for the grant before creating a new one. This is stated as a behavioral invariant the function enforces, not a schema-level guarantee — `authz.device_authorization_sessions` can structurally hold multiple rows per grant; the proposal's point is that `session_issue` never leaves more than one of them live.
- `authz.device_session_challenges`: `id`, `device_grant_id`, `action`, `session_id` (nullable only for `session_issue`), `nonce`, `created_at`, `expires_at`, `used_at`.

### 3.3 Proposed wire protocol

**Canonical message** (unchanged from round 2 — the `body_sha256`/`method`/`path` circularity was already removed then):

```
voxtr-athlete-<action>-v1
device_grant_id=<lowercase uuid>
challenge_id=<lowercase uuid>
nonce=<base64url, no padding>
```

**`device-session-challenge` (issue) — pre-proof response vocabulary collapsed to avoid enumeration (round 3 finding §4a):** round 2's response distinguished `issued` from `grant_not_active`, which — since this step happens *before* any device proof — lets an unauthenticated caller learn whether a specific `device_grant_id` is currently active, the exact enumeration oracle `authz.issue_claim_challenge` was built to avoid. Corrected response vocabulary, mirroring that existing precedent exactly: `{outcome: "issued", challenge_id, nonce, expires_at}` | `{outcome: "challenge_not_available"}` — the latter folding together an unknown `device_grant_id`, an inactive/revoked grant, and any other non-issuable reason into one generic response, "by construction," never individually distinguishable from outside. A session-bound action additionally may return `{outcome: "session_invalid"}` for a missing/expired/revoked **caller-presented** `session_token` — kept distinct because it describes the caller's own credential, not a fact about some other target that an outside party could enumerate.

**`device-session-submit` (consume + perform) — one atomic transaction, stated explicitly (round 3 finding §3):** the entire sequence — lock the challenge row, validate it (`used_at`/expiry/`action`/session-binding), verify the signature, mark `used_at`, re-check `device_grants`/owner-binding/session validity with a fresh clock read taken after the last lock (§4.6), and perform the action's own effect (session insert/rotate, or the `hydration_snapshots` read/write) — happens inside **one single database transaction**. Either all of it commits or none of it does; a crash or lost connection at any point rolls back the challenge consumption together with everything else, so "challenge consumed but effect never performed" cannot exist as a committed fact. (Round 2's "fails closed" phrasing implied two separate commits; this round states the actual, single-transaction boundary instead.)

**Lost-response retry, restated from the committed outcome, not an impossible in-between state:** if the caller's HTTP response is lost, it cannot tell locally whether the transaction above committed. The uniform, correct response is the same regardless: request a fresh challenge for the same action and retry. If the original attempt committed, the old challenge is already consumed and cannot be reused either way; the action's own idempotency (`session_issue`'s single-active-session rule below; `hydration_ack`'s `already_completed` fold, §4.4) makes the retry safe whether or not the original committed.

**`session_issue`, made genuinely idempotent in effect (round 3 finding §3):** within its own transaction, under the `device_grants` row lock it already takes (§4.6), `session_issue` first checks for an existing session matching §3.2's invariant for this `device_grant_id`; if one exists, it is revoked in the **same** transaction before the new row is created. A lost-response retry therefore converges to exactly one active session no matter how many times it is retried — never silently accumulating parallel sessions, closing the gap round 3 found in round 2's "idempotent net effect" claim, which was asserted but not actually enforced.

**The two session clocks, stated accurately as two different properties (round 4 finding §3, correcting round 3's own imprecise restatement):** renewal already requires a fresh signature on *every* renewal (§3.3 above) — so the 90-day `absolute_expires_at` cannot be "how long a session lives without a fresh signature"; that is what the 7-day sliding `expires_at` actually bounds. Stated correctly: **`expires_at` (7-day sliding)** bounds how long the session can go *without* a successful proof/renewal before it lapses on its own. **`absolute_expires_at` (90-day hard cap)** bounds the total lifetime of *one renewal chain* — the same session row, rotated forward by successive valid renewals — regardless of how many of those renewals succeeded; once reached, that chain ends. A fresh `session_issue` (§3.3) starts an entirely new chain, with its own fresh 90-day clock, requiring only the still-active grant and the still-held key — never blocked by a prior chain's absolute cap. The property that was already correct and remains unchanged: the *only* thing that bounds total access duration across any number of chains is the grant's own active status, ended solely by Parent revocation — the stolen-bearer-vs-stolen-key distinction §3.5 already states.

**Swift↔Deno vectors:** none of the four action-bound fixtures exist yet; this document does not claim otherwise.

### 3.4 Proposed issuance/renewal flow — unchanged in shape, now backed by §3.3's corrected semantics

1. Issuance, renewal, get, and ack each go through `device-session-challenge`/`device-session-submit` with their own action; renewal/get/ack additionally bind to the caller's exact presented session (`session.grant == challenge.grant == target grant`).
2. Storage: device-only Keychain.

### 3.5 Automatic technical renewal vs. genuine Parent re-pairing, with concrete bounded defaults

Unchanged recommendation: 7-day sliding / 90-day absolute (PROPOSED, pending approval), automatic silent renewal while key and grant remain valid, Parent involvement only for revocation/key-loss/new-installation. §3.3 above adds the precise statement of what the absolute cap does and does not bound. Bearer-only renewal remains removed as a live alternative (§9.1).

## 4. PROPOSED — hydration upload/get/ack lifecycle

### 4.1 Unchanged

Upload must be Parent-pushed; the backend cannot source these fields itself.

### 4.2 Proposed upload/association model — lock before deciding, not decide-then-lock (round 4 finding §1, a TOCTOU bug in round 3's own fix)

**What was still wrong after round 3:** round 3 correctly gave each branch the right lock — but it left the *choice* of which branch to take as a plain, unlocked lookup performed *before* either lock was acquired. That is a classic check-then-act race: upload's unlocked read observes no `device_grants` row and decides "unclaimed"; between that read and upload actually acquiring the invitation lock, `claim_device_grant` runs to completion (locks the invitation, inserts and associates the grant, commits, releases); upload then acquires the now-free invitation lock and proceeds with the *stale* "unclaimed" decision — staging a new row under `connection_request_id` as though no grant existed, even though one now does and has already passed its own association step. The staged row is orphaned: nothing will ever associate it.

**The fix: one explicit ordering where the branch decision itself happens only after a lock is already held, never before.**

1. Lock `authz.parent_sessions` row (the Parent's own session), then **unconditionally** lock `authz.invitations` `FOR UPDATE` — the same resource `decide_connection_request`/`claim_device_grant`/`submit_connection_request` already lock, taken for *every* call regardless of which branch it turns out to be.
2. **Only now**, with that lock held, re-query whether a `device_grants` row exists for this `connection_request_id`. Because `claim_device_grant`'s first-claim path needs this exact same invitation lock to insert that row, there is no window left: either the grant was already there before this transaction started (we see it), or `claim_device_grant` is concurrently blocked waiting for the same lock (and will only proceed, and only be visible to a *later* caller, after we release it) — there is no way to observe "not yet claimed" and have it become stale before we act on it, because we never release the invitation lock between the observation and the action.
3. **If a grant now exists:** additionally lock that exact `device_grants` row `FOR UPDATE` (the same row `revoke_device_grant` locks) → lock the exact approving binding (§4.6.1, sourced from `device_grants.approving_owner_binding_id`) → fresh clock check (`status = 'active' AND revoked_at IS NULL`) → write into `hydration_snapshots` keyed by `device_grant_id`.
4. **If no grant exists:** confirm `connection_requests.status = 'approved'` (if not yet, return `not_yet_approved` and stop — nothing to stage against yet) → lock the exact approving binding (§4.6.1, sourced from `connection_requests.approving_owner_binding_id`, already written by `decide_connection_request` under this same invitation lock) → stage the row keyed by `connection_request_id`.

Both branches now hold the invitation lock continuously from before the branch decision until after the write — the decision and the action are the same critical section, not two separate steps a concurrent commit can slip between.

**Association at claim is unchanged**: `claim_device_grant`'s first-claim path inserts the new row and associates any already-staged snapshot in the same transaction, under the invitation lock it already holds — nothing about this fix changes that side.

**Tests added this round:** the exact contention scenario the review described — `claim_device_grant` commits strictly between upload's *old* unlocked preflight read and its invitation-lock acquisition — proving upload's post-lock re-query correctly reclassifies to the claimed branch and never leaves an orphaned stage. Both lock orderings from round 3 (revoke-before-upload's-grant-lock; upload's-write-before-revoke) remain required, now additionally exercised through the corrected lock-first ordering above.

Interruption/retry/immutability rules (idempotent-replace-before-association, immutable-after) are unchanged by this fix.

### 4.3 Get and ack

Both device-proof-gated per §3.3/§3.4.

### 4.4 Idempotency

`already_completed` fold, unchanged from round 2.

### 4.5 Completion model, retention bound, and permanent outcome marker (round 3 finding §4b)

**What round 2 still left open:** a retention/cleanup bound for tombstoned rows, and what happens once a tombstone is actually deleted — without something permanent recording the outcome, deleting the tombstone would make "never staged" and "staged, completed, and later cleaned up" indistinguishable again, reopening exactly the ambiguity the tombstone was built to close.

**Fix — a permanent, non-PII outcome marker on the permanent row, not just the temporary one.** `authz.device_grants` gains one more proposed column: `hydration_outcome` (`NULL | 'acked' | 'expired' | 'revoked'`), written in the **same transaction** as the `hydration_snapshots` tombstone write (§4.2's revised locking makes this safe for the revoked case specifically). `hydration-get`/`hydration-ack` check this permanent column first; it answers `already_completed`/`deadline_passed`/`grant_revoked` correctly forever, whether or not the `hydration_snapshots` row itself (PII-bearing until tombstoned, non-PII and small afterward) still exists.

**Proposed retention bound (PROPOSED default, pending approval):** tombstoned `hydration_snapshots` rows (already non-PII) are retained for 30 days for audit/support purposes, then deleted by a best-effort cleanup job. Deletion changes nothing observable — `device_grants.hydration_outcome` continues to answer every subsequent call correctly, and the immutability rule (§4.2) continues to reject any upload against a grant whose `hydration_outcome` is already set, regardless of whether the snapshot row survives.

Three triggers (verified ack; deadline passed; grant revocation via `revoke_device_grant`'s own same-transaction statement) are unchanged from round 2 other than this additional permanent marker.

### 4.6 Authorization and concurrency boundaries

**4.6.1 Owner-binding identity — ACCEPTED for Internal Alpha, 2026-10-03 (round 3 finding §2; [Product Owner acceptance](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969125531)).**

Round 2 weakened this to "some binding is active for the workspace" and moved the real property to an open question — round 3 correctly rejected that as describing a weaker check as completion of the finding. **Accepted design (still proposed at the implementation level — no migration exists yet):** `authz.connection_requests` gains a proposed `approving_owner_binding_id` column (`REFERENCES authz.workspace_owner_bindings(id)`), written by `decide_connection_request` at the moment of approval from the exact `workspace_owner_bindings` row that function already locks and reads (`v_binding.id` is already in scope there — no new lookup, just one more column write). `authz.device_grants` gains the same column, copied from the approving `connection_requests` row by `claim_device_grant` at claim time. Every operation's owner-binding check in this proposal — issuance, renewal, get, ack, upload — now means: *the specific binding named by `approving_owner_binding_id` is itself still `revoked_at IS NULL`*, not merely "some binding exists for the workspace." A different, newer active binding (an owner change) does **not** satisfy this check, because it is a different row — exactly closing round 3's "a different active binding must not satisfy the check."

**For consistency, `revoke_device_grant`'s own existing owner-binding check is accepted to move to the same, stronger form** — the Product Owner's acceptance explicitly covers this retrofit, not just the new operations (§9.4) — flagged as a change to already-shipped logic to be made in the same implementation slice, not hidden inside a later step.

**Migration/backfill — fail-closed, accepted for Internal Alpha (round 4's recommendation; the round 3 "not denied solely for that reason" default would have preserved exactly the old-owner-carry-over risk this design exists to close).** The migration adding these columns must backfill existing `device_grants`/`connection_requests` rows created before it. For a given historical row, backfill `approving_owner_binding_id` from whichever `workspace_owner_bindings` row was active at that row's own `created_at`, if exactly one such row can be identified. **Where that is ambiguous or unavailable, the accepted rule is to fail closed**: a historical grant whose provenance cannot be unambiguously backfilled is treated the same as one whose approving binding is revoked — its dependent device-authorization operations (issuance, renewal, get, ack) are denied until the Parent re-approves (an explicit re-pairing, not an automatic re-enrollment) — rather than silently preserving an unverifiable old-owner authorization. The compatibility alternative (treat `NULL` provenance as passing) is **rejected for Internal Alpha** per the Product Owner's 2026-10-03 decision (§9.4), kept below only as rejected history. This step is added to §8's sequence as its own explicit item.

**The status-quo alternative, kept only as rejected history, not a live option:** the "any active binding" check `revoke_device_grant` uses today is weaker — it does not notice an owner change at all. It is not adopted: a device grant silently remaining valid across an owner change with no re-approval by the new owner is exactly the risk the accepted design above closes.

**4.6.2 Lock order, fresh-clock rule, serialization boundary — unchanged from round 2 except where §4.2 above revises the upload row**, with `workspace_owner_bindings` row locks now also covering the lookup described in 4.6.1 above. Target-independent public errors and privileges unchanged.

## 5. CloudKit / legacy pairing boundary

Unchanged from round 2's corrected inventory (record types qualified against `CKShare`, two distinct share roots, `ScopedDelegate`'s confirmed `nil`-batch/unmapped-event behavior, domain-neutral adapter recommendation). No round 3 finding touched this section directly beyond the §2.2 production-direction correction already applied there.

## 6. Current, superseded status pointers

Unchanged from round 2's corrected attribution (the normative contract's §7 is superseded by the separate project-status document, not a later section of the same file).

## 7. Proposed test and evidence gates

### 7.1 SQL
Unchanged matrix from round 2, plus (round 3): single-active-session-per-grant enforcement under `session_issue` retry; `approving_owner_binding_id` check correctly denying a grant after an owner change while a *different* binding is active; `device_grants.hydration_outcome` answering correctly after the matching `hydration_snapshots` row is deleted. **Corrected this round (round 5 finding §1 — this line still asserted the behavior round 4's own §4.6.1/§9.4 revision superseded):** the default/recommended-policy test now asserts that backfill-left-`NULL` provenance **fails closed** (dependent operations denied) until an explicit Parent re-approval repairs it (a fresh `approving_owner_binding_id` write, the same path a new grant gets) — matching §4.6.1's and §9.4's fail-closed recommendation, not the allow-on-`NULL` behavior that recommendation replaced. If the Product Owner instead selects the compatibility alternative (§9.4), its own allow-on-`NULL` test is a **separate, explicitly conditional** case run only under that choice — never part of the unconditional default matrix alongside the fail-closed test, since the two are mutually exclusive policies.

### 7.2 Concurrency
Unchanged, plus (round 3): both upload/revoke lock orderings from §4.2, under real contention (NOWAIT-probe style), confirming no payload recreation after a revoked tombstone in either ordering. **Corrected this round (round 5 finding §2 — the round 4 version of this test described an impossible interval):** `claim_device_grant` cannot commit while `hydration-upload` already holds the invitation row, since both require that same lock — "claim commits strictly between upload's lock acquisition and its re-query" is not a reachable interleaving. The real race boundary to test is **before** upload's lock acquisition: claim commits after upload's own prior, now-removed unlocked preflight observation (if any such diagnostic read is retained at all) but strictly before upload actually acquires the invitation lock; upload's **authoritative, post-lock** re-query must then observe the now-existing grant and correctly take the claimed branch, never the stale unclaimed one. The reciprocal ordering is tested too: upload acquires the invitation lock first, and claim's own attempt to lock the same row must wait until upload's transaction releases it (commits or rolls back) before claim can proceed — proving the actual serialization property the corrected §4.2 design relies on, in both directions.

### 7.3 HTTP / live integration
Unchanged, plus (round 3): collapsed pre-proof challenge-issue vocabulary confirmed non-enumerating across all four actions; a lost-response retry of `session_issue` confirmed to leave exactly one active session.

### 7.4 iOS / 7.5 TestFlight
Unchanged.

## 8. Recommended bounded implementation sequence

Unchanged shape from round 1/2, with one explicit new step (round 3): the `approving_owner_binding_id` migration and its backfill (§4.6.1) is its own reviewable step within slice (1)/(2), not an incidental detail of implementing the session/hydration slices — named here so it cannot be silently skipped or assumed trivial.

## 9. Genuinely unresolved Product Owner decisions

### 9.1 Session renewal design

Unchanged recommendation (7-day sliding / 90-day absolute, mandatory fresh-signature renewal, no bearer-only alternative). §3.3 now states precisely what the absolute cap does and does not bound (round 3) — this does not change the recommendation, only clarifies its actual security property.

### 9.2 / 9.3

Unchanged (hydration field list; pre-grant staging retention bound).

### 9.4 Owner-binding identity on an existing grant — ACCEPTED for Internal Alpha, 2026-10-03

**Product Owner decision recorded** ([PR #108 comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969125531), replying "Enig" to [ChatGPT's round 6 recommendation](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969116873) on reviewed HEAD `b6e387571871cd700e92d87e568cb38c9fe42ff6`): both (a) and (b), previously open, are now **accepted for Internal Alpha**:

- (a) **Accepted**: the strong, exact approving-owner-binding model (§4.6.1) is the accepted direction, including retrofitting `revoke_device_grant`'s own existing check to the same strong form — not merely a new-operations-only recommendation.
- (b) **Accepted**: ambiguous historical provenance **fails closed** — a pre-existing grant whose approving binding cannot be unambiguously backfilled requires explicit Parent re-approval/re-pairing before its dependent device-authorization operations are permitted; the compatibility alternative (allow-on-`NULL`) is rejected for Internal Alpha, not merely deprioritized.

This acceptance is documentation-only: it records a Product Owner decision on the *proposed* design, not an implementation, migration, or deployment authorization — none of the schema/function changes §4.6.1 describes (the new `approving_owner_binding_id` column, the `decide_connection_request`/`claim_device_grant` writes, the `revoke_device_grant` retrofit) exist yet.

### 9.5

Unchanged (CloudKit/legacy screen retirement timing).

## 10. ChatGPT review — finding-to-change map, all five rounds

Round 6 ([comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969116873)) found no further substantive contract defect and marked this document technically review-complete as documentation — still explicitly **PROPOSED, NOT APPROVED**, not an implementation authorization. It asked that the Product Owner explicitly accept or change each choice in §9 before this proposal is treated as an accepted engineering direction, and recommended accepting the fail-closed historical-provenance treatment (§9.4) specifically. This paragraph is the only change round 6 required beyond this heading's own round count.

### Round 1 (`a422ec3`) — device proof; identity facts; upload ordering/durability; authorization/concurrency; renewal vs. re-pairing; CloudKit/status evidence. See prior HEAD's §10 for detail; all six carried forward and refined in later rounds below.

### Round 2 (`7159c95`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5968416078))

| Finding | Change |
|---|---|
| Executable proof protocol | Removed circular `body_sha256`; defined exact wire shapes; stated no fixtures exist. |
| Approval→staging→claim race | Symmetric upload/association model; corrected first-claim lock-order claim. |
| Owner-binding/lock completeness | Uniform check (later found too weak — see round 3); lock-order table; serialization restated. |
| Renewal recommendation | Concrete 7/90-day default; bearer-only alternative dropped. |
| Evidence/CloudKit completeness | Fixture direction corrected (later found still incomplete — see round 3); CloudKit inventory added; §8 misattribution fixed. |

### Round 3 (`eb1e366`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969012187))

| Finding | Change made |
|---|---|
| §1 Remaining upload↔revoke race | §4.2 now locks the actual shared resource per branch: the invitation row when unclaimed (shared with first-claim/approval), the **exact `device_grants` row** when already claimed (the same row `revoke_device_grant` locks) — closing the interleaving where invitation-only locking left revocation and upload unserialized. Added both-ordering concurrency tests. |
| §2 Owner-binding identity | §4.6.1 now recommends binding each grant to the exact approving `workspace_owner_bindings` row via a new `approving_owner_binding_id` column (on both `connection_requests` and `device_grants`), with revocation/replacement of that specific binding invalidating dependent authorization — the strong property round 2 had weakened into an open question. The "any active binding" form is kept only as a documented, named-weaker alternative (§9.4), and `revoke_device_grant`'s own check is proposed to move to the same strong form for consistency. Added an explicit migration/backfill step to §8, with a stated, bounded rule for provenance that cannot be backfilled unambiguously. |
| §3 Challenge/effect atomicity + session_issue semantics | §3.3 states challenge consumption, rechecks, and the action's effect happen in one database transaction — removing the "consumed but not performed" framing that implied two separate commits. Lost-response retry restated from the committed-or-not outcome. `session_issue` is now made genuinely idempotent (at most one active session per grant, enforced by revoking-then-reissuing inside its own transaction) rather than merely asserted idempotent. States precisely what the 90-day absolute cap does and does not bound (token lifetime between proofs, not total device access). |
| §4a Public-error enumeration | Collapsed the challenge-issue step's pre-proof outcomes to `issued`/`challenge_not_available`, mirroring `authz.issue_claim_challenge`'s own established anti-enumeration fold, removing the `grant_not_active` oracle that contradicted §4.6's own target-independent-errors claim. |
| §4b Tombstone retention | Added a proposed 30-day non-PII retention bound and, more importantly, a permanent `device_grants.hydration_outcome` marker written in the same transaction as the tombstone, so correctness survives the tombstone's own eventual deletion. |
| §4c Evidence overclaim | Corrected §2.2's "exercised every day against the live claim-submit function" to the actual fact: exercised today only by local Docker-backed integration tests, since no hosted deployment exists. |
| §4d Stale CI link | This comment and the PR description are updated to cite CI for the actual new HEAD below, not the superseded `7159c95` Codemagic link. |
| Capability confirmation | Reconfirmed below, unchanged from the round 3 answer already given. |

### Round 4 (`7af0817`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969063633))

| Finding | Change made |
|---|---|
| §1 Branch decision raced against first claim | §4.2 rewritten: the invitation row is now locked **unconditionally first**, and only *after* that lock is held does the function re-query whether a grant exists — removing the unlocked preflight read that let a concurrent `claim_device_grant` commit between observation and action, which could otherwise leave a staged snapshot permanently orphaned. Added the exact contention test the review specified. |
| §2 Evidence overclaim, still present | Re-read `postgrest_bridge_integration.ts` directly: it signs with Deno WebCrypto, never Swift CryptoKit — round 3's "exercised today only by local Docker-backed integration tests" repeated the same conflation round 2 made. §2.2 now states all three evidence layers separately and names the Swift-signs→Deno-verifies direction as the one still unproven by any fixture or device run. |
| §3 Two session clocks conflated | §3.3 corrected: the 7-day sliding `expires_at` bounds time without a successful renewal; the 90-day `absolute_expires_at` bounds one renewal *chain's* total lifetime despite continuous successful renewals, not "time without a fresh signature" (renewal already requires one every cycle). A fresh `session_issue` starts a new chain; only the grant's own active status bounds total access. |
| §4 Historical-provenance default | §4.6.1/§9.4: flipped the recommendation from "not denied solely for missing provenance" to **fail-closed** for ambiguous historical grants at Internal Alpha, with the compatibility alternative kept only as a named option carrying its stated residual risk and bounded population — not described as the strong property being "universal" while `NULL` rows bypass it. |
| Stale CI link | Checked `get_status` for the actual new HEAD before citing anything; none reported yet, stated as such rather than reusing a prior build. |
| Capability confirmation | Reconfirmed again, unchanged — event-driven while this session is active, not persistent independent of it. |

### Round 5 (`f6ad4bd`, [comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969097831))

| Finding | Change made |
|---|---|
| §1 Test matrix still asserted the superseded allow-on-NULL behavior | §7.1's test-matrix line still described the pre-round-4 policy (NULL provenance not denied by itself), contradicting §4.6.1/§9.4's own fail-closed recommendation two sections away. Corrected: the default test now asserts denial plus the Parent-re-approval repair path; the compatibility alternative's allow-on-NULL test is kept only as an explicitly conditional case under "if the Product Owner selects compatibility," never in the unconditional matrix. |
| §2 Impossible contention interval in the concurrency test | §7.2 described `claim_device_grant` committing "between upload's lock acquisition and its re-query" — not reachable, since both operations need the same invitation-row lock, so once upload holds it claim cannot proceed at all. Corrected to the real boundary: claim commits after upload's prior unlocked preflight observation but before upload's actual lock acquisition, so upload's post-lock re-query must observe the grant and take the claimed branch; added the reciprocal ordering (upload locks first, claim waits) to prove the serialization property in both directions. |

## 11. Source and precedence

Unchanged: Product Constitution → living Architecture → ADR → Domain & Data Model → Living PRD → lower documentation → implementation, per CLAUDE.md §1. [Issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates remain open; nothing here closes any of them.
