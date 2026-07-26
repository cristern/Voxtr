import Foundation
import VoxtrCoreContracts

/// Sprint 11: the minimal protocol for `CoachingApplicationService`'s
/// one operation. Same pattern as `WeeklyReviewProviding`/
/// `WeeklyCoachingContextProviding`/`ParentObservationProviding`: lets
/// `WeeklyReviewViewModel`'s tests substitute a deterministic double
/// for "does the ViewModel delegate correctly," without needing a real
/// `CoachingApplicationService` (and everything it in turn depends on)
/// just to test delegation. `CoachingApplicationService` is the only
/// production conformer.
@MainActor
public protocol CoachingPresentationProviding {
    func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation
}

extension CoachingApplicationService: CoachingPresentationProviding {}

/// Sprint 11: the single, reusable orchestrator of the coaching
/// pipeline. Before this sprint, `WeeklyReviewViewModel` itself called
/// `WeeklyCoachingContextService` → `CoachingEngine` →
/// `CoachingPresentationMapper` directly — that three-step call
/// sequence is extracted here unchanged, so any future consumer (Home
/// Dashboard, Morning Experience, Widgets, an eventual AI layer) can
/// request a `CoachingPresentation` without re-deriving this sequence
/// itself. There is exactly one place in the codebase that performs
/// this orchestration.
///
/// SCOPE, DELIBERATELY MINIMAL: obtains `WeeklyCoachingContext`,
/// invokes `CoachingEngine`, invokes `CoachingPresentationMapper`,
/// returns `CoachingPresentation`. Nothing else — no caching (a second
/// call always re-runs the full pipeline; there is no stored state to
/// go stale), no persistence, no retry, no analytics, no business
/// rule. `CoachingEngine` and `CoachingPresentationMapper` are
/// constructed fresh per call, exactly as `WeeklyReviewViewModel`
/// already did before this extraction — both are stateless value
/// types with a no-argument initializer, so there is nothing to gain
/// from injecting or storing them, and doing so would be exactly the
/// kind of abstraction "not yet justified by the current codebase"
/// this sprint asks to avoid.
///
/// `Do NOT modify CoachingEngine/CoachingResult/CoachingPresentation/
/// CoachingPresentationMapper/WeeklyCoachingContext` — none of them
/// are touched by this file; it only calls their existing public API
/// in the same order they were already called in.
///
/// DEPENDENCY DIRECTION: `WeeklyReviewViewModel` → this service →
/// `WeeklyCoachingContextProviding` → `CoachingEngine` →
/// `CoachingPresentationMapper`. This type never imports or references
/// `WeeklyReviewViewModel`, SwiftUI, or any UI-layer type — the
/// dependency only flows one way.
@MainActor
public final class CoachingApplicationService {
    private let coachingContextService: any WeeklyCoachingContextProviding

    public init(coachingContextService: any WeeklyCoachingContextProviding) {
        self.coachingContextService = coachingContextService
    }

    /// Runs the complete deterministic pipeline for one athlete/week
    /// and returns the result. Throws only if `coachingContextService`
    /// genuinely throws — `CoachingEngine`/`CoachingPresentationMapper`
    /// are both pure functions that never throw.
    public func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
        let context = try coachingContextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: weekStart)
        let result = CoachingEngine().analyse(context)
        return CoachingPresentationMapper().map(result)
    }
}
