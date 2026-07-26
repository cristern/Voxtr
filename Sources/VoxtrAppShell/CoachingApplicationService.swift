import Foundation
import VoxtrCoreContracts
import VoxtrCoachingDomain

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
/// `CoachingPresentationMapper` directly — that call sequence is
/// extracted here unchanged in spirit, so any future consumer (Home
/// Dashboard, Morning Experience, Widgets, an eventual AI layer) can
/// request a `CoachingPresentation` without re-deriving this sequence
/// itself. There is exactly one place in the codebase that performs
/// this orchestration.
///
/// SCOPE, DELIBERATELY MINIMAL: obtains `WeeklyCoachingContext`, maps
/// it to `CoachingAnalysisInput`, invokes `CoachingEngine`, invokes
/// `CoachingPresentationMapper`, returns `CoachingPresentation`.
/// Nothing else — no caching (a second call always re-runs the full
/// pipeline; there is no stored state to go stale), no persistence, no
/// retry, no analytics, no business rule. `CoachingAnalysisInputMapper`,
/// `CoachingEngine`, and `CoachingPresentationMapper` are all
/// constructed fresh per call — all three are stateless value types
/// with a no-argument initializer, so there is nothing to gain from
/// injecting or storing them.
///
/// Sprint 14 (revised): the pipeline now has one more explicit step —
/// `CoachingAnalysisInputMapper` — after an architecture review found
/// `WeeklyCoachingContext` to be an application-layer aggregation DTO,
/// not something `CoachingEngine` should own or accept directly. This
/// service is exactly where that mapping belongs: it already owns the
/// full sequence, and adding one more explicit step here keeps
/// `CoachingEngine`'s contract limited to what Coaching itself owns
/// (`CoachingAnalysisInput`) without hiding the translation inside a
/// larger, unrelated service.
///
/// `Do NOT modify CoachingEngine/CoachingResult/CoachingPresentation/
/// CoachingPresentationMapper` — none of them are touched by this
/// file; it only calls their existing public API.
///
/// DEPENDENCY DIRECTION: `WeeklyReviewViewModel` → this service →
/// `WeeklyCoachingContextProviding` → `CoachingAnalysisInputMapper` →
/// `CoachingEngine` → `CoachingPresentationMapper`. This type never
/// imports or references `WeeklyReviewViewModel`, SwiftUI, or any
/// UI-layer type — the dependency only flows one way.
@MainActor
public final class CoachingApplicationService {
    private let coachingContextService: any WeeklyCoachingContextProviding

    public init(coachingContextService: any WeeklyCoachingContextProviding) {
        self.coachingContextService = coachingContextService
    }

    /// Runs the complete deterministic pipeline for one athlete/week
    /// and returns the result. Throws only if `coachingContextService`
    /// genuinely throws — `CoachingAnalysisInputMapper`/`CoachingEngine`/
    /// `CoachingPresentationMapper` are all pure functions that never
    /// throw.
    public func coachingPresentation(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> CoachingPresentation {
        let context = try coachingContextService.weeklyCoachingContext(forAthlete: athleteId, weekStart: weekStart)
        let input = CoachingAnalysisInputMapper().map(context)
        let result = CoachingEngine().analyse(input)
        return CoachingPresentationMapper().map(result)
    }
}
