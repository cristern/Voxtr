# Athlete Connection V1 — focused security contract decisions

Status: **PROPOSAL — awaiting Product Owner decisions; do not implement as an approved contract.** 2026-09-21. This is a bounded companion to `AthleteConnectionV1-RecoveredAPIContract.md` on documentation PR #97, not an independent source of truth. Superseded report details must not be silently promoted into Architecture.

## Purpose

Make the nearby QR → Parent approves exact device → athlete hydrates and gets revocable access flow both privacy-safe and recoverable. Lock only materially consequential choices, then derive exact request/response and database contracts in the authoritative living Architecture. Backend Foundation V1 is merged but has no real auth schema or deployment.

## Already agreed; not reopened

Parent selects canonical existing athlete; QR is an invitation to request, not permission; Parent explicitly approves specific device after displaying a matching request code; no minor PII in anonymous QR/API responses; backend DB time enforces 15-minute invitation expiry and one successful grant per invitation; server enforces revocation for future sensitive online operations; distinct membership/device grant/session; stable IDs; CloudKit business sync retained but no CKShare pairing; new workspace SIWA binding and clearly limited existing-workspace Internal Alpha enrollment. Signing-key ownership is not encryption. Old PR #95 must not be merged.

## Decisions requiring explicit approval

### D1. Post-approval hydration confidentiality and service visibility

**Option A (proposed for Internal Alpha):** only after verified Parent approval and proof of possession of the approved request's device signing key, deliver the minimal required hydration fields over authenticated HTTPS with an opaque, grant-bound short-lived server session. The service temporarily handles plaintext to deliver it; encrypt at rest under properly restricted server-managed mechanisms only if it must persist a recovery copy. Minimize fields and retention. Do NOT claim end-to-end encryption or that DB operators cannot read plaintext.

**Option B:** implement separate encryption/key-agreement key material, an explicit encryption protocol, ciphertext-only recovery and key-rotation/reinstall rules. More cryptography and client/server scope. Requires independent design and tests; the earlier report's encryption-to-P256-signing-key text is invalid.

**Recommendation: A**, provided V1 accepts the backend as a trusted data processor. If confidentiality from the backend operator itself is a requirement, choose B and formally specify the cryptographic envelope before implementation.

### D2. Interrupted hydration, retries and retention

**Option A (proposed):** one grant per invitation; same-device cryptographically authenticated retry can resume an incomplete hydration through a bounded, one-time recovery payload; explicit `hydration-complete` acknowledgment deletes it, as does expiry; a new device always requires a new invitation. Proposed short retention window **24 hours**, not previously approved; exact duration needs approval. Never delete the only recovery copy upon mere HTTP response write, and never issue a second grant on retry.

**Option B:** no recovery storage; network failure during hydration requires starting new pairing. Less stored PII, more family friction. Remove/replace a committed grant only with an explicit server-side recovery protocol, never by overriding uniqueness.

**Recommendation: A** if recoverability matters for nearby pairing. The original report's 72-hour figure was illustrative, not settled.

### D3. Runtime session, online revocation and offline state

**Option A (proposed):** short-lived opaque server session stored in device-only Keychain; each sensitive online backend request checks the authoritative grant is active, not just an unexpired token. Signatures over fresh server challenges renew session; require online revalidation at app relaunch before representing the connection as live. When offline or check fails, distinguish `cannot verify` from `revoked`, don't claim remote deletion of already downloaded data. **Session lifetime and UI offline access policy remain parameters to approve**; original ~1 hour token and 15-minute sensitive-freshness numbers were suggestions, not fixed contract.

**Option B:** token-only validation until TTL expiry, with delayed online revocation even while network is available; simpler but undermines the stated server-enforced revocation outcome. Not recommended for sensitive endpoints.

**Recommendation: A**, with an explicit product decision on whether already-local non-sensitive offline history may still be viewed when online authorization cannot be verified; no silent claims of current access.

### D4. Existing-workspace ownership enrollment and recovery

**Already-approved Internal Alpha fallback:** verified SIWA sign-in and deliberate human display-name confirmation; trust is limited, not independent cryptographic ownership proof. Do not treat a client-reported CloudKit `recordChangeTag` or `AccountId.pending` as proof. Do not automatically migrate ownership to a new SIWA `sub` on account changes. **Proposal:** restrict existing-workspace enrollment to an explicit Parent-initiated internal-alpha operation; log non-PII audit metadata and make account-change recovery a separate reviewed flow. Live CloudKit token access test may strengthen access evidence but cannot prove SIWA↔CloudKit identity equivalence.

Product Owner must accept the remaining risk and whether recovery/account changes are blocked pending manual intervention in V1.

## Technical contracts for architecture review after decisions

- Per-request P-256 Secure Enclave **signing** key; public key stored by request; display code shown separately only to the requesting device and authenticated Parent list. Code is human device matching, never a credential.
- Server challenge bound to request ID, purpose, nonce and deadline; signature verified against approved request key before atomic claim, with replay rejection. Exact canonical signing bytes, challenge expiration and one-use behavior to be designed/tested, not inferred from old text.
- Claim transaction must lock invitation (`SELECT ... FOR UPDATE OF i` or equivalent), recheck DB-time expiry, approved request/key and consumption, atomically issue one grant with `UNIQUE(grants.invitation_id)`; distinguish verified same-device idempotency from a second device. Run two-request concurrency tests against real isolated PostgreSQL.
- Private authorization tables outside exposed Data API; no direct `anon`/`authenticated` privilege; Edge Functions are policy gate. JWT/JWKS verify audience, issuer, signature, expiry and nonce for SIWA; store privileged credentials server-side only. New workspace binds identity before creation; existing workspace fallback does not become a claimed ownership proof.
- No implementation or hosted Supabase changes in documentation PR #97.

## Closeout sequence

1. Product Owner chooses D1–D4 and exact D2 retention/session/offline parameters or authorizes a narrower V1 fallback.
2. Incorporate settled choices into **living Architecture**, followed by linked ADR and Domain & Data Model/Project Context; explicitly mark provenance and supplant historical CKShare and earlier `recordChangeTag` text. Update backend `CLAUDE.md` to point to one authoritative source after the documentation PR is approved/merged.
3. Only then write one bounded Claude prompt for first real migration/CI integration tests. Backend foundation CI success is not proof of authorization security.
