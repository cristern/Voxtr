# Athlete Connection V1 — recovered API/security design and correction ledger

Status: **review draft / recovered source, NOT a complete approved implementation contract**. Added to documentation PR #97 on 2026-09-21. Companion to [authorization architecture](AthleteConnectionV1-Authorization.md) and [ADR](ADR-AthleteConnection-BackendAuthorization.md); their approved outcomes take precedence over obsolete details below. Do not implement a migration, API or cryptographic protocol directly from this recovery document until the correction gaps are resolved and explicitly approved.

## Provenance and accuracy

A previously uploaded report has now been recovered from Vǫxtr's file library: **“Vǫxtr — Athlete Connection V1: Final Security Design & API Contract”**, uploaded 2026-09-17 12:56 (file reference in current review: `turn341file0`; exact report begins with this heading and contains Sections 1–16). A preceding report **“Minimal Authorization Service — Architecture & API Contract”**, uploaded 2026-09-17 12:10 (file reference `turn339file0`), is earlier and contains acknowledged unresolved claim/device decisions. The final-design report is a design report, not an implemented or live-validated system. Its Section 15 expressly lists unresolved Product Owner decisions. A later correction and the merged CloudKit ownership spike invalidate the final report's particular client-supplied `recordChangeTag` ownership-proof claim. Source documents are uploaded-file references, **not** automatically committed canonical files; copy of the entire report has not been inserted into repository or claimed as separately approved.

**Source priority:** approved product outcomes and later corrections > final-design report > earlier minimal-service proposal > historical CKShare discovery. Report tables saying “PASS” mean the report's *design assessment*, not passing tests or real-world verification.

## 1. Approved and retained outcomes

- Parent chooses an existing athlete before creating a nearby QR invitation; scanning alone creates a request and never grants access. Parent expressly approves the intended device.
- No minor name/birthdate or hydration data is exposed to any unauthenticated QR holder. Preserve the same stable workspace, participant and athlete IDs; business membership remains in iOS domains.
- Authoritative invitation TTL is **15 minutes** against database/server time; exactly **one successful device grant per invitation**, including concurrent claims and retry handling.
- Backend owns invitation/request/device-grant authorization state. Runtime session is not equivalent to grant; local participant business membership is not equivalent to device authorization. CloudKit remains for separate business sync, not CKShare pairing/authorization.
- Parent can revoke grants server-side; revoked grants cannot authorize subsequent sensitive online operations. Previously downloaded/offline bytes cannot be recalled. Unverifiable offline access must be shown honestly.
- New-workspace SIWA owner binding happens at creation. Existing-workspace migration has an explicitly limited Internal Alpha trust step: SIWA + human display-name confirmation, **not independent cryptographic CloudKit ownership proof**. `AccountId.pending` is not real ownership evidence.
- PR #95 public `.readOnly` invitation must remain unmerged; spike PR #96 provides no live Apple verification. Backend PR #1 provides scaffold and CI only.

## 2. Original design details recovered, with their status

The 2026-09-17 final-design report Sections 5–10 proposed these concrete mechanisms. They are reproduced here as a **recoverable engineering baseline**, NOT automatically approved wire/schema declarations:

### Athlete key, request matching, claim

- AthleteApp generates a P-256 Secure Enclave **signing** key; request submission sends public key and receives a fresh request-specific human comparison code in its direct HTTPS response. The Parent sees the code only on a workspace-authenticated request list and visually compares it with the athlete's device. The code identifies a request for human approval, but is **not authentication** or proof of the child's real-world identity.
- Claim requires a fresh server nonce and signature verified against the exact approved request's stored public signing key. Lost-response retry from that same key can be idempotent; a different device must never obtain an existing grant/payload by presenting an invitation ID or stolen grant ID.
- The signing key is for signatures and possession only. **It does not provide encryption**. The final report's statement that a payload can be encrypted directly to its `P256.Signing` public key is not a valid encryption construction and must not be implemented. A separate reviewed confidentiality design (recipient encryption/key-agreement key or appropriately authenticated HTTPS delivery) and associated threat model are required.

### Database proposal from original report Section 10

The earlier report suggested `parents(sub PK)`, `workspace_owners(workspace_id,sub PK)`, `invitations(id,workspace_id,athlete_id,created_at,expires_at,consumed_at)`, `requests(id,invitation_id,public_key,display_code,status,created_at)`, `grants(id,invitation_id UNIQUE,workspace_id,athlete_id,device_public_key,status,created_at,revoked_at)`, and `payloads(grant_id PK, encrypted_payload,retain_until)`. It proposed indexes on `requests(invitation_id)` and `grants(workspace_id)`. These are **historical proposed columns**, not ready-to-run DDL: the enrollment security correction and encryption change may alter schema and storage. Any auth tables should be private/non-Data-API exposed and privilege-audited before migration.

### Atomic consumption requirement

The original report Section 6 proposed one transaction to check approval and DB-time expiry, consume the **invitation** and insert one grant; `UNIQUE(grants.invitation_id)` is a necessary independent backstop. Its example `SELECT ... FROM requests JOIN invitations ... FOR UPDATE` must be corrected to lock the authoritative invitation row explicitly (`FOR UPDATE OF i`, with a suitable alias), and concurrent claims for different requests sharing the invitation must race under that one lock. Check expiry and consumption **inside** the transaction after the lock; do not rely on an application-side check or solely on request-level `consumed_at`. For a same-key retry, distinguish genuine idempotent retrieval from minting an additional grant. This is a constraint to validate with real PostgreSQL concurrency tests, not a claim tests already exist.

### Session and revocation baseline

The original Section 7 proposes short-lived (~one-hour) server-issued session bearer tokens in device-only Keychain; refresh requires a fresh signature over a server nonce. `grantId` alone is never authorization. The backend must check active grant status on sensitive operations; revocation blocks future online authorization even if a token has not reached its expiry. Section 8 proposes immediate re-verification on relaunch and honest offline/uncertain state. The extra 15-minute sensitive-operation freshness threshold and exact one-hour token/offline limits were **proposals pending Product Owner confirmation**, not approved numbers. Never claim local PII is remotely erased.

## 3. Historical API inventory (final report Section 9; names/shapes NOT frozen)

| Path | Original purpose / caller | Security consequence and correction |
| --- | --- | --- |
| `POST /v1/parent/register` | Parent workspace enrollment, SIWA | Original body contained `{workspaceId,nonce,proof:<recordChangeTag+nonce>}`; **proof is invalid as independently verifiable ownership**, do not implement as described. Needs separate new/existing workspace handling. |
| `POST /v1/invitations` | Parent creates `{workspaceId,athleteId}`, receives `{invitationId,expiresAt}` | Server session and workspace scope; DB-generated times; no athlete PII to QR. |
| `POST /v1/invitations/{id}/requests` | Unauthenticated athlete submits signing public key; receives `{requestId,displayCode}` | Multiple request IDs may compete; code only on direct response and Parent-authenticated list. Unknown vs expired response must avoid enumeration. |
| `GET /v1/workspaces/{workspaceId}/requests?status=pending` | Parent fetches pending requests and codes | Owner-bound session authorization, never grant token/PII leakage. |
| `POST /v1/requests/{id}/approve` and `/reject` | Parent chooses request; approve supplies minimum hydration input in original report | Exactly which fields/where payload is stored and confidentiality method **need corrected design**. Approval must not itself expose data or grant access to any other request. |
| `GET /v1/requests/{id}/challenge` | Fresh nonce for approved request's claim | Nonce identity/expiry/one-use and signature canonicalization still require a full wire contract. |
| `POST /v1/requests/{id}/claim` | Athlete signs challenge, receives grant/session and protected hydration | Atomic invite lock + unique grant; authenticate device key. Original `encryptedPayload` shape is not approval for the invalid signing-key encryption claim. |
| `POST /v1/requests/{id}/hydration-complete` | Same authorized athlete acknowledges completion | Delete retained payload only after authenticated acknowledgement; loss/retry retention length needs decision. |
| `GET /v1/grants/{id}` and `POST /v1/grants/{id}/refresh` | Grant status and signature-based session renewal | Grant ID never credential; active server grant checked on sensitive operations and refresh. |
| `POST /v1/grants/{id}/revoke` | Parent revokes workspace-scoped grant | Enforced server-side, honest offline behavior. |

The complete, corrected payload field schema, request-state transitions, error mapping, challenge binding/canonical bytes and session invalidation have **not** been verified in a post-correction authoritative source. They are NOT inferred here.

## 4. Specific corrections overriding the original final-design report

1. **Ownership spoofing:** client returning `recordChangeTag` plus nonce cannot itself prove a CloudKit operation occurred; those values are caller-controlled from backend's perspective. No server validation means no proof. The later merged [ownership evidence spike](../AthleteConnectionOwnershipVerificationSpike.md) found a real CloudKit Web Auth Token path but no cryptographic link to SIWA `sub` and no live Apple-service test. Maintain existing-workspace **explicit limited trust enrollment**; new workspaces bind authenticated Parent identity when created. Do not present `technicalOwnerAccountId` migration as automatically safe or identify SIWA `sub` with CloudKit identity.
2. **Recipient confidentiality:** signing-key proof does not encrypt the hydration payload. Choose and document a separate actual confidentiality mechanism; the approved outcome is no preapproval PII and protected postapproval delivery, not any particular unverified cryptographic claim.
3. **SQL concurrency:** the invitation row is the contention point; explicit `FOR UPDATE OF i`, verify/consume/create grant atomically, unique invitation ID in grants; real concurrent claim test.
4. **Revocation semantics:** `WorkspaceParticipant` business membership does not equal device grant. Keep a server-authenticated active-grant check for each sensitive operation; don't describe token expiry alone as immediate online revocation.
5. **Decision boundaries:** numbers of ~1 hour for tokens, 15 minutes for *sensitive-use freshness*, 72 hours encrypted payload retention, and recovery UX without CloudKit were suggestions in original report, not approved parameters. Only invitation TTL = 15 minutes is approved in the available record.

## 5. Implementation gate and verification plan

Before backend Stage B/migrations, obtain Product Owner sign-off on the corrected protocol details that materially change privacy, auth or offline UX; first produce a reviewed, explicit normative specification covering new/existing Parent onboarding, grant/session checks, approved request identity challenge protocol, hydration protection and retention, states and failure contracts. Match to existing Vǫxtr code and Apple SDK semantics, not merely report text.

Automated minimum: PostgreSQL concurrency test (two different approved request claims, one grant); expiry-boundary and duplicate/retry tests; authorization tests for wrong Parent/workspace, stolen grant ID, unexpected QR requests, revocation on existing session and no unauthenticated PII. Separate cryptographic unit tests from genuine Apple device/CloudKit service integration. GitHub Actions is backend CI; Codemagic Swift compile; TestFlight two physical iPhones is runtime acceptance. None of these backend/security end-to-end gates passed merely because Backend Foundation V1 CI is green.

**Status accounting:** this recovery reduces the documentation gap materially but does **not** erase it or authorize implementation. No source text for the later full Security Contract Correction report has been verified in the available files; the precise corrected normative API/state machine is still an explicit, bounded dependency. This document makes the recovered source and unsafe superseded statements discoverable for a future review without pretending a full contract is recovered.
