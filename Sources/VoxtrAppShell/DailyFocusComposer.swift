import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
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
/// repository, or any service — `compose`'s own `resolveSport` closure
/// parameter (Sport / Activity Identity domain foundation, Blocker B
/// fix) is the caller's already-resolved lookup, never a repository
/// this type reaches for itself; `VoxtrCoreReferenceData` is imported
/// only for the `Sport` type that closure's signature names.
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
    /// Sport / Activity Identity domain foundation, Blocker B fix
    /// (review correction): `resolveSport` is a plain parameter, not
    /// stored state — this type stays exactly as stateless/pure as its
    /// own doc comment above describes, it just now takes the one extra
    /// input it needs to resolve a Sport-only activity's honest label
    /// instead of the rejected `?? ""` fallback. Defaulted to
    /// `{ _ in nil }` so every pre-existing call site keeps compiling.
    public func compose(
        todaysActivities: [PlannedActivityCompletion]?,
        coaching: CoachingPresentation?,
        resolveSport: (SportId) -> Sport? = { _ in nil }
    ) -> DailyFocusPresentation? {
        if let incomplete = todaysActivities?.first(where: { !$0.isCompleted }) {
            return DailyFocusPresentation(
                title: ActivityLabelResolver.primaryLabel(
                    name: incomplete.plannedActivity.title,
                    sportId: incomplete.plannedActivity.sportId.map(SportId.init(rawValue:)),
                    resolveSport: resolveSport
                ),
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
