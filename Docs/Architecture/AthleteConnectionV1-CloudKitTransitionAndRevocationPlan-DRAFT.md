# Athlete Connection V1 — CloudKit transition and existing-access revocation plan

**Status: repository-grounded plan, documentation-only, pending ChatGPT/Product Owner review.** Supersedes the task-brief-only prior revision of this same file. This is runtime contract [§8 step 6](AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md#8-recommended-bounded-implementation-sequence): a boundary review and a separately reviewable revocation plan, not an implementation authorization. Nothing here changes product behavior, removes CloudKit code, migrates data, deploys, or merges.

## 0. What this document is and is not

- A full elaboration of the baseline contract's [§5 CloudKit/legacy pairing boundary](AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md#5-cloudkit--legacy-pairing-boundary--retirement-timing-accepted-deferred-2026-10-03) and [§9.5](AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md#95-cloudkitlegacy-screen-retirement-timing--accepted-deferred) — the "separately reviewed existing-access revocation plan" that document explicitly deferred to this one. It does not re-litigate or amend §5/§9.5's own accepted facts; it extends them with the concrete plan those sections called for.
- Grounded in direct inspection of `cristern/Voxtr` `develop` at `a53bddbb78057243ae7774ec9b83284d45dc7658` (PR #117 merge). Every repository-fact claim below cites an exact path; several directly re-verify claims the baseline contract already made, rather than assuming they still hold after #116/#117 merged.
- Does not implement anything: no CloudKit code is removed, no migration runs, no UI changes, no backend change, no hosted deployment. The adapter/UI integration slices in §5 are a dependency map only.
- Does not close any of [issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates. Gate C (actual CloudKit permissions/revocation) is this document's own subject, and this document does not itself constitute the evidence that gate requires — see §7.
- Flags six genuine product decisions individually in §8, with a recommended default each. None is silently selected here.

## 1. Baseline and authority

Per [CLAUDE.md §1](../../CLAUDE.md), authority runs Product Constitution → Architecture → ADR → Domain & Data Model → Living PRD → lower documentation → implementation. This document is lower documentation, subordinate to and never amending the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md), the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md), or the accepted [runtime authentication and hydration contract](AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md).

- PR #117 (issue #111, the athlete-side backend hydration adapter) merged into `develop` at `a53bddbb78057243ae7774ec9b83284d45dc7658`, following the device-authorization-session client (PR #116). This is the current baseline for every source citation below.
- Runtime contract baseline: `AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md`, accepted in full at `e53d653f17909abd705d06eda2b77867038ff5b7` (see that document's own §9 for all six accepted Product Owner decisions, and §10 for its eight ChatGPT review rounds). Still accurate against current `develop`: re-verified below (§2) rather than assumed.
- [Issue #107 comment 5972055089](https://github.com/cristern/Voxtr/issues/107#issuecomment-5972055089) (provenance clarification cited by issue #112): records the accepted §4.6.1 owner-binding provenance precision and the backend-#11 merge checkpoint. It is backend grant/request provenance, not CloudKit-specific; cited here only because issue #112 named it as required reading — it does not change anything in this document's own CloudKit findings.
- [Issue #98](https://github.com/cristern/Voxtr/issues/98), gate 3 ("actual CloudKit permissions and revocation"): the task that originally asked for exactly this repository-wide audit. Still open — see §7.

## 2. Repository inventory — CKShare roots, databases, sync, and caches

All facts in this section were verified directly against `develop` at `a53bddb`, not inferred from the baseline contract's own §5 (though they confirm it).

### 2.1 Two independent CKShare roots, one confirmed consumer

Exactly two Vǫxtr-defined `CKRecord` `recordType` values exist repo-wide: `FamilyWorkspace` (`Sources/VoxtrCore/CloudKit/FamilyWorkspaceCloudRecordMapping.swift`) and `AthleteConnectionInvitation` (`Sources/VoxtrCore/CloudKit/AthleteConnectionInvitationCloudRecordMapping.swift`). `CKShare` itself is an Apple-provided `CKRecord` subclass, outside this count, present on both roots below.

1. **`FamilyWorkspace`-root share** (`Sources/VoxtrCore/CloudKit/FamilyWorkspaceOwnerShareCoordinator.swift`, `ensureSharingRoot(forWorkspace:)`): a Parent-owned, per-workspace custom zone (`FamilyWorkspaceCloudZoneIdentifier.ownerZoneID(forWorkspace:)`) in the owner's own private database, with one deterministic root `CKRecord` and one `CKShare` rooted on it (`publicPermission = .none`). Idempotent: repeated calls converge on the same zone/record/share, never duplicating any of the three (`ensureZone`/`ensureRootRecord`/`ensureShare`, each with its own fetch-before-create or conflict-convergence path). **No participant-side acceptance consumer for this exact share was found in this repository** — `prepareInvitation` (below) calls `ensureSharingRoot` only to obtain the already-established `zoneID`; the share/root record this method itself returns are otherwise unused by the invitation flow. Reported as "none found," not "none exists" — this is the same honest framing the baseline contract already used.
2. **`AthleteConnectionInvitation`-root share** (`FamilyWorkspaceOwnerShareCoordinator.createInvitationShare(zoneID:payload:)`, called from `Sources/VoxtrAppShell/AthleteConnectionOwnerHandoffService.swift`): one brand-new, independent invitation record + `CKShare` per invitation, **never idempotent, never reused** — every call to `prepareInvitation(forAthlete:workspaceId:invitedBy:)` creates a fresh `invitationId` and a fresh share, placed in the same zone `ensureSharingRoot` already established, with no `.parent` relationship to that zone's own root record. `publicPermission = .none`; only the specific person the Parent's native share sheet targets can join. Record payload: the 11-field `AthleteConnectionInvitationCloudRecordPayload` (workspace/participant/athlete/parent identity + athlete bootstrap fields — exactly runtime contract §2.4's table). **Confirmed acceptance consumer:** `Sources/VoxtrCore/CloudKit/FamilyWorkspaceParticipantShareCoordinator.swift`'s `resolveAcceptedShare(from:)` — accepts/resolves via `CloudKitTransport.accept(_:)`, reads `metadata.hierarchicalRootRecordID` (which, since PR #68's architecture change, is the invitation record's own ID directly — no separate workspace-root fetch), and fetches that record from `CKContainer.sharedCloudDatabase`.

### 2.2 Transport/database scope — two sync engines, no business-data delivery through either

`Sources/VoxtrCore/CloudKit/CloudKitTransport.swift`: two independent `CKSyncEngine` instances per device — `privateEngine` → `CKContainer.privateCloudDatabase` (the current device's own zone(s): a Parent's `FamilyWorkspace` zone, or an Athlete's own private zone), `sharedEngine` → `CKContainer.sharedCloudDatabase` (zones shared TO the current device by another owner — how an Athlete device reaches the Parent-owned `FamilyWorkspace` zone after share acceptance; the Parent's own device never uses its shared database for its own zone). `ScopedDelegate.handleEvent` (lines 237–244) persists only `.stateUpdate` sync-engine continuity state and logs every other event as "not yet mapped" — no record-level event handling exists. `nextRecordZoneChangeBatch` (lines 246–255) **always returns `nil`**, honestly documented as such because no local write path creates a `CKRecord` change yet. **Two running sync engines, by themselves, establish no business-data delivery today** — this is independently re-confirmed against current `develop`, not merely cited from the baseline contract.

### 2.3 Legacy acceptance/sync consumer chain — full sequencing, re-verified

The complete Athlete-side consumer chain for an accepted `CKShare`, read end to end from current source (`Sources/VoxtrAppShell/AthleteRuntimeSession.swift`, `AthleteConnectionLifecycleService.swift`):

1. `AthleteCloudKitShareAppDelegate.application(_:userDidAcceptCloudKitShareWith:)` (`AthleteRuntimeSession.swift:177-190`) — the real iOS callback, bridging into `AthleteRuntimeSession.shared.handleAcceptedCloudKitShare(_:)` via a structured `Task { @MainActor in }`.
2. `AthleteRuntimeSession.handleAcceptedCloudKitShare` → `AthleteConnectionLifecycleService.connect(from:)` (`AthleteConnectionLifecycleService.swift:155-163`).
3. `FamilyWorkspaceParticipantShareCoordinator.resolveAcceptedShare(from:)` (§2.1) → `AcceptedFamilyWorkspaceShare`.
4. `AthleteIdentityHydrationService.hydrate(_:)` (unchanged by #116/#117 — confirmed in §2.4 below) — upserts `ParentProfile` → `FamilyWorkspace` → owner `WorkspaceParticipant` (created `.active` directly) → `AthleteProfile` → athlete `WorkspaceParticipant` (created `.invited`, never auto-activated) → `AthleteAccessGrant`, by stable ID, idempotent per step.
5. `AcceptWorkspaceInvitationService.accept(...)` — the sole canonical `.invited → .active` transition for the athlete's own participant; independently re-evaluates eligibility from a fresh `AthleteRepository` lookup.
6. `AthleteConnectionIdentityBindingService.bind(...)` (B2.3) — binds the accepted transport identity to the exact existing local identity, requiring it already `.active`.
7. `AthleteSessionActivationService.activate(boundIdentity:)` (B2.4, `AthleteSessionActivationService.swift:79-129`) — re-fetches the specific `WorkspaceParticipant` by ID and re-validates workspace/role/state/athlete-link against the **current** record (never trusting the B2.3 result as authority on its own) before resolving `CurrentSessionActor.resolve(from:)`.
8. `AthleteRuntimeSession.state` becomes `.connected(CurrentSessionActor)` — held only in memory.

**No persisted runtime-session restoration exists for AthleteApp.** `AthleteRuntimeSession.swift:65-75`'s own doc comment states this explicitly: nothing infers or restores an actor at launch; a relaunch after a previously successful connection starts back at `.notConnected`; there is no `UserDefaults`/Keychain persistence of `participantId` for this purpose (unlike `FamilyRestorationService` on the Parent side, `Sources/VoxtrAppShell/FamilyRestorationService.swift`, which restores Parent-side state from the local SwiftData graph directly, not from any CloudKit-specific session record). **Concretely:** relaunching AthleteApp today requires a **new** accepted-share callback to reach `.connected` again; the already-hydrated SwiftData rows persist regardless (§2.5), but the in-memory `CurrentSessionActor` does not survive a relaunch by any mechanism this repository implements.

**Re-activation re-validates fully, every time.** Because `AthleteSessionActivationService.activate(boundIdentity:)` always re-fetches and re-checks the live `WorkspaceParticipant` record, any `.active → .revoked` style local state change *would* be caught at the **next** activation attempt — but there is currently no local mechanism to make that exact transition at all (§2.7), and no mechanism to re-run activation **while an app process is already running** with a `.connected` state — `AthleteRuntimeSession` holds its actor in memory for the process lifetime with no periodic re-check.

### 2.4 The new, parallel device-authorization/hydration path converges on the same local rows — confirmed unchanged

PR #116/#117 added `AthleteDeviceAuthorizationSessionManager`/`AthleteDeviceAuthorizationSessionService`/`AthleteBackendHydrationAdapter` (`Sources/VoxtrAppShell/`). Confirmed directly in `CompositionRoot.swift:311-332`: `athleteBackendHydrationAdapter` is constructed with **the same** `athleteIdentityHydrationService` instance as the legacy `athleteConnectionLifecycleService` (line 330 passes `identityHydrationService: athleteIdentityHydrationService`, the identical object registered at line 317). `AthleteIdentityHydrationService.hydrate(_:)` itself takes zero PR #116/#117 changes beyond the one explicitly-approved internal test-only fault seam added in PR #117 (`accessGrantPersistenceFaultForTesting`, `nil` for every real caller — see that PR's own delivery record). **Both the legacy CKShare path and the new backend-session path write to the exact same stable-ID-keyed SwiftData rows** — this is the concrete mechanism behind "preserve IDs and membership" in §4.1 below: there is structurally only one destination graph, never two.

The adapter is registered but, per its own doc comment and `CompositionRoot.swift:319-326`'s comment, **not wired into any UI/navigation** — `AthleteRuntimeSession`/`AthleteRootView` still only ever call the legacy `AthleteConnectionLifecycleService.connect(...)` path. No code path exists today that calls the new adapter in production.

### 2.5 Local SwiftData caches — what persists independently of CloudKit or backend state

Once hydrated (by either path, §2.4), these rows exist in the device's local SwiftData store (`SwiftDataPersistenceController`, confirmed `cloudKitDatabase: .none` per `CloudKitTransport.swift`'s own doc comment — SwiftData's own CloudKit mirroring is explicitly not used) and are **not** deleted by anything CloudKit- or backend-side:

- `ParentProfile`, `FamilyWorkspace`, owner `WorkspaceParticipant`, the athlete's `WorkspaceParticipant`, `AthleteProfile`, `AthleteAccessGrant` — the exact six entities `AthleteIdentityHydrationService.hydrate(_:)` upserts (§2.4).
- Everything downstream that the athlete's own app builds against that local graph once connected (Planning/Training/Reflection domain rows) — these are the athlete's own locally-created business data, never themselves sourced from or synced through CloudKit (§2.6), so neither CloudKit revocation nor backend grant revocation touches them at all; they are governed exclusively by the device's own local SwiftData lifecycle (app delete, OS reinstall, etc.).

### 2.6 Confirmed: no Planning/Training/Reflection CloudKit sync exists today

Independently re-verified (not merely cited from the baseline contract or `CloudKitTransport.swift`'s own comment):

```
$ grep -rn "import CloudKit" Sources/VoxtrPlanningDomain Sources/VoxtrTrainingDomain Sources/VoxtrReflectionDomain
(no matches — exit code 1)
```

Combined with §2.2's confirmed "`nextRecordZoneChangeBatch` always returns `nil`," this closes the exact question issue #98 gate 3 asks ("Confirm whether any Planning/Training/Reflection data are actually synced over CloudKit today"): **no.** Nothing in this domain can be "revoked" via CloudKit, because nothing in it is delivered via CloudKit in the first place.

### 2.7 Confirmed: no existing local mechanism to revoke an already-active athlete's membership, and no `CKShare` participant-removal code anywhere

Two distinct, confirmed gaps, both load-bearing for §4 below:

1. **`CKShare.Participant` removal/revocation is never referenced anywhere in this repository.** A repo-wide grep for `CKShare.Participant`, `removeParticipant`, and `revoke` across `Sources/VoxtrCore/CloudKit` and `Sources/VoxtrAppShell` finds zero code that calls CloudKit's own share-participant-removal or share-deletion API. The only "revoke" concepts that exist are `ParentWorkspaceRepository.revokeInvitation(_:)` (a **local SwiftData** state transition, below) and the backend's `authz.revoke_device_grant` (a **server-side** device-grant status flip, entirely new-path, §3) — neither one calls any CloudKit API at all.
2. **`revokeInvitation(_:)` only applies to a pending invitation, not an active member.** `Sources/VoxtrParentDomain/ParentWorkspaceRepository.swift:323-339`: `precondition(participant.state == .invited, ...)` — this method is structurally inapplicable to a `WorkspaceParticipant` that has already reached `.active`. **There is currently no canonical local operation that transitions an already-`.active` athlete participant to any non-active state at all** — not `.revoked`, not anything else. `AthleteSessionActivationService`'s own re-validation (§2.3) would correctly *reject* re-activation if such a transition existed and ran before the next activation attempt, but nothing in this codebase today can perform that transition on an already-active member. This is recorded as a genuine finding, not assumed away, and feeds directly into Product Decision 1 in §8.

## 3. What backend grant revocation can and cannot enforce — the exact boundary

Restating runtime contract §5's accepted boundary, now with §2's full citation trail behind it:

**Enforced by backend revocation (`authz.revoke_device_grant`, §2.2 of the runtime contract):** once a Parent revokes a `device_grants` row, every subsequent `device-session-challenge`/`device-session-submit` call for that grant — session issuance, renewal, `hydration_get`, `hydration_ack` — is denied, synchronously, re-checked under lock at the one authoritative point in `device-session-submit` (contract §3.3 step 7). This is the **entire** enforcement surface backend revocation has. It governs only the new device-authorization-session/hydration path (§2.4) — a path not yet wired into any UI (§2.4) and therefore, as of this plan, enforcing nothing in production yet.

**Never enforced by backend revocation, stated honestly, not conflated:**
- It does **not** retroactively invalidate any `CKRecord` already delivered to the Athlete device via `sharedCloudDatabase` before revocation. CloudKit delivery is asynchronous and provider-controlled; the backend has no channel to it at all.
- It does **not** recall offline bytes already resident on the Athlete device — anything already hydrated into local SwiftData (§2.5) stays there. There is no remote-wipe mechanism for a SwiftData store in this architecture, and this document does not propose inventing one (see Product Decision 2, §8).
- It does **not** remove or expire the `CKShare` itself, nor the Athlete device's continuing ability to re-fetch the invitation record from `sharedCloudDatabase` for as long as CloudKit itself keeps that share valid — because, per §2.7 finding 1, nothing in this codebase ever calls the CloudKit API that would do so.
- It does **not** activate, deactivate, or otherwise touch `WorkspaceParticipant.state` — local membership state is exclusively `AcceptWorkspaceInvitationService`'s (`.invited → .active`) and, per §2.7 finding 2, has no existing "active → revoked" counterpart at all.
- It does **not** retire the legacy CloudKit acceptance screen/flow — that flow has no dependency on the new backend path whatsoever; the two run in parallel today (§2.4) and neither one currently deactivates the other.
- **This document, and backend revocation generally, never promises erasure of CloudKit's own server-side copies, Apple's backups, or any provider-side retention** — exactly the same honesty standard runtime contract §9.6 already holds for the backend's own Postgres-side PII, extended here to CloudKit's copies, which this codebase has even less visibility into than its own database.

**Conclusion, stated as the thing a Parent might reasonably expect but currently does not get:** revoking a device grant (once the new path is live) stops that device from ever authenticating a NEW backend session or hydration call again. It says nothing whatsoever about a device that already accepted the OLD CloudKit share and already has its own local copy of the family's bootstrap identity. Those are two independent systems today, and closing that gap is exactly this plan's own subject (§4).

## 4. Existing-access transition and revocation plan

### 4.1 Identity and membership preservation

Every identity the legacy path hydrates (`ParentProfile.id`, `FamilyWorkspace.id`, both `WorkspaceParticipant.id`s, `AthleteProfile.id`, `AthleteAccessGrant`) is the exact same stable ID the new backend path's own 11-field projection carries (confirmed identical field set: runtime contract §2.4's table vs. `AthleteConnectionInvitationCloudRecordPayload`'s own 11 fields, both consumed by the **same** `AthleteIdentityHydrationService.hydrate(_:)` call, §2.4). **No transition or migration step in this plan renames, reissues, or duplicates any ID.** A device that already hydrated via the legacy path and later also completes the new backend path's own claim/hydration flow converges on the identical local rows by find-by-ID-or-create — never a second identity for the same athlete, never an orphaned duplicate. This is a structural property of the existing shared pipeline (§2.4), not a new mechanism this plan introduces.

### 4.2 Handling already-accepted shares and offline state, honestly

Per §3, an already-accepted `CKShare` and its already-hydrated local rows are **not** touched by anything in the new backend path, and this plan does not propose a mechanism that silently touches them either (see Product Decision 2, §8, for the one genuinely open question here: whether a *future* slice should add one). What this plan *does* specify, for the transition period while both paths coexist:

- The legacy CloudKit acceptance screen/flow (§2.3) remains fully available and unmodified until the retirement criteria in §6 are met — per runtime contract §9.5, already accepted.
- A device that has an already-accepted share and already-hydrated rows experiences **no behavior change** from this plan alone — this plan authorizes no code change at all.
- A **future** transition slice (§5, not this document) that wires the new backend path into UI must not require re-accepting a CloudKit share for a device that already has one — it converges on the same local rows via §4.1's identity preservation, exactly as a fresh backend-only device would, just arriving at an already-populated graph instead of an empty one (the same "partial/already-populated graph resume" property runtime contract §2.4/§4.5 already relies on for its own retry story).

### 4.3 Staged rollout

A recommended, non-binding staging shape for the **future** implementation slice (§5), consistent with this codebase's existing small-slice precedent (runtime contract §8):

1. **Stage 0 (this document):** boundary review and revocation plan — documentation only, no code.
2. **Stage 1:** wire the new backend path's UI-facing flow (§5.1/§5.2) as an **additional**, opt-in path — e.g., a new-pairing entry point — while the legacy CloudKit flow remains the only path for any device that already has an accepted share. Both paths write to the same rows (§4.1); neither is removed.
3. **Stage 2:** once §6's four two-device TestFlight criteria pass for the new path, offer the new path as the **default** for new pairings, with the legacy flow still reachable (e.g., for already-mid-flight invitations) but no longer the primary entry point.
4. **Stage 3 (the actual "retirement" runtime contract §9.5 defers to):** remove the legacy CloudKit acceptance UI/code paths **only after** every device this family of apps still supports has either completed the new path or been given an explicit, communicated migration window — itself a product decision (Product Decision 3, §8) this plan does not resolve unilaterally.

No stage above is authorized by this document; §5 defines dependencies only, not a go-ahead.

### 4.4 Rollback and its limits

- **Rolling back Stage 1→0 or Stage 2→1** (disabling the new path's UI entry point again) is low-risk: the new path currently writes nothing that the legacy path's own rows don't already cover (§4.1), and disabling a UI entry point is reversible by definition.
- **Rolling back Stage 3** (having already removed legacy CloudKit code) is **not** symmetric. Once the legacy acceptance screen/code is actually deleted, restoring it means re-adding real code, not flipping a flag — and any device that, in the interim, still only has an old, un-migrated accepted share would need that code back to ever complete its original flow. This is exactly why runtime contract §9.5 requires the two-iPhone TestFlight evidence (§6) to pass **before** retirement, not after — rollback safety is bought by not removing the legacy path until the replacement is proven, not by assuming a revert is always cheap.
- **Backend grant revocation itself has no rollback concept beyond re-issuing a new grant** (a new Parent approval/claim) — consistent with D2-family reasoning already accepted elsewhere in this contract family; this plan does not propose a "un-revoke" operation.

### 4.5 Conflict and isolation behavior

- **Family isolation is unaffected by any of this.** `AthleteIdentityHydrationService.hydrate(_:)`'s existing `differentFamilyAlreadyExists`/`ownerParticipantConflict`/`athleteParticipantConflict`/`athleteProfileConflict` checks (unchanged, §2.4) apply identically regardless of which path (legacy CloudKit or new backend) produced the incoming projection — the same conflict rules a device already enforces today continue to apply once both paths are live simultaneously.
- **A device that somehow pairs via both paths for the same athlete** converges, never conflicts, because both paths hand `hydrate(_:)` the same stable IDs for the same athlete (§4.1) — this is the ordinary idempotent-upsert case already tested by the existing hydration test suites (`AthleteConnectionLifecycleServiceTests.swift`, `AthleteBackendHydrationAdapterTests.swift`), not a new conflict class this plan needs to invent handling for.
- **A device that pairs via the new backend path for a DIFFERENT family than its existing legacy-hydrated one** hits the same `differentFamilyAlreadyExists` guard the legacy path already enforces (Sprint 1's accepted single-family-per-device assumption, unchanged) — no new isolation rule is needed; the existing one already covers the cross-path case because both paths share one hydration service.

### 4.6 User-visible states

Three honestly distinct states a user-facing surface would need to represent once both paths coexist (naming only — no UI is built by this document):

1. **"Connected via legacy invitation"** — an already-accepted CloudKit share, with locally-hydrated rows, and no backend device-authorization session at all. This is every device that has ever completed the existing flow, as of this plan.
2. **"Connected via backend session"** — a device-authorization session exists and is active (once §5's integration slice ships); hydration occurred via the new adapter.
3. **"Access revoked, offline copy may still exist"** — the honest state after a Parent revokes a backend device grant for a device that is state 2: the device can no longer get a new session, a new hydration snapshot, or renew — but its already-hydrated local SwiftData rows (§2.5) are not erased by this action, and if that same physical device *also* independently holds an accepted CloudKit share from state 1 at some point, revoking the backend grant does nothing to that share either (§3). **This plan explicitly rejects presenting state 3 as "this device no longer has access"** — that claim would be false per §3, and this project's own UX principles ([CLAUDE.md §10](../../CLAUDE.md)) forbid "no false NOW/current-state claims when data is insufficient." A correct label is closer to "the Parent has revoked ongoing authorization for this device; any family information already on it may still be present until the device itself is reset or the app is deleted" — exact copy is a UI-slice decision (§5.2), not resolved here.

There is currently no state machine or persisted flag anywhere in the codebase that tracks which of these three states a given device is actually in — that tracking is itself part of the future integration slice (§5.2), not something this plan retrofits today.

## 5. Minimal future integration slices — dependency map only, not implemented

### 5.1 Parent-upload slice

**What it needs, not yet built:** a ParentApp-side flow that, after the existing invitation/approval/claim handshake (already merged, backend PR #9/#10, iOS PR #106) completes, calls the backend's `hydration-upload` endpoint (runtime contract §4.2, backend-side only — not yet implemented per that contract's own §8 sequencing) with the same 11-field projection `AthleteConnectionOwnerHandoffService.prepareInvitation` already assembles today for the legacy CKShare payload (§2.1) — the **same** local lookups (`ParentWorkspaceRepository`, `AthleteRepository`), a **different** transport (an authenticated HTTP call instead of a `CKRecord` write). **Dependency:** the backend `hydration-upload` Edge Function itself (runtime contract §8 step 3) is not confirmed merged as of this plan's own baseline SHA — this slice cannot start until that backend slice ships and its own PR records its real SHA.

### 5.2 Athlete activation/UI integration slice

**What it needs, not yet built:**
- A new pairing entry point (QR or equivalent, reusing the existing `AthleteDeviceAuthorizationScanView`/`AthleteDeviceAuthorizationPairingCoordinator` machinery already merged for claim-submit) that, once `.authorized(grantId:)` is reached, calls `AthleteBackendHydrationAdapter.hydrate(deviceGrantId:)` (already registered, §2.4) instead of waiting for a CKShare acceptance callback.
- A **persisted** session-state holder for AthleteApp — §2.3 found none exists today (`AthleteRuntimeSession` is memory-only). This slice must decide how a relaunched AthleteApp knows it already has an active backend device-authorization session, without inventing a parallel, competing identity store. The most direct option, consistent with "preserve IDs and membership" (§4.1), is checking `AthleteDeviceAuthorizationSessionManager`'s own already-persisted Keychain session record (confirmed to exist: `AthleteDeviceAuthorizationSessionStore.swift`, already merged) and the local hydrated graph together, rather than adding a new flag — but which exact UI state that resolves to is a product decision (§4.6), not resolved here.
- The three-state surface from §4.6, wired to real data instead of being a naming exercise.
- **Dependency:** both §5.1 and the existing (merged) claim/session/hydration machinery. **Does not depend on** any CloudKit removal — this slice can ship entirely alongside the untouched legacy flow (Stage 1, §4.3).

### 5.3 Ordering, restated from runtime contract §8

Backend hydration-upload (§5.1's dependency) → Parent-upload UI (§5.1) → Athlete activation/UI (§5.2) → this document's own retirement criteria (§6) → only then, Stage 3 retirement (§4.3). Issue #113 ("hosted/two-iPhone readiness") is explicitly the subsequent task that exercises §5.1–§5.2 once they exist — not itself a dependency this plan needs to satisfy first.

## 6. Two-device TestFlight evidence — retirement criteria

Per runtime contract §9.5 (accepted) and §7.5, retirement of the legacy CloudKit flow requires these four scenarios to pass on two physical iPhones via TestFlight — restated here as the concrete evidence plan this document is responsible for defining, not for producing (none of this has occurred):

1. **Connection.** Device A (Parent) approves a connection request; Device B (Athlete) claims it, receives a device-authorization session, calls the new hydration adapter, and reaches the same locally-hydrated, displayed-athlete state the legacy flow reaches today — verified by comparing the resulting local rows (§2.5) against the legacy flow's own known-good shape, not merely "the screen looks right."
2. **Restart.** Device B is force-quit and relaunched after a successful connection. Per §5.2's own open dependency, this requires the new persisted-session mechanism to exist; the test must show Device B resumes in a genuinely `.connected`-equivalent state without a fresh CKShare-style re-acceptance step, and without silently re-trusting stale local data that a revocation (scenario 4) would have invalidated in the meantime.
3. **Interruption/retry.** Network interruption during claim, during `hydration_get`, and during `hydration_ack` — each resumed per runtime contract §4.2/§4.5's own idempotent-retry design (already specified, not newly invented here) — confirmed to produce no duplicate local rows (§4.1) and no permanently-stuck state.
4. **Revocation, online and offline-then-reconnect.** Parent revokes the device grant on Device A. Device B, first while online (sees denial on its very next backend call) and separately while offline-then-reconnecting (per runtime contract §7.5's own reference to "D3's honest 'connection cannot be verified' state, then denial on reconnect"), must show the §4.6 state-3 behavior honestly — denied for any NEW backend call, with no false claim that previously-hydrated local data vanished, and (if the device happens to also hold a legacy accepted share) no incorrect claim that CloudKit access was also revoked, since per §3 it was not.

**Until all four pass on real hardware, the legacy CloudKit acceptance flow stays in place, unmodified** — this is the literal content of the already-accepted "deferred" decision (runtime contract §9.5); this plan does not shorten, soften, or reinterpret that bar.

## 7. Relationship to issue #98 and #113

- **Issue #98 gate 3** ("actual CloudKit permissions and revocation") asked for exactly the inventory in §2 and the honest boundary in §3. This document delivers that inventory and that boundary, confirmed against current `develop`. **It does not close gate 3 itself** — gate 3's own text also asks to "specify the smallest cleanup/migration and two-device TestFlight tests," which §4/§6 now do, but closing a security evidence gate is a Product Owner/reviewer call on the evidence, not something a documentation PR grants itself. This document recommends gate 3 be evaluated against §2/§3/§4/§6 together, but leaves the gate open pending that review.
- **Issue #98 gates 1 and 2** (workspace trusted enrollment; retention and provider reality) are outside this document's scope entirely — untouched here, exactly as issue #112 specified.
- **Issue #113** ("hosted/two-iPhone readiness") is the subsequent task that would actually execute §6's evidence plan once §5's slices exist. This document defines what that evidence must show; it does not perform it.

## 8. Product Owner decisions — flagged individually, none silently selected

### Decision 1 — Is "revoke an already-active athlete's local membership" in scope for this transition at all?

**Finding (§2.7):** no existing code path can transition an already-`.active` `WorkspaceParticipant` to any other state. `revokeInvitation(_:)` only applies to `.invited`. Backend grant revocation (new path) stops future sessions but never touches this local state.
**Recommended default:** treat this as explicitly out of scope for the CloudKit transition itself — it is a pre-existing gap in local membership management, not something CloudKit retirement created or needs to solve to proceed. Track it as its own, separate backlog item (a genuine "remove an active family member" feature) rather than bundling it into this plan.
**Alternative:** block CloudKit retirement until such a mechanism exists, on the reasoning that "revocation" should mean something locally too. Not recommended — it conflates two different systems' responsibilities and would stall retirement on an unrelated feature.

### Decision 2 — Should a future slice add any form of remote data invalidation for already-hydrated local rows?

**Finding (§3):** backend revocation today, and under this plan, never touches already-hydrated local SwiftData rows. No remote-wipe mechanism exists or is proposed.
**Recommended default:** do not build one for Internal Alpha. The existing accepted posture elsewhere in this contract family (e.g., runtime contract §9.6's own honest "operational target, not guaranteed erasure" framing for backend PII) already accepts that offline/local copies are a known, documented limit, not a gap to engineer around at this stage.
**Alternative:** add a "remote sign-out" push that, on next launch/foreground, clears locally-hydrated rows for a revoked athlete. Real engineering cost (a new trusted push channel, a new local-deletion policy intersecting with the athlete's own independently-created Planning/Training/Reflection data, §2.5) for a benefit not yet requested by any approved product direction.

### Decision 3 — What migration window, if any, is owed to a device that only ever completed the legacy CloudKit flow, before Stage 3 retirement removes that code?

**Finding (§4.3/§4.4):** Stage 3 rollback is not symmetric; removing legacy code before every such device has migrated or been given explicit notice is effectively a one-way action for those devices.
**Recommended default:** require explicit confirmation, at Stage 3 approval time, of how many (if any) devices are known to be in "legacy-only" state, and communicate a migration path before removing legacy code — not a specific number of days, since this is an Internal Alpha population the Product Owner already has direct visibility into.
**Alternative:** retire immediately once §6's four criteria pass on TestFlight, treating any legacy-only device as an acceptable loss. Plausible for a small enough Internal Alpha population, but a decision only the Product Owner can make with real knowledge of who is actually on that path.

### Decision 4 — Should the new backend path be the default for new pairings as soon as it exists, or only after full parity/UI polish?

**Finding (§4.3 Stage 1 vs. Stage 2):** nothing structurally prevents offering the new path immediately as an additional option once §5.1/§5.2 ship; §4.1's shared-identity property means doing so creates no migration debt either way.
**Recommended default:** Stage 1 (additional, opt-in) first, Stage 2 (default) only after §6's TestFlight evidence — as already staged in §4.3 — rather than flipping the default the moment the code compiles.
**Alternative:** default immediately on merge, treating Codemagic green as sufficient. Rejected consistently with this entire contract family's own standing "CI is not product/hosted/physical-device evidence" position (CLAUDE.md §7, runtime contract §7 generally).

### Decision 5 — Exact user-facing copy for the §4.6 "state 3" (revoked, offline copy may still exist) surface

**Finding (§4.6):** the honest content of this state is specified; its exact wording is not, deliberately — wording is a product/UX call, not an engineering one.
**Recommended default:** short, calm, technically accurate per §4.6's own sentence, reviewed against CLAUDE.md §10's "Calm by Default" / "no false NOW/current-state claims" principles before any implementation slice ships it.
**Alternative:** omit the state-3 surface entirely for Internal Alpha (silently do nothing special when a grant is revoked on a device that still has local data). Not recommended — it would let a Parent believe revocation fully "removed" access when it provably has not (§3), which risks a false security expectation.

### Decision 6 — Should `FamilyWorkspace`-root share (§2.1, no confirmed consumer) be removed now, deferred with everything else, or investigated further before this plan's own retirement timeline applies to it?

**Finding (§2.1):** this share is created (`ensureSharingRoot`) but no acceptance consumer for it specifically was found in this repository — it may be genuinely unused infrastructure, or a consumer may exist outside what this inventory's grep-based method could find (e.g., dead code reachable only via a code path this review did not execute).
**Recommended default:** treat it identically to the invitation-root share for retirement timing (§6) rather than removing it early on the strength of a "no consumer found" result alone — a negative result from static inspection is not the same evidentiary bar this whole plan otherwise insists on (real two-device TestFlight evidence) before taking an irreversible action.
**Alternative:** remove it now, since documentation elsewhere (B2.1) already calls it "reserved for whatever later, genuinely family-wide sharing scope needs" and no such scope has been approved. Plausible, but a scope decision beyond this document's own documentation-only authorization — recorded here for the Product Owner to decide, not decided here.

## 9. Source and precedence

Subordinate to the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md), the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md), and the accepted [runtime authentication and hydration contract](AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md), per [CLAUDE.md §1](../../CLAUDE.md). Every source citation in §2 was verified directly against `cristern/Voxtr` `develop` at `a53bddbb78057243ae7774ec9b83284d45dc7658` while preparing this document; none is carried forward from the baseline contract without independent re-confirmation. [Issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates remain open; §7 states this document's own, honest relationship to gate 3 specifically. No implementation, migration, deployment, or merge is authorized here; a separately authorized task is required for any of §5's integration slices or §4.3's staged rollout.
