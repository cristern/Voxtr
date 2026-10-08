# Athlete Connection V1 — CloudKit transition and existing-access revocation plan

Status: **Task brief only — repository audit and plan not yet delivered.**
Task: [issue #112](https://github.com/cristern/Voxtr/issues/112).
Coordination: [issue #107](https://github.com/cristern/Voxtr/issues/107).
Prepared after Product Owner-requested merge of PR #117 and request for the next Claude task on 2026-10-08.

## Baseline and authority

PR #117 merged into develop at `a53bddbb78057243ae7774ec9b83284d45dc7658`.
Follow CLAUDE.md and its authority hierarchy. Read the current normative security and Parent authentication contracts, the runtime authentication/hydration contract (accepted baseline `e53d653f17909abd705d06eda2b77867038ff5b7`), and #107 provenance comment 5972055089. Verify current merged backend declarations and pin exact repository SHAs.

This task is §8 step 6: a documentation-only boundary review. It does not authorize implementation, deployment, legacy removal or new product behavior.

## Required delivery

Replace this task brief with a repository-grounded plan, distinguishing verified source facts, proposed changes, CI evidence, hosted/provider evidence and unexecuted physical-device tests.

1. Inventory actual invitation-root CKShare, reserved family-workspace-root CKShare, private/shared database paths, acceptance/sync consumers, local SwiftData caches and any current Planning/Training/Reflection sync. Cite exact paths and SHAs.
2. Explain what backend grant revocation denies, and which independent accepted CloudKit routes/offline bytes it cannot recall. Do not promise erasure of offline copies or backups.
3. Specify a separately reviewable existing-access revocation and transition plan: identity/membership preservation, handling accepted shares, staged rollout, rollback limits, conflict/isolation behavior and user-visible states.
4. Map minimal future parent-upload, athlete claim/session/hydration/activation/UI integration slices and dependencies without implementing them or bundling them into this PR.
5. Define two-device TestFlight prerequisites and evidence for connection, restart, interruption/retry and online/offline→reconnect revocation. Preserve legacy acceptance until those named criteria pass.
6. Keep #98 evidence gates open unless actual evidence closes a named gate. #113 hosted/two-phone readiness remains a subsequent task.
7. List each genuine product decision individually with recommended default, rationale and effects; do not silently select a new policy.

## Scope and validation

Documentation only. No Swift/backend/schema/CI behavior changes, destructive migration, CloudKit retirement, hosted deployment or merge.
Preserve the 969-test baseline (968 main + 1 hosted Keychain), test identity gates and production-direction signing evidence; no repairs to the 36 unrelated native target omissions.

Verify links and source references; review the complete final diff. Report actual exact-SHA checks/logs/artifacts if run, or honestly state not run/not applicable. Documentation CI never proves provider behavior or physical-device outcomes.

## Bilateral handoff

Claude must fetch this PR's current HEAD and all current reviews/comments at start, after delivery and CI completion, and before stopping. Resolve findings by comment ID and reviewed SHA.
Update/verify Claude's own exact-PR comment/review/commit subscription if supported; report supported scope and idle-session/wake limitations. GitHub CI completion is not itself a supported trigger here: post a fresh exact-SHA CI/delivery comment. Do not assume any comment launches an idle agent.
Use this same task branch/PR; do not reopen merged #117 or create a second PR for the same task. No merge/deploy without separate explicit PO approval.
