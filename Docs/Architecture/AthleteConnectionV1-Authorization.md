# Athlete Connection V1 — authorization architecture and evidence boundaries

Status: **documented approved direction; detailed security/API contract still requires source verification before implementation**. Documentation consolidation, 2026-09-21. This note does not supersede the Product Constitution or the living Architecture v1.0 document. It records the bounded decisions and verified state needed to migrate the approved contract into that document without silently inventing missing details. See [ownership spike](../AthleteConnectionOwnershipVerificationSpike.md) for technical evidence and limitations.

## Purpose and outcome

A Parent chooses an existing athlete, displays a nearby QR code, and explicitly authorizes a requesting Athlete installation. The Athlete gets access to **exactly the selected athlete**, without creating another athlete identity or exposing a minor's profile to anyone merely holding a QR link. A connection should be revocable. The QR is a request mechanism, not authorization or proof of membership.

## Approved domain ownership and boundaries

- `cristern/Voxtr` remains authoritative for `AthleteProfile`, `WorkspaceParticipant` business membership, stable workspace/participant/athlete IDs, Planning, Training and Reflection. No sibling/name/age matching or second athlete identity.
- `cristern/Voxtr-Backend` is a deliberately narrow authorization service on Supabase (Edge Functions and PostgreSQL). It owns invitation/request/grant/revocation state and authoritative invitation expiry/consumption. Distinguish business membership, device authorization grant and runtime session; one must never silently stand in for another.
- CloudKit remains the existing business-sync transport. **Only Athlete Connection pairing/authorization** moves away from the current invitation `CKShare` route; this is not a replacement of all CloudKit use.
- Parent approval is required **before first grant activation**; possession of a QR or invitation ID alone never activates a session or authorizes hydration.

## Approved security outcomes (not implementation claims)

1. Invitation lifetime: **15 minutes**, evaluated by the backend against authoritative server/database time, not client clocks.
2. Exactly **one successful connection per invitation**, enforced atomically in the database under concurrent requests; retries and competing requests must not cause multiple grants. The final SQL schema, states and endpoint semantics must come from the full approved contract before coding.
3. The unauthenticated invitation surface must not expose athlete name, date of birth or any other hydration/profile payload. Parent approval and verified authorization precede sensitive hydration; signing or key possession alone is **not** a confidentiality/encryption mechanism.
4. Parent can revoke a device grant, and subsequent sensitive operations/session checks must reject revoked grants. Local UI revocation without server enforcement is insufficient. Do **not** promise erasure of previously downloaded/offline data or instant enforcement on an offline device.
5. Stable IDs remain authoritative; `FamilyWorkspace.technicalOwnerAccountId = AccountId.pending` must not be interpreted as a verified Sign in with Apple subject or migrated opportunistically.
6. Device key possession and runtime session/grant checks are separate concerns from Parent identity, workspace ownership and business membership. Avoid client-asserted authorization, permissive RLS and service-role secrets on devices.

## Parent enrollment: separate cases and honest trust boundary

- **New workspaces:** the approved direction is binding the authenticated Parent's Sign in with Apple identity when creating a new workspace, before allowing that workspace to be enrolled. This is a required future implementation behavior, **not verified as present in the current app**.
- **Existing workspaces:** Product Owner accepted a bounded **Internal Alpha** enrollment trust step using Sign in with Apple plus manual Parent display-name confirmation; this is **not cryptographic proof of workspace ownership**. Do not upgrade this wording to an independently verified guarantee.
- The merged [ownership verification spike](../AthleteConnectionOwnershipVerificationSpike.md) explores a potentially stronger CloudKit Web Auth Token / Web Services record-access check. Its verdict is **NOT VERIFIED / NOT FEASIBLE as a standalone cryptographic SIWA-to-CloudKit ownership binding**: no live Apple-service round trip occurred, and no documented linkage between CloudKit account identity and the SIWA `sub` was established. Performing both checks in one enrollment session can be investigated, but is not proof of a cryptographic link and must not be represented as implemented or live-validated.

## Rejected/unsafe path

[Vǫxtr PR #95](https://github.com/cristern/Voxtr/pull/95) changes the invitation `CKShare` public permission to `.readOnly`. Its recorded payload includes a minor's given name and birth date. Any forwarded QR holder could resolve that invitation record. The proposed change is **not the approved solution; do not merge PR #95**. Merely changing CloudKit share permission does not implement 15-minute server expiry, one-time consumption, explicit Parent approval or grant revocation.

## Implementation and validation status (as of 2026-09-21)

- [Vǫxtr PR #96](https://github.com/cristern/Voxtr/pull/96), the isolated ownership-evidence compile/spike, is merged to `develop`. Compile/tests passing do not demonstrate a working live CloudKit Web Services validation.
- [Vǫxtr-Backend PR #1](https://github.com/cristern/Voxtr-Backend/pull/1) is merged to backend `develop` at `fcbab9bce256f643924032962de8882b6eb2f9ac`; both PR checks passed at source HEAD `2b961d48848c242f68a08aa2a8fe4a40de2b5b93`. This adds repository/Supabase scaffolding, CI, migration structure and a **not-deployed** diagnostic `health` function. No backend authorization schema, endpoints, linked hosted project, real data or deployment exists as a result of that PR.
- The old QR/CloudKit acceptance implementation remains historical implementation rather than approval for a PII-bearing public invitation. A fully working secure two-device pairing and real runtime revocation are **not** validated.

## Required documentation gate before schema/API implementation

The **complete** approved security contract (exact endpoints and request/response payloads; invitation/request/grant state transitions; atomic transaction and idempotency rules; device-key challenge semantics; SIWA verification; sensitive hydration delivery/encryption; session issuance and validation; revocation and offline behavior) is not committed in this repository or the backend repository and was not fully recoverable from the reviewed canonical materials. Do not infer these details from this summary or from code. Locate the original approved contract/review artifacts, reconcile them with the Architecture and an ADR, and obtain explicit Product Owner approval of any genuinely missing decision. Only then implement the first real migration. This is a documentation dependency, not permission to redesign the agreed product behavior.

## Source and precedence

Product Constitution → living Architecture → ADR → Domain & Data Model → Living PRD → lower documentation → implementation. Historical [Foundation B closeout](../AthleteConnectionFoundationB-Closeout.md) described the earlier CloudKit `CKShare` implementation path and is **superseded for Athlete Connection authorization by the above approved backend direction**, not erased as historical runtime evidence. This file is a consolidation record pending incorporation into the actual living Architecture document, not a second independently authoritative security contract.
