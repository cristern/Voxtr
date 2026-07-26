import Foundation
import VoxtrCoreContracts

/// Sprint 14: moved from `VoxtrAppShell` into `VoxtrCoachingDomain` —
/// content and behavior unchanged by the move.
///
/// Sprint 7: one structured, objective coaching finding. A plain
/// `String`-backed enum, not free text — per the coaching architecture,
/// `CoachingResult` must never contain UI text, localisation, markdown,
/// or motivational language. Each case names a fact `CoachingEngine`
/// evaluated directly from `WeeklyCoachingContext`; turning a case into
/// user-facing copy is the Presentation Layer's job, not this type's.
///
/// REVISION: this originally also had `highCompletionRate`/
/// `lowCompletionRate` cases, gated by an 80%/50% threshold invented
/// for this implementation and never specified anywhere. Removed
/// entirely, not replaced with different numbers — "high"/"low"
/// completion cannot be derived from `WeeklyCoachingContext` without
/// picking an arbitrary cutoff, which is exactly the kind of
/// undocumented product decision this engine must not make on its own.
/// `plannedActivityCount`/`completedPlannedActivityCount`/
/// `uncompletedPlannedActivityCount` remain available on
/// `WeeklyCoachingContext` for whatever actually-specified threshold a
/// future product decision defines.
public enum CoachingInsight: String, Equatable, Sendable, CaseIterable {
    case allPlannedActivitiesCompleted
    case somePlannedActivitiesMissed
    case noWeeklyReflection
    case weeklyReflectionCompleted
    case noParentObservations
    case parentObservationsPresent
}

/// Sprint 7: the structured output of one coaching analysis, for one
/// athlete/week. Contains only `CoachingInsight` values (plus the
/// athlete/week the analysis is about, for traceability once separated
/// from the `WeeklyCoachingContext` it came from) — no interpretation,
/// no text.
///
/// Kept in its own file, separate from `CoachingEngine` — the same
/// reason `WeeklyCoachingContext` (Sprint 6) is its own file, separate
/// from `WeeklyCoachingContextService`: this type is meant to be
/// consumed independently by both a future UI layer and a future AI
/// layer, not treated as an implementation detail of one specific
/// engine.
public struct CoachingResult: Equatable, Sendable {
    public let athleteId: AthleteId
    public let weekStart: LocalDate
    /// Ordered deterministically by evaluation order (the same fixed
    /// rule sequence every time — see `CoachingEngine.analyse`), not by
    /// any notion of importance or severity, since ranking findings
    /// would itself be a form of interpretation this engine doesn't do.
    public let insights: [CoachingInsight]

    public init(athleteId: AthleteId, weekStart: LocalDate, insights: [CoachingInsight]) {
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.insights = insights
    }
}
