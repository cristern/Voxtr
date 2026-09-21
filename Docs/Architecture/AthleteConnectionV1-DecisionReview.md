# Athlete Connection V1 — decision ledger

Status: Product Owner decisions D1–D4 **approved 2026-09-21**. This is a concise ledger; the [normative behavioral contract](AthleteConnectionV1-NormativeSecurityContract.md) owns precise approved requirements, while [technical review](AthleteConnectionV1-TechnicalProtocolReview.md) contains **engineering proposals not yet approved**. The [recovered original report](AthleteConnectionV1-RecoveredAPIContract.md) is provenance, not a contract for implementing stale/unsafe details.

## Purpose

A nearby Parent-approved request connects exactly one selected existing athlete to the actual Athlete installation, without PII exposure to QR holders and with server-enforced single-use authorization, honest offline behavior and recoverable activation.

## Already agreed before D1–D4

Stable identity/One Truth; Parent first selects athlete; QR requests only; Parent visibly compares a request-specific code and approves exact request; invitation server TTL 15 minutes; one successfully issued grant per invitation with atomic database consumption and safe same-key idempotency; no child name/birthdate in anonymous QR/endpoint; server-revocable installation grant distinct from `WorkspaceParticipant` business membership and runtime session; CloudKit continues independent business sync, not CKShare pairing; new workspaces require SIWA binding, existing-workspace Internal Alpha enrollment admits a known limited trust step. PR #95 public `.readOnly` CKShare permission is not approved. A P-256 signing key does not encrypt.

## Product Owner decisions — approved verbatim in substance

| ID | Approved | Consequence |
| --- | --- | --- |
| D1 | Postapproval minimal athlete data transferred over protected HTTPS; backend may temporarily process it. | Trusted data processor, no end-to-end encryption claim; only exact approved authorized installation receives payload. |
| D2 | Same approved installation resumes interrupted connection up to **24 h**, no renewed Parent approval. Temporary data deleted on confirmed completion or deadline. | Fixed deadline from first successful grant, same-key proof and no second grant. Hard read cutoff and monitored deletion; backup erasure limits must be disclosed and technically addressed, not silently ignored. |
| D3 | Cached local data viewable offline; UI explicitly says connection cannot be verified; no new protected sync. | Online grant check/revocation, no claim that backend can delete offline bytes or automatically revoke separately accepted CloudKit permissions. |
| D4 | Existing workspaces in Internal Alpha use verified SIWA plus manual workspace confirmation with explicit trust limitation; owner-account change separate controlled process. | No first-registration-wins by arbitrary UUID, no client `recordChangeTag` proof, no automatic SIWA transfer; new workspaces bind SIWA at creation. |

## Technical review pending — not additional settled product decisions

Engineering defaults proposed in the linked technical review: 60-second bound nonce, 10-minute opaque session, versioned action/request-bound ECDSA signing protocol with Swift↔backend test vectors, private `authz` tables and metadata-only initial migration. Before implementing: prove/lock SIWA-new-workspace integration and Internal Alpha enrollment authorization, actual hydration snapshot/init parameters, 24-hour deletion versus provider backup behavior, CloudKit-sync revocation boundary, correct custom JWT handling and exact wire/DDL. These are security architecture gates. Do not present candidate values or historical sample routes/schema as approved simply because this product decision ledger is approved.

## Governance

PR #97 is documentation only and requires separate Product Owner merge approval. Backend PR #1 is already merged scaffold only. No code, hosted Supabase config, migration, main merge or PR #95 merge is authorized by D1–D4.
