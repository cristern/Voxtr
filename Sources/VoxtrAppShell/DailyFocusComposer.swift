import Foundation
import VoxtrTrainingDomain

/// Sprint 13 (architecture correction): composes `DailyFocusPresentation`
/// from already-loaded outputs only. Replaces the original
/// `DailyFocusViewModel`, which duplicated `HomeDashboardViewModel`'s
/// own service calls — `HomeDashboardViewModel` is now the single
/// owner of loading today's training and the coaching presentation;
/// this type only selects among what it's given.
///
/// A pure, stateless `struct` with a no-argument initializer — same
/// shape as `CoachingEngine`/`CoachingPresentationMapper`, for the same
/// reason: there is no state to hold and nothing to inject, so there is
/// no class and no actor isolation here. Never touches SwiftData, a
/// repository, or any service — confirmed by inspection: this file
/// imports only `Foundation` and `VoxtrTrainingDomain` (needed only for
/// the `PlannedActivityCompletion` parameter type).
public struct DailyFocusComposer: Sendable {
    public init() {}

    /// The fixed priority order this feature specifies, applied to
    /// already-computed facts only — nothing here recomputes
    /// `isCompleted` (already derived by
    /// `TrainingPlanningCoordinationService`) or re-derives which
    /// `CoachingPresentationAction` an insight gets (already assigned
    /// by `CoachingPresentationMapper`).
    ///
    /// 1. Any incomplete planned activity today.
    /// 2. A coaching item whose `action` is not `.none`, found by
    ///    walking `coaching.sections` in `CoachingPresentation`'s own
    ///    existing fixed order — which actionable item wins (if more
    ///    than one exists) is deterministic without this function
    ///    inventing a new ranking.
    /// 3. Otherwise `nil` — nothing requiring attention.
    ///
    /// Passing `nil` for either parameter represents "this source
    /// failed to load" (distinguished from "loaded but empty," which is
    /// `[]`/a `CoachingPresentation` with empty `sections`) — the
    /// caller (`HomeDashboardViewModel`) decides what `nil` means; this
    /// function only treats a `nil` source as having nothing to
    /// contribute to composition, never as a reason to fail itself.
    @MainActor
    public func compose(
        todaysActivities: [PlannedActivityCompletion]?,
        coaching: CoachingPresentation?
    ) -> DailyFocusPresentation? {
        if let incomplete = todaysActivities?.first(where: { !$0.isCompleted }) {
            return DailyFocusPresentation(
                title: ActivityLabelResolver().primaryLabel(for: incomplete.plannedActivity),
                subtitle: TrainingStrings.notCompletedLabel,
                action: .none,
                source: .todaysTraining
            )
        }

        if let coaching {
            for section in coaching.sections {
                if let actionable = section.items.first(where: { $0.action != .none }) {
                    return DailyFocusPresentation(
                        title: actionable.text,
                        subtitle: section.title,
                        action: actionable.action,
                        source: .coaching
                    )
                }
            }
        }

        return nil
    }
}
