# Athlete Connection V1 — project status (2026-09-21)

Status: documentation-only checkpoint in PR #97, **not** a claim of working Athlete Connection V1. Do not merge without explicit Product Owner approval.

## Purpose and sources

Track agreed decisions, implementation and remaining gates without reconstructing history. Product Owner-approved D1–D4 are recorded in [decision record](Architecture/AthleteConnectionV1-DecisionReview.md). [Normative security contract](Architecture/AthleteConnectionV1-NormativeSecurityContract.md) defines approved behavior, invariant/security requirements and explicitly identified missing implementation parameters. [Architecture](Architecture/AthleteConnectionV1-Authorization.md) and [ADR](Architecture/ADR-AthleteConnection-BackendAuthorization.md) retain architectural framing; recovered historical [API report ledger](Architecture/AthleteConnectionV1-RecoveredAPIContract.md) is **not** a current implementation specification.

## Decision and implementation ledger

| Area | Current state | Next gate |
| --- | --- | --- |
| UX/identity | Nearby QR requests access; Parent selects an existing exact athlete and approves a visually matched device request before activation. | Implement and validate on two devices; never infer sibling identities. |
| Privacy / D1 | **Approved 2026-09-21:** minimum hydration data over authorized HTTPS after approval; backend may process temporarily; QR holders/other devices get none. Public CKShare permission change in PR #95 not approved. | Specify precise payload, authenticated handling, private storage/backups and no PII disclosure. |
| Interrupted pairing / D2 | **Approved:** same approved installation can resume within 24 hours without new Parent approval; delete temporary data on verified completion or deadline. First new grant still requires unexpired 15-minute invitation. | Define exact claim and recovery transaction, state transitions and cleanup; exercise lost response and expiry tests. |
| Offline / D3 | **Approved:** cached data viewable offline with explicit `cannot verify connection` state; no new protected sync. Online server grant revocation mandatory. | Define precise session protocol and iOS UX; do not claim offline erase. |
| Existing workspace / D4 | **Approved for Internal Alpha:** verified SIWA plus manual workspace display confirmation is explicitly limited trust; account-owner change uses separate controlled process. CloudKit spike did not establish cryptographic SIWA binding. | Complete secure enrollment conflict/audit procedure; never use old recordChangeTag proof. |
| New workspace | Bind verified SIWA identity at creation; `AccountId.pending` cannot be treated as owner evidence. | Reviewed new-workspace and migration protocol before implementation. |
| Authorization | Backend alone owns invitation/request/device grant and runtime access decisions; business membership remains iOS domain. 15-minute expiry, one grant/invitation and revocation are required. | Freeze endpoint wire contract, state machine, DDL, challenge bytes, session checks and concurrency tests. |
| iOS spike | Vǫxtr PR #96 merged; test-only CloudKit evidence investigation, no live Apple-service proof. | Do not treat spike as production ownership verification. |
| Backend foundation | `cristern/Voxtr-Backend` PR #1 merged 2026-09-21; merge SHA `fcbab9bce256f643924032962de8882b6eb2f9ac`, source HEAD `2b961d48848c242f68a08aa2a8fe4a40de2b5b93`, both GitHub Actions checks successful. | Use approved normative behavior plus reviewed exact technical contract before first migration with isolated DB validation. |
| Supabase hosting | `voxtr-auth-dev` exists as development project; PR #1 did not link, deploy, migrate or change hosted configuration. | Deliberate test-only setup after security review; never use actual minor data in dev. |
| Runtime | Secure two-iPhone pairing, hydration and revocation **not yet validated**. | Codemagic Swift compile; real TestFlight two-device runtime acceptance. |

## Documentation authority and outstanding consistency work

The supplied living `Vøxtr_Architecture_v1.0.docx` contains governance/scope but not the revised authorization section; `00_Project_Context_v1.0.docx` still states development has not started. They are stale and require a separately reviewed canonical update. Foundation B closeout's CKShare-based happy path is historical and superseded **for pairing/authorization only** by backend direction; CloudKit continues business sync. Do not erase historical evidence or silently present this PR's companion Markdown as an already-updated DOCX source of truth.

**Next:** review the bounded remaining *engineering* decisions in the normative contract (SIWA enrollment, exact endpoint and request states, session/challenge protocol, retention/backups, abuse controls and CloudKit sync enforcement); incorporate the approved contract into the living Architecture and synchronize backend `CLAUDE.md` by a reviewed backend documentation PR. Only then authorize first SQL migration/API implementation. The Product Owner's D1–D4 behavior choices are settled and must not be reopened without an explicit new product discussion.

## Branch and merge governance

This documentation checkpoint is on a task branch and PR #97 to `develop`, with no code or Supabase modifications. Product Owner approval is required before merge. Do not merge `main` or PR #95 as part of documentation closeout.
