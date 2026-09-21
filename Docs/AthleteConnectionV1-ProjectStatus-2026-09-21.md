# Athlete Connection V1 — project status (2026-09-21)

Status: documentation-only project checkpoint; not a claim of working Athlete Connection V1.

## Purpose

Track what is decided, implemented, verified and still blocked without requiring developers to reconstruct the pairing project from previous chats. The architecture consolidation and its explicit detailed-contract gap are recorded in [Athlete Connection authorization architecture](Architecture/AthleteConnectionV1-Authorization.md). Do not treat this status note as an alternate architectural authority.

## Decision and implementation ledger

| Area | Current state | Next gate |
| --- | --- | --- |
| UX | Nearby QR requests access; Parent must approve before activation. | Implement and validate on two devices. |
| Privacy | Anonymous QR holders must not access minor's hydration data. Public CKShare permission change in PR #95 is not approved. | Keep PR #95 unmerged and deliver authenticated hydration only. |
| Authorization | Backend is narrow owner of invitation/request/device grant/session access decisions; business membership remains in iOS domains. 15-minute expiry, one successful grant per invitation, revocation required. | Locate full approved schema/API contract, then reviewed implementation. |
| Existing workspace ownership | Internal Alpha fallback (SIWA + human display-name confirmation) approved with explicit trust limitation; CloudKit token spike did not demonstrate a cryptographic SIWA binding or live verification. | Preserve caveat in implementation and TestFlight checks. |
| New workspace ownership | SIWA identity binding on workspace creation required by direction; not verified implemented. | Specify binding from actual approved contract before implementation. |
| iOS spike | Vǫxtr PR #96 merged; test-only native CloudKit evidence investigation, no live Apple-service proof. | Do not treat spike as production ownership verification. |
| Backend foundation | `cristern/Voxtr-Backend` PR #1 merged to `develop` 2026-09-21; merge SHA `fcbab9bce256f643924032962de8882b6eb2f9ac`. Source HEAD `2b961d48848c242f68a08aa2a8fe4a40de2b5b93`; two GitHub Actions checks successful. | Add contract first; then first migration with isolated database validation. |
| Supabase hosting | `voxtr-auth-dev` exists as development project; PR #1 did not link, deploy, apply migrations or change hosted configuration. | Deliberate dev deployment after reviewed scope and secrets setup. |
| Runtime | Secure pairing, cross-device hydration and revocation **not** validated end-to-end. | Codemagic for Swift compile; TestFlight on physical devices for runtime. |

## Documentation closeout prerequisites

The supplied living `Vøxtr_Architecture_v1.0.docx` contains governance/scope sections but not the full Athlete Connection API/security contract. `00_Project_Context_v1.0.docx` still describes architecture as planned and development as not started; it is historically stale for the current Alpha. The repository's Foundation B closeout describes a former CKShare-based approved direction; that paragraph is superseded for **pairing/authorization only** by the later backend decision. These documents must be reconciled under the established documentation hierarchy. Do not quietly overwrite history or promote this summary into a complete security spec.

**Next action:** obtain the actual approved detailed security-contract text and incorporate it into the canonical living Architecture and ADR, with explicit provenance, then update Project Context and backend repository's `CLAUDE.md` reference. Only after that authorize the first schema/API implementation. Avoid creating a second independently maintained contract in the backend.

## Branch and merge governance

This checkpoint is on a documentation-only `claude/...` branch, PR to `develop`; it does not change application code or Supabase. Product Owner approval is required before merge. Do not merge `main` or PR #95 as part of documentation closeout.
