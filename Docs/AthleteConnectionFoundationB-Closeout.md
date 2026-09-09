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
before broader Athlete experience work begins.

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
- Vǫxtr custom CloudKit schema captured in
  `CloudKit/VoxtrCloudKitSchema.ckdb` and deployed to Production;
- CloudKit's own generated sharing schema bootstrapped in Development and
  deployed to Production;
- Parent-side `Connect Athlete App` now gives immediate calm in-progress
  feedback and rejects parallel re-entry while an invitation is being created.

As of `develop` commit
`1eec3b7835c4aeb9acdf0fcc704b783a64047dc6` (PR #80 merged), Parent TestFlight
successfully progresses through the share-creation path that previously failed.

This does **not** by itself prove the full B2 exit contract. Full two-device
acceptance, exact-athlete binding and persistent AthleteApp lifecycle still
require runtime validation / follow-up work.

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

PR #71 remains **open and unmerged** and is not part of the accepted solution.
Its hypothesis that using the authoritative server-returned saved `CKShare`
would fix the original crash was superseded by symbolication and later runtime
evidence: the original crash occurred at `CKContainer(identifier:)`, before
zone/root/share work, and subsequent blockers were signing/schema related.

Do not merge or reuse #71 without a separate evidence-based review.

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

QR implementation should build on the now-working canonical invitation creation
rather than replace it.

## Open follow-ups before main Athlete experience work

1. **Athlete Release signing** — Athlete Release still carries the historical
   signing-disable flags and must be corrected before serious physical-device
   AthleteApp runtime validation.
2. **Activity Edit — Split Activity** — approved usability/closeout item:
   existing activities must expose the canonical Split Activity operation from
   Edit without duplicating split domain logic. This is a must-fix before the
   main serious Athlete App work.
3. **QR-first Athlete Connection** — implement the approved nearby pairing happy
   path using the existing invitation identity and CloudKit acceptance/binding
   pipeline.
4. **Persistent Athlete connection/session lifecycle** — already-connected
   AthleteApp relaunch should restore canonical actor/session state without a
   fresh share callback or UserDefaults identity truth.
5. **First cross-device business proof** — Parent Planning → Athlete executes /
   logs in Training → Parent sees the same canonical performed result. Prove
   `Planning proposes → Training proves` before broad Athlete Home expansion.

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
- Vǫxtr custom schema plus CloudKit-generated sharing schema are established in
  Production.
- PR #79 is closed unmerged after successful one-time bootstrap.
- PR #80 is merged and Codemagic-green.
- QR-first nearby pairing is the approved V1 Athlete Connection happy path.
- full two-device B2 completion is still an explicit runtime gate, not assumed
  from Parent share creation alone.
- Athlete Release signing and Activity Edit → Split Activity remain required
  follow-ups before main Athlete experience work.
