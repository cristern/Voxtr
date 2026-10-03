# Athlete Connection V1 — proposed runtime authentication and hydration contract

**Status: PROPOSED ENGINEERING CONTRACT — NOT APPROVED. Documentation only.** Product Owner authorized bounded discovery and documentation of this dependency on 2026-10-03 (`cristern/Voxtr#107`, comment `issuecomment-5966620681`); that authorization covers writing this document, not implementing it. This file does not supersede, compete with, or stand equal to the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) (D1–D4, approved) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md) (approved, merged). It proposes the **next**, currently undocumented layer — how an already-approved installation (post-`claim-submit` `.authorized(grantId:)`) subsequently proves it is still authorized, and how it receives the selected athlete's minimum bootstrap data — and marks every new number, table and endpoint as a proposal requiring separate Product Owner review. No code, migration, endpoint, hosted deployment, or merge follows from this document.

## 0. What this document is and is not

- It is a single, clearly marked proposed contract, linked from the canonical documents below, not a second independently authoritative one.
- It reuses the existing, already-approved Athlete device-possession primitive (`KeychainAthleteDeviceSigningKeyStore`, P-256, Secure-Enclave-first) and the existing backend canonical-message wire pattern (`_shared/canonicalMessage.ts`). It does not invent a new device-identity mechanism.
- It does not re-litigate D1–D4, Parent authentication/session design, or the already-implemented, already-approved 24-hour same-installation recovery window (D2). It builds the **next** layer on top of the existing `authz.device_grants` row that `claim-submit` already creates.
- It keeps [issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates open and does not promise physical backup erasure.
- It does not retire any legacy CloudKit pairing/acceptance screen, does not silently activate workspace membership, and does not remove any existing accepted `CKShare`.

## 1. Closed milestone — repository facts (both repos independently `git fetch`-confirmed and cross-checked against the GitHub API)

| Repo | PR | Title | Merge state | SHA |
|---|---|---|---|---|
| `cristern/Voxtr-Backend` | [#10](https://github.com/cristern/Voxtr-Backend/pull/10) | Parent-authenticated device grant listing/revocation | merged to `develop` | `5cdac7d39aacc5e298ee06f62c3d06f18e8e88d9` |
| `cristern/Voxtr` | [#106](https://github.com/cristern/Voxtr/pull/106) | Athlete Connection iOS pairing (QR scan → claim) | merged to `develop` | `4df62923549a3538cb81b66788f5777a19880579` |

Both SHAs match current `origin/develop` tips, confirmed directly via `git fetch origin develop && git log --oneline -1 origin/develop` in each repository at the time of writing (iOS: `4df6292 Merge pull request #106 from cristern/claude/athlete-connection-ios-pairing-v1`). The GitHub API's `pull_request_read` (`get` method) independently reports `merged: true` for both at these SHAs. (`list_pull_requests` reported `merged: false` for the same PRs in this session — a confirmed API discrepancy between the list and single-PR endpoints; the single-PR `get` result and the direct `git fetch` of `develop`'s tip are the authoritative facts recorded here, not the list endpoint.)

Neither PR establishes runtime sessions, hydration, membership activation, or CloudKit revocation — confirmed by inspection of both PRs' actual diffs/bodies, consistent with the governing task comment's own framing. Backend PR #9 (connection-invitation flow, merged) explicitly flagged grant revocation as unimplemented future work at the time; PR #10 implemented exactly that, and nothing else.

Two other documentation PRs targeting iOS `develop` remain **open and unmerged** as of this writing: [#104](https://github.com/cristern/Voxtr/pull/104) ("Record merged Athlete Connection operator issuance Slice C") and [#85](https://github.com/cristern/Voxtr/pull/85) ("Update Athlete Connection closeout and AthleteApp sequencing"). Both predate PR #106 and the current `develop` tip and are superseded in substance by the project-status checkpoint update in this PR; they are not reconciled or closed by this document (closing/merging another contributor's open PR is outside this task's scope) and are noted here only so they are not mistaken for current status.

## 2. Current-state inventory — repository facts, not proposals

### 2.1 Athlete device-possession primitive (existing, reused — not reinvented)

`Sources/VoxtrAppShell/AthleteDeviceSigningKeyStore.swift`: `KeychainAthleteDeviceSigningKeyStore` (conforms to `AthleteDeviceSigningKeyStoring`) generates a fresh installation-specific P-256 signing key (Secure Enclave where supported, software fallback otherwise) on first use, stores the key material in Keychain, and writes a matching installation marker to `UserDefaults`. `loadOrCreateSigningKey()` is used only to *start* a new attempt; `loadExistingSigningKey()` is used to *continue* one already bound to a specific key and throws rather than silently minting a replacement — this distinguishes "same install, relaunch" from "reinstall, orphaned Keychain material." Public key is exposed as 65-byte uncompressed SEC1/X9.63 (`x963Representation`); signatures are 64-byte raw `r‖s` (P1363, `rawRepresentation`), matching `_shared/p256.ts`'s verifier exactly.

### 2.2 Backend wire pattern this proposal must reuse unchanged (existing, confirmed against current source)

`supabase/functions/_shared/canonicalMessage.ts` (backend, read in full this session): a frozen, versioned, five-line `\n`-terminated UTF-8 canonical message — version line, then `challenge_id=`, `request_id=`, `invitation_id=`, `nonce=` (base64url) — deliberately not JSON, so there is exactly one byte sequence per tuple. `Sources/VoxtrAppShell/AthleteDeviceAuthorizationService.swift`'s `canonicalMessageBytes(...)` reproduces this exact format client-side for `claim-submit`. Any new signed-proof endpoint proposed below reuses this same construction (version line + `key=value\n` lines, lowercase UUIDs, base64url nonce) with a **new, distinct version-line string** so a runtime-session proof can never be replayed as a claim proof or vice versa.

Confirmed current schema (`supabase/migrations/20260923060545_authz_schema_v1.sql`):
- `authz.connection_requests`: `id`, `invitation_id`, `device_public_key` (`BYTEA`), `display_code`, `status` (`pending|approved|rejected|claimed`), `created_at`, `decided_at`, `decided_by_parent_id`. Composite unique `(id, invitation_id, device_public_key)`, referenced by `device_grants`' composite FK — a grant is structurally bound to the exact device that made the request.
- `authz.claim_challenges`: `id`, `connection_request_id`, `nonce` (`BYTEA`), `created_at`, `expires_at` (`CHECK (expires_at = created_at + interval '60 seconds')`), `used_at`. Single-use, 60-second TTL, already approved (NormativeSecurityContract §6).
- `authz.device_grants`: `id`, `invitation_id` (`UNIQUE`), `connection_request_id`, `workspace_id`, `athlete_id`, `device_public_key`, `status` (`active|revoked`), `created_at`, `revoked_at`, `recovery_deadline` (`CHECK (recovery_deadline = created_at + interval '24 hours')`). This is the **existing, already-implemented, already-approved** row the proposal below must authenticate against — it is not re-specified or re-approved here.
- `authz.parent_sessions` (`20260928100000_authz_parent_auth_session_v1.sql`): `token_hash`, `authenticated_at` (set once, carried forward unchanged by rotation), `expires_at` (24h sliding, `LEAST(clock_timestamp() + 24h, absolute_expires_at)`), `absolute_expires_at` (30-day hard ceiling, copied forward verbatim). This two-axis shape is the **pattern** §3 below proposes mirroring for an Athlete runtime session — explicitly not the same table, values, or approval.

`Sources/VoxtrAppShell/AthleteDeviceAuthorizationService.swift` also confirms the exact gateway convention any new Athlete-facing endpoint must follow: Supabase `apikey` + `Authorization: Bearer <anon key>` headers only (never a Parent-session header, never a service-role or operator secret), `URLSessionParentAuthenticationTransport` reused as plain HTTP plumbing, snake_case wire encoding, and a single-vocabulary thrown-error surface per endpoint.

### 2.3 Pairing handoff point (existing, confirmed)

`AthleteDeviceAuthorizationPairingCoordinator`'s state machine ends a successful attempt at `.authorized(grantId: UUID)`. This proposal's runtime-authentication contract (§3) begins exactly there: it does not touch invitation, request, challenge, or claim semantics, all already approved and implemented.

### 2.4 Hydration pipeline and bootstrap field inventory (existing, confirmed)

`AthleteIdentityHydrationService.hydrate(_:)` (`Sources/VoxtrAppShell/`, 261 lines, read in full) is a `@MainActor` six-step, idempotent-per-step but **not atomic across steps** upsert pipeline (parent → workspace → owner participant → athlete profile → athlete participant → access grant), currently driven by the **legacy CloudKit** payload `AthleteConnectionInvitationCloudRecordPayload` (`Sources/VoxtrCore/CloudKit/AthleteConnectionInvitationCloudRecordMapping.swift`, 11 fields):

| Field | Required by | Why |
|---|---|---|
| `workspaceId` | `FamilyWorkspace` lookup/creation | Stable ID; workspace is the membership root |
| `intendedParticipantId` | owner `WorkspaceParticipant` upsert | Preserves the Parent's own stable participant ID across hydration |
| `intendedAthleteId` | `AthleteProfile`/`AthleteAccessGrant` | The one canonical ID the whole flow exists to bind to — never inferred from name/date |
| `parentId` | `ParentProfile` upsert | Stable Parent identity, independent of SIWA subject |
| `parentGivenName` | `ParentProfile` display | Display only; not used in any identity/authorization check — candidate for omission, see §8 |
| `workspaceDisplayName` | `FamilyWorkspace` display | Display only |
| `ownerParticipantId` | owner `WorkspaceParticipant` | Distinguishes the Parent's own participant row from the athlete's |
| `athleteGivenName` | `AthleteRepository.stageAthlete(givenName:)` | Required (non-optional) parameter of the existing initializer |
| `athleteBirthDateISO` | `stageAthlete(birthDate: LocalDate)` | Required; parsed from ISO date text — existing hydration error path already surfaces a raw unparseable-date reason string that must be scrubbed before any backend-facing diagnostic (see §4.6) |
| `athleteTimeZoneId` | `stageAthlete(timeZoneId:)` | Required |
| `athleteDevelopmentStage` | `stageAthlete(developmentStage:)` | Required |

`AthleteRepository.stageAthlete(...)` also accepts optional `familyName: String? = nil` and `preferredName: String? = nil`, which the current 11-field legacy payload never supplies — not a blocking gap (both are optional with safe defaults), but worth recording: any new hydration payload (§4) can choose to add them or leave them unset, and that choice is a product/UX question, not an engineering constraint.

`AthleteAccessGrant` (`Sources/VoxtrParentDomain/ParentEntities.swift`, local SwiftData `@Model`): `id`, `workspaceId`, `participantId`, `athleteId`, five `Bool` permission flags, `createdAt`/`updatedAt`/`revokedAt`, `schemaVersion`. This is the **iOS-local** record of "this installation may act for this athlete in this workspace" — it is not, and must never be conflated with, the backend's `authz.device_grants` row. Both canonical docs (NormativeSecurityContract §1, ProjectStatus 2026-09-21) repeat this warning; this proposal preserves it: `AthleteAccessGrant` is written locally only after a successful runtime-session-backed hydration (§4), never created from a bare backend grant ID alone.

`AthleteDeviceAuthorizationReceipt` (`AthleteDeviceAuthorizationReceiptStore.swift`, Keychain-backed) is explicitly metadata-only — it deliberately carries no challenge ID, nonce, or signature (all single-use/consumed) and is never treated as proof of *current* authorization. This proposal's runtime session (§3) is the thing that actually proves current authorization; the receipt is not upgraded to do so.

## 3. PROPOSED — Athlete runtime-authentication contract

Everything numbered in this section is a **proposed engineering default requiring separate Product Owner sign-off**, not an approved value. Parent-session TTLs (24h sliding / 30d absolute, approved 2026-09-28) are **not** an Athlete approval by extension; they are cited only as the existing pattern this mirrors in shape.

### 3.1 What already exists and is not re-proposed

The fixed **24-hour same-installation recovery window (D2)** is already approved and implemented as `authz.device_grants.recovery_deadline`. It governs exactly one thing: whether the *same proven device key* may resume claim-submit and receive the *same* grant again without a new invitation/approval, within 24 hours of the grant's creation. It says nothing about ongoing access *after* that deadline — that is the actual gap this section proposes filling.

### 3.2 Proposed new concept: the athlete runtime session

A new backend table, `authz.athlete_runtime_sessions` (proposed name/shape, not final), one row per issuance, mirroring `authz.parent_sessions`' two-axis shape:

- `id`, `device_grant_id` (`NOT NULL REFERENCES authz.device_grants(id)`), `token_hash`, `created_at`, `authenticated_at` (set once at issuance from the *current* successful key-proof event, carried forward unchanged by rotation — never refreshed by a mere rotation, exactly as `parent_sessions.authenticated_at` behaves), `expires_at`, `absolute_expires_at`, `revoked_at`.
- **Proposed defaults (PROPOSED, not approved):** `expires_at` sliding window of engineering-default length (e.g. 24 hours, to be decided — see §8.1, since this is the one genuinely new product question), recomputed at rotation via the same `LEAST(clock_timestamp() + <sliding>, absolute_expires_at)` pattern already proven in `parent_sessions`; `absolute_expires_at` an engineering-default hard ceiling (e.g. 30 days, likewise undecided) from issuance.
- Every session check (issuance, rotation, and — critically, per NormativeSecurityContract §3's existing instruction that active-grant must be checked on *every* sensitive operation, not just issuance — every hydration GET and every future sensitive Athlete-side call) re-verifies, at query time: `device_grants.status = 'active'`, `device_grants.revoked_at IS NULL`, the session's own `device_grant_id` still matches, and the session itself is unrevoked and unexpired by current `clock_timestamp()`. A revoked grant invalidates every session issued against it immediately, without needing to revoke sessions individually — the grant is the root of trust, not the session.

### 3.3 Proposed issuance/refresh/revalidation flow

1. **Issuance.** A new Edge Function (proposed name: `runtime-session-issue`), gateway-gated exactly like the three existing Athlete-facing functions (`apikey`/anon-key pair, no Parent session header). Request carries `device_grant_id` and a signed proof over a **new** canonical message version line (e.g. `voxtr-athlete-runtime-session-issue-v1`) binding `grant_id` + a fresh, single-use, short-TTL nonce (reusing the exact `claim_challenges`-style issue/consume pattern — a new parallel table, e.g. `authz.runtime_session_nonces`, not the same rows `claim_challenges` already burned, so a runtime-session proof can never consume or be confused with a claim-time challenge). The function re-verifies `device_public_key` on the referenced `device_grants` row matches the signature's key, and that the grant is `active`. On success: issue a session row, return an opaque bearer token (hashed server-side, as `parent_sessions.token_hash` already does) plus `expires_at`/`absolute_expires_at`.
2. **Refresh/rotation.** A new function (proposed: `runtime-session-refresh`), presented bearer token, re-checks grant-active status, rotates `expires_at` via the same `LEAST(...)` formula, carries `authenticated_at` forward unchanged, never extends `absolute_expires_at`. Mirrors `parent_sessions` rotation exactly.
3. **Revalidation.** Every subsequent sensitive call (hydration GET, §4) re-checks the full chain (§3.2) inline — never trusts a cached "was valid at issuance" result.
4. **Storage.** Device-only Keychain, matching NormativeSecurityContract §3's existing instruction ("never UserDefaults authorization truth"); a reinstall or lost signing key is a new installation requiring full re-pairing, not session recovery.

### 3.4 What this section deliberately does not decide

Whether an athlete installation needs periodic *re-proof* (a fresh signature, not just an unexpired bearer token) at some cadence, and what that cadence should be, is an open product question — see §8.1. This proposal's refresh flow (3.3.2) is written to support either answer (bearer-token-only refresh, or refresh that also demands a fresh signature) without committing to one yet.

## 4. PROPOSED — hydration upload/get/ack lifecycle

### 4.1 Why upload must be Parent-pushed, not backend-pulled

The backend currently stores none of the business fields in §2.4's table — `authz.invitations`/`connection_requests`/`device_grants` carry only `workspace_id`/`athlete_id` (opaque UUIDs), never a name, birth date, or display string. Per D1/NormativeSecurityContract §3 ("no profile/Planning/Training/Reflection duplication as permanent backend truth"), the backend must not become a secondary source of this data by, e.g., independently querying iOS state it has no channel to reach. The only place the minimum snapshot can come from is the **already-authenticated Parent**, at the moment of approval — this is a **recommendation**, not a request for a decision, since the alternative (backend-sourced) is not actually available given the current backend data model; it is recorded as a recommendation rather than asserted as decided because it does shape the endpoint list below.

### 4.2 Proposed flow

1. **Upload** (proposed: `hydration-upload`, Parent-session-authenticated — carries `X-Voxtr-Parent-Session`, exactly like the existing enrollment/invitation-creation endpoints, never the Athlete gateway pattern). Called by the Parent's own device immediately after approving a connection request, before or alongside issuing the display-code approval. Body: the exact IDs (`workspace_id`, `athlete_id`, `participant_id`s, `device_grant_id` once claimed) plus the minimum snapshot from §2.4's table, pruned to fields with no safe alternative (see §8.2 for which fields are still open). Stored in a new temporary table (proposed: `authz.hydration_snapshots`), one row per `device_grant_id`, with its own short retention deadline **equal to the existing `recovery_deadline` already on that grant** — not a second, independently-tracked deadline, to avoid two sources of truth for "when does this stop being retrievable."
2. **Get** (proposed: `hydration-get`). Athlete-gateway-gated like §3's functions, requires a **valid, unexpired, grant-active runtime session** (§3) — not merely a device signature — since this is exactly the kind of sensitive operation NormativeSecurityContract §3 requires an active-grant check on, every time, not only at issuance. Synchronously denies (does not attempt, does not partially respond) once `clock_timestamp() > recovery_deadline`, even if the cleanup/purge job that should have deleted the row has not yet run — this mirrors D2's own existing instruction exactly and is not a new rule.
3. **Ack** (proposed: `hydration-ack`). Called by the Athlete installation only after its own local `AthleteIdentityHydrationService.hydrate(...)` six-step pipeline (§2.4) completes successfully end-to-end. Only `ack` deletes the `hydration_snapshots` row — not a bare `GET` — specifically so a dropped HTTP response after a successful `GET` can be retried without re-triggering re-issuance of a new snapshot, and so a `GET` that the device received but failed to fully apply (e.g. app killed mid-`hydrate`) can be retried from the same, still-present snapshot rather than silently losing the data or requiring a brand-new Parent approval.

### 4.3 Idempotency and interrupted retries

`GET` is idempotent and repeatable until `ack` or deadline (whichever first). `ack` itself must be idempotent (a second `ack` for an already-deleted row returns the same "already complete" outcome, not an error) — the same pattern `claim-submit`'s `granted`/`already_granted` fold already uses for the analogous "did this already happen" question, reused here rather than invented fresh.

### 4.4 Purge/cleanup failure handling

Exactly as D2 already requires for the recovery payload: a best-effort cleanup job deletes expired/acked snapshot rows, but the **read path itself** is the actual enforcement boundary (synchronous deny-after-deadline in `hydration-get`, §4.2.2) — cleanup job failure is an operational/retention concern, not a security hole, because the read path never depends on cleanup having already run. This document makes no claim about underlying provider/hosted backup erasure timing; [issue #98](https://github.com/cristern/Voxtr/issues/98)'s gate B remains open and unverified, exactly as every prior canonical document already states.

### 4.5 No permanent backend profile authority

The snapshot row is retention-bounded and deleted on `ack` or deadline. The backend never becomes a place one can later query "what is this athlete's name" outside the bounded recovery window — consistent with D1 and with the existing warning against conflating `AthleteAccessGrant` (iOS, permanent, canonical) with any backend row (temporary, bounded, non-authoritative).

### 4.6 Safe errors, no PII in diagnostics

Every proposed endpoint above reuses the existing `readBoundedJson` body-size-limit pattern and the existing scrubbing discipline already enforced in the merged operator/connection-flow endpoints (comparison codes and similar sensitive values are never written to integration-test or production diagnostic output). The hydration pipeline's current raw-unparseable-date error-reason string (§2.4, flagged previously in the 2026-09-21 project-status checkpoint and still not fixed) must be scrubbed before any new endpoint response or log line can safely include a hydration-failure reason — this is a pre-existing, already-known issue repeated here because the new `hydration-ack`/error-reporting path is exactly where it would otherwise resurface, not a new defect this document discovers.

## 5. CloudKit / legacy pairing boundary

This proposal changes nothing about CloudKit. Specifically:

- **What backend revocation (an `authz.device_grants` row transitioning to `revoked`) blocks under this proposal:** issuance of new runtime sessions (§3.2 checks grant status at issuance and at every revalidation); any `hydration-get` call (§4.2.2); any future sensitive Athlete-gateway-authenticated backend call that performs the same active-grant check. That is the **entire** enforceable boundary.
- **What it does not, and cannot, do:** retroactively invalidate already-synced CloudKit records reached through the existing, separate CKShare business-sync transport (D3); recall bytes already downloaded to an offline device; silently activate or remove `WorkspaceParticipant`/`FamilyMembership` state; retire the legacy CloudKit pairing/acceptance screen. All four are explicitly out of scope for this document and remain, as the governing task instructs, a **separate integration/release gate** — the same CloudKit scope/revocation gate [issue #98](https://github.com/cristern/Voxtr/issues/98) already tracks as open (gate C), unchanged by this proposal.
- The legacy `AthleteConnectionInvitationCloudRecordPayload`/CKShare acceptance path (Foundation B) remains exactly as superseded-for-pairing-authorization-only as the existing canonical documents already state (NormativeSecurityContract §1, Authorization.md "Source and precedence") — not retired, not newly deprecated by this document.

## 6. Proposed test and evidence gates

Distinguishing, as the governing task requires: **repository facts** (exists today), **CI evidence** (a green Actions run would demonstrate), **unverified provider/hosted behavior** (cannot be demonstrated by CI at all), and **product choices** (require Product Owner decision, not a test).

### 6.1 SQL (repository fact once written; CI evidence once run)

- Schema tests for `authz.athlete_runtime_sessions` / `authz.runtime_session_nonces` / `authz.hydration_snapshots`: structural constraints mirroring the existing `ps_authenticated_at_not_after_created_at` / `ps_expires_at_not_after_absolute` pattern on `parent_sessions`, and the existing `dg_recovery_deadline_derivation`-style `CHECK` pattern on `device_grants`, applied to the new tables' own derived columns.
- A revoke-vs-active-session regression matrix, in the same shape as the existing 6-case unknown/own/foreign × 5-session-state matrix (`authz_device_grant_management_test.sql` Test 18) — here: revoked/active grant × valid/expired/revoked runtime session × hydration-get attempt.

### 6.2 Concurrency (real PostgreSQL, same discipline as every existing concurrency script in `tests/schema/`)

- Session-rotation-under-contention, mirroring `authz_parent_session_rotation_concurrency_test.sh`'s existing pattern, applied to `athlete_runtime_sessions`.
- Revoke-grant-races-session-issuance and revoke-grant-races-hydration-get, in the same NOWAIT-probe-barrier style the device-grant-revocation concurrency suite now uses (Test 7, strengthened across rounds 3–4 this session) — not a sleep-based approximation.
- Dual-claim-vs-hydration-upload ordering: does a Parent's `hydration-upload` for a given `device_grant_id` ever race a not-yet-committed `claim-submit` for the same grant in a way that could leak or misattach a snapshot. (Genuinely new scenario this proposal introduces; no existing test covers it.)

### 6.3 HTTP / live integration (Docker-backed Supabase/PostgREST, same harness as `postgrest_bridge_integration.ts`)

- Full issue → refresh → revalidate → revoke → denied-after-revoke flow for runtime sessions.
- Full upload → get → ack, get-after-deadline-denied, and ack-is-idempotent flows for hydration.
- Confirms, as every existing integration test already does, that no sensitive value (device public key, signature, snapshot payload) appears in a non-2xx diagnostic body.

### 6.4 iOS (deterministic unit tests, same discipline as `ParentSignInCoordinatorTests.swift` and the existing pairing-coordinator tests)

- Runtime-session persistence and the same installation-marker-mismatch detection the signing-key store already implements, applied to session storage: a reinstall must be treated as "no session," never as a stale/renewable one.
- Hydration retry-idempotency: a `GET` interrupted mid-`hydrate()` must be retryable from the same snapshot without a second Parent approval, and a repeated `ack` after local completion must not error.
- No test in this proposal depends on `Date.now`, current weekday, locale, or CI run time for an exact asserted result — every time-dependent case injects a reference date, per CLAUDE.md §8.

### 6.5 Hosted and two-iPhone TestFlight (cannot be substituted by CI; unverified until physically run)

- Two physical iPhones: Parent approves on device A; Athlete installation on device B claims, receives a runtime session, hydrates, and displays the selected athlete — not a simulator, not a mocked transport.
- Physical revoke-while-online (device B's next sensitive call is denied) and revoke-while-offline-then-reconnect (device B sees the honest "connection cannot be verified" D3 state while offline, then is denied on reconnect) scenarios.
- Reinstall-on-device-B scenario: confirms session/signing-key loss is treated as a new installation requiring re-pairing, not a silently-recovered session.
- None of the above has occurred for this proposal; it does not exist yet. This gate is listed so it is not later asserted as satisfied by CI alone, consistent with "CI is not product approval" in the governing task comment.

## 7. Recommended bounded implementation sequence

**Recommended:** (1) backend runtime-session migration + bridge + Edge Functions + SQL/concurrency/integration tests, as its own reviewable slice, following the exact Slice A/B/C precedent already used for Parent authentication and enrollment; (2) backend hydration upload/get/ack migration + bridge + Edge Functions + tests, as a second, separate slice — upload is Parent-session-authenticated and shares no code path with (1) beyond the IDs involved, so combining them would only make each PR harder to review without reducing real coupling; (3) iOS runtime-session client, reusing `AthleteDeviceSigningKeyStore` and the exact gateway/canonical-message pattern `AthleteDeviceAuthorizationService.swift` already establishes, with Keychain-only session storage; (4) iOS hydration consumption wired into the existing `AthleteIdentityHydrationService` (replacing its current legacy-CloudKit-payload input with the new backend-sourced snapshot, while keeping the same six-step upsert pipeline — not rewriting it); (5) the CloudKit/legacy-boundary integration review from §5, explicitly as its own separate gate, not bundled into (1)–(4); (6) two-iPhone TestFlight evidence (§6.5).

**Alternative considered and not recommended:** combining (1) and (2) into a single backend slice. Rejected because it would produce a materially larger single PR for no coupling benefit — the existing precedent of small, separately reviewable backend slices (SIWA verifier → Parent sessions → enrollment redemption → operator issuance → connection-invitation flow → device-grant management, each its own PR) has held up well across four rounds of review on the most recent slice and should continue.

## 8. Genuinely unresolved Product Owner decisions

### 8.1 Does authorized Athlete access persist indefinitely after the 24-hour D2 window, or does it require periodic re-proof?

This is the actual new product question this entire task exists to raise — nothing in the existing approved contract (D1–D4) answers it, because D2 only ever addressed the *bootstrap recovery* window, not ongoing access afterward. Two genuine alternatives, with a recommendation:

- **Alternative A — session-bounded, periodic re-proof** (mirrors the Parent 24h/30d pattern in shape, not value): the Athlete installation must periodically re-authenticate (fresh signature) on some cadence, enforced by `expires_at`/`absolute_expires_at` as proposed in §3.2. Matches the product's existing instinct (Parent sessions already work this way) and bounds how long a compromised-but-undetected device can act. Cost: a currently-offline-then-reconnecting Athlete device could find itself needing a fresh signed proof before its next sensitive call, which is new user-facing friction that doesn't exist today.
- **Alternative B — grant-bounded, no independent session expiry**: the runtime session never expires on its own; the **grant** (`device_grants.status`) is the only thing that can end access, and the session row exists purely to avoid re-signing on every single call (a short-lived bearer token as a convenience cache, not an independent trust boundary). Simpler, and arguably more honest about what's actually true today (nothing currently re-checks Athlete device possession after claim-submit) — but means a stolen/cloned session token remains valid indefinitely until the Parent notices and revokes, with no independent time-based backstop.
- **Recommendation:** Alternative A, with conservative proposed defaults (e.g. a sliding window measured in days, not hours, since this is a child's device used intermittently, not a Parent's phone used daily) — but the exact numbers, and whether A or B is preferred at all, are Product Owner decisions, not something this document can settle.

### 8.2 Exact minimum hydration field list

§2.4's eleven existing legacy fields are a *starting* inventory, not a final answer. Two concrete open items: (a) is `parentGivenName` actually needed on the Athlete side for anything beyond display, or can it be dropped from the new snapshot entirely, reducing what crosses the wire; (b) should the new snapshot also populate `familyName`/`preferredName` (currently available as optional `stageAthlete` parameters but never supplied by the legacy payload), or is omitting them an accepted product choice. Neither blocks the engineering design in §4, but both affect exactly what minimum snapshot gets specified in the eventual migration.

### 8.3 CloudKit/legacy screen retirement timing

Confirmed out of scope for this document (§5) and for [issue #98](https://github.com/cristern/Voxtr/issues/98)'s gate C — recorded here only so it is visibly still open, not silently dropped, and not something this proposal accidentally answers by omission.

## 9. Source and precedence

Product Constitution → living Architecture → ADR → Domain & Data Model → Living PRD → lower documentation → implementation, per CLAUDE.md §1. This document sits at the same tier as the [technical protocol review](AthleteConnectionV1-TechnicalProtocolReview.md) — an engineering proposal awaiting review — and is explicitly subordinate to, and must never be read as amending, the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) or the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md). [Issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates remain open; nothing in this document closes any of them.
