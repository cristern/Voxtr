# Sprint 2 Release Notes

Sprint 2 goal: Weekly Planning and Commit Week — a parent can create a
draft weekly plan for their athlete, add/edit/delete planned activities
while it's a draft, and commit the week (an irreversible transition,
enforced by the same optimistic-concurrency model already used for
`AthleteProfile`).

## Stories

- **S2.0** — Planning persistence infrastructure. `WeekPlan`/
  `PlannedActivity` (already-defined v1.3 entities) registered in the
  app schema; `PlanningRepository` (insert/fetch, no `#Predicate`, no
  shared test helpers — established project conventions). Found and
  fixed a real SwiftData bug on this Xcode/OS generation along the way:
  `Could not cast value of type '__NSCFNumber' to 'NSString'`, caused by
  storing a custom `Codable` struct (`LocalDate`) directly on a
  `@Model`. Fixed by storing an ISO string internally with a computed
  `LocalDate` property — same public API, confirmed via multiple
  independent Apple Developer Forum reports of the identical crash.
- **S2.1** — `PlanningService.getOrCreateWeekPlan`: one draft per
  athlete/week, no duplicates.
- **S2.2** — Add/edit `PlannedActivity`, deterministic ordering.
  Proactively applied the same `LocalDate` storage fix to
  `PlannedActivity.localDate`, since deterministic ordering is exactly
  the condition that triggers it.
- **S2.3** — `WeekPlan.commit`, mirroring `AthleteProfile.
  applyMutation`'s existing optimistic-concurrency pattern exactly:
  `expectedRevision` must match or a `WeekPlanConflictError` is thrown
  and nothing changes; on success, status/revision update together.
  Editing a `PlannedActivity` is rejected once its `WeekPlan` is
  committed.
- **S2.4** — First functional Weekly Planning UI (`WeeklyPlanningView`/
  `WeeklyPlanningViewModel`) in `VoxtrAppShell`, wired into
  `FamilyHomeView`. Added the one capability that didn't already exist:
  deleting a `PlannedActivity` (draft-only, mirroring edit's guards).
- **S2.5** — Finalization: end-to-end test covering the full lifecycle
  (restore family → draft → add activities → recreate the
  `ModelContainer` → restore → edit while draft → commit → edit
  rejected after commit); completed two controls the view had been
  missing since S2.4 (an activity-type picker in both the add form and
  the edit sheet — the view model already supported this, the view
  never exposed it); full accessibility identifier coverage on every
  planning control; this document.

## Explicitly out of scope for Sprint 2

CloudKit, activity logging, reflections, notifications, calculations,
dashboards, and any AthleteApp-specific workflow.

## Test status

All Sprint 2 tests pass in Codemagic as of this note, including the new
end-to-end lifecycle test and the `WeeklyPlanningViewModel` suite
covering committed-state behavior — including one test that
deliberately documents current, intentional behavior: adding an
activity after commit is **not** restricted (only edit and delete are),
since that's what the approved scope actually asked for.

## CI status

- `package-tests` — passing.
- `pr-validation` — to be confirmed for this story before merging to
  `main`.

## Deferred: renaming `VoxtrSprint0Tests`

Still deferred, for the same reason given in the Sprint 1 release
notes: touching the native test target name means touching
`Package.swift`, every file's build-phase membership in
`project.pbxproj`, and the `VoxtrTests` scheme simultaneously, for a
purely cosmetic gain. Not attempted this sprint either.
