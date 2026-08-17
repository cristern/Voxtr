# Vǫxtr Claude Code Engineering Contract

## 1. Authority hierarchy
When sources conflict, follow this order:
1. Product Constitution
2. Architecture
3. ADR / Architectural Decisions
4. Domain & Data Model
5. Living PRD
6. Design System
7. AI Development Guide
8. Project Context
9. Solution Inventory
10. Product Backlog
11. Existing implementation

Do not silently resolve contradictions. Report material conflicts.

## 2. Core product and architecture invariants
- Preserve One Truth.
- Planning proposes; Training proves; Reflection learns/explains.
- Human judgement before AI.
- Long-term development over short-term performance.
- Reflection before statistics.
- Cross-domain relationships use stable IDs, never title/date matching.
- Canonical Vǫxtr weeks are Monday–Sunday using existing LocalDate semantics.
- Do not introduce locale-dependent week identity.
- Preserve athlete/family isolation and privacy boundaries.
- Do not introduce sibling comparison, arbitrary scoring, streaks, XP, manipulative engagement, or synthetic readiness scores unless explicitly approved.

## 3. Domain ownership
Respect existing domain/module ownership.
Do not duplicate orchestration, persistence logic, derivation logic, or source-of-truth models in UI/ViewModels or sibling domains.
Reuse canonical services/read models where they already exist.

## 4. Git and branch safety
- Never work directly on `develop` or `main`.
- Each task uses a dedicated `claude/...` branch.
- One task branch should normally correspond to one PR.
- Do not merge to `develop`.
- Push only the task branch.
- Stop after push and wait for review/approval.
- A branch is considered finished after its PR is merged; use a new branch for subsequent fixes.
- One Claude Code task branch should normally correspond to one PR.
- Once that PR has been merged, that task branch is considered finished.
- Any subsequent fix discovered after merge/Codemagic/TestFlight should normally use a new task branch from the latest develop rather than reusing the merged branch.

### Branch lifecycle
- Every implementation task starts from latest develop on a fresh task branch.
- After explicit review approval and successful merge into develop, the completed task branch should be deleted from the remote repository and locally where applicable.
- `main` and `develop` are permanent branches and must never be deleted.
- Never delete a branch unless all intended commits are already reachable from develop.
- A post-merge fix always uses a new branch from latest develop; never resurrect a completed branch.

## 5. Scope discipline
- Make the smallest complete change that satisfies the approved task.
- Do not make unrelated cleanup or speculative refactors.
- Do not silently change product behavior.
- Clearly distinguish required fixes from optional proposals.
- Preserve previously accepted behavior unless the task explicitly changes it.

## 6. Required implementation workflow
For every task:
1. Inspect the actual repository and relevant implementation before editing.
2. Confirm the root cause or current architecture.
3. Identify affected production and test surfaces.
4. Implement the smallest correct change.
5. Perform a bounded same-pattern audit.
6. Run relevant available checks.
7. Review the final diff.
8. Commit on the task branch.
9. Push only the task branch.
10. Report and stop for review.

## 7. Compile-oriented audit
Before delivery, explicitly check relevant:
- imports
- module dependencies
- initializers and construction sites
- protocol conformances
- property/type changes
- actor isolation / `@MainActor`
- async/await boundaries
- SwiftUI `@ViewBuilder` correctness
- duplicate/conflicting Swift attributes
- tests affected by signature or dependency changes

Do not rely only on local static reasoning when Codemagic is the authoritative compiler/test gate.

### Mandatory final-diff Swift/test compile audit
Before reporting a task ready for review:
- reopen every changed Swift/test file after final edits;
- resolve real declaration types rather than infer them;
- check typed `Identifier<T>` vs `UUID`/`rawValue`, optionality, `Int` types, `LocalDate` vs `Date`, enums, initializer labels/order, closures, async/throws, actor isolation, protocols, access levels, imports, SwiftUI `@ViewBuilder`/state/bindings;
- for every modified test comparison/assertion, resolve the static type of both sides and verify the operator is valid;
- search an existing compiling test for unfamiliar patterns;
- perform this against the FINAL diff;
- do not report "ready for review" while known compile uncertainty remains.

### Repo-wide enum consumer audit
Whenever an enum case is added, removed, renamed, or changes meaning:
- inspect the final enum declaration and list all cases;
- search the ENTIRE repository for consumers of that enum, not only files in the task diff;
- inspect every exhaustive switch and verify it against the final declaration;
- do not add `default` merely to silence compiler exhaustiveness;
- inspect non-switch consumers where changed case semantics can affect behavior;
- this audit is mandatory even when the affected consumer file was untouched by the task.

## 8. Testing rules
Prefer extending an existing relevant test over creating a new test file.

Add tests for concrete product/domain invariants and confirmed regressions, especially:
- athlete/family isolation
- identity preservation
- persistence
- recurring materialization/deduplication
- duplicate logging protection
- privacy
- historical week identity
- critical state transitions

Avoid brittle presentation-only tests.

Time-dependent tests must be deterministic:
- inject reference dates / LocalDate where available
- do not depend on `Date.now`, current weekday, locale, or CI run time when exact results are asserted

When a test and current approved product contract conflict, investigate before changing production code.

## 9. Pattern-impact audit
When fixing a defect, check nearby/sibling surfaces for the same root cause.

Fix another occurrence only when:
- it has the same root cause,
- the intended contract is the same,
- the fix is low risk,
- and it remains within task scope.

Otherwise report it as follow-up work.

## 10. UX and product boundaries
Preserve Vǫxtr's existing UX principles:
- Calm by Default
- clear role boundaries
- no invented fallback content presented as truth
- no false NOW/current-state claims when data is insufficient
- no hidden materialization from read-only display
- historical content must preserve correct athlete/week identity
- private athlete content must never be exposed to Parent actors

Do not redesign product philosophy or information architecture unless explicitly tasked.

## 11. Persistence and identity
- Persist canonical entities through existing repositories/services.
- Preserve typed/stable IDs throughout navigation and domain relationships.
- Do not infer entity relationships from title, date, display text, or list position.
- Read-only composition must not create/mutate canonical records unless explicitly part of the approved contract.

## 12. Delivery report
At the end of each implementation task report:
- active branch
- root cause / implementation rationale
- files changed
- production behavior changed
- tests added/changed
- checks performed and results
- bounded same-pattern audit result
- commit hash
- push result
- known risks or follow-ups
- whether the branch is ready for review

## 13. Merge gate
Claude Code must never treat its own implementation as approval to merge.
Claude Code must never merge on its own initiative.

After explicit approval from the user/product/architecture reviewer, Claude Code may merge the approved task branch into `develop`.

Before merging, Claude must verify:
- the approved branch is unchanged since review
- the intended PR/diff matches what was approved
- no new commits or unrelated changes have appeared

Claude Code must never merge to `main` unless explicitly instructed.

The required lifecycle is:
Claude Code task branch
→ push
→ human/product/architecture review
→ explicit approval
→ PR merge to `develop`
→ Codemagic
→ TestFlight/runtime verification where relevant

## 14. Default decision rule
When uncertain:
- preserve existing accepted behavior,
- prefer maintainability over shortcuts,
- prefer canonical services/models over duplication,
- prefer deterministic behavior,
- prefer explicit identity over inference,
- and report ambiguity instead of inventing a product decision.
