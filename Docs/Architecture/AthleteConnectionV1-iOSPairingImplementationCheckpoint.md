# Athlete Connection V1 — iOS Pairing Implementation Checkpoint (review round 4)

This records what changed in `claude/athlete-connection-ios-pairing-v1`
(cristern/Voxtr PR #106) across review rounds 2 through 4, and the exact
current state of each area. It does not restate the whole feature — see
`AthleteConnectionV1-NormativeSecurityContract.md`,
`AthleteConnectionV1-ParentAuthenticationContract.md`, and
`ADR-AthleteConnection-BackendAuthorization.md` for that.

Round 2 is sections 1–8 below. Round 3, prompted by three concrete
implementation findings against commit `fe4ea86` (a Swift 6
Sendable-only fix; no behavior change), is recorded in "Round 3" below.
Round 4 — the current round, two concluding UI findings against round
3's own `904d531` — is recorded in "Round 4" below.

## Scope correction

Keeping the existing, unmodified CloudKit CKShare pairing screens
alongside this new backend-authorized flow for this slice is a scope
decision the repository owner confirmed during review — **not** a
position `ADR-AthleteConnection-BackendAuthorization.md` itself takes.
That ADR records the decision to build this backend-authorized flow; it
says nothing about the existing CKShare screens. Their eventual
retirement remains separate follow-up work with its own security/release
review, independent of this checkpoint.

## 1. Athlete gateway configuration

`AthleteDeviceAuthorizationService` now requires an injected
`AthleteDeviceAuthorizationGatewayConfiguration` (an `anonKey: String`)
and attaches both `apikey` and `Authorization: Bearer <anonKey>` headers
to `connection-request-submit`, `claim-challenge`, and `claim-submit` —
the exact pair `cristern/Voxtr-Backend`'s own
`tests/integration/postgrest_bridge_integration.ts` uses against those
same three `verify_jwt`-default-`true` endpoints. No Parent session,
service-role key, or operator secret is ever attached on this side.
Before any network attempt, the service throws
`.gatewayConfigurationMissing` if the key is empty, so a missing
configuration fails once, clearly, instead of repeatedly hitting a
gateway that can only reject it. `CompositionRoot`'s own default is an
obviously non-functional placeholder string, matching
`cristern/Voxtr-Backend`'s own `.env.example` convention — never a real
hosted credential.

## 2. Key protection and installation lifecycle

`AthleteDeviceSigningKeyStore` was restructured around three injected
seams — `AthleteDeviceKeyMaterialStoring` (raw Keychain bytes),
`AthleteInstallationMarkerStoring` (an opaque marker in `UserDefaults`,
wiped on uninstall unlike Keychain), and `AthleteDeviceSigningKeyGenerating`
(key generation/reconstitution, injectable so Secure Enclave failure and
corrupt material are deterministically testable without real hardware).

- **Relaunch** reuses the same key: the marker Keychain holds for the
  stored key matches the marker `UserDefaults` currently holds.
- **Reinstall**: `UserDefaults` is wiped, so a fresh marker is minted:
  even if Keychain still holds the previous install's key (it can
  survive deletion), the markers no longer match, so it is treated as
  orphaned and a genuinely new key is generated — never silently reused
  across installs.
- **Secure Enclave failure** on a capable device now propagates
  (`.secureEnclaveFailure`) instead of being swallowed by a `try?`
  fallback to software — no silent protection downgrade. A device
  without Secure Enclave (every Simulator, some older devices) still
  falls back to software, which is an expected platform limitation, not
  a failure.
- **Missing/corrupt key during a known pairing** fails safely:
  `loadExistingSigningKey()` (used by `submitClaim`, which continues an
  attempt already bound to a specific key) never creates a replacement —
  it throws `.noKeyForCurrentInstallation` explicitly. Only
  `loadOrCreateSigningKey()` (used by `submitConnectionRequest`, which
  starts a new attempt) may generate a fresh key.
- **Storage failure prevents submission with an unpersisted key**:
  `loadOrCreateSigningKey()` propagates a save failure rather than
  returning an in-memory-only key that a later relaunch could never
  recover.

## 3. Coordinator lifecycle, cancellation, generations

Both `AthleteDeviceAuthorizationPairingCoordinator` (Athlete) and
`AthleteDeviceAuthorizationInvitationCoordinator` (Parent) now own their
poll/attempt work as an explicit `Task` plus a `generation` counter.
Starting a new attempt (`beginPairing`/`start`) or cancelling
(`cancel`/`stop`/`reset`) bumps the generation and cancels the owned
task; every `state =` write is guarded by a check that the work's own
captured generation still matches the current one and the task has not
been cancelled — checked after every network await, before signing,
before submitting a claim, before starting a poll, and again right
before publishing. Both hosting views call the coordinator's
cancellation on `.onDisappear`, which SwiftUI fires for an explicit
dismiss button and an interactive swipe dismissal alike. Parent
decisions are single-flight (`isDecisionPending`); Parent polling also
ends locally once the invitation's own `expiresAt` has passed, without a
further network call.

## 4. Claim recovery and pairing receipt

`AthleteDeviceAuthorizationReceiptStore` persists the minimal
installation-scoped metadata needed to resume after an interruption —
invitation id, connection request id, and (once known) grant id/recovery
deadline. It is explicitly metadata, never proof of current access, and
never stores a challenge id/nonce/signature (all single-use and already
consumed). The Athlete scan screen calls
`resumePendingAttemptIfAny()` once, before any scan, to pick this back up.

A network failure specifically during `claim-submit` is treated as
ambiguous — the backend may have processed the proof before the
connection dropped — so the coordinator requests a fresh challenge for
the SAME request/key and retries, rather than resubmitting the
connection request or requiring a new invitation. `claim-challenge`
returning `request_not_available`, and the poll budget running out, are
both described honestly in the UI (neither proves the Parent didn't
approve). The per-invitation `too_many_requests` cap is described
accurately too — it does not reset by waiting, so the message directs
the Athlete to ask for a new invitation.

## 5. Parent authentication recovery

`AthleteDeviceAuthorizationInvitationCoordinator` surfaces
`notSignedIn`/`sessionInvalid`/`sessionExpired`/`reauthenticationRequired`
as a distinct `.authenticationRequired` state rather than a generic
failure message, and preserves exactly which operation failed
(`pendingOperation`: the selected athlete/workspace for a failed
`start`, or the exact invitation/request/decision/display code for a
failed `decide`). The Parent-side view presents the package's existing,
unmodified `ParentEnrollmentView` (the only public SIWA surface
`VoxtrParentAuthentication` exposes — `ParentSignInCoordinator` itself is
package-internal) as a sheet; dismissing it is the Parent's own explicit
action, which is when `retryAfterReauthentication()` resumes the
original operation. Nothing retries automatically, and a session
refresh can never satisfy `reauthenticationRequired` — only a fresh SIWA
handshake. Approving a request now requires an explicit confirmation
dialog naming the exact request's own display code before `decide(...)`
is ever called.

## 6. QR format and wire validation

`AthleteDeviceAuthorizationQRPayload` now carries an explicit `v=1`
query item; validation rejects an unsupported version, a duplicate or
unrecognized query item, and any userinfo/port/path/fragment the real
payload never carries. `validate(_:)` returns only the decoded
invitation UUID — never a URL or host — so nothing downstream can derive
a backend destination from scanned input; the real base URL always
comes from injected configuration. `AthleteDeviceAuthorizationService`
now validates the backend's own display-code shape (exactly 6 uppercase
hex characters, matching `authz.submit_connection_request`'s own
generation) and challenge nonce (exactly 32 bytes once decoded, strict
base64url charset matching `_shared/base64url.ts`'s own
`decodeBase64Url`), failing closed with `.malformedResponse` otherwise.

## 7. Cross-implementation P-256 fixture

`AthleteConnectionCrossImplementationFixtureTests` hardcodes a fixed
canonical message / 65-byte public key / 64-byte raw signature triple,
generated and independently confirmed by the backend's own unmodified
`verifyP256Signature`/`buildCanonicalMessageBytes` (Deno 2.9.6, the
backend's own `_shared/p256.ts` header's cited version) via a one-off
script that never touched the backend repository's own working tree
(deleted immediately after running; `git status` in
`/home/user/voxtr-backend` was confirmed clean afterward). The exact
script and its captured output are both recorded verbatim in that test
file's own header comment, for anyone to re-run and reproduce. CryptoKit
independently verifies the SAME bytes. Still unverified: a real Secure
Enclave key (CryptoKit's SE key type cannot be constructed from
arbitrary bytes, by design) and a real hosted network round trip — both
remain for physical-device TestFlight testing.

## 8. Honest UI and deferred data setup

The Athlete success screen no longer says "Connected" — it says "Device
authorized" plus "Setting up the athlete's data on this device isn't
available yet." Nothing in this slice hydrates athlete data, accepts a
CKShare, activates business membership, or shows the normal athlete
dashboard as a consequence of backend device authorization; that
boundary is unchanged from the first round and remains exactly where the
Normative Security Contract draws it.

## Round 3

Three findings against `fe4ea86`: a stored receipt's `grantId` was
treated as current authorization without any backend check; a transient
failure or poll-timeout offered only "Scan again" (a brand-new
connection request), with no same-request resume and no preserved
comparison code; and Parent reauthentication opened the ordinary account
screen (which shows enrollment/sign-out, not SIWA, while a token is
still present) and lost the in-progress operation on a polling auth
failure. None of these required a new backend endpoint — the fix reuses
the backend's own existing D2 recovery semantics (`authz
.issue_claim_challenge` issues a fresh challenge for an already-claimed
request within its 24-hour recovery deadline; `claim-submit` answers with
`already_granted`).

### 9. Receipts are never proof of current authorization

`AthleteDeviceAuthorizationReceipt` gained `displayCode: String?` —
local metadata only (`nil`-safe for receipts saved before this field
existed). `AthleteDeviceAuthorizationService.currentInstallationHasExistingSigningKey()`
is a new non-generating pre-check mirroring `loadExistingSigningKey()`'s
own contract.

`AthleteDeviceAuthorizationPairingCoordinator.resumePendingAttemptIfAny()`
no longer shortcuts a `grantId`-bearing receipt straight to
`.authorized`. It now always:

1. Checks `currentInstallationHasExistingSigningKey()` first — a
   reinstalled/orphaned receipt or a missing/corrupt key is cleared
   (`receiptStore.clearReceipt()`) and reported `.failed`, with **no
   network call and no replacement key generated**, whether or not the
   receipt already recorded a grant.
2. Otherwise requests a fresh `claim-challenge` and submits a signed
   `claim-submit` for the same request/key — a receipt with a prior
   grant goes through `.reconfirmingPreviousGrant(grantId:)` (a new
   `State` case, distinct from `.authorized` on purpose) and the backend
   answers `already_granted` if the grant is still active and within its
   recovery window. A locally stored `recoveryDeadline` already in the
   past is never itself treated as proof of revocation or of continued
   validity — only the backend's response decides.

`saveReceipt` failures are now handled explicitly instead of `try?`:

- Right after a connection request is submitted, a save failure stops
  the attempt (`.failed`) **before any claim is ever sent** — the
  backend-side request remains submitted and visible to the Parent, but
  this installation does not proceed into a claim it cannot durably
  record.
- Right after the backend confirms a grant, a save failure still reports
  `.authorized` truthfully (the backend really did confirm it), but sets
  a new published `unpersistedAuthorizationWarning` string explaining
  that a future relaunch may not be able to show this without a new
  scan — shown in the scan view's success state.

### 10. Same-request resumability in the Athlete UI ("Continue connection")

A new `State.interrupted(displayCode: String?)` case covers every
resumable interruption: a transient network failure requesting a
challenge, a permanent local failure, or poll-budget exhaustion. A new
public `continuePendingAttempt()` resumes the same stored receipt (same
invitation/request/key) with a fresh challenge — it never calls
`connection-request-submit` again. `reset()` ("Scan again") is now the
explicit, separate action that discards the stored receipt
(`receiptStore.clearReceipt()`) and starts over.

`attemptClaim`'s error handling now distinguishes PERMANENT local
failures (`.signingKeyUnavailable`, `.gatewayConfigurationMissing`) from
AMBIGUOUS network failures (`.network`, `.malformedResponse`): the
former sets `.interrupted` and stops immediately — it is never retried
automatically up to the 100-attempt poll budget, since nothing about
retrying the exact same request can fix a missing key or configuration.
The latter is unchanged — fall through to the next poll tick with a
fresh challenge.

`AthleteDeviceAuthorizationScanView` renders `.reconfirmingPreviousGrant`
as a waiting state and `.interrupted` as a new screen offering "Continue
connection" (primary) alongside "Scan again" (secondary, explicit), with
the receipt's own comparison code shown when available.

### 11. Parent reauthentication is now explicit and resumable

`ParentSignInCoordinator` gained `forceFreshSignIn: Bool` (constructor
parameter) and `justCompletedFreshSignIn: Bool` (published, cleared the
moment a new attempt is pinned). `shouldFetchReadyHandshake` now also
fires when `forceFreshSignIn` is set, even while `isSignedIn` is already
`true` — a live-but-stale session (exactly
`ParentAuthenticationError.reauthenticationRequired`'s own shape) is
offered a brand-new SIWA attempt directly, never gated behind the Parent
finding "Sign out" first. An ordinary token refresh still cannot satisfy
this; only a completed handshake through this coordinator can.

`ParentEnrollmentView` gained `forcesReauthentication: Bool` and
`onReauthenticated: (() -> Void)?`. In forced mode it shows only the SIWA
button or, once `justCompletedFreshSignIn` is `true`, an explicit
"Continue" button — never the enrollment/sign-out sections, and never
treating `justCompletedFreshSignIn` or a mere dismissal as proof on its
own. `onReauthenticated` fires only after that explicit tap.

`AthleteDeviceAuthorizationInvitationView`'s reauthentication sheet
binding had a `set: { _ in }` no-op — unable to respond to interactive
swipe-dismiss, which fought the Parent's own gesture. It now uses a real
`@State private var isReauthenticationSheetDismissed` flag with a
working setter, reset via `.onChange(of: coordinator.state)` when state
leaves `.authenticationRequired`. The sheet's toolbar button is now
"Cancel" (dismisses only, does not retry) rather than a "Done" that
always retried; only `ParentEnrollmentView`'s own `onReauthenticated`
(after a real fresh SIWA completion plus explicit Continue) calls
`retryAfterReauthentication()`.

`AthleteDeviceAuthorizationInvitationCoordinator.PendingOperation` gained
`.resumePolling(invitation:)`: an authentication failure while polling
`connection-request-list` now preserves the exact invitation already
being polled, and `retryAfterReauthentication()` resumes polling it
directly rather than requiring (or creating) a new invitation.

### 12. Deterministic regression tests (round 3)

All new tests use controlled fakes (a non-sleeping polling clock,
continuation-based gated transports) — no timing guesses. Highlights
(see the four touched test files for the complete list): a granted
receipt reconfirms over the network before reporting `.authorized`; a
reinstalled/orphaned receipt or missing key never authorizes and never
generates a replacement key (with or without a grant already recorded);
a pending-receipt save failure blocks the claim; a post-grant save
failure still reports `.authorized` with a warning
(`FakeReceiptStore.failOnSaveCallNumber` — deterministically fails the
Nth `saveReceipt` call, replacing an earlier, rejected `Task.yield()`-based
draft that would have been a timing guess); a transient failure's
`continuePendingAttempt()` resumes with a fresh challenge and never
resubmits the connection request; poll-budget exhaustion and a permanent
local failure are both resumable/non-looping; `forceFreshSignIn` offers
SIWA directly while signed in (with an explicit regression test that
ordinary mode is unaffected); `justCompletedFreshSignIn` only flips after
a real completed handshake, never from cancellation/failure/mere
sign-in; and a polling authentication failure resumes the same
invitation after reauthentication, never creating a new one. All
pre-existing cancellation/generation tests for both coordinators are
preserved unchanged.

## Round 4

Two concluding UI findings against round 3's own `904d531`:

### 13. The comparison code is now shown under pending resume

`resumeStoredReceipt()`'s no-grant branch previously set a bare
`.resuming` state, which the Athlete scan view rendered as only a
spinner ("Resuming your previous connection attempt…") — even when the
receipt already had its own `displayCode`. `State.resuming` now carries
`displayCode: String?` (the receipt's own comparison code, `nil`-safe for
a receipt saved before that field existed), and the scan view renders it
through the EXISTING `awaitingApprovalView` (now widened to accept an
`Optional<String>`), reusing its `athleteDeviceAuthorizationScan.displayCode`
identifier rather than introducing a parallel one. This state is set
BEFORE `pollForApprovalAndClaim` ever calls `claim-challenge`, so the
code is visible immediately on resume — including through every
`request_not_available` tick — never only after a timeout. A receipt
without a stored code shows an honest "Waiting for the parent to
approve on their device" message instead of fabricating one. Resuming
still never calls `connection-request-submit` (unchanged from round 2's
own design) and still uses the SAME `invitationId`/`connectionRequestId`
and the SAME already-established signing key (unchanged from round 3's
key-ownership check).

Also fixed in the same pass: `attemptClaim`'s post-grant `saveReceipt`
call was dropping `displayCode` entirely (defaulting to `nil`) every
time a receipt was re-saved after a confirmed grant — now threads the
SAME `displayCode` the attempt has been carrying throughout, so it
survives being overwritten by the grant-bearing receipt.

### 14. The Parent can reopen reauthentication after dismissing it

`authenticationRequiredView` previously showed only a `ProgressView` —
including after the Parent explicitly cancelled/swiped away the
reauthentication sheet, when no operation was actually running at all,
which read as a perpetual, misleading spinner. It now shows a "Sign in
to continue" action that reopens the SAME sheet for the SAME
`pendingOperation` (untouched by dismissal, so nothing needs to be
re-derived or re-requested).

The underlying presentation state (whether the sheet is shown, and how
dismiss/reopen/a state change interact) is now extracted into
`AthleteDeviceAuthorizationReauthenticationSheetPresentation` — a pure,
SwiftUI-free struct with no reference to the coordinator and no way to
trigger a decision or a retry — so it is deterministically unit-tested
directly (`AthleteDeviceAuthorizationReauthenticationSheetPresentationTests`)
rather than only exercising the coordinator's own network-facing state.
`AthleteDeviceAuthorizationInvitationView` now delegates to it from the
sheet's `isPresented` binding, the Cancel button, `onReauthenticated`,
and the `.onChange(of: coordinator.state)` reset — replacing the earlier
plain `@State private var isReauthenticationSheetDismissed` flag
one-for-one. Cancel/dismiss still never sends a decision or retry: only
`onReauthenticated` (a real completed SIWA handshake plus the Parent's
own explicit Continue tap) calls `retryAfterReauthentication()`.

### 15. Round 4 deterministic tests

`AthleteDeviceAuthorizationPairingCoordinatorTests` gained a new
`GatedClaimChallengeTransport` (continuation-based, mirroring the
existing `GatedSubmitTransport`) so a test can observe `.resuming`'s own
published `displayCode` BEFORE any `claim-challenge` round trip
completes — never a fixed real-time wait raced against a poll loop whose
fake clock never truly sleeps. Covers: the stored code is visible the
moment resume begins and stays visible through to poll-budget exhaustion
without ever calling `connection-request-submit`; an older receipt with
no stored code resumes honestly without inventing one. A new, fully pure
`AthleteDeviceAuthorizationReauthenticationSheetPresentationTests` covers
the sheet's own presentation state directly: shown exactly when
authentication is required; hidden after `dismiss()` even while still
required; shown again after `reopen()`; a dismissal clears once state
genuinely leaves `.authenticationRequired` but never while the SAME
failure persists; and `dismiss()` can never itself cause a presentation
when none is required — by construction, since the type holds no
coordinator reference at all.

## Known limitations carried forward

- No local Swift toolchain exists in the authoring environment —
  Codemagic remains the authoritative compiler/test gate; see the PR's
  own report for the build/test result on this round's final `HEAD`.
- Physical Secure Enclave key generation/reconstitution and a real
  hosted backend round trip are both still unverified outside Codemagic
  and TestFlight.
- Retiring the legacy CKShare pairing screens is explicitly out of scope
  for this checkpoint — see "Scope correction" above.
- Round 3's own behavior (the resumable receipt-reconfirmation path,
  "Continue connection", and forced Parent reauthentication) and round
  4's own UI finish (the comparison code shown under pending resume, and
  reopening reauthentication after dismissal) are likewise unverified on
  a physical device/TestFlight outside Codemagic.
