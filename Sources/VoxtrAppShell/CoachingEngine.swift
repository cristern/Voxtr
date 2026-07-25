import Foundation
import VoxtrCoreContracts

/// Sprint 7: the first deterministic Coaching Engine. Consumes
/// `WeeklyCoachingContext` only (a pure value type — see that type's
/// own doc comment) and produces a `CoachingResult` (see
/// `CoachingResult.swift`). Pure and side-effect free: a stateless
/// `struct` with one method and no stored properties, not a class,
/// since there is no state to hold and nothing to inject — matching
/// what "deterministic, pure, side-effect free" actually means for a
/// Swift type, not just a description of intent.
///
/// Never touches SwiftData, `ModelContext`, a repository, or any
/// service/coordination service — `WeeklyCoachingContext` already
/// contains everything this engine evaluates. Confirmed by inspection:
/// this file imports only `Foundation` and `VoxtrCoreContracts`.
///
/// RULE SCOPE: every rule here evaluates an objective, directly
/// countable/comparable fact already present in `WeeklyCoachingContext`
/// — completion counts and presence/absence of a reflection or
/// observations. None of this infers motivation, confidence, fatigue,
/// injury risk, readiness, or personality — those require judgment this
/// engine deliberately does not make. `weekPlanStatus` is available on
/// the context but deliberately unused by any rule this sprint —
/// nothing in the approved scope asked for a draft/committed-based
/// rule, and adding one would be exactly the kind of unrequested,
/// speculative rule this sprint should not introduce.
///
/// REVISION — REMOVED, NOT REPLACED: this engine originally also
/// evaluated `highCompletionRate`/`lowCompletionRate` against an 80%/
/// 50% threshold. Those specific numbers were never given anywhere in
/// the approved scope or the project's product documentation — they
/// were this implementation's own invented values, which made them an
/// undocumented (if visibly-commented) product decision. "High"/"low"
/// completion cannot be derived from `WeeklyCoachingContext` without
/// picking *some* arbitrary cutoff, and no cutoff is specified anywhere
/// to derive it from — so rather than inventing a replacement number,
/// both rules are removed. `plannedActivityCount`/
/// `completedPlannedActivityCount`/`uncompletedPlannedActivityCount`
/// remain on `WeeklyCoachingContext`, available to a future rule once
/// an actual product decision defines what "high"/"low" means.
///
/// As of this revision, every remaining rule below evaluates a fact
/// that is either a direct presence/absence check or a direct count
/// comparison (`> 0`, `== 0`) — no numeric threshold, ratio, or other
/// invented constant appears anywhere in this file.
public struct CoachingEngine: Sendable {
    public init() {}

    /// Evaluates every rule against `context` in the same fixed order
    /// every time (see the sequence below) — this IS the deterministic
    /// ordering `CoachingResult.insights` documents. "Order" here means
    /// literal sequence, not precedence — no rule firing suppresses or
    /// depends on any other; all six are evaluated independently.
    ///
    /// DESIGN NOTE on "no findings"/"empty context": `weeklyReflection`/
    /// `parentObservations` are strict binaries (present or absent) —
    /// exactly one of each pair below always fires, by construction, so
    /// `insights` is never a true empty array, even for a fully empty
    /// `WeeklyCoachingContext` (nothing planned, no reflection, no
    /// observations) — that specific case still produces
    /// `[.noWeeklyReflection, .noParentObservations]`. What *is* always
    /// reachable is zero insights from the completion-based rules
    /// specifically — an athlete/week with nothing planned
    /// (`plannedActivityCount == 0`) skips both of those rules. The
    /// test suite covers both of these explicitly, by name.
    public func analyse(_ context: WeeklyCoachingContext) -> CoachingResult {
        var insights: [CoachingInsight] = []

        if context.plannedActivityCount > 0 && context.uncompletedPlannedActivityCount == 0 {
            insights.append(.allPlannedActivitiesCompleted)
        }
        if context.uncompletedPlannedActivityCount > 0 {
            insights.append(.somePlannedActivitiesMissed)
        }

        if context.weeklyReflection == nil {
            insights.append(.noWeeklyReflection)
        } else {
            insights.append(.weeklyReflectionCompleted)
        }

        if context.parentObservations.isEmpty {
            insights.append(.noParentObservations)
        } else {
            insights.append(.parentObservationsPresent)
        }

        return CoachingResult(athleteId: context.athleteId, weekStart: context.weekStart, insights: insights)
    }
}
