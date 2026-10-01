# Athlete Connection V1 — iOS Pairing Implementation Checkpoint (review round 2)

This records what changed in `claude/athlete-connection-ios-pairing-v1`
(cristern/Voxtr PR #106) in response to the first round of review, and
the exact current state of each area. It does not restate the whole
feature — see `AthleteConnectionV1-NormativeSecurityContract.md`,
`AthleteConnectionV1-ParentAuthenticationContract.md`, and
`ADR-AthleteConnection-BackendAuthorization.md` for that.

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

## Known limitations carried forward

- No local Swift toolchain exists in the authoring environment —
  Codemagic remains the authoritative compiler/test gate; see the PR's
  own report for the build/test result on this round's final `HEAD`.
- Physical Secure Enclave key generation/reconstitution and a real
  hosted backend round trip are both still unverified outside Codemagic
  and TestFlight.
- Retiring the legacy CKShare pairing screens is explicitly out of scope
  for this checkpoint — see "Scope correction" above.
