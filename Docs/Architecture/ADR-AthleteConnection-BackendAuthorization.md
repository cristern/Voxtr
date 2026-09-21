# ADR — Narrow backend authorization for Athlete Connection V1

Status: **records approved architectural direction**, 2026-09-21; **does not replace the missing detailed security/API contract**. Product Constitution and the living Architecture retain higher authority. See [architecture consolidation](AthleteConnectionV1-Authorization.md) for security outcomes, evidence boundaries and remaining detailed-contract gate.

## Context and purpose

The QR-first two-device connection needs to bind a Parent-selected existing athlete without disclosing minor profile data to a forwarded QR holder or granting device access without the Parent's approval. The historical CloudKit invitation flow failed `CKError.unknownItem`; PR #95 proposed public `.readOnly` access to a record carrying minor PII. CloudKit invitation URLs do not themselves provide backend-enforced 15-minute expiry, exactly-once grant issuance or remote grant revocation. Human and business identities cannot be inferred from possession of a URL.

## Decision already approved by the Product Owner

Use a **minimal Vǫxtr-operated authorization backend** for Athlete Connection pairing only, hosted for development on Supabase Edge Functions and PostgreSQL. An invitation is a request, not a grant; the Parent authorizes a specific request before the first device grant/session becomes active. The server/database owns invitation/request/grant/revocation state, server-time expiry and atomic exactly-once consumption. Profile hydration is authorized only after successful approval and authorization, not available anonymously from the QR.

Existing CloudKit business synchronization remains in place; this ADR **does not** migrate athlete profiles, business membership, Planning, Training or Reflection to Supabase. `AthleteProfile` and `WorkspaceParticipant` remain the canonical iOS domain identities, with stable IDs preserved end to end. Device grant and runtime session are distinct from workspace membership. Revocation must be enforced on future online access; already downloaded/offline bytes cannot be retroactively recalled.

## Enrollment trust qualification

For new workspaces, bind authenticated Parent Sign in with Apple identity at workspace creation (future requirement, not claimed implemented). For already-existing workspaces, the Product Owner accepted an explicitly bounded Internal Alpha step using Sign in with Apple plus human display-name confirmation, **not cryptographic ownership verification**. The isolated CloudKit token spike did not live-validate Web Services access and did not prove any cryptographic connection to SIWA `sub`; do not elevate it into an identity guarantee. See [spike evidence](../AthleteConnectionOwnershipVerificationSpike.md).

## Alternatives considered and disposition

- Continue the public PII-bearing invitation CKShare path (PR #95): **not approved**; allows QR holder to resolve the minor's data and does not meet expiry/consumption/approval/revocation outcomes.
- Replace all CloudKit synchronization with the backend: out of scope and violates the narrow domain ownership decision.
- Add a local-only revocation flag or treat QR possession as identity: cannot enforce future server access and does not satisfy Parent approval.

## Consequences and required gates

The backend is an additional, narrowly bounded service with its own deployment/secrets/database migrations. Backend Foundation V1 merged in [Voxtr-Backend PR #1](https://github.com/cristern/Voxtr-Backend/pull/1); it added scaffolding/CI only, with no hosted deployment, migrations or authorization logic. The complete approved API/state-machine/SQL/device-key/hydration/session contract must be recovered and reconciled into the living Architecture before implementation; this ADR deliberately cannot supply missing endpoint or cryptographic details. Develop via task branches and reviewed PRs, validate SQL/concurrency in isolated CI, Swift via Codemagic and final two-device behavior via TestFlight. Never merge PR #95 as a workaround.
