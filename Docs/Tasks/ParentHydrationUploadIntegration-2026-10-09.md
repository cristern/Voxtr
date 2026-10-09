# Parent hydration upload — bounded implementation task

Authorized by Product Owner on 2026-10-09 ("fint, sett igang"), following explicit merge of PR #118. This is the first missing iOS prerequisite in the transition plan §5.1, before athlete activation/UI §5.2. The initial PR contains only this task brief; implementation has not been delivered.

Base: develop at a599a6c97a9a73d1b95b6535d9d5a4b5b2de97ee.
Branch: claude/parent-hydration-upload-integration.
Coordination: issue #107. Use this same branch and PR for implementation and review fixes.

## Required reading and authority

Read CLAUDE.md and its authority hierarchy, the normative security and Parent authentication contracts, the accepted runtime authentication/hydration contract §§2.4, 4.2–4.6, and the merged CloudKit transition plan §§5.1–5.3. Inspect current iOS and backend declarations directly at exact SHAs. Backend develop baseline from PR118 audit: 7b10e6ba1a0f51c5cf9034bce2ca8dd73a6c4f18; fetch current SHA and report any contract difference.

The backend hydration-upload endpoint already exists in source. Hosted deployment, provider retention and real-family-data readiness are not established by this task. Keep issue #98 open; issue #113 remains later hosted/two-iPhone evidence. Do not contact a hosted service with real family data as part of implementation verification.

## Goal and complete scope

Extend the existing opt-in Parent backend pairing journey so an explicitly approved connection request can upload the selected athlete's exact 11 bootstrap fields via the existing Parent-authenticated hydration-upload endpoint. Make upload status, retry and reauthentication usable from that journey. Approval and successful upload are distinct states: an approved request with failed upload must not be shown as ready for athlete hydration.

Use existing ParentAuthenticationService/transport/session handling and composition patterns. Inspect AthleteDeviceAuthorizationInvitationCoordinator, InvitationService/View, AthleteConnectionOwnerHandoffService, repositories, and CompositionRoot. Put orchestration/projection in canonical service ownership, not duplicated UI persistence logic.

1. Resolve projection by exact workspace, selected athlete, intended participant, Parent profile and owner participant IDs. Validate workspace/role/link consistency and reject missing, duplicate or conflicting identities. The legacy handoff service contains first-match owner/Parent lookups: do not blindly copy those where workspace-scoped identity is required. No display-name, order, birth-date or sibling fallback.
2. Send connection_request_id plus exactly the canonical 11 snake_case fields in hydration-upload/index.ts. Never send Parent identity as authentication, unrelated family/training/reflection data, optional familyName/preferredName, or secrets in logs.
3. Invoke upload only after actual approval success for the exact request. Never on reject or failed approval. Support approval/claim races using actual backend outcomes and the existing staging/association contract. Do not wait for a Parent-visible "claim completed" signal the source does not supply.
4. Preserve an immutable pending projection/request context for retry. Do not recompute changed profile data into a different retry payload silently. Respect backend staged identical-payload idempotency, payload mismatch rejection, associated/tombstoned immutability and authoritative deadlines. A lost upload response must not be interpreted as proof of either success or failure; expose a bounded honest recovery path according to the actual backend outcome contract. No fabricated success for immutable/terminal responses.
5. Authentication failure must use the existing explicit SIWA reauthentication flow, then retry upload for the same approved request without creating a new invitation or repeating approval unnecessarily. Session refresh alone cannot satisfy sensitive-action freshness.
6. Preserve cancellation/generation and single-flight guards across every await, stop/restart, sign-out/reauthentication and selection change. Late responses from an old workspace/request must never publish readiness for a new one.
7. Surface distinct approved/uploading/uploaded and actionable failure/retry states, using calm truthful copy. This does not activate athlete membership or claim the athlete app is connected. Keep existing legacy CloudKit flow and the current backend pairing entry/default choice intact.
8. Update project status and explain the remaining athlete activation/UI prerequisite honestly.

## Out of scope

Athlete runtime restoration/activation/UI implementation, backend changes, hosted deployment, CloudKit cleanup or removal, data migration/wipe, local membership revocation, flipping pairing defaults, and acceptance of any of PR118's seven product proposals. No merge or TestFlight release. No training/reflection/Today UI additions. Do not close #98/#113.

## Verification and delivery

Meaningful tests: all 11 fields and wire headers; workspace/athlete isolation and conflicting identities; reject/failed approval sends zero uploads; successful approval sends exact context; session invalid/expired/freshness recovery; lost response and immutable/conflict handling against actual backend semantics; cancellation/late responses at approval/upload/reauthentication boundaries. Use actual transport fixtures, not only success mocks or tests mirroring implementation.

Preserve baseline 969 native tests (968 main + 1 hosted Keychain), test identities/count gates, both app builds and Release signing evidence. Add required new tests to native wiring. The 36 pre-existing omitted native tests remain separate scope. Do not relax CI to get green.

Reopen final changed Swift/test files and audit actual types, Sendable/MainActor boundaries and native test registration. Deliver exact HEAD, changed files, findings-to-tests map and limitations. After Codemagic completion post a new exact-SHA CI/delivery comment with full logs/artifacts and counts; a green check alone is insufficient and is not a supported automation wake-up.

Fetch current PR comments/reviews and actual HEAD at start, after delivery, after CI completion, and before stopping. Resolve reviews by comment ID and reviewed SHA. Verify your own comment/review/commit subscription for this exact new PR if supported; report supported scope and idle-session limitation. Do not inherit an assumed subscription from #118. Posting a GitHub comment does not guarantee an idle agent starts. Stop for independent review and explicit PO merge approval.
