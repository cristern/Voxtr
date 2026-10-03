# Athlete Connection V1 — proposed runtime authentication and hydration contract

**Status: PROPOSED ENGINEERING CONTRACT — NOT APPROVED. Documentation only.** Product Owner authorized bounded discovery and documentation of this dependency on 2026-10-03 (`cristern/Voxtr#107`, comment `issuecomment-5966620681`); that authorization covers writing this document, not implementing it. Three ChatGPT review rounds on PR #108 ([round 1](https://github.com/cristern/Voxtr/pull/108#issuecomment-5967090837), [round 2](https://github.com/cristern/Voxtr/pull/108#issuecomment-5968416078), [round 3](https://github.com/cristern/Voxtr/pull/108#issuecomment-5969012187)) requested changes; this revision addresses every finding from all three — see §10. This file does not supersede, compete with, or stand equal to the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) (D1–D4, approved) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md) (approved, merged). No code, migration, endpoint, hosted deployment, or merge follows from this document.

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

**Cross-implementation evidence, direction and scope corrected again this round (round 3 finding §4).** `AthleteConnectionCrossImplementationFixtureTests.swift` proves: a Deno-generated signature, confirmed valid by the backend's own Deno verifier, also verifies under Swift CryptoKit — i.e. Swift's *verification* side is wire-compatible with Deno's. It does **not** prove the reverse (Swift signs, Deno verifies), which is what production actually does. **Round 3 correction:** that reverse direction is **not**, as an earlier revision of this document said, "exercised every day against the live claim-submit function" — there is no hosted deployment yet (confirmed against the project-status document), so there is no live daily traffic of any kind. The accurate statement: `AthleteDeviceAuthorizationService.swift`'s Swift-signs path is exercised today only by local, Docker-backed integration tests (`tests/integration/postgrest_bridge_integration.ts`) running the real, unmodified Edge Function code in a local Supabase stack, and will be exercised live only once hosted deployment and TestFlight evidence exist — both still open gates.

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

**What the absolute cap actually limits, stated precisely (round 3 finding §3):** the 90-day `absolute_expires_at` (§3.5) bounds how long a *single issued session* can live without a fresh signature — it is **not** a cap on how long a device can retain access overall, since `session_issue` itself is gated only by the grant's active status and the still-held key, never by any session's own absolute cap, and can always mint a fresh session with its own fresh 90-day clock. The only thing that bounds total access duration is the grant's own active status, ended solely by Parent revocation — the same stolen-bearer-vs-stolen-key distinction §3.5 already states, made explicit here for exactly what the number limits.

**Swift↔Deno vectors:** none of the four action-bound fixtures exist yet; this document does not claim otherwise.

### 3.4 Proposed issuance/renewal flow — unchanged in shape, now backed by §3.3's corrected semantics

1. Issuance, renewal, get, and ack each go through `device-session-challenge`/`device-session-submit` with their own action; renewal/get/ack additionally bind to the caller's exact presented session (`session.grant == challenge.grant == target grant`).
2. Storage: device-only Keychain.

### 3.5 Automatic technical renewal vs. genuine Parent re-pairing, with concrete bounded defaults

Unchanged recommendation: 7-day sliding / 90-day absolute (PROPOSED, pending approval), automatic silent renewal while key and grant remain valid, Parent involvement only for revocation/key-loss/new-installation. §3.3 above adds the precise statement of what the absolute cap does and does not bound. Bearer-only renewal remains removed as a live alternative (§9.1).

## 4. PROPOSED — hydration upload/get/ack lifecycle

### 4.1 Unchanged

Upload must be Parent-pushed; the backend cannot source these fields itself.

### 4.2 Proposed upload/association model — the remaining race closed by locking the actual shared resource (round 3 finding §1)

**What was still wrong after round 2:** round 2 had `hydration-upload` lock the `authz.invitations` row and assumed this would serialize it against `revoke_device_grant`. Per §2.2's confirmed facts, `revoke_device_grant` never locks the invitation row at all — it locks `device_grants`. So the claimed-branch design (upload "looks up" an existing grant without locking it) left exactly the interleaving round 3 described possible: upload reads an active grant, revoke commits a tombstone, upload then still writes fresh PII after the revocation.

**The fix: two branches, each locking the resource that is actually shared with the operation it must serialize against.**

- **Unclaimed branch** (no `device_grants` row exists yet for this `connection_request_id`): lock `authz.invitations` `FOR UPDATE` — the same resource `decide_connection_request`/`claim_device_grant`/`submit_connection_request` already lock — then `workspace_owner_bindings` row (§4.6.1), then stage the row keyed by `connection_request_id`. This branch's serialization is against first-claim and approval, which is what the invitation lock actually shares with.
- **Already-claimed branch** (a `device_grants` row already exists): lock that **exact `device_grants` row `FOR UPDATE`** — the same row `revoke_device_grant` locks — then `workspace_owner_bindings` row (§4.6.1), then the `hydration_snapshots` row. Only *after* acquiring the `device_grants` lock does the function take a fresh `clock_timestamp()` read and re-check `status = 'active' AND revoked_at IS NULL`; if revoked, it rejects (`grant_revoked`) and writes nothing. Because this is the same row `revoke_device_grant` locks, the two operations are now genuinely serialized: whichever commits first (upload's write, or revoke's tombstone) is observed by the other, and §4.5's same-transaction revocation purge means a revoke that commits *after* an upload's write still removes that freshly-written PII, in the same transaction as the revocation itself — closing the gap for both orderings, not just one.

**Association at claim remains as round 2 described it**, unaffected by this fix: `claim_device_grant`'s first-claim path inserts the new `device_grants` row and, in the same transaction, associates any already-staged `hydration_snapshots` row for that `connection_request_id` — this needs no lock on a pre-existing grant row because there is no pre-existing grant row on this path; the insert itself is the serialization point.

**Tests added this round:** both lock orderings explicitly — revoke's commit landing before upload's `device_grants`-row lock attempt (upload must then see `revoked`, write nothing); upload's lock/write committing before revoke's (revoke's own same-transaction purge, §4.5, must still remove that PII); and no-payload-recreation-after-a-revoked-tombstone under real contention (NOWAIT-probe style, matching this codebase's existing concurrency-test discipline), not merely asserted.

Interruption/retry/immutability rules (§4.2 round 2: idempotent-replace-before-association, immutable-after) are unchanged by this fix.

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

**4.6.1 Owner-binding identity — the strong design is now the recommendation, not the status quo (round 3 finding §2).**

Round 2 weakened this to "some binding is active for the workspace" and moved the real property to an open question — round 3 correctly rejected that as describing a weaker check as completion of the finding. **Corrected engineering recommendation:** `authz.connection_requests` gains a proposed `approving_owner_binding_id` column (`REFERENCES authz.workspace_owner_bindings(id)`), written by `decide_connection_request` at the moment of approval from the exact `workspace_owner_bindings` row that function already locks and reads (`v_binding.id` is already in scope there — no new lookup, just one more column write). `authz.device_grants` gains the same column, copied from the approving `connection_requests` row by `claim_device_grant` at claim time. Every operation's owner-binding check in this proposal — issuance, renewal, get, ack, upload — now means: *the specific binding named by `approving_owner_binding_id` is itself still `revoked_at IS NULL`*, not merely "some binding exists for the workspace." A different, newer active binding (an owner change) does **not** satisfy this check, because it is a different row — exactly closing round 3's "a different active binding must not satisfy the check."

**For consistency, `revoke_device_grant`'s own existing owner-binding check is proposed to move to the same, stronger form** — flagged explicitly as a further change to already-shipped logic, not hidden inside a later implementation step, because leaving it on the old "any active binding" form while every new operation uses the strong form would make the two inconsistent with each other on the very question round 3 raised.

**Migration/backfill, named explicitly rather than left implicit (round 3 finding §2):** the migration adding these columns must backfill existing `device_grants`/`connection_requests` rows created before it. For a given historical row, backfill `approving_owner_binding_id` from whichever `workspace_owner_bindings` row was active at that row's own `created_at`, if exactly one such row can be identified; where that is ambiguous or unavailable from existing audit data, the column is left `NULL` for that row and **pre-existing grants with a `NULL` provenance are not denied solely for that reason** — a bounded decision this document surfaces for Product Owner sign-off, not one it resolves by inventing a default. This step is added to §8's sequence as its own explicit item, not left as an unstated implementation detail.

**The status-quo alternative, kept only as a documented alternative with its own security consequence, never as "done":** the "any active binding" check `revoke_device_grant` uses today is weaker — it does not notice an owner change at all. Adopting it everywhere (instead of the recommendation above) would mean a device grant silently remains valid across an owner change with no re-approval by the new owner — recorded in §9.4 as the explicit alternative and its consequence, not as this document's actual recommendation.

**4.6.2 Lock order, fresh-clock rule, serialization boundary — unchanged from round 2 except where §4.2 above revises the upload row**, with `workspace_owner_bindings` row locks now also covering the lookup described in 4.6.1 above. Target-independent public errors and privileges unchanged.

## 5. CloudKit / legacy pairing boundary

Unchanged from round 2's corrected inventory (record types qualified against `CKShare`, two distinct share roots, `ScopedDelegate`'s confirmed `nil`-batch/unmapped-event behavior, domain-neutral adapter recommendation). No round 3 finding touched this section directly beyond the §2.2 production-direction correction already applied there.

## 6. Current, superseded status pointers

Unchanged from round 2's corrected attribution (the normative contract's §7 is superseded by the separate project-status document, not a later section of the same file).

## 7. Proposed test and evidence gates

### 7.1 SQL
Unchanged matrix from round 2, plus (round 3): single-active-session-per-grant enforcement under `session_issue` retry; `approving_owner_binding_id` check correctly denying a grant after an owner change while a *different* binding is active; backfill-left-`NULL` provenance not causing a denial by itself; `device_grants.hydration_outcome` answering correctly after the matching `hydration_snapshots` row is deleted.

### 7.2 Concurrency
Unchanged, plus (round 3): both upload/revoke lock orderings from §4.2, under real contention (NOWAIT-probe style), confirming no payload recreation after a revoked tombstone in either ordering.

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

### 9.4 Owner-binding identity — reframed as the alternative, not the recommendation (round 3 correction)

§4.6.1 now recommends the strong, provenance-based check as the engineering default. What remains genuinely open is only: (a) whether the Product Owner accepts retrofitting `revoke_device_grant`'s own existing check to the same strong form (a change to already-shipped behavior, with the stated migration/backfill cost); (b) how pre-existing grants whose provenance cannot be unambiguously backfilled should be treated beyond this document's "do not deny solely for missing provenance" default, if the Product Owner wants a stricter rule instead.

### 9.5

Unchanged (CloudKit/legacy screen retirement timing).

## 10. ChatGPT review — finding-to-change map, all three rounds

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

## 11. Source and precedence

Unchanged: Product Constitution → living Architecture → ADR → Domain & Data Model → Living PRD → lower documentation → implementation, per CLAUDE.md §1. [Issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates remain open; nothing here closes any of them.
