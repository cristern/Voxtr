import Foundation
import VoxtrCoreContracts
import VoxtrCoachingDomain

/// Sprint 14 (revised): the explicit boundary component between
/// `VoxtrAppShell.WeeklyCoachingContext` (the cross-domain aggregation
/// DTO) and `VoxtrCoachingDomain.CoachingAnalysisInput` (what
/// `CoachingEngine` actually owns and consumes).
///
/// Pure structural translation only — no coaching decision logic here.
/// Deciding what `.allPlannedActivitiesCompleted` or `.noWeeklyReflection`
/// mean is `CoachingEngine`'s job; this type only reshapes data, the
/// same category of work `CoachingPresentationMapper` does at the
/// opposite end of the pipeline (structured result → presentation),
/// not business logic.
///
/// Stateless — a `struct` with a no-argument initializer, matching
/// every other pure pipeline stage in this codebase
/// (`CoachingEngine`/`CoachingPresentationMapper`). Never accesses a
/// repository or `ModelContext` — confirmed by inspection: this file's
/// only imports are `Foundation`, `VoxtrCoreContracts`, and
/// `VoxtrCoachingDomain` (needed for `CoachingAnalysisInput`'s type
/// itself — this is the permitted direction, `VoxtrAppShell` →
/// `VoxtrCoachingDomain`).
public struct CoachingAnalysisInputMapper: Sendable {
    public init() {}

    /// Reduces `context` to only the facts `CoachingEngine`'s rules
    /// actually read. `weeklyReflection`/`parentObservations` collapse
    /// to plain presence/absence `Bool`s here — see
    /// `CoachingAnalysisInput`'s own doc comment for why carrying their
    /// full Reflection-domain-shaped content forward would be exposing
    /// detail Coaching's rules never touch. Every other
    /// `WeeklyCoachingContext` field (`previousWeekStart`,
    /// `weekPlanStatus`, `completedPlannedActivityCount`,
    /// `unplannedLoggedActivityCount`, `totalLoggedActivityCount`) is
    /// intentionally dropped — not carried, not renamed, not
    /// approximated — because no engine rule reads it.
    public func map(_ context: WeeklyCoachingContext) -> CoachingAnalysisInput {
        CoachingAnalysisInput(
            athleteId: context.athleteId,
            weekStart: context.weekStart,
            plannedActivityCount: context.plannedActivityCount,
            uncompletedPlannedActivityCount: context.uncompletedPlannedActivityCount,
            hasWeeklyReflection: context.weeklyReflection != nil,
            hasParentObservations: !context.parentObservations.isEmpty
        )
    }
}
