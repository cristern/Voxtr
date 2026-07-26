import Foundation
import VoxtrCoreContracts

/// Sprint 14: moved from `VoxtrAppShell` into this dedicated
/// `VoxtrCoachingDomain` target — the coaching decision core was
/// already pure (only `Foundation`/`VoxtrCoreContracts`), just filed in
/// the wrong package. Content and behavior are unchanged by the move.
///
/// Sprint 14 (revised): after an architecture review, this engine no
/// longer accepts `WeeklyCoachingContext` — that type was found to be
/// an application-layer aggregation DTO (owned by `VoxtrAppShell`), not
/// a Coaching concept. The engine now accepts `CoachingAnalysisInput`
/// (see that type's own doc comment) — a minimal, coaching-owned shape
/// containing only the facts this engine's rules actually read.
/// `VoxtrAppShell.CoachingAnalysisInputMapper` converts
/// `WeeklyCoachingContext` into it; this file has no knowledge of that
/// mapper, of `WeeklyCoachingContext`, or of `VoxtrAppShell` at all.
///
/// Sprint 7: the first deterministic Coaching Engine. Consumes
/// `CoachingAnalysisInput` only (a pure value type — see that type's
/// own doc comment) and produces a `CoachingResult` (see
/// `CoachingResult.swift`). Pure and side-effect free: a stateless
/// `struct` with one method and no stored properties, not a class,
/// since there is no state to hold and nothing to inject — matching
/// what "deterministic, pure, side-effect free" actually means for a
/// Swift type, not just a description of intent.
///
/// Never touches SwiftData, `ModelContext`, a repository, or any
/// service/coordination service — `CoachingAnalysisInput` already
/// contains everything this engine evaluates. Confirmed by inspection:
/// this file imports only `Foundation` and `VoxtrCoreContracts`.
///
/// RULE SCOPE: every rule here evaluates an objective, directly
/// countable/comparable fact already present in `CoachingAnalysisInput`
/// — completion counts and presence/absence of a reflection or
/// observations. None of this infers motivation, confidence, fatigue,
/// injury risk, readiness, or personality — those require judgment this
/// engine deliberately does not make.
///
/// REVISION — REMOVED, NOT REPLACED: this engine originally also
/// evaluated `highCompletionRate`/`lowCompletionRate` against an 80%/
/// 50% threshold. Those specific numbers were never given anywhere in
/// the approved scope or the project's product documentation — they
/// were this implementation's own invented values, which made them an
/// undocumented (if visibly-commented) product decision. "High"/"low"
/// completion cannot be derived from `CoachingAnalysisInput` without
/// picking *some* arbitrary cutoff, and no cutoff is specified anywhere
/// to derive it from — so rather than inventing a replacement number,
/// both rules are removed.
///
/// As of this revision, every remaining rule below evaluates a fact
/// that is either a direct presence/absence check or a direct count
/// comparison (`> 0`, `== 0`) — no numeric threshold, ratio, or other
/// invented constant appears anywhere in this file.
public struct CoachingEngine: Sendable {
    public init() {}

    /// Evaluates every rule against `input` in the same fixed order
    /// every time (see the sequence below) — this IS the deterministic
    /// ordering `CoachingResult.insights` documents. "Order" here means
    /// literal sequence, not precedence — no rule firing suppresses or
    /// depends on any other; all six are evaluated independently.
    ///
    /// DESIGN NOTE on "no findings"/"empty input": `hasWeeklyReflection`/
    /// `hasParentObservations` are strict binaries — exactly one of
    /// each pair below always fires, by construction, so `insights` is
    /// never a true empty array, even for a fully empty
    /// `CoachingAnalysisInput` (nothing planned, no reflection, no
    /// observations) — that specific case still produces
    /// `[.noWeeklyReflection, .noParentObservations]`. What *is* always
    /// reachable is zero insights from the completion-based rules
    /// specifically — an athlete/week with nothing planned
    /// (`plannedActivityCount == 0`) skips both of those rules. The
    /// test suite covers both of these explicitly, by name.
    public func analyse(_ input: CoachingAnalysisInput) -> CoachingResult {
        var insights: [CoachingInsight] = []

        if input.plannedActivityCount > 0 && input.uncompletedPlannedActivityCount == 0 {
            insights.append(.allPlannedActivitiesCompleted)
        }
        if input.uncompletedPlannedActivityCount > 0 {
            insights.append(.somePlannedActivitiesMissed)
        }

        if input.hasWeeklyReflection {
            insights.append(.weeklyReflectionCompleted)
        } else {
            insights.append(.noWeeklyReflection)
        }

        if input.hasParentObservations {
            insights.append(.parentObservationsPresent)
        } else {
            insights.append(.noParentObservations)
        }

        return CoachingResult(athleteId: input.athleteId, weekStart: input.weekStart, insights: insights)
    }
}
