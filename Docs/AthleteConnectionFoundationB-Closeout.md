# Athlete Connection Foundation B — Runtime Closeout

Status: living closeout note for the implemented Athlete Connection foundation.

This document records verified implementation/runtime state after the original
`AthleteConnectionFoundationB-Discovery.md`. It does not replace that discovery
record or the canonical Architecture / Project Context / Product Backlog.

## Purpose

Athlete Connection exists to bind a Parent-selected existing `AthleteProfile`
to AthleteApp without creating a second athlete identity. CloudKit is transport;
Vǫxtr stable workspace / participant / athlete IDs remain canonical.

The current foundation is intended to make a real cross-device connection safe
before Athlete business capabilities depend on that connection. AthleteApp shell
and UX work may proceed independently when it does not assume pairing runtime
success or introduce new business truth.

## Verified implementation state

The implementation now has the following foundations merged to `develop`:

- explicit CloudKit transport outside SwiftData mirroring;
- Parent-owned custom family zone in the private database;
- immutable `AthleteConnectionInvitation` records bound to exact stable
  workspace / participant / athlete identity;
- one fresh `CKShare` per invitation;
- acceptance/hydration paths designed to reuse the same stable IDs rather than
  name/order/age heuristics;
- Parent-side handoff preparation and presentation;
- Internal Alpha, PII-safe CloudKit diagnostics;
- Parent Release signing corrected so the final signed TestFlight app actually
  carries its CloudKit/container entitlements;
- Athlete Release signing corrected and verified through signed TestFlight
  artifact/runtime launch (PR #83);
- Vǫxtr custom CloudKit schema captured in
  `CloudKit/VoxtrCloudKitSchema.ckdb` and deployed to Production;
- CloudKit's own generated sharing schema bootstrapped in Development and
  deployed to Production;
- Parent-side `Connect Athlete App` gives immediate calm in-progress feedback
  and rejects parallel re-entry while an invitation is being created;
- Activity Edit exposes the canonical Split Activity operation (PR #82);
- QR-first nearby pairing is implemented and merged (PR #84): Parent renders the
  canonical existing `CKShare.url` as QR, AthleteApp scans it, resolves
  `CKShare.Metadata`, and enters the existing canonical acceptance/exact-identity
  binding pipeline;
- PR #84 passed Codemagic compile/test validation before merge.

As of `develop` commit
`c4b6fbd1c4cc42394a653a1dc4a14a3d3b545077` (PR #84 merged), the QR-first
implementation is integrated on `develop` and compile/test validated.

This does **not** prove the full B2 exit contract. Full two-device QR acceptance,
exact-athlete runtime binding and persistent AthleteApp lifecycle still require
physical-device runtime validation / follow-up work.

## CloudKit root-cause chain

Three distinct infrastructure blockers were discovered and resolved in order:

1. **Parent final signing** — the source project declared the CloudKit
   entitlements, but Parent Release explicitly disabled signing. The provisioning
   profile was correct while the final app omitted the entitlements. PR #75
   removed the Release-only signing-disable flags and final IPA diagnostics then
   proved CloudKit/container/environment matched.
2. **Vǫxtr custom schema** — TestFlight then reached
   `sharing-root-save · invalidArguments`. The container had never had the
   Vǫxtr custom record schema established/deployed. PR #78 added the schema
   artifact/manifest; `FamilyWorkspace` and `AthleteConnectionInvitation` were
   imported to Development and deployed to Production.
3. **CloudKit sharing system schema** — runtime then advanced to
   `share-save · invalidArguments`; Production logs showed `BAD_REQUEST`,
   `USER_ERROR` and `_pcs_data`. A one-time Development-targeted physical-device
   build successfully created a real `CKShare`, after which CloudKit generated
   `cloudkit.share` in Development. Deploying that schema change to Production
   removed the blocker in the normal TestFlight ParentApp.

`cloudkit.share` and `_pcs_data` are CloudKit-managed. They must not be added to
Vǫxtr's `.ckdb` schema artifact or application mapping tests. See
`CloudKit/VoxtrCloudKitSchemaManifest.md` for the durable operational sequence.

## Temporary bootstrap PR #79

PR #79 (`claude/cloudkit-development-share-bootstrap`) was intentionally a
one-time bootstrap mechanism: manual Ad Hoc ParentApp signing for CloudKit
Development, safe entitlement diagnostics and an installation/runbook path for
a Product Owner without a Mac.

The workflow was successfully validated on a registered physical iPhone and
served its purpose. Because the workflow/scripts were temporary infrastructure,
PR #79 was **closed unmerged** after success rather than introducing one-time
machinery into `develop`.

If the same bootstrap is ever required for a new/fresh CloudKit environment,
recreate the smallest necessary temporary tooling from current `develop` rather
than reopening #79 as if it were permanent product infrastructure.

## PR #71 disposition

PR #71 is **closed unmerged and superseded** and is not part of the accepted
solution. Its hypothesis that using the authoritative server-returned saved
`CKShare` would fix the original crash was superseded by symbolication and later
runtime evidence: the original crash occurred at `CKContainer(identifier:)`,
before zone/root/share work, and subsequent blockers were signing/schema related.

Do not reopen, merge or reuse #71 without a separate evidence-based review.

## Approved product direction — QR-first nearby pairing

The original Apple recipient/share UI is no longer the intended V1 happy path.
The approved Athlete Connection V1 direction is **nearby-first QR pairing**.

Purpose: when the Parent and athlete are physically together, connect the
Parent-selected existing athlete to AthleteApp in roughly a minute with minimal
ambiguity.

Required invariants:

- Parent selects an existing `AthleteProfile` first.
- The same canonical immutable invitation/handoff identity is used; QR is a
  transport/presentation mechanism, not a second invitation model.
- Stable workspace / participant / athlete IDs remain authoritative.
- CloudKit remains transport only.
- Exact-athlete binding must remain sibling-safe.
- Human choice of athlete precedes transport; no heuristic identity matching.
- Remote/flexible sharing remains later scope (for example Share Sheet,
  Messages/Mail, AirDrop-style handoff or copy/share link).

PR #84 implements this transport direction by building on the canonical
invitation/share flow rather than replacing it. Runtime proof remains pending
until the Product Owner can perform the required two-device TestFlight test.

## Current AthleteApp sequencing decision

Physical two-device pairing validation is temporarily unavailable. Product work
may therefore continue in parallel without falsely treating pairing as proven.

Approved sequencing:

1. **Athlete App Shell / UX Foundation may proceed now.** Purpose: make
   AthleteApp look and feel like a coherent, usable product rather than a
   technical connection shell. Scope may include app structure, navigation,
   empty states, connected/not-connected presentation, Profile/Settings and
   visual consistency with the existing design system.
2. This shell/UX work must **not** introduce a new business capability whose
   correctness depends on unproven pairing/runtime data. It must not add fake
   local actor state, UserDefaults identity truth, timing hacks or duplicate
   domain ownership.
3. QR pairing remains **implemented and compile/test validated, but not
   two-device runtime-proven** until TestFlight validation is performed.
4. **Persistent Athlete connection/session restoration remains a separate
   connection lifecycle task.** It must restore canonical actor/session state on
   relaunch and must not be hidden inside UX polish.
5. After the shell/UX foundation, make an explicit product decision on the
   **first meaningful Athlete business capability** before implementing it.
   “Athlete Now” or showing planned activities are possible proposals, not yet
   canonical decisions.
6. The first Parent Planning → Athlete Training cross-device business proof is
   deferred until AthleteApp has a meaningful Athlete capability to exercise.

This sequencing preserves the distinction between making AthleteApp usable as a
product surface and proving business behavior across devices.

## Open follow-ups

1. **Two-device QR runtime validation** — Parent selects Athlete A, AthleteApp
   scans the QR, exact Athlete A identity is resolved, no sibling/duplicate
   identity appears, and the observed relaunch behavior is recorded.
2. **Athlete App Shell / UX Foundation** — proceed independently of the pending
   two-device test, bounded by the sequencing decision above.
3. **Persistent Athlete connection/session lifecycle** — already-connected
   AthleteApp relaunch should restore canonical actor/session state without a
   fresh share callback or UserDefaults identity truth.
4. **First meaningful Athlete capability — product decision required** — define
   what AthleteApp should first help the athlete understand/do/achieve before
   implementation begins.
5. **First cross-device business proof** — once that capability exists, prove a
   canonical Parent/Athlete workflow such as Planning proposes → Training proves.

## Product/architecture guardrails preserved

- One Truth: one authoritative owner per business concept.
- AthleteProfile is the person/data identity; WorkspaceParticipant is the actor.
- CloudKit identity is transport, not product identity.
- Planning proposes; Training proves; Reflection explains and learns.
- No fake local actor state, timing hacks or forced identity refreshes.
- No sibling ranking or heuristic sibling binding.
- Calm by Default: invitation creation shows bounded progress without fake
  percentages or urgency.

## Documentation impact

Durable consequences that should also be reflected in the next canonical
Architecture / Project Context / Product Backlog revisions:

- Parent CloudKit signing is corrected and runtime-proven.
- Athlete Release signing is corrected and signed TestFlight launch verified.
- Vǫxtr custom schema plus CloudKit-generated sharing schema are established in
  Production.
- PR #79 is closed unmerged after successful one-time bootstrap.
- PR #71 is closed unmerged and superseded.
- Activity Edit → Split Activity is complete (PR #82).
- QR-first nearby pairing is implemented and merged (PR #84), with two-device
  runtime proof still explicitly pending.
- Athlete App Shell / UX Foundation is approved to proceed while pairing runtime
  validation is unavailable, provided it does not depend on pairing success or
  add new business truth.
- persistent session restoration remains separate work.
- the first meaningful Athlete business capability requires a separate product
  decision.
- cross-device Planning → Training proof is deferred until AthleteApp has that
  meaningful capability.
