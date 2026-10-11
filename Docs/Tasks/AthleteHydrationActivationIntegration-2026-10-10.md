# Athlete hydration, activation and runtime UI integration — 2026-10-10

Status: Product Owner authorized this bounded implementation with “Kjør på” on 2026-10-10, following the merge of Parent-upload PR #119. This initial commit is a task brief, not delivered implementation or merge approval.

Repository: cristern/Voxtr. Base: develop at `cbf6d82c06b84341e69b51bba6d95bc7553839fa`. Task branch: `claude/athlete-hydration-activation-integration`. Continue on this branch and its draft PR; do not create a parallel task PR. Coordination anchor: [#107](https://github.com/cristern/Voxtr/issues/107).

## Authority and required reading

Read CLAUDE.md completely and follow its authority hierarchy. Read the normative security contract and Parent authentication contract, the accepted runtime authentication/hydration contract (especially §§2.4,3,4.2–4.6,5,7), and the merged CloudKit transition/revocation plan (especially §§4.6,5.1–5.3). These live in Docs/Architecture. The PROPOSED/DRAFT filenames retain historical names; use their dated acceptance records and preserve higher-level authority. Read Docs/Tasks/ParentHydrationUploadIntegration-2026-10-09.md and the final PR119 review [6095082113](https://github.com/cristern/Voxtr/pull/119#issuecomment-6095082113).

PR118 merged a plan only. Its seven product proposals remain unaccepted. This task authorizes the §5.2 integration slice, including necessary minimal restoration metadata and session-validation orchestration; it does not authorize those proposals.

## Concrete problem and intended behavior

AthleteDeviceAuthorizationScanView currently ends at “Device authorized” and says athlete setup is unavailable. AthleteBackendHydrationAdapter exists and is registered, but production UI does not call it. AthleteRuntimeSession is memory-only and activates solely from the separate legacy CKShare lifecycle. Wire the existing device-authorization route through hydration and canonical membership acceptance/binding/activation so the exact approved athlete reaches the existing Athlete shell.

A successful claim proves a grant was obtained, not that hydration is ready or a runtime actor has been activated. An unexpired Keychain session or pairing receipt is metadata, never fresh authorization proof. A permanent hydration completion marker is also not fresh grant validation.

## Implementation boundary

Use existing services and repositories, including:
- AthleteDeviceAuthorizationScanView / AthleteDeviceAuthorizationPairingCoordinator.
- AthleteDeviceAuthorizationSessionManager / SessionService / SessionStore / ReceiptStore.
- AthleteBackendHydrationAdapter and AthleteIdentityHydrationService.
- AcceptWorkspaceInvitationService, AthleteConnectionIdentityBindingService and AthleteSessionActivationService.
- AthleteRuntimeSession, AthleteRootView, AthleteShellRoute, CompositionRoot and AthleteApp lifecycle wiring.

Inspect actual declarations and all consumers before editing. Add a bounded coordinator/service where needed; do not duplicate the six-step hydration implementation or canonical membership operations in a ViewModel. Narrow additive seams in these existing collaborators are permitted only when essential to this flow, with regression coverage.

### 1. Exact-target hydration and activation

After actual `.authorized(grantId:)`, acquire/validate the exact grant's session, call the existing backend hydration adapter, then perform the athlete's canonical invitation acceptance, identity binding and runtime activation. Hydration still leaves the athlete participant invited; acceptance alone owns invited→active. Re-fetch current eligibility and participant facts, including actual AthleteProfile.workspaceId, before acceptance/activation. Never use display names, list positions, or an arbitrary active local athlete to select the target.

Preserve exact workspace/participant/athlete/owner stable IDs and the accepted 11-field wire mapping. Reject missing, duplicate, foreign-family and conflicting graphs without fallback or invented data. Backend device grants and local AthleteAccessGrant are different concepts.

The adapter currently returns an outcome without target IDs; resolve this explicitly with the smallest sound metadata/result seam. If a local grant→identity checkpoint is needed, derive it only from a validated response for that exact grant and store only the minimum stable IDs/continuity facts with existing secure device-only mechanisms. It is a reference to canonical rows, not a parallel identity graph or authorization source. Document its write ordering around local persistence and ACK. Do not expand the backend payload or infer a binding from whatever family happens to be present.

`.alreadyCompleted` cannot fabricate lost bootstrap data. Activate/restore only when the exact grant has a trustworthy local identity binding and the complete graph passes canonical revalidation. If ACK succeeded but its response was lost, retry safely against the existing graph. If local metadata/rows are missing or conflicting after server completion, show a truthful recovery/re-approval requirement rather than claim success or re-create unavailable data.

### 2. Restoration and real online validation

On every launch and foreground, present a restored backend connection as cached/unverified first; issue an actual signed `session_issue` or `session_renew` round trip before presenting freshly verified status. The manager's existing cached-token fast path must not satisfy this requirement. Add an explicit bounded online-validation operation if needed, reusing session service, proof rules and storage. Hydration GET/ACK cannot substitute for this check because terminal hydration outcomes persist independently of current grant status.

Restore the exact grant from stored session/continuity metadata without replaying a 24-hour claim-recovery flow as the normal restoration path. The D2 hydration deadline and the session's sliding/absolute expiry are separate clocks. Reinstall/missing signing key requires fresh pairing; do not generate a replacement signing key as proof for an old grant. Handle Keychain save failure honestly rather than promise restart continuity.

Cached data may remain viewable with calm “connection cannot be verified” framing (D3); no new protected sync while unverified. A locally resolved actor for cached display must not be treated as authorization for protected operations.

### 3. Honest states and retries

Implement transition-plan §4.6 with explicit origin/status:
- Legacy invitation connected, distinct from backend authorization.
- Backend connection freshly verified this launch/foreground cycle, with separate setup/hydration readiness.
- Cached backend connection unverified, including offline state.
- Observed denial: specific `.grantRevoked` permits Parent-revoked copy; `SessionFailure.grantUnavailable` requires neutral unavailable/re-approval copy.

Distinguish waiting for Parent upload, D2 hydration deadline passed, network/configuration/malformed response, installation key unavailable, local graph/persistence failure and ACK not confirmed. Do not map all to Parent revocation. Retry the same grant with fresh proofs and idempotent local hydration; do not automatically create invitations, request duplicate Parent approval or scan again for transient errors. Use bounded attempts/manual retry with no runaway loop.

On confirmed denial clear the active runtime actor, invalidate relevant authorization and stop work that relied on it. Preserve already-persisted local rows. Never imply local bytes or legacy CloudKit access were erased. A legacy callback must not mask a denied backend connection or upgrade its status.

### 4. Cancellation and concurrent context changes

Guard every await and the challenge→submit seams with cancellation and attempt/session generations. Cancel/dismiss, background/foreground replacement, new QR/grant selection and sign-out/invalidation must prevent stale requests from mutating identity, activating an actor, reporting success or clearing a newer grant/session. Coalesced session work must not let an unverified caller inherit a cached result as fresh evidence. Test late success and late denial against a replacement context. Retain partial committed hydration for safe retry; do not wipe it.

## Explicit exclusions

No backend implementation, migration or hosted deployment; no real-family hosted traffic. No CloudKit removal/cleanup, remote wipe or local active-membership revocation feature, default path flip, legacy migration window or acceptance of PR118's seven proposals. Keep the legacy route available and preserve its existing behavior while surfacing provenance honestly. No Athlete Home redesign, new training/reflection sync, notifications or AI features. No merge or deployment approval.

Backend hydration implementation is merged; hosted configuration/provider readiness is not established. Test with controlled fixtures and CI, never real family data. Issue #98 stays open; #113 remains the later hosted/two-physical-iPhone evidence task.

## Native tests and delivery

Extend relevant existing tests where possible. Register all new source/test files in native Xcode targets and required Package.swift surfaces. Preserve PR119's executed baseline: 1034 main + 2 hosted Keychain = 1036 native tests, including the earlier 969 baseline identities. Counts alone are not identity preservation. Track the 36 pre-existing omissions separately, never silently expand this task to fix them.

Required deterministic regressions: exact sibling/foreign workspace binding; missing/duplicate/conflict rejection; hydration doesn't activate before canonical acceptance; waiting-upload→retry success; GET interruption/partial persistence/ACK lost-response retry without duplicates; alreadyCompleted with complete vs missing/conflicting local graph; restart after D2 expiry with valid session and completed local graph; fresh launch/foreground forces actual session round trip despite unexpired cached token; revoke while force-quit→cached/unverified→denial; offline cached view with no protected sync; expired/session-invalid recovery; missing installation key; Keychain persistence failure; cancellation/replacement/late success/late denial at each meaningful await; legacy callback cannot mask backend denial.

Run Codemagic for the exact delivered HEAD. Require full native logs/JUnit/xcresult-derived identities, zero failures/skips for required tests, both ParentApp and AthleteApp simulator builds, and the existing Release signing-configuration gate. Do not label that gate as a signed archive or TestFlight/physical-device proof. Reopen the final Swift/test diff, resolve actual declarations/types, audit enum consumers repository-wide, and report risks honestly.

## Bilateral handoff and stopping rule

At start, after implementation delivery, after CI completion and before stopping: fetch actual PR HEAD and current comments/reviews. Verify/update your own subscription for this exact PR's comments/reviews/commits if supported, and explicitly confirm supported scope and any idle-session limitation. Never inherit PR119 subscription assumptions. GitHub comments do not establish that an idle agent is running.

Post implementation delivery and a new CI completion comment each tied to full exact HEAD SHA, linking actual run/logs/artifacts and addressing current ChatGPT findings. CI completion is not a supported GitHub webhook trigger here; the exact-SHA completion comment is necessary. Continue fixes in this same PR. Stop for review after delivery; do not merge or deploy.
