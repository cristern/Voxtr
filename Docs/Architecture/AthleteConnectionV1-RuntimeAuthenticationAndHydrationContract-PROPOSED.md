# Athlete Connection V1 — proposed runtime authentication and hydration contract

**Status: PROPOSED ENGINEERING CONTRACT — NOT APPROVED. Documentation only.** Product Owner authorized bounded discovery and documentation of this dependency on 2026-10-03 (`cristern/Voxtr#107`, comment `issuecomment-5966620681`); that authorization covers writing this document, not implementing it. Round 1 ChatGPT review ([PR #108, comment `5967090837`](https://github.com/cristern/Voxtr/pull/108#issuecomment-5967090837)) requested changes; this revision addresses every numbered finding — see §10 for the finding-to-change map. This file does not supersede, compete with, or stand equal to the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) (D1–D4, approved) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md) (approved, merged). It proposes the **next**, currently undocumented layer — how an already-approved installation (post-`claim-submit` `.authorized(grantId:)`) subsequently proves it is still authorized, and how it receives the selected athlete's minimum bootstrap data — and marks every new number, table and endpoint as a proposal requiring separate Product Owner review. No code, migration, endpoint, hosted deployment, or merge follows from this document.

## 0. What this document is and is not

- It is a single, clearly marked proposed contract, linked from the canonical documents below, not a second independently authoritative one.
- It reuses the existing, already-approved Athlete device-possession primitive (`KeychainAthleteDeviceSigningKeyStore`, P-256, Secure-Enclave-first) and the existing backend canonical-message wire pattern (`_shared/canonicalMessage.ts`). It does not invent a new device-identity mechanism.
- It does not re-litigate D1–D4, Parent authentication/session design, or the already-implemented, already-approved 24-hour same-installation recovery window (D2). It builds the **next** layer on top of the existing `authz.device_grants` row that `claim-submit` already creates.
- It keeps [issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates open and does not promise physical backup erasure.
- It does not retire any legacy CloudKit pairing/acceptance screen, does not silently activate workspace membership, and does not remove any existing accepted `CKShare`.
- **Naming note (round 1 finding, §5):** this proposal's backend "device-authorization session" must never be named or confused with the already-shipped, unrelated `AthleteRuntimeSession` class (`Sources/VoxtrAppShell/AthleteRuntimeSession.swift`, Foundation B2.5) — that existing type is the CKShare-acceptance runtime-presence holder for `CurrentSessionActor`, a legacy concept this proposal does not touch. Every reference below to the new concept uses **device-authorization session**, not "runtime session," specifically to avoid that collision.

## 1. Closed milestone — repository facts (both repos independently `git fetch`-confirmed and cross-checked against the GitHub API)

| Repo | PR | Title | Merge state | SHA |
|---|---|---|---|---|
| `cristern/Voxtr-Backend` | [#10](https://github.com/cristern/Voxtr-Backend/pull/10) | Parent-authenticated device grant listing/revocation | merged to `develop` | `5cdac7d39aacc5e298ee06f62c3d06f18e8e88d9` |
| `cristern/Voxtr` | [#106](https://github.com/cristern/Voxtr/pull/106) | Athlete Connection iOS pairing (QR scan → claim) | merged to `develop` | `4df62923549a3538cb81b66788f5777a19880579` |

Both SHAs match current `origin/develop` tips, confirmed directly via `git fetch origin develop && git log --oneline -1 origin/develop` in each repository. (`list_pull_requests` reported `merged: false` for the same PRs in this session — a confirmed API discrepancy between the list and single-PR endpoints; the single-PR `get` result and the direct `git fetch` of `develop`'s tip are the authoritative facts recorded here.)

Neither PR establishes device-authorization sessions, hydration, membership activation, or CloudKit revocation. Two other documentation PRs targeting iOS `develop` remain open and unmerged: [#104](https://github.com/cristern/Voxtr/pull/104), [#85](https://github.com/cristern/Voxtr/pull/85) — noted only so they are not mistaken for current status; not reconciled here.

## 2. Current-state inventory — repository facts, not proposals

### 2.1 Athlete device-possession primitive (existing, reused — not reinvented)

`Sources/VoxtrAppShell/AthleteDeviceSigningKeyStore.swift`: `KeychainAthleteDeviceSigningKeyStore` generates a fresh installation-specific P-256 signing key (Secure Enclave where supported) on first use, stores it in Keychain, and writes a matching installation marker to `UserDefaults`. `loadOrCreateSigningKey()` starts a new attempt; `loadExistingSigningKey()` continues one already bound to a specific key and throws rather than silently minting a replacement, distinguishing "same install, relaunch" from "reinstall, orphaned Keychain material." Public key: 65-byte uncompressed SEC1/X9.63. Signature: 64-byte raw `r‖s` (P1363).

### 2.2 Backend wire pattern and existing cross-implementation evidence (existing, confirmed against current source)

`supabase/functions/_shared/canonicalMessage.ts`: a frozen, versioned, five-line `\n`-terminated UTF-8 canonical message for the claim-proof action specifically — version line, then `challenge_id=`, `request_id=`, `invitation_id=`, `nonce=` (base64url). `Sources/VoxtrAppShell/AthleteDeviceAuthorizationService.swift`'s `canonicalMessageBytes(...)` reproduces this exact format client-side.

**Existing cross-implementation evidence (corrected — round 1 finding §6):** `Tests/VoxtrSprint0Tests/AthleteConnectionCrossImplementationFixtureTests.swift` already establishes real Swift↔Deno interoperability **for this one message shape**: a fixed set of IDs/nonce was signed once, interactively, with Swift CryptoKit, submitted against the real, unmodified backend `_shared/canonicalMessage.ts`/`_shared/p256.ts`/`_shared/base64url.ts` (not simulated or re-derived), and the resulting public key/signature/`{ok:true}` verification result was captured and frozen into the Swift test as literal hex constants. This is genuine, repository-grounded interoperability evidence — **not** a live, continuously-executed round trip (the test re-verifies the same frozen bytes on every run; it does not call a live backend), and it covers **only** the claim-submit message shape. Any new action-bound message shape this proposal introduces (§3.3) needs its own, separately generated fixture before it can be trusted — a new version-line string alone is not evidence of interoperability.

Confirmed current schema (`supabase/migrations/20260923060545_authz_schema_v1.sql`):
- `authz.connection_requests`: `id`, `invitation_id`, `device_public_key` (`BYTEA`), `display_code`, `status`, `created_at`, `decided_at`, `decided_by_parent_id`. Composite unique `(id, invitation_id, device_public_key)`.
- `authz.claim_challenges`: `id`, `connection_request_id`, `nonce` (`BYTEA`), `created_at`, `expires_at` (`= created_at + 60s`), `used_at`. Single-use, 60-second TTL, approved.
- `authz.device_grants`: `id`, `invitation_id` (`UNIQUE`), `connection_request_id`, `workspace_id`, `athlete_id`, `device_public_key`, `status` (`active|revoked`), `created_at`, `revoked_at`, `recovery_deadline` (`= created_at + 24h`). Composite FKs `dg_request_invitation_devicekey_fk` and `dg_invitation_workspace_athlete_fk` structurally bind a grant to the exact device/request/invitation/workspace/athlete it descends from — the pattern §4's new table reuses.
- `authz.parent_sessions` (`20260928100000_authz_parent_auth_session_v1.sql`): `token_hash`, `authenticated_at` (set once, carried forward unchanged by rotation), `expires_at` (24h sliding, `LEAST(clock_timestamp() + 24h, absolute_expires_at)`), `absolute_expires_at` (30-day hard ceiling, copied forward verbatim). This two-axis shape is the pattern §3 mirrors — not the same table, values, or approval.
- `authz.revoke_device_grant`'s actual lock order (`20261002160000_authz_device_grant_management_v1.sql`, confirmed from source): **(1)** `authz.parent_sessions` row `FOR UPDATE` → session-only time checks (Gate 1) → **(2)** target `authz.device_grants` row `FOR UPDATE` → **(3)**, only if the grant was found, the workspace's `authz.workspace_owner_bindings` row `FOR UPDATE`. `authz.claim_device_grant`'s own lock order is `authz.invitations` row `FOR UPDATE` → (on retry) the specific `authz.device_grants` row `FOR UPDATE`. §3.3 and §4.6 below adopt this exact ordering (session → target grant → dependent row) for every new function, so no new function introduces a lock-order pair that could deadlock against an existing one.

`AthleteDeviceAuthorizationService.swift` confirms the gateway convention any new Athlete-facing endpoint must follow: Supabase `apikey`/`Authorization: Bearer <anon key>` headers only (never a Parent-session header), snake_case wire encoding, single-vocabulary thrown-error surface.

### 2.3 Pairing handoff point (existing, confirmed)

`AthleteDeviceAuthorizationPairingCoordinator`'s state machine ends a successful attempt at `.authorized(grantId: UUID)`. This proposal begins exactly there.

### 2.4 Hydration pipeline and bootstrap field inventory (existing, confirmed — identity mapping corrected per round 1 finding §2)

`AthleteIdentityHydrationService.hydrate(_:)` (`Sources/VoxtrAppShell/`, read in full) is a `@MainActor` six-step, idempotent-per-step but **not atomic across steps** upsert pipeline: `hydrateParent` → `hydrateWorkspace` → `hydrateOwnerParticipant` → `hydrateAthleteProfile` → `hydrateAthleteParticipant` → `hydrateAccessGrant`, driven by the legacy CloudKit payload `AthleteConnectionInvitationCloudRecordPayload` (11 fields):

| Field | Required by (actual step/initializer) | Why |
|---|---|---|
| `workspaceId` | `hydrateWorkspace` | Stable ID; workspace is the membership root |
| `intendedParticipantId` | `hydrateAthleteParticipant` — **this is the selected ATHLETE's own `WorkspaceParticipant.id`**, created with `role: .athlete` and `linkedAthleteId == intendedAthleteId` | The existing athlete-participant row this invitation connects — never the owner |
| `intendedAthleteId` | `hydrateAthleteProfile`/`hydrateAthleteParticipant`/`hydrateAccessGrant` | The one canonical `AthleteProfile.id` the whole flow binds to |
| `parentId` | `hydrateParent` | Stable `ParentProfile.id`, independent of SIWA subject |
| `parentGivenName` | `hydrateParent` → `ParentProfile(givenName:)` | **Required, non-empty.** `ParentProfile.givenName: String` is a non-optional initializer parameter, and the payload's own doc comment states it explicitly: *"the Parent's own real, non-fabricated given name — `ParentProfile.givenName` is a required, non-empty field; a placeholder here would be invented content presented as truth."* This is not an optional display convenience — see the correction to §8.2 below. |
| `workspaceDisplayName` | `hydrateWorkspace` → `FamilyWorkspace(displayName:)` | Required, same non-fabrication reasoning |
| `ownerParticipantId` | `hydrateOwnerParticipant` — **the owner (Parent) `WorkspaceParticipant.id`, role `.workspaceOwner`** — also reused as `AthleteAccessGrant.participantId` in `hydrateAccessGrant` | Distinguishes the Parent's own participant row from the athlete's |
| `athleteGivenName` | `hydrateAthleteProfile` → `stageAthlete(givenName:)` | Required (non-optional) |
| `athleteBirthDateISO` | `stageAthlete(birthDate: LocalDate)` | Required; parsed from ISO date text — the existing hydration error path surfaces a raw unparseable-date reason string that must be scrubbed before any new endpoint/log exposes a hydration-failure reason (§4.7) |
| `athleteTimeZoneId` | `stageAthlete(timeZoneId:)` | Required |
| `athleteDevelopmentStage` | `stageAthlete(developmentStage:)` | Required |

`AthleteRepository.stageAthlete(...)` also accepts optional `familyName: String? = nil` and `preferredName: String? = nil` — genuinely optional on the model, never supplied by the current 11-field payload; whether to add them to a new snapshot is a real open question (§9.2), unlike `parentGivenName`.

**`hydrateAccessGrant` — corrected description.** It creates a local `AthleteAccessGrant` keyed by `(participantId: projection.ownerParticipantId, athleteId: projection.intendedAthleteId)` — i.e. a record that **the owner (Parent) participant has full access permission to this athlete's data**, a business-membership/permission fact entirely local to the iOS domain. The previous revision of this document described this as "this installation may act for this athlete in this workspace," which is the exact conflation the canonical documents (NormativeSecurityContract §1, ProjectStatus) already warn against: `AthleteAccessGrant` says nothing about *which device* is acting, and nothing about *runtime/device authorization* — it is a Parent-side permission row, not the backend's `authz.device_grants` row, and not this proposal's new device-authorization session either. This document now consistently keeps those three concepts (business permission grant, backend device grant, device-authorization session) separate in every section below.

`AthleteDeviceAuthorizationReceipt` (Keychain-backed) remains explicitly metadata-only — no challenge ID, nonce, or signature — and is never treated as proof of current authorization; §3 is the thing that actually proves it.

## 3. PROPOSED — Athlete device-authorization session contract

Everything numbered in this section is a **proposed engineering default requiring separate Product Owner sign-off**, not an approved value. Parent-session TTLs (24h sliding / 30d absolute, approved 2026-09-28) are **not** an Athlete approval by extension; cited only as the existing pattern mirrored in shape.

### 3.1 What already exists and is not re-proposed

The fixed **24-hour same-installation recovery window (D2)** is already approved and implemented as `authz.device_grants.recovery_deadline`. It governs exactly one thing: whether the same proven device key may resume `claim-submit` and receive the same grant again within 24 hours of the grant's creation, with no new invitation/approval. It says nothing about ongoing access after that deadline — the actual gap this section fills.

### 3.2 Proposed new table: `authz.device_authorization_sessions`

(Deliberately not "runtime session" — see §0's naming note.) Mirrors `authz.parent_sessions`' two-axis shape:

- `id`, `device_grant_id` (`NOT NULL REFERENCES authz.device_grants(id)`), `token_hash`, `created_at`, `authenticated_at` (set once at issuance from the signature-proof event that created this row, carried forward unchanged by every later rotation — exactly as `parent_sessions.authenticated_at` behaves), `expires_at`, `absolute_expires_at`, `revoked_at`.
- **Proposed defaults, PROPOSED not approved** (reasoning in §9.1): a sliding `expires_at` window measured in days, recomputed at each successful renewal via `LEAST(clock_timestamp() + <sliding>, absolute_expires_at)`; an `absolute_expires_at` hard ceiling from issuance.
- Every operation that touches this row — issuance, renewal, and every hydration call (§4) — re-verifies at query time, in this order (matching §2.2's confirmed lock order): the session's own `device_grant_id` FK target is still `authz.device_grants.status = 'active'` AND `revoked_at IS NULL`, then the session row itself is unrevoked and unexpired by current `clock_timestamp()`. A revoked grant invalidates every session issued against it immediately without needing to touch session rows individually — the grant remains the root of trust.

### 3.3 Proposed challenge/proof wire shapes (round 1 finding §1 — concrete, not a placeholder)

**New table**, parallel to `authz.claim_challenges`: `authz.device_session_challenges` — `id`, `device_grant_id`, `action` (`CHECK (action IN ('session_issue','session_renew','hydration_get','hydration_ack'))`), `nonce` (`BYTEA`), `created_at`, `expires_at` (`= created_at + 60s`, same TTL convention), `used_at`. A challenge issued for one `action` can never be consumed by another — enforced both by the `action` column itself and, independently, by the canonical message (below) naming the action in its own version line, so a cross-action replay is rejected twice over, not relying on either check alone.

**Canonical message, per action** — extends the existing five-line pattern (§2.2) rather than replacing it, with one new version line per action and explicit method/path/body binding:

```
voxtr-athlete-<action>-v1
device_grant_id=<lowercase uuid>
challenge_id=<lowercase uuid>
nonce=<base64url>
method=<HTTP method, e.g. POST>
path=<function name, e.g. hydration-get>
body_sha256=<base64url SHA-256 of the exact request body bytes, or the literal string "none" for a body-less call>
```

Four actions, four distinct version-line strings: `voxtr-athlete-session-issue-v1`, `voxtr-athlete-session-renew-v1`, `voxtr-athlete-hydration-get-v1`, `voxtr-athlete-hydration-ack-v1`. The `method`/`path`/`body_sha256` lines bind the signature to the exact HTTP call being authorized — directly answering the review's request that a signed proof for one action/body cannot be replayed against a different method, path, or body. Each of these four shapes needs its own frozen Swift↔Deno fixture, generated the same way `AthleteConnectionCrossImplementationFixtureTests.swift` already did for the claim-proof shape (§2.2) — not inferred from that existing fixture, which covers a different message entirely.

### 3.4 Proposed issuance/renewal flow — device proof required on every sensitive call, not bearer-only

**Round 1 finding §1 correction:** the previous revision allowed bearer-only renewal and treated fresh device proof as optional future policy. NormativeSecurityContract §3 already requires fresh device-key proof for hydration and grant refresh; this revision makes every one of the four actions below require a fresh, single-use, action-bound signature — never bearer-token possession alone.

1. **Issuance** (proposed Edge Function: `device-session-issue`). Gateway-gated like the three existing Athlete-facing functions. Device first requests a challenge bound to `(device_grant_id, action='session_issue')`, signs the canonical message (§3.3), submits `{device_grant_id, challenge_id, signature}`. Backend re-verifies the signature against `device_grants.device_public_key` for that exact grant, consumes the challenge, checks `device_grants.status = 'active'`, creates the session row, returns an opaque bearer token (hashed server-side) plus `expires_at`/`absolute_expires_at`.
2. **Renewal** (proposed: `device-session-renew`). **Requires both** the current bearer token **and** a fresh signed proof over a challenge bound to `(device_grant_id, action='session_renew')` — not the token alone. Re-checks grant-active status, rotates `expires_at` via the same `LEAST(...)` formula, carries `authenticated_at` forward unchanged.
3. **Hydration GET and ACK** (§4) each require their own fresh, action-bound signed proof in addition to a valid bearer session — directly closing the "ack authorization" and "hydration retrieval needs device proof" gaps the review raised, so a stolen bearer token alone can neither read nor prematurely erase bootstrap data.
4. **Storage.** Device-only Keychain, never UserDefaults. A reinstall or lost signing key is a new installation requiring full re-pairing, detected the same way `currentInstallationHasExistingSigningKey()` already detects it today.

### 3.5 Automatic technical renewal vs. genuine Parent re-pairing (round 1 finding §5)

These are two different things and the previous revision conflated them. **Automatic technical renewal**: as long as the installation still holds its signing key and the grant remains active, renewal (§3.4.2) happens silently in the background — the device signs its own fresh challenge with a key it already has; no user interaction, no Parent involvement, no new friction, at whatever cadence keeps the sliding window from lapsing (e.g. renewing once a meaningful fraction of the window has elapsed). **Genuine Parent/user involvement is needed only when:** the grant is revoked (Parent action); the signing key/installation is lost (a reinstall, detected via the existing installation-marker mismatch — a new installation requiring full re-pairing, not session recovery); or this is a brand-new installation that never held a grant. After the 24-hour D2 bootstrap-recovery deadline has passed, renewal continues to operate purely from the still-active grant and the still-held key — it never reopens, re-associates, or re-fetches the (by then deleted or tombstoned, per §4.5) hydration snapshot, and never revives the invitation; hydration is a one-time bootstrap event, fully decoupled from ongoing session renewal.

**Stolen-bearer vs. stolen-key/device, stated precisely:** session/token expiry bounds exposure of a bearer token that leaked *without* the signing key (e.g. from logs or a memory snapshot) — such a token eventually stops working on its own. It does **not** bound or mitigate compromise of the actual signing device/key: an attacker who has the key can mint fresh, validly-signed sessions indefinitely, regardless of any session TTL, until the Parent revokes the grant. Session expiry is a leak-containment property, not a device-compromise mitigation, and this document does not claim otherwise.

## 4. PROPOSED — hydration upload/get/ack lifecycle

### 4.1 Why upload must be Parent-pushed, not backend-pulled

The backend currently stores none of the business fields in §2.4's table — `authz.invitations`/`connection_requests`/`device_grants` carry only opaque workspace/athlete UUIDs, never a name or birth date. Per D1/NormativeSecurityContract §3 ("no profile duplication as permanent backend truth"), the backend cannot independently source this data; only the already-authenticated Parent, at approval time, can supply it. This is a recommendation grounded in the current data model, not an open decision.

### 4.2 Proposed upload ordering — one coherent model, chosen (round 1 finding §3)

**Round 1 correction:** the previous revision uploaded "immediately after approval" but keyed the snapshot by `device_grant_id` — a row that does not exist until claim-submit succeeds, minutes (or never) after approval. That was an internal contradiction between its own two sentences. This revision picks, and justifies, **exact-approved-request staging before claim**:

1. **Stage at approval** (proposed: `hydration-upload`, Parent-session-authenticated — carries `X-Voxtr-Parent-Session`, never the Athlete gateway pattern). Called by the Parent's device at the moment it approves a connection request (`authz.connection_requests.status → 'approved'`). Snapshot keyed by `connection_request_id` (which exists at this point) in a new table, `authz.hydration_snapshots`, with a composite FK `(connection_request_id, invitation_id)` into `authz.connection_requests`, mirroring `device_grants`' own `dg_request_invitation_devicekey_fk` pattern exactly. The call also re-checks the Parent's `workspace_owner_bindings` row is active (`FOR UPDATE`, mirroring `revoke_device_grant`'s own owner-binding check) — an authenticated Parent session alone is not sufficient; it must also still own this workspace.
2. **Bounded pre-grant retention: the invitation's own existing 15-minute expiry, not a second, independently-tracked deadline.** Claiming must complete before the invitation expires (already approved, already enforced) — so a staged snapshot that is never claimed is already bounded by a deadline that exists today. No new pre-grant TTL is introduced. (Whether the Product Owner wants a separate, possibly shorter, pre-grant bound instead is recorded as an open question in §9.3 — this is a recommendation, not a unilateral decision.)
3. **Atomic association at claim.** The instant `authz.claim_device_grant` creates the new `device_grants` row (inside that same function, under the device-grant row lock it already holds — see §2.2's lock order), it also sets the matching `hydration_snapshots.device_grant_id` for that `connection_request_id`, switching the row's governing deadline from the invitation's 15-minute window to the grant's existing `recovery_deadline`. From this point, a second composite FK — `(device_grant_id, workspace_id, athlete_id)` into `authz.device_grants` — rejects any mismatch using the authoritative relation, exactly as the review asked.
4. **Interruption/retry.** Re-uploading for the same, still-unclaimed `connection_request_id` is an idempotent replace (the Parent app can safely retry after a dropped response). Once a row is associated to a `device_grant_id` (or tombstoned, §4.5), it becomes immutable — any further upload attempt against that `connection_request_id` or `device_grant_id` is rejected outright, never silently recreating or overwriting PII.

### 4.3 Get and ack — both device-proof-gated (round 1 finding §1)

Both require the action-bound signed proof from §3.3/§3.4 in addition to a valid, grant-active device-authorization session — not a bearer token alone.

- **Get** (`hydration-get`): denies synchronously once `clock_timestamp() >= recovery_deadline` (`>=`, corrected from the prior `>` — matching `parent_sessions`' own boundary convention rather than `claim_device_grant`'s looser `>`, since this is a new check and this document picks the stricter, already-precedented convention deliberately). Returns the full snapshot while the grant is active and the deadline has not passed.
- **Ack** (`hydration-ack`): the device calls this only after its own `AthleteIdentityHydrationService.hydrate(...)` pipeline (§2.4) completes successfully end-to-end.

### 4.4 Idempotency

A second `ack` for an already-tombstoned grant (§4.5) returns the same `already_completed` outcome, not an error — reusing `claim-submit`'s own `granted`/`already_granted` fold pattern for "did this already happen," rather than inventing a new shape for the same question.

### 4.5 Completion model and deletion triggers (round 1 finding §3 — corrected)

**Round 1 correction:** "only ack deletes" conflicted with this document's own cleanup text and with the approved revoke lifecycle. Deletion of the PII-bearing fields happens on **whichever of three triggers fires first**, never only one:

1. **Verified ack** — the normal path. The row's PII columns are cleared and replaced with a minimal non-PII tombstone: `device_grant_id`, `completed_at`. A subsequent `hydration-get` against a tombstoned row returns a distinct `already_completed` outcome — never `not_found` (which stays reserved for "never uploaded," genuinely ambiguous with "expired" or "revoked" otherwise) and never the PII itself again.
2. **Deadline passed** — enforced synchronously by the read-denial in §4.3 regardless of whether the best-effort cleanup job has already run; the job's role is deleting the now-unreadable row, not gating readability.
3. **Grant revocation** — `revoke_device_grant`'s existing transaction (or an immediately-following step under the same row lock it already holds) also purges this row's PII, so a revoked grant cannot still be used to retrieve a snapshot through a race with the cleanup job.

A tombstoned or revoked row rejects any further `hydration-upload` for that `device_grant_id`/`connection_request_id` outright (§4.2.4) — a replay can never recreate deleted PII.

### 4.6 Authorization and concurrency boundaries (round 1 finding §4)

- **Owner-binding-active checks**: required on `hydration-upload` (Parent-session side, §4.2.1) in addition to the device-side `device_grants.status = 'active'` check already required on get/ack/session issuance/renewal.
- **Target-independent public errors**: every new function's HTTP-visible error shape must not reveal whether a referenced ID exists before the caller's own session/ownership is validated — the same anti-enumeration discipline `revoke_device_grant`'s own round-1 fix (session checks decided before any target lookup) already established; these new functions copy that ordering, not reinvent it.
- **Privileges**: `authz.device_authorization_sessions`, `authz.device_session_challenges`, and `authz.hydration_snapshots` are private `authz` schema tables with the same RLS/privilege posture (no direct `anon`/`authenticated` access) as every existing table in this schema.
- **Early invalid-session rejection / fresh checks after waits**: every new function applies the confirmed Gate-1/Gate-2 pattern (§2.2) — session-only, non-target-dependent outcomes decided immediately after the session lock, before any target row is even looked up; target-dependent, time-based outcomes re-evaluated with a fresh `clock_timestamp()` read taken *after* that target row's lock is actually acquired, never before.
- **Lock order**: every new function takes locks in the confirmed existing order — session row (where a session argument is present) → target `device_grants`/`connection_requests`/`hydration_snapshots` row → any further dependent row (`workspace_owner_bindings`) — never the reverse of any pair an existing function already locks, so no new deadlock cycle is introduced.
- **Serialization boundary, stated honestly:** this is ordinary MVCC row-locking, not an instantaneous global cutover. A `hydration-get` or session renewal that acquires its own locks and passes every check strictly before a concurrent `revoke_device_grant` call commits is legitimately allowed to complete, even though the revocation happens at nearly the same wall-clock moment. The actual guarantee is narrower and must be stated as such: any operation whose own check sequence *begins* after the revocation has already committed will observe the revoked state and fail. This document does not claim revocation is instantaneous across in-flight operations — only that it is correctly serialized against operations that have not yet started their own checks.

## 5. CloudKit / legacy pairing boundary — repository-grounded inventory (round 1 finding §6)

**Record types (confirmed by grep, consistent with `CloudKitTransport.swift`'s own repo-wide-audit claim):** exactly two `CKRecord` types exist anywhere in this codebase — `FamilyWorkspace` (business identity/zone root, `FamilyWorkspaceCloudRecordMapping.swift`) and `AthleteConnectionInvitation` (pairing, §2.4). **No Planning/Training/Reflection `CKRecord` type exists at all** — `CloudKitTransport.swift`'s own header comment states this as an already-verified, repo-wide-audited fact ("no `recordType` for `PlannedActivity`/`LoggedActivity`/etc. exists anywhere in this codebase... Planning/Training/Reflection/etc. domain modules never import CloudKit at all"), independently re-confirmed this session by grep against those domain packages. This proposal's CloudKit boundary is therefore narrower in practice than the product name "Athlete Connection" might suggest: there is no cross-domain business data flowing through CloudKit today, only business *identity* (`FamilyWorkspace`) and the pairing handshake record.

**Transport/database scope (confirmed from `CloudKitTransport.swift`):** two independent `CKSyncEngine` instances per device. `privateEngine` → `CKContainer.privateCloudDatabase`, where a device's own owned zone lives (a Parent's `FamilyWorkspace` zone is always created in the *owner's* private database — a CloudKit constraint, not a Vǫxtr choice). `sharedEngine` → `CKContainer.sharedCloudDatabase`, through which an Athlete device, after accepting the Parent's `CKShare`, addresses the *Parent-owned* zone. The Parent's own device never uses `sharedCloudDatabase` for its own zone.

**Exact enforceable boundary under this proposal — unchanged from the prior revision's substance, restated precisely:** backend revocation (`device_grants.status → 'revoked'`) blocks new device-authorization-session issuance/renewal (§3.4) and both hydration calls (§4.3) — nothing else. It does not, and cannot: retroactively invalidate `CKRecord`s already delivered through `sharedCloudDatabase`; recall bytes already downloaded to an offline device; silently activate or remove `WorkspaceParticipant`/`FamilyMembership` state; retire the legacy pairing/acceptance screen. All remain a separate integration/release gate — [issue #98](https://github.com/cristern/Voxtr/issues/98) gate C, unchanged.

**Domain-neutral hydration adapter (round 1 finding §3, implementation recommendation for a later slice, not this document):** `AthleteIdentityHydrationService.hydrate(_:)` itself should not be modified to accept a new input type. Instead, a new adapter (mirroring `AthleteConnectionInvitationCloudRecordMapping`'s own shape) should translate a `hydration-get` response into the same `AthleteConnectionInvitationCloudRecordPayload` the service already consumes — so the six-step pipeline, its conflict semantics, and the legacy CKShare-sourced path all remain exactly as they are today, untouched and not retired, with only the caller choosing which adapter constructed the payload for a given connection.

## 6. Proposed test and evidence gates

Distinguishing **repository facts** (exists today), **CI evidence** (a green Actions run would demonstrate), **unverified provider/hosted behavior** (cannot be demonstrated by CI at all), and **product choices** (require Product Owner decision).

### 6.1 SQL (repository fact once written; CI evidence once run)

- Schema tests for `authz.device_authorization_sessions`/`authz.device_session_challenges`/`authz.hydration_snapshots`, mirroring the existing `ps_authenticated_at_not_after_created_at`/`ps_expires_at_not_after_absolute`/`dg_recovery_deadline_derivation`-style structural `CHECK`s.
- The existing 6-case unknown/own/foreign × 5-session-state regression matrix pattern (`authz_device_grant_management_test.sql` Test 18), applied to the new hydration-get/ack/session functions.
- **New, round-1-required cases:** wrong device key against a correct `device_grant_id`; a valid bearer session presented with no signature at all (stolen-bearer-without-key); a challenge issued for one `action` submitted against a different action (cross-action replay); owner-binding revoked between upload staging and association; the `>=` recovery-deadline boundary at exact equality; privilege-denial checks confirming `anon`/`authenticated` cannot call any of the three new RPCs directly.
- iOS-side identity-mapping regression tests (closing round 1 finding §2's correctness gap): sibling/foreign-family isolation (`differentFamilyAlreadyExists`), each of the three relational-conflict cases (`ownerParticipantConflict`, `athleteParticipantConflict`, `athleteProfileConflict`), a partial-hydration-retry case (failure injected partway through the six steps, then a successful resume), and an explicit assertion that hydration never transitions a `WorkspaceParticipant.state` to `.active` (no unauthorized membership activation).

### 6.2 Concurrency (real PostgreSQL, same discipline as every existing concurrency script in `tests/schema/`)

- Session-renewal-under-contention, mirroring `authz_parent_session_rotation_concurrency_test.sh`.
- Revoke-grant-races-session-issuance/renewal and revoke-grant-races-hydration-get/ack, in the NOWAIT-probe-barrier style the device-grant-revocation suite already uses (not sleep-based).
- Upload-stage-races-claim: does a Parent's `hydration-upload` for a given `connection_request_id` ever race a not-yet-committed `claim-submit` for the same request in a way that could leak or misattach a snapshot — genuinely new, no existing test covers it.
- Recovery-deadline-boundary-during-genuine-contention: a `hydration-get` that begins its checks just before the deadline but whose lock wait extends past it must still be denied (mirrors the existing device-grant-revocation Test 6's before/after-DB-time evidence pattern, applied to `>=`).

### 6.3 HTTP / live integration (Docker-backed Supabase/PostgREST, same harness as `postgrest_bridge_integration.ts`)

- Full issue → renew (with fresh signature) → revalidate → revoke → denied-after-revoke flow.
- Full stage-at-approval → associate-at-claim → get → ack (`already_completed` on repeat) and get-after-deadline-denied flows.
- No sensitive value (device public key, signature, snapshot payload) appears in any non-2xx diagnostic body, as every existing integration test already confirms for its own endpoints.

### 6.4 iOS (deterministic unit tests, same discipline as `ParentSignInCoordinatorTests.swift`)

- Device-authorization-session persistence and the same installation-marker-mismatch detection the signing-key store already implements, applied to session storage: a reinstall is "no session," never a stale/renewable one.
- Hydration retry-idempotency across the corrected staging model (§4.2): an interrupted `get` is retryable from the same snapshot; a repeated `ack` after local completion returns `already_completed`, never an error.
- No test depends on `Date.now`, current weekday, locale, or CI run time for an exact asserted result — every time-dependent case injects a reference date, per CLAUDE.md §8.

### 6.5 Hosted and two-iPhone TestFlight (cannot be substituted by CI; unverified until physically run)

- Two physical iPhones: Parent approves on device A; Athlete installation on device B claims, receives a device-authorization session, hydrates via the new adapter (§5), displays the selected athlete.
- Physical revoke-while-online and revoke-while-offline-then-reconnect scenarios (D3's honest "connection cannot be verified" state, then denial on reconnect).
- Reinstall-on-device-B: confirms session/signing-key loss is a new installation requiring re-pairing.
- None of the above has occurred for this proposal. Listed so it is never later asserted as satisfied by CI alone.

## 7. Recommended bounded implementation sequence

**Recommended:** (1) backend device-authorization-session migration + bridge + Edge Functions + SQL/concurrency/integration tests, as its own slice, following the Slice A/B/C precedent; (2) backend hydration staging/association/get/ack migration + bridge + Edge Functions + tests, as a second, separate slice, now correctly ordered per §4.2 (stage-at-approval, associate-at-claim); (3) iOS device-authorization-session client, reusing `AthleteDeviceSigningKeyStore` and `AthleteDeviceAuthorizationService.swift`'s exact gateway/canonical-message pattern, with Keychain-only session storage, named distinctly from `AthleteRuntimeSession` (§0); (4) the domain-neutral hydration adapter (§5) feeding `AthleteIdentityHydrationService.hydrate(_:)` unchanged; (5) the CloudKit/legacy-boundary integration review from §5, as its own separate gate; (6) two-iPhone TestFlight evidence (§6.5).

**Alternative considered and not recommended:** combining (1) and (2). Rejected for the same reason as before — no real coupling benefit, and the existing small-slice precedent has held up across four review rounds on the most recent backend slice.

## 8. Current, superseded status pointers (round 1 finding §6)

Two paragraphs in [the normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) read as current but are dated/superseded by later sections of that **same** file, and by this document's §2.2 cross-implementation finding:

- §6's "Swift CryptoKit ↔ Deno interoperability is not yet tested" (dated 2026-09-25) is superseded: a frozen, one-time-generated cross-implementation fixture for the claim-proof message shape now exists (§2.2 above) — though, as stated there, it is not a continuously-executed live round trip and does not extend to any new message shape.
- §7's "Backend PR #5 merged the independent SIWA verifier only; HTTP authentication, nonce/session storage and enrollment are not implemented" (dated 2026-09-28) is superseded within that same document by its own later dated section ("Backend Parent authentication and enrollment checkpoint — 2026-09-28" and the project-status checkpoints), which already record backend PR #6/#7 implementing exactly those. Flagged here because a reader of §7 in isolation would be misled; the historical text in both places is preserved, not deleted, per that document's own established convention.

## 9. Genuinely unresolved Product Owner decisions

### 9.1 Does authorized Athlete access persist indefinitely after the 24-hour D2 window, or does it require periodic re-proof?

The actual new product question this task exists to raise. Two alternatives, stated precisely after round 1's correction (§3.5):

- **Alternative A — session-bounded, periodic re-proof.** The device-authorization session has its own sliding/absolute expiry (§3.2); renewal (§3.4.2) always requires a fresh signature, automatically and silently as long as the key and grant remain valid (§3.5) — this is a genuine, independent trust boundary: even a stolen bearer token alone cannot renew past expiry without the key.
- **Alternative B — grant-bounded, no independent trust boundary.** The session token still carries *some* short operational lifetime for ordinary leak-hygiene (so a token that leaked without the key eventually goes stale on its own), but renewal needs no fresh signature — it is reminted silently from the token alone, up to that hygiene lifetime. The only real trust boundary is the grant itself; the token's expiry is a leak-containment timer, not an independent check.
- **Recommendation:** Alternative A, with a conservative multi-day sliding default — exact numbers are a Product Owner decision, not something this document can settle. Alternative A is also the one that actually closes the "stolen bearer token" gap the round 1 review raised; Alternative B does not.

### 9.2 Minimum hydration field list — the real remaining question

`parentGivenName` is **not** an open question (§2.4 correction) — it is required by the existing `ParentProfile` initializer and the existing payload's own non-fabrication rule, and dropping it would require an explicit separate model/pipeline change, not a quiet omission. The genuinely open item is whether the new snapshot should also populate the model's actually-optional `familyName`/`preferredName` fields, which the legacy payload has never supplied.

### 9.3 Pre-grant staging retention bound

§4.2.2 recommends reusing the invitation's existing 15-minute expiry as the staged snapshot's pre-grant retention bound, rather than introducing a second, independently-tracked deadline. Whether the Product Owner wants a separate (possibly shorter) bound instead is open.

### 9.4 CloudKit/legacy screen retirement timing

Confirmed out of scope for this document (§5) and for [issue #98](https://github.com/cristern/Voxtr/issues/98) gate C — recorded here only so it stays visibly open.

## 10. Round 1 ChatGPT review — finding-to-change map

Reviewed HEAD at round 1: `a422ec31d3a55bad1fd084687c55840c86c22487` ([comment](https://github.com/cristern/Voxtr/pull/108#issuecomment-5967090837)).

| Finding | Change made |
|---|---|
| §1 Preserve device proof | §3.3 defines concrete action-bound canonical message shapes (method/path/body-bound); §3.4 requires fresh signed proof on issuance, renewal, hydration-get, and hydration-ack — bearer-only renewal/get removed; §2.2 corrects the cross-implementation-evidence claim to one verified shape only. |
| §2 Correct identity facts | §2.4 table and `hydrateAccessGrant` description corrected against actual source (`intendedParticipantId` = athlete participant, not owner; access grant = business permission, not device authorization); §9.2 corrects the `parentGivenName` claim; §6.1 adds the requested isolation/conflict/partial-retry/no-activation tests. |
| §3 Upload ordering/durability | §4.2 picks and justifies stage-at-approval/associate-at-claim; §4.5 lists all three deletion triggers (ack, deadline, revocation) and the tombstone/`already_completed` model; `>` corrected to `>=`. |
| §4 Authorization/concurrency boundaries | §4.6 adds owner-binding checks, target-independent errors, Gate 1/2 reuse, explicit lock order, and an honest serialization-boundary statement; §6.1/§6.2 add the requested test cases. |
| §5 Automatic renewal vs. re-pairing | §3.5 separates the two explicitly, states the stolen-bearer-vs-stolen-key distinction, and resolves Alternative B's prior self-contradiction in §9.1. |
| §6 Repository-grounded CloudKit/status evidence | §5 adds the confirmed record-type/transport inventory and the `AthleteRuntimeSession` naming-collision note; §8 marks the two stale normative-contract paragraphs with pointers, preserving their historical text. |

## 11. Source and precedence

Product Constitution → living Architecture → ADR → Domain & Data Model → Living PRD → lower documentation → implementation, per CLAUDE.md §1. This document sits at the same tier as the [technical protocol review](AthleteConnectionV1-TechnicalProtocolReview.md) and is explicitly subordinate to, and must never be read as amending, the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md). [Issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates remain open; nothing in this document closes any of them.
