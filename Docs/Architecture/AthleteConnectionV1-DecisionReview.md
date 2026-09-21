# Athlete Connection V1 — Product Owner security decision record

**Status: D1–D4 APPROVED 2026-09-21.** Supersedes the earlier *proposal / awaiting decision* text in this file. This is a decision ledger, not a second implementation contract. The [normative security contract](AthleteConnectionV1-NormativeSecurityContract.md) defines the approved outcomes and clearly labels remaining technical protocol work. The [backend ADR](ADR-AthleteConnection-BackendAuthorization.md) and [authorization architecture](AthleteConnectionV1-Authorization.md) remain the architectural references under the Product Constitution and living Architecture hierarchy.

## Purpose

Make nearby QR → Parent approves exact device → protected hydration and revocable connection privacy-safe, recoverable and calm, without inventing a second athlete identity or falsely claiming offline revocation can erase downloaded data. Backend Foundation V1 is merged but neither backend authorization nor hosted deployment is implemented.

## Prior approvals preserved

Parent chooses exact existing athlete; QR only invites a request; Parent approves the request for the physically verified device; no minor PII in anonymous QR/public APIs; authoritative 15-minute invitation TTL and one successful connection per invitation; stable IDs; CloudKit remains for business sync, not CKShare pairing; separate workspace membership/device grant/runtime session; server-side online revocation. Signatures prove signing-key possession, not encryption. PR #95's public PII-bearing invitation remains unapproved.

## D1 — Data transport: APPROVED, HTTPS

After Parent approval and device-authenticated authorization, the backend may temporarily process **only the necessary athlete hydration information** over protected HTTPS. Other QR holders and unapproved/different devices receive none. The backend is a trusted processor and is **not promised to be unable to read plaintext**. The old proposal to encrypt data to a `P256.Signing` public key was invalid; no end-to-end encryption requirement was approved. Any persistence must be private, minimal and subject to approved 24-hour retention, audit and operational backup limitations.

## D2 — Recovery: APPROVED, 24 hours

The **same approved installation** can resume an interrupted hydration without new Parent approval within **24 hours** after grant creation, after fresh proof of possession and active-grant checks. No second grant may be created. Retained temporary data are deleted on authenticated successful completion or by the deadline, whichever occurs first; revocation must also deny retrieval and remove retained recovery data. 24 hours does not extend the 15-minute window for the first claim: an unconsumed expired invitation requires a new invitation. Earlier 72-hour retention was illustrative and is superseded.

## D3 — Offline: APPROVED, cached view with uncertainty

Previously downloaded local information remains viewable offline. The app shows that the connection **cannot currently be verified**, not that it is active or revoked without evidence. No new protected synchronization operations while authorization cannot be verified. Server-side online sensitive operations check live grant status even if a session token has not expired. The earlier proposal for 15-minute sensitive-use freshness and ~1-hour token lifetime remains **unapproved engineering parameters**, not user-facing access requirements. Revocation cannot recall offline bytes.

## D4 — Existing workspace ownership: APPROVED for Internal Alpha only

Parent signs in with Apple and deliberately confirms the existing workspace/display name. This is an explicitly bounded **human trust** enrollment, NOT independent cryptographic workspace ownership verification. `AccountId.pending`, client-returned `recordChangeTag`, or SIWA↔CloudKit coincidence must not be promoted into ownership proof. Owner-account change is a **separate controlled recovery process**, not automatic self-service rebind. New workspaces must bind authenticated SIWA identity at creation. The isolated CloudKit ownership spike did not live-prove SIWA identity equality.

## Consequences and implementation gate

The Product Owner has approved all four behavior decisions. No further Product Owner selection is required among the old A/B options. Technical security design remains necessary before coding: exact wire API, trusted Parent onboarding and conflict policy, states/DDL/concurrency, signing challenge canonical bytes, token/session TTL and verification, sensitive-field inventory, private retention/cleanup/backup semantics, rate-limiting and cross-system CloudKit boundary. These are **engineering design obligations**, not permission to alter D1–D4. Recovered historical API paths/schema are candidates, not frozen contract. The [normative contract](AthleteConnectionV1-NormativeSecurityContract.md) gives the approved invariants, acceptance gates and explicit remaining parameters; the recovery ledger flags invalid old mechanisms.

Documentation PR #97 changes documentation only. It does not authorize implementation, Supabase mutation, merge, or deployment; all require the established separate review and explicit approvals.
