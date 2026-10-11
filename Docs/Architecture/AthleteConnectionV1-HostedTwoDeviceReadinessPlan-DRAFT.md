# Athlete Connection V1 — hosted deployment and two-iPhone TestFlight readiness plan

**Status: repository-grounded readiness checklist, documentation-only, pending ChatGPT/Product Owner review.** Authorized by [issue #113 comment `6106355509`](https://github.com/cristern/Voxtr/issues/113#issuecomment-6106355509) ("Kjør på" after PR #120 merged) for **preparation only** — a readiness checklist, scenario matrix and evidence template. Nothing here performs a hosted deployment, migration, TestFlight publication, real-family hosted traffic, CloudKit cleanup, or product default change. All ten scenarios below are **NOT EXECUTED**; this document defines what evidence a later, separately authorized execution task must produce — it does not produce that evidence itself.

## 0. What this document is and is not

- The subsequent task the [CloudKit transition and existing-access revocation plan](AthleteConnectionV1-CloudKitTransitionAndRevocationPlan-DRAFT.md) §5.3/§7 and the [runtime authentication and hydration contract](AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md) §7.5/§9.5 already named as the one that exercises their own evidence requirements, once the integration slices they describe exist. This document confirms those slices now exist (§2 below) and defines the concrete execution plan — it is not itself that execution.
- Grounded in direct inspection of `cristern/Voxtr` `develop` at `b947df8e9e0ced26a8cd60cef62c8edf604716b5` (PR #120 merge, the exact baseline [issue #113's authorization comment](https://github.com/cristern/Voxtr/issues/113#issuecomment-6106355509) names) and `cristern/Voxtr-Backend` `develop` at `7b10e6ba1a0f51c5cf9034bce2ca8dd73a6c4f18` (backend PR #13), independently re-fetched and re-verified while preparing this document rather than assumed from either repository's own prior documentation.
- Does not implement, deploy, migrate, or configure anything. No code, migration, workflow, CI configuration, or test behavior changes anywhere in this PR.
- Does not close any of [issue #98](https://github.com/cristern/Voxtr/issues/98)'s three evidence gates, all three still open as of this writing (re-confirmed directly against the live issue, not inferred).
- Reports every prerequisite honestly as **VERIFIED / UNVERIFIED / BLOCKED / DEFERRED** per the authorization comment's own instruction — an unknown hosted fact is UNVERIFIED, never assumed passing or failing.
- Surfaces one genuine, previously unreported finding (§3.1) discovered while re-verifying source for this document: a pre-existing native-test-registration gap that includes a file whose tests were specifically written to close a PR #120 review finding, and whose coverage has consequently never actually executed under any green CI run to date.

## 1. Source provenance

### 1.1 iOS — VERIFIED

- `cristern/Voxtr` `develop` HEAD, independently re-fetched for this document: `b947df8e9e0ced26a8cd60cef62c8edf604716b5` (PR #120 merge). Matches the exact SHA [issue #113's authorization comment](https://github.com/cristern/Voxtr/issues/113#issuecomment-6106355509) names as the current integrated baseline.
- PR #120's own reviewed HEAD `9342e692ed9ff9e48f811c2a2ed57699af7e0963` passed Codemagic build 283 (check run `114393731829`, conclusion `success`): both app builds, the Release signing-configuration gate, and the native test suites all green — full per-step evidence already posted on [PR #120](https://github.com/cristern/Voxtr/pull/120#issuecomment-6105668587) and independently confirmed with exact counts (1,064 main-suite + 2 hosted-Keychain identities, zero failures/skips) in [the final ChatGPT verification comment](https://github.com/cristern/Voxtr/pull/120#issuecomment-6105684850). This document treats that count as the current native-test baseline and does not re-run it; §3.1 below reports a related, separate gap that count does not cover.
- **Material update since the CloudKit transition plan was written (re-verified directly in source for this document, not assumed from that now-partially-stale document):** the CloudKit transition plan's §5.1/§5.2 "not yet built" dependencies are **both now built and merged**:
  - §5.1 (Parent-upload UI): `ParentHydrationUploadService`, registered in `CompositionRoot.swift:399-404`, confirmed present. Delivered by PR #119, merged to `develop` at `cbf6d82c06b84341e69b51bba6d95bc7553839fa` (confirmed in `git log`).
  - §5.2 (Athlete activation/UI integration): `AthleteRootView.swift:58,68,77,86,97,100` confirmed to resolve and route on `AthleteBackendConnectionCoordinator.self`'s state — the adapter is now wired into the real UI/navigation path, not merely registered-but-unused as the transition plan's own §2.4 originally found. Delivered by PR #120 (this document's own baseline).
  - **This means both of the CloudKit transition plan's named integration-slice dependencies for its own §6 retirement-criteria evidence are satisfied in source** — the blocker for executing that plan's two-device TestFlight scenarios is no longer "the code doesn't exist," it is hosted deployment and physical devices (§2 below).

### 1.2 Backend — VERIFIED

- `cristern/Voxtr-Backend` `develop` HEAD, independently re-fetched for this document: `7b10e6ba1a0f51c5cf9034bce2ca8dd73a6c4f18` — **exactly** matches the SHA the authorization comment cites as "current backend source revision." No newer commit exists on backend `develop` as of this writing; re-verified by direct `git fetch` + `git log origin/develop..` diff (empty).
- Migration inventory (`supabase/migrations/`, 12 files, re-listed directly via `git ls-tree` against `origin/develop`): `20260923060545_authz_schema_v1`, `20260923091317_authz_claim_transaction_v1`, `20260923184014_authz_connection_request_devicekey_immutable_v1`, `20260924053810_authz_claim_proof_handler_v1`, `20260928100000_authz_parent_auth_session_v1`, `20260929090000_authz_workspace_enrollment_redemption_v1`, `20260930100000_authz_workspace_enrollment_issuance_v1`, `20260930150000_authz_connection_invitation_flow_v1`, `20261002160000_authz_device_grant_management_v1`, `20261003070000_authz_owner_binding_provenance_v1`, `20261004060000_authz_device_session_v1`, `20261005000000_authz_hydration_v1`.
- Edge Function inventory (`supabase/functions/`, 18 functions + `health` + `_shared`, re-listed directly via `git ls-tree`): `auth-nonce`, `claim-challenge`, `claim-submit`, `connection-invitation-create`, `connection-request-decide`, `connection-request-list`, `connection-request-submit`, `device-grant-list`, `device-grant-revoke`, `device-session-challenge`, `device-session-submit`, `health`, `hydration-upload`, `operator-cancel-enrollment`, `operator-issue-enrollment`, `parent-auth-complete`, `parent-session-refresh`, `parent-session-revoke`, `workspace-enrollment-redeem`.
- **Deployed function revisions — explicitly NOT established by this inventory, per the authorization comment's own instruction that merged source is not evidence of deployed revision.** See §2.2.

## 2. Prerequisite gates

Each gate reports **VERIFIED** (directly observed repository/CI fact), **UNVERIFIED** (genuinely unknown hosted/physical fact this task cannot establish — not assumed either way), **BLOCKED** (a required mechanism is confirmed absent or confirmed insufficient), or **DEFERRED** (explicitly out of this document's scope by prior authorization).

### 2.1 Source provenance — VERIFIED (§1 above)

Exact iOS HEAD, exact backend HEAD, migration inventory and Edge Function inventory all independently re-confirmed directly against both repositories' current `develop`, not inferred from either repository's own prior documentation. No mismatch found between the authorization comment's cited baseline and the actual current state of either repository.

### 2.2 Hosted deployment — BLOCKED (no deployment procedure exists; no evidence of any deployment)

- **Finding:** `cristern/Voxtr-Backend`'s own CI (`.github/workflows/ci.yml`) explicitly runs with "no hosted Supabase project or credentials... required or used by this workflow." No deploy workflow of any kind exists in the repository — confirmed by `git ls-tree` over `.github/workflows/`, which lists only `ci.yml`.
- **Finding:** the backend's own `README.md` states directly, multiple times, that "Nothing here was deployed to the hosted Supabase project" and names the hosted project explicitly as `voxtr-auth-dev` (development project, Supabase's own "Production" branch terminology notwithstanding) — never confirmed reachable, configured, or populated by anything this inspection can observe.
- **Consequently:** there is no ordered deployment/migration procedure, no deployment verification step, and no rollback/forward-repair plan anywhere in either repository today. This is not a gap in this document's own research — it is a gap in the repositories themselves. **A concrete deployment procedure must be authored as its own deliverable before any hosted execution**, separately Product-Owner-approved per the authorization comment's own requirement, including: exact migration-apply order (the 12 files in §1.2, in filename/timestamp order, matching `supabase/migrations`' own ordering convention), a verification step per migration (e.g. confirming expected tables/functions/privileges exist post-apply), and an explicit rollback or forward-repair plan for a partially-applied migration set.
- Not itself a Codemagic/CI concern: Codemagic's existing `codemagic.yaml` workflows (`testflight-release`/`testflight-parent`/`testflight-athlete`, confirmed present) publish **iOS app builds** to TestFlight — none of them deploys backend Supabase migrations or functions. The two are independent gates.

### 2.3 Configuration — PARTIALLY VERIFIED (names only, never values, per the authorization comment's own instruction)

Required environment variable names, confirmed directly from `cristern/Voxtr-Backend`'s own `.env.example` and `supabase/config.toml` (no value read, requested, or printed anywhere in this inspection):

| Variable | Required by | Note |
|---|---|---|
| `SUPABASE_URL` | Every function | Local `supabase start` output or the hosted project's Dashboard → Settings → API value |
| `SUPABASE_ANON_KEY` | Client-facing Athlete-side calls | Safe to expose to a trusted client by Supabase's own design |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-side privileged calls only | Bypasses RLS; must never reach the iOS application |
| `APPLE_SIWA_AUDIENCE` | `parent-auth-complete` | The accepted Apple ID token audience (e.g. app bundle ID); `parent-auth-complete` fails to boot without it set, confirmed by its own cold-start check |
| `OPERATOR_SECRET` | `operator-issue-enrollment`, `operator-cancel-enrollment` | The sole Internal Alpha operator's own credential; a value under 32 characters is treated as unconfigured |

- **UNVERIFIED:** whether these are actually set, with correct values, in any hosted Supabase project's function-secrets configuration. This inspection has no access to any hosted dashboard or secret store and does not attempt to reach one.
- **UNVERIFIED:** Apple Developer / App Store Connect SIWA Services ID and redirect configuration for the audience named above — outside both repositories' own source, requires direct Apple Developer / App Store Connect console verification.
- **UNVERIFIED:** whether a `voxtr-auth-dev` Supabase project actually exists, is reachable, and its plan/region/configuration — this document does not attempt any network reachability check against it, consistent with the authorization's "no real-family hosted traffic" boundary.

### 2.4 Retention — BLOCKED for hosted scheduling/alerting (local SQL mechanism exists; nothing schedules or observes it)

- **Finding, VERIFIED directly in source:** `authz.hydration_purge_due()`/`authz.hydration_run_purge()` (backend `20261005000000_authz_hydration_v1.sql`, confirmed present) implement the purge logic the runtime contract §9.6/§4.5 require — tombstoning expired-staged and deadline-passed PII, and permanently deleting old (30-day) tombstones — and separately expose `overdue_live_count`/`oldest_deadline` as an observable return value a caller could use for alerting.
- **Finding, VERIFIED directly in source (the migration's own comment, quoted exactly):** *"NOT scheduled or hosted by this migration — see this file's own [header] comment... no pg_cron job or Supabase Scheduled Function"* and *"no hosted retry/alerting wrapper here; a caller (eventually, a real scheduled job) is responsible [for it]."* This is the repository's own explicit, honest statement of the gap — not this document's inference.
- **Consequently, exactly matching the authorization comment's own warning ("Local SQL functions/tests alone do not satisfy this"):** the one-hour overdue-PII detection/alert-delivery requirement and observable job-failure requirement are **BLOCKED** — no scheduling mechanism (pg_cron, Supabase Scheduled Function, or external cron caller) exists anywhere in either repository, and therefore nothing currently invokes the purge function on any schedule, hosted or otherwise. **A scheduling/alerting mechanism and its own deployment must be built and verified before any hosted execution that depends on this gate** — this is a real engineering gap, not a configuration toggle.
- The 30-day tombstone cleanup and failure-recovery mechanism (same functions) exist in source but are equally un-scheduled; same blocker applies.

### 2.5 Provider privacy — UNVERIFIED / DEFERRED (explicitly out of this document's scope)

- Provider (Supabase) backup/log retention for the `voxtr-auth-dev` project specifically: **UNVERIFIED** — this is exactly [issue #98 gate 2](https://github.com/cristern/Voxtr/issues/98)'s own subject, confirmed still open on the live issue, and explicitly out of this document's scope per issue #112's own prior framing (restated unchanged by the CloudKit transition plan §7).
- Per the authorization comment's own instruction: **use synthetic, isolated fixtures for the proposed first run** (§4 below) — never real family data — specifically because this gate is unresolved.

### 2.6 App distribution — UNVERIFIED (the mechanism exists in source; its actual configured/triggered state does not)

- **Finding, VERIFIED directly in `codemagic.yaml`:** three TestFlight-publishing workflows exist — `testflight-release` (both apps, tag-triggered), `testflight-parent` (manual, ParentApp only), `testflight-athlete` (manual, AthleteApp only) — each gated on a Codemagic "App Store Connect" integration (`app_store_connect: "Vøxtr App Store Connect"`) and failing fast with an explicit named error if `APP_STORE_CONNECT_ISSUER_ID`/`APP_STORE_CONNECT_KEY_IDENTIFIER`/`APP_STORE_CONNECT_PRIVATE_KEY` are not configured.
- **UNVERIFIED, and not establishable from this sandbox:** whether that Codemagic integration is actually configured with real credentials, whether either workflow has ever actually been triggered, whether any build currently exists in App Store Connect/TestFlight for either app, and the exact signed build/version numbers for both roles. This sandbox has no Codemagic dashboard access and no Mac/Xcode — consistent with the user having no Mac, per the original issue's own framing, Codemagic/TestFlight remains the only path, and this document cannot shortcut that by inspecting source alone.
- Device/iOS-version compatibility for the two intended physical iPhones: **UNVERIFIED** — no information about specific devices exists in either repository; this is information only the Product Owner holds.
- **Simulator CI green (confirmed, §1.1) is explicitly not this evidence**, per the authorization comment's own instruction, and is not claimed as such anywhere in this document.

### 2.7 Devices — UNVERIFIED (Product Owner-held facts, not repository facts)

- Physical iPhone A (Parent) / B (Athlete): existence, iOS version, and current state — **UNVERIFIED**, no claim made either way.
- Isolated synthetic workspace and its exact stable IDs for the first run: **not yet created** — this document specifies the shape (§4) but does not create one, consistent with "no real-family hosted traffic" and "no production changes."
- Safe scenario reset procedure: **not yet defined operationally** — §4's evidence template requires a "cleanup/reset result" field per scenario, but the actual reset mechanism (e.g. a synthetic-workspace teardown script or manual Dashboard cleanup) does not exist in either repository today and is itself a prerequisite for execution, not merely documentation.

## 3. Native test registration — a genuine, newly-found gap

### 3.1 Finding

Independently re-verified for this document, not carried forward from any prior PR's own claim: of the 98 Swift files under `Tests/VoxtrSprint0Tests/`, **35 are not referenced anywhere in `App/Voxtr.xcodeproj/project.pbxproj`** — confirmed by checking each file's exact basename against the project file directly, not inferred from a prior count. This is close to, but not identical to, the "36 pre-existing omissions" the authorization comment itself references (one file's status appears to have changed since that comment was written; this document reports the number as directly observed today, `35`, rather than reconciling the discrepancy, which is immaterial to the finding itself). A rough `grep -c "@Test("` over those 35 files totals approximately 694 test-attribute occurrences — reported as an approximate, grep-based count, not an authoritative one, since this sandbox has no Swift toolchain to compile or enumerate them definitively.

**The one specific instance worth naming individually:** `AthleteShellRoutingTests.swift` is among the 35. This file already existed before PR #120 (created in the original Athlete App shell foundation commit) and was specifically extended during PR #120's own R1 review-fix round to add tests for `AthleteShellRoute.route(legacyState:backendState:)` and `AthleteShellRoute.backendStatusNotice(for:)` — the exact routing logic R1 found was letting a legacy-connected device mask an observed backend denial. The file currently contains 29 `@Test` methods. **None of them has ever compiled or run under any CI build to date**, including PR #120's own green build 283, because the file itself was never added to the native Xcode target. The 1,064-identity count [independently confirmed on PR #120](https://github.com/cristern/Voxtr/pull/120#issuecomment-6105684850) does not include this file — it was already absent before PR #120 touched it, and PR #120 did not add it either.

### 3.2 Why this matters for hosted/two-device readiness specifically

This is not merely a test-count bookkeeping issue. R1's own fix (masked backend denial) and its regression coverage live in exactly this file. The fact that CI has been reporting green while this specific regression suite never executes means **the routing/denial-masking behavior the two-device revocation scenarios (T7, T8 below) depend on has zero automated regression coverage today**, despite having a review history that treats it as resolved. This does not mean the behavior is wrong — direct source inspection in the PR #120 delivery history shows the fix was made and independently delta-reviewed against the diff — but it means the only thing currently guarding against a regression is manual review, not CI, for this specific file.

### 3.3 Recommendation

Registering all 35 files at once in the same change that touches production code risks surfacing long-dormant failures from code paths that have genuinely never been compiled or run before, mixed in with unrelated work — exactly the risk the PR #119 review (which found and deliberately did not fix this same class of gap beyond its own three new files) already flagged. This document recommends a dedicated, bounded, test-registration-only follow-up task — scoped to adding file references and nothing else, reviewed for compile/pass status in isolation — before, or in parallel with, hosted execution; it does not itself perform that registration.

## 4. Proposed scenario matrix — all NOT EXECUTED

Restating and lightly cross-referencing the ten scenarios the authorization comment already specifies, with exact current-source anchors added where they sharpen "required observation" into something checkable against a specific file/line rather than only a behavioral description. **No scenario below has been executed. This table defines required evidence; it is not evidence.**

| ID | Scenario | Required observation | Source anchor |
|---|---|---|---|
| T1 | Authenticate/enroll/approve; upload-before-claim | B claims, signed `session_issue` succeeds, hydration-get/ACK completes; canonical workspace/participant/athlete/owner IDs and accepted/bound/active graph match. | `AthleteBackendConnectionCoordinator.runActivation` (iOS); `hydration-upload`→`claim_device_grant` association (backend §4.2) |
| T2 | Claim-before-upload | Honest waiting state (`.waitingForParentApproval`, from hydration outcome `.notYetAvailable`); later upload/retry converges without another Parent approval or duplicate rows. | `AthleteBackendConnectionCoordinator` state machine; backend `hydration-upload` idempotent-staging path |
| T3 | Relaunch and foreground | Cached-unverified (D3, state 3) immediately; freshly verified (state 2) only after an actual signed `session_issue`/`session_renew` round trip — never a hydration call alone. Capture request/outcome evidence without bearer/key/payload. | `AthleteDeviceAuthorizationSessionManager.ensureActiveSession`'s cached fast path vs. `ensureFreshlyVerifiedSession`'s forced round trip |
| T4 | Revoke while B is force-quit | Relaunch begins cached-unverified (state 3); online verification denies, runtime authorization clears; cached graph is not claimed deleted. | `AthleteBackendConnectionCoordinator.restoreOnLaunchOrForeground` → `performFreshVerification` |
| T5 | Interrupt claim, get and ACK separately; lose successful ACK response | Retry converges idempotently; no duplicate graph, no permanently stuck state; `already_completed` requires complete consistent local graph (the checkpoint store). | `AthleteBackendConnectionCheckpointStore`; backend `hydration_outcome` permanent marker |
| T6 | Partial hydration / missing or conflicting graph | Retry repairs only allowed partial state; conflict remains honest (`.recoveryRequired`), no invented alternate identity or false activation. | `AthleteBackendConnectionCoordinator.completeLocalActivation`'s `athleteId`/participant revalidation (R3 fix, PR #120) |
| T7 | Online revoke; offline revoke then reconnect | Cached D3 display remains unverified offline with no protected sync; reconnect signed session validation denies. Legacy route cannot mask denial. Distinguish neutral `grantUnavailable` from explicit `grantRevoked`. | `AthleteShellRoute.backendStatusNotice`/`route(legacyState:backendState:)` — **§3.1's registration gap directly affects this scenario's own regression coverage** |
| T8 | Reinstall B; wrong installation/key; sibling/foreign IDs | Old installation/key cannot authorize new installation; exact grant→workspace/participant/athlete/owner isolation; no foreign data. | `KeychainAthleteDeviceSigningKeyStore.loadExistingSigningKey()`; backend composite FKs (§1.2 schema) |
| T9 | Session 7-day sliding / 90-day absolute and D2 deadline | Use deterministic existing test evidence for clock boundaries; keep session clocks separate from hydration recovery. Do not wait 90 days or weaken production clocks. | `AthleteDeviceAuthorizationSessionManagerTests` (clock-injected, already exists per §1.1's confirmed-registered list) |
| T10 | Network/config/key/persistence failure and late completion after context replacement | Honest recoverable state; no stale activation/authorization; retry follows existing cancellation/generation safeguards. | `AthleteBackendConnectionCoordinator`'s generation-fencing (`isCurrent(myGeneration)`), confirmed by PR #120's R2/R6 regression tests |

## 5. Evidence template

Record per scenario, exactly as the authorization comment specifies — never a secret, raw personal payload, or signing key:

| Field | Note |
|---|---|
| UTC timestamp | Start and end of the scenario attempt |
| Operator / device alias | A synthetic alias, never a real name |
| App build / TestFlight number | Both AthleteApp and ParentApp, exact build numbers (§2.6) |
| Exact backend revision / configuration identifier | The deployed function/migration revision actually in effect at test time (§2.2) — never inferred from a `develop` SHA alone |
| Synthetic scenario ID | T1–T10 from §4 |
| Expected vs. actual | Stated independently, not merged into one line |
| Pass / fail / blocked | If blocked, name the blocking prerequisite from §2 |
| Redacted log/screenshot reference | A pointer (e.g. a filename), never the raw artifact pasted inline if it could contain PII |
| Cleanup / reset result | Confirmation the synthetic workspace was returned to a clean state, or why not |

## 6. Readiness decision

**What can be executed after separate approval, once §2's blockers are closed:**
1. A scenario run against a hosted, deployed backend (§2.2) with scheduling/alerting actually wired (§2.4) and documented provider-privacy facts (§2.5), using synthetic fixtures only.
2. Two-iPhone TestFlight builds for both roles (§2.6), once the Codemagic App Store Connect integration is confirmed configured.

**Concrete blockers, named individually, with owners:**

| Blocker | Owner | Why it blocks execution |
|---|---|---|
| No deployment/migration procedure exists (§2.2) | Needs authoring + PO approval | Nothing can be hosted without one |
| No scheduling/alerting mechanism for the purge function (§2.4) | Needs building + deploying | The one-hour retention target is currently unenforceable, hosted or not |
| Provider backup/log retention undocumented (§2.5) | Issue #98 gate 2 | Required before any real data; synthetic fixtures route around it for the *first* run only |
| Codemagic App Store Connect integration configuration unknown (§2.6) | Product Owner / Codemagic dashboard access | Cannot confirm either TestFlight workflow is actually usable |
| Physical devices / synthetic workspace not yet provisioned (§2.7) | Product Owner | No scenario can run without them |
| 35-file native test registration gap (§3) | Needs its own bounded follow-up task | T7/T8's own regression coverage is currently unverified by CI |

**The smallest separately-approvable next execution step**, in order: (1) author and get approval for the deployment/migration procedure (§2.2); (2) build and deploy the purge-scheduling/alerting mechanism (§2.4); (3) confirm or configure the Codemagic App Store Connect integration (§2.6) and produce one TestFlight build of each app; (4) only then attempt T1 (the simplest scenario) against a hosted backend with synthetic fixtures, before attempting T2–T10.

**This document makes no release/retirement recommendation.** Per the authorization comment's own instruction, that follows only after the named criteria in §4 actually pass and the Product Owner approves — none of which has occurred.

## 7. Boundaries, restated

No deployment, migration, TestFlight publication, real-family hosted traffic, product default change, or CloudKit cleanup is authorized by this document. [Issue #98](https://github.com/cristern/Voxtr/issues/98) remains open, all three gates. The CloudKit transition plan's seven product decisions and scenario 5 (old-share cleanup) are not resolved here — they remain that document's own open items. No local-membership revocation, remote wipe, or backend change is proposed or performed here. This document itself requires separate ChatGPT review and explicit Product Owner approval before any later execution task cites it as settled.

## 8. Source and precedence

Subordinate to the [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md), the [Parent authentication contract](AthleteConnectionV1-ParentAuthenticationContract.md), the accepted [runtime authentication and hydration contract](AthleteConnectionV1-RuntimeAuthenticationAndHydrationContract-PROPOSED.md), and the [CloudKit transition and existing-access revocation plan](AthleteConnectionV1-CloudKitTransitionAndRevocationPlan-DRAFT.md), per [CLAUDE.md §1](../../CLAUDE.md). Every repository-fact claim in this document was independently re-verified against both repositories' current `develop` while preparing it, including re-fetching both remotes rather than trusting a locally cached ref. No implementation, migration, deployment, or merge is authorized here.
