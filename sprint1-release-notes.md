# Sprint 1 Release Notes

Sprint 1 goal: a parent can create a family (parent profile, workspace,
first athlete, access grant), have it persist locally, and have it
correctly restored on relaunch — atomically, with no partial state ever
left behind on failure, and no crash on invalid input.

## Stories

- **S1.0** — Persistence infrastructure, `ModelContainer` composition.
- **S1.1** — `ParentWorkspaceRepository` (`ParentProfile`, `FamilyWorkspace`, `WorkspaceParticipant`).
- **S1.2 / S1.2a** — `AthleteRepository`, `AthleteAccessGrantRepository`, `FamilyOnboardingCoordinator`. S1.2's coordinator was rejected for not being atomic across all five entities; S1.2a corrected this — stage-then-single-save-then-rollback-on-any-failure, with autosave disabled for the duration.
- **S1.3** — `FamilyRestorationService` / `FamilyRestorationState` (`.noExistingFamily` / `.existingFamily` / `.inconsistentGraph`).
- **S1.4** — Parent onboarding UI (`CreateFamilyView`, `CreateFamilyViewModel`, `RootView`, `FamilyHomeView`), validation mirroring existing domain preconditions.
- **S1.5** — Finalization: reviewed the onboarding flow end to end, added an end-to-end persistence test, duplicate-submission and coordinator-failure-surfacing tests, accessibility identifiers/labels, centralized the onboarding flow's dynamic user-facing strings for future localization, and this document.
- **CI-01** — Restructured CI so `package-tests` runs only on push to `develop`, `pr-validation` runs tests→AthleteApp→ParentApp only for PRs targeting `main` (stopping immediately on any failure), and the two simulator-build workflows became manual-only — avoiding a simulator build running while tests are failing.

## Explicitly out of scope for Sprint 1

CloudKit, Weekly Review, notifications, dashboards, calculations, recommendations, and any AthleteApp-specific workflow (AthleteApp remains a placeholder).

## Test status

All Sprint 1 unit and end-to-end tests pass in Codemagic as of this note, including:

- Atomicity: creation, and rollback (leaving zero new entities) on a failure injected at each stage of the coordinated transaction, via an internal test-only seam — not by relying on any particular SwiftData failure mode, after two earlier attempts (a uniqueness-constraint collision, and pointing a store at `/dev/null`) both turned out not to reliably produce a catchable failure at the right point.
- Restoration: empty store, a fully consistent family, and multiple shapes of an inconsistent graph — including across a genuinely recreated `ModelContainer` pointed at the same on-disk store, not just a reused container instance.
- Onboarding UI: field-level validation, duplicate/reentrant submission prevention, and a coordinator failure surfacing as a single submission-level error rather than a crash.

## CI status

- `package-tests` — automatic on push to `develop`; passing.
- `pr-validation` — automatic on PRs targeting `main`; passing.
- `athlete-simulator-build` / `parent-simulator-build` — manual-only; last run green.
- `testflight-release` — untouched in Sprint 1, triggers only on `release/*` tags.

## Deferred: renaming `VoxtrSprint0Tests`

The native Xcode test target and the `Tests/VoxtrSprint0Tests/` folder are
still named after Sprint 0, when the target was created. Renaming them
was considered in S1.5 and deliberately deferred rather than attempted:

- The name is used as the SPM test target name in `Package.swift`, as
  the native Xcode target name and product name in `project.pbxproj`
  (which every test file's build-phase membership references), and in
  the `VoxtrTests` scheme's XML. A rename touches all of these
  simultaneously.
- CI only recently became reliably green after several rounds of
  genuine crash/compile debugging in exactly this project structure.
  A cosmetic rename carries real risk of reintroducing exactly that
  class of problem for no functional benefit.
- Nothing in Sprint 1's scope depends on the name — it's purely
  cosmetic housekeeping.

Recommendation: do this as its own isolated, dedicated change — ideally
right after a sprint boundary where CI is confirmed green and no other
change is in flight — not bundled into a feature story.
