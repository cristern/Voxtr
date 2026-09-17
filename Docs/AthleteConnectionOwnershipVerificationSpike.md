# Athlete Connection V1 — Existing Workspace Ownership Verification Spike

Status: completed proof-of-concept investigation. Not an implementation of
Athlete Connection V1 or the authorization service. See the Security Contract
Correction report (session record) for the full approved security contract
this spike narrows one bounded item of.

## What this spike investigated

The approved security contract's one remaining bounded trust requirement:
whether a Vǫxtr backend can independently verify — not merely trust a
client-reported claim — that a Parent enrolling an **already-existing**
`FamilyWorkspace` has legitimate CloudKit-level authority over it, using
`CKFetchWebAuthTokenOperation` and CloudKit Web Services.

## Repository facts confirmed during this spike

- The `FamilyWorkspace` root `CKRecord` is created by
  `FamilyWorkspaceOwnerShareCoordinator.ensureRootRecord` (called from
  `ensureSharingRoot`), saved to `transport.database(for: .private)` —
  `Sources/VoxtrCore/CloudKit/FamilyWorkspaceOwnerShareCoordinator.swift:54-106`.
  This is a real, confirmed-by-code CKRecord in the Parent device's own
  private CloudKit database, not inferred from SwiftData or a CKShare alone.
- `CloudKitTransport`'s full method surface (unchanged from prior sessions'
  findings) has no existing user-identity or Web Services integration —
  this spike's code is entirely new, isolated (see below), and does not
  modify `CloudKitTransport` itself.
- `AccountId`/`FamilyWorkspace.technicalOwnerAccountId` remain untouched —
  this spike does not migrate or write to either, per its own scope limits.

## The candidate mechanism, verified

`CKFetchWebAuthTokenOperation` — a real, native `CloudKit` framework
operation (`CKDatabaseOperation` subclass), confirmed via Apple's own SDK
header (`CKFetchWebAuthTokenOperation.h`): `init(APIToken:)`, a
`fetchWebAuthTokenCompletionBlock: (String?, Error?) -> Void` property
(deprecated in favor of a Result-based variant since iOS 15, still present
and usable), `API_AVAILABLE(macos(10.11), ios(9.2), tvos(9.1), watchos(3.0))`
— well within Vǫxtr's `.iOS(.v17)` floor (`Package.swift:24`).

It uses the device's **already-authenticated native CloudKit session** (the
same iCloud account already governing the FamilyWorkspace's private
database) to mint a short-lived Web Auth Token — **no separate, user-visible
re-authentication step is required**, correcting this session's own earlier,
more pessimistic assumption that a CloudKit-JS-style web sign-in window
would be needed.

That token, handed to an independent backend, lets the backend itself call
CloudKit Web Services' REST API to fetch the FamilyWorkspace record **as
that user** — Apple's own servers decide success or failure, not a
client-reported claim.

## Point-by-point verdict against the six required properties

1. **Authenticate the credential with Apple** — YES. `CKFetchWebAuthTokenOperation` + a CloudKit Dashboard API Token is a real, documented mechanism.
2. **Access/verify access to the correct FamilyWorkspace record** — YES. The backend performs the actual CloudKit Web Services record fetch itself, using the token; Apple's server is the arbiter.
3. **Bind evidence to a fresh challenge** — YES, structurally: Apple's own Web Auth Token semantics are single-round-trip and self-rotating (each server response invalidates the token that produced it), giving real, Apple-provided anti-replay behavior for free.
4. **Establish that the evidence belongs to the authenticated Parent being enrolled** — **NO.** Apple's own developer forums confirm: *"The unique user identifiers for Sign in with Apple and CloudKit are not linked"* — there is no documented Apple mechanism cryptographically binding a CloudKit identity to a Sign-in-with-Apple `sub`. The two are separate authentication systems. This spike's evidence can prove "this app session currently has native CloudKit access to this specific record" — a real, strong, Apple-verified fact — but cannot, by itself, prove that fact belongs to a specific, independently-authenticated Sign-in-with-Apple identity. The two proofs can only be tied together by **co-occurrence** — both performed within one short enrollment call, on one device, in one app session — which is a real, meaningfully strong deterrent (an attacker would need actual native CloudKit access to the target workspace, not merely a guessed UUID) but is **not** a formal cryptographic binding.
5. **Reject a different account that merely knows workspaceId** — YES. A different account's own `CKFetchWebAuthTokenOperation` call authenticates as that account; the subsequent CloudKit Web Services fetch of the target FamilyWorkspace record fails under Apple's own access control, not Vǫxtr's.
6. **Prevent replay of old verification evidence** — YES, per point 3's self-rotating token semantics.

## What the credential actually proves — stated precisely, per the spike's own instruction not to overclaim

`CKFetchWebAuthTokenOperation`'s resulting token, successfully used against
CloudKit Web Services, proves **CloudKit access** to the specific
FamilyWorkspace record — for a private-database, owner-created zone (as
this one is — confirmed above), Apple's own access model means this is
functionally equivalent to **ownership**, not merely shared read access,
since no other participant has ever been added to this record (confirmed
in prior sessions' repository audits: zero `addParticipant` calls anywhere
in this codebase). It does **not** prove the real-world identity of the
person operating the device, and does **not** prove that identity is the
same as a separately-established Sign-in-with-Apple session, beyond the
co-occurrence argument in point 4 above.

## Missing operational prerequisite (Section 7's required stopping boundary)

No live Apple-service integration was executed. This environment has:

- No CloudKit Dashboard access for Vǫxtr's `iCloud.app.voxtr.shared`
  container, and therefore no real CloudKit Web Services API Token.
- No hosted backend to receive and use a Web Auth Token against the
  CloudKit Web Services REST API.
- No physical device signed into a real Vǫxtr FamilyWorkspace-owning
  iCloud account to exercise `CKFetchWebAuthTokenOperation` live.

Per this spike's own explicit instruction, this boundary is reported
rather than worked around with fabricated credentials or a simulated
success result. The code committed in this spike (see below) proves the
API surface is real and compiles against this codebase's actual CloudKit
imports — nothing more.

## Verdict

**NOT VERIFIED / NOT FEASIBLE** as a complete, standalone, cryptographically
air-tight ownership proof — point 4 remains unclosed, and no live
Apple-service round-trip was executed in this environment (a second,
independent reason this cannot be marked VERIFIED FEASIBLE).

This is a substantially narrower, better-characterized negative result than
the prior (rejected) `recordChangeTag`-based proposal: five of six required
properties are genuinely satisfiable with a real, documented Apple
mechanism: only the identity-binding property remains open, and it is now
open in a specific, bounded way (co-occurrence-only, not cryptographic)
rather than being entirely unaddressed.

## Recommended smallest next action

Per the approved security contract's own fallback (Product Owner-approved):
retain the bounded, explicitly-named enrollment trust step for existing
workspaces (Sign-in-with-Apple + human display-name confirmation), now
optionally **strengthened, not replaced**, by requiring the SAME enrollment
call to also succeed at a `CKFetchWebAuthTokenOperation`-based CloudKit
access check against the target FamilyWorkspace record — raising the real
attack bar (genuine native CloudKit access to the workspace required, not
merely a guessed UUID) without claiming a cryptographic guarantee this
mechanism cannot actually provide. This is a design refinement for the
already-approved fallback, not a new trust anchor requiring further
Product Owner sign-off — the underlying trust decision (accept a bounded,
non-cryptographic enrollment step) was already made.

## Files changed in this spike

- `Package.swift` — new isolated `VoxtrOwnershipEvidenceSpike` target/product (not linked by `VoxtrAppShell` or either app target; included only in `VoxtrSprint0Tests`'s dependencies for compile validation).
- `Sources/VoxtrOwnershipEvidenceSpike/WorkspaceOwnershipEvidenceSpike.swift` — the candidate mechanism's real API shape, never invoked by production code.
- `Tests/VoxtrSprint0Tests/WorkspaceOwnershipEvidenceSpikeTests.swift` — structural/compile-shape tests only; no live CloudKit I/O, per this codebase's established XCTEST-SAFETY convention.
- This document.

## Explicit confirmation

The existing Athlete Connection flow (`AthleteConnectionScanCoordinator`,
`AthleteConnectionLifecycleService`, `FamilyWorkspaceOwnerShareCoordinator`,
etc.) is **unchanged**. No invitation-share permission was changed. No
`WorkspaceParticipant` state transition logic was touched. `AccountId`/
`technicalOwnerAccountId` were not migrated. PR #95 remains open and
unmerged, untouched by this spike.
