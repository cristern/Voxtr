import Foundation
import VoxtrCoreContracts

/// Sprint 14 (revised): `CoachingEngine`'s own input contract —
/// introduced after an architecture review determined that
/// `WeeklyCoachingContext` is an application-layer aggregation DTO
/// (every one of its fields originates in Planning, Training, or
/// Reflection; `Coaching` merely consumes them), not a type Coaching
/// itself owns. `CoachingAnalysisInput` is what Coaching actually
/// owns: the minimal, coaching-neutral shape its own rules require.
///
/// Deliberately NOT a field-for-field mirror of `WeeklyCoachingContext`
/// — that would just relocate the same "reproduce everything a
/// producer might have" habit this review exists to correct. Every
/// field here was chosen by reading `CoachingEngine.analyse(_:)`
/// itself:
/// - `plannedActivityCount`/`uncompletedPlannedActivityCount`: read
///   directly, by value, in the completion-related rules.
/// - `hasWeeklyReflection`/`hasParentObservations`: the engine only
///   ever checks presence/absence (`== nil`, `.isEmpty`) — never reads
///   into a reflection's or observation's own content — so this type
///   carries that fact as a plain `Bool`, not the richer
///   `WeeklyReflectionSummary`/`[ParentObservationSummary]` shapes
///   `WeeklyCoachingContext` has. Those richer shapes are Reflection
///   domain vocabulary (`overallSatisfaction`, `loadFelt`, `whatWorked`
///   ...) that Coaching's rules never touch — carrying them here would
///   be exposing Reflection-domain detail through a type that's
///   supposed to be coaching-neutral.
/// - `athleteId`/`weekStart`: carried through unchanged into
///   `CoachingResult`, for traceability — not evaluated by any rule,
///   but genuinely required output, not incidental.
///
/// Not included, because no rule reads them: `previousWeekStart`,
/// `weekPlanStatus` (`CoachingEngine`'s own doc comment already flags
/// this one as deliberately unused), `completedPlannedActivityCount`
/// (redundant with the two fields that are actually compared),
/// `unplannedLoggedActivityCount`, `totalLoggedActivityCount`.
///
/// No dependency on `VoxtrAppShell`, SwiftUI, SwiftData, or any
/// feature-domain package — confirmed by this file's own imports.
/// `Equatable` (matching `CoachingResult`'s own conformance) so tests
/// can compare instances directly; `Sendable` for the same reason
/// `WeeklyCoachingContext` needs it — this is the type that actually
/// crosses `CoachingEngine`'s boundary now.
public struct CoachingAnalysisInput: Sendable, Equatable {
    public let athleteId: AthleteId
    public let weekStart: LocalDate
    public let plannedActivityCount: Int
    public let uncompletedPlannedActivityCount: Int
    public let hasWeeklyReflection: Bool
    public let hasParentObservations: Bool

    public init(
        athleteId: AthleteId,
        weekStart: LocalDate,
        plannedActivityCount: Int,
        uncompletedPlannedActivityCount: Int,
        hasWeeklyReflection: Bool,
        hasParentObservations: Bool
    ) {
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.plannedActivityCount = plannedActivityCount
        self.uncompletedPlannedActivityCount = uncompletedPlannedActivityCount
        self.hasWeeklyReflection = hasWeeklyReflection
        self.hasParentObservations = hasParentObservations
    }
}
