import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 5.2: explicit load state, rather than separate optional
/// properties — `.loading`/`.failed` are unambiguous, and `.loaded`
/// carries the full `WeeklyReviewCoordinationService` result unchanged.
/// There is deliberately no separate "empty" or "partial" case: a week
/// with no plan, no activities, or no reflection is still a normal
/// `.loaded` result (`WeeklyReviewResult`'s own optionals/empty arrays
/// already say so) — inventing a fourth top-level case would just
/// duplicate information the result already carries, which is exactly
/// what "avoid storing duplicate derived copies of the coordination
/// result" warns against. The view renders each section's own empty
/// state by reading the result directly.
public enum WeeklyReviewLoadState {
    case loading
    case loaded(WeeklyReviewResult)
    case failed
}

/// Sprint 9: mirrors `WeeklyReviewLoadState`'s exact shape and
/// reasoning, for the coaching pipeline specifically. Kept as a
/// completely separate state property (see
/// `WeeklyReviewViewModel.coachingPresentationState`) rather than
/// merged into `WeeklyReviewLoadState` — a coaching failure must not
/// force the rest of Weekly Review into `.failed` too. No separate
/// "empty" case here either, for the same reason `WeeklyReviewLoadState`
/// has none: `CoachingPresentation.sections.isEmpty` already says so,
/// and the view reads that directly rather than this type duplicating
/// it as a fourth case.
public enum CoachingPresentationLoadState {
    case loading
    case loaded(CoachingPresentation)
    case failed
}

/// Sprint 5.2: backs `WeeklyReviewView`. Every read goes through
/// `WeeklyReviewProviding` (in production, `WeeklyReviewCoordinationService`)
/// — this type never touches `PlanningService`/`TrainingService`/
/// `WeeklyReflectionService` directly (the coordination result already
/// supplies everything this screen shows), never imports SwiftData, and
/// recomputes nothing — completion state, ordering, and date-range
/// scoping are exactly what the coordination service already returned.
@MainActor
@Observable
public final class WeeklyReviewViewModel {
    public private(set) var loadState: WeeklyReviewLoadState = .loading
    /// Sprint 9: independent from `loadState` by design — see
    /// `CoachingPresentationLoadState`'s doc comment. A coaching
    /// pipeline failure never touches this property's sibling.
    public private(set) var coachingPresentationState: CoachingPresentationLoadState = .loading

    public let athleteId: AthleteId
    public let weekStart: LocalDate

    private let coordinationService: any WeeklyReviewProviding
    /// Sprint 9: the one new dependency that sprint added. Sprint 11:
    /// now the whole pipeline call sequence (previously three calls
    /// made directly in `loadCoachingPresentation` below) lives in
    /// `CoachingApplicationService` — this ViewModel only requests the
    /// finished result. It still never touches `WeeklyCoachingContext`,
    /// `CoachingEngine`, or `CoachingPresentationMapper` directly.
    private let coachingPresentationProvider: any CoachingPresentationProviding

    public init(
        coordinationService: any WeeklyReviewProviding,
        coachingPresentationProvider: any CoachingPresentationProviding,
        athleteId: AthleteId,
        weekStart: LocalDate
    ) {
        self.coordinationService = coordinationService
        self.coachingPresentationProvider = coachingPresentationProvider
        self.athleteId = athleteId
        self.weekStart = weekStart
    }

    /// Loads (or reloads) the review for this screen's fixed
    /// `athleteId`/`weekStart`. The same method serves both the initial
    /// load and "reload after returning from the reflection form" —
    /// both are just "ask the coordination service again."
    public func load() {
        loadState = .loading
        do {
            let result = try coordinationService.weeklyReview(forAthlete: athleteId, weekStart: weekStart)
            loadState = .loaded(result)
        } catch {
            loadState = .failed
        }
    }

    /// Sprint 11: this ViewModel no longer orchestrates the coaching
    /// pipeline — it delegates to `CoachingApplicationService` (via
    /// `CoachingPresentationProviding`) and stores what comes back. The
    /// pipeline sequence itself (context assembly → engine → mapper)
    /// lives in exactly one place now, not here.
    ///
    /// A thrown error here (a genuine technical failure fetching the
    /// underlying data) becomes `.failed`, never a silently-empty
    /// `.loaded` — see `CoachingPresentationLoadState`. Separate from
    /// `load()` so a coaching failure never blocks the rest of the
    /// screen from loading.
    public func loadCoachingPresentation() {
        coachingPresentationState = .loading
        do {
            let presentation = try coachingPresentationProvider.coachingPresentation(forAthlete: athleteId, weekStart: weekStart)
            coachingPresentationState = .loaded(presentation)
        } catch {
            coachingPresentationState = .failed
        }
    }
}
