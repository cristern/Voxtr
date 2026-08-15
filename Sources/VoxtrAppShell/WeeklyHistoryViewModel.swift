import Foundation
import VoxtrCoreContracts
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Area 6 (Parent Time Navigation & Weekly History package): "Weekly
/// History / Week by Week", under Training. Reconstructs the factual
/// truth of ONE concrete, already-completed week — Planning proposes,
/// Training proves, Reflection explains. This is deliberately NOT a
/// new historical storage entity: every field here is read directly
/// from `WeeklyReviewCoordinationService.weeklyReview(forAthlete:weekStart:)`,
/// the SAME assembly `WeeklyReviewView` (the current-week screen)
/// already uses — reused verbatim, not duplicated or reimplemented.
/// No domain-level change was required or made.
@MainActor
@Observable
public final class WeeklyHistoryViewModel {
    public let athleteId: AthleteId
    public private(set) var weekStart: LocalDate
    public private(set) var result: WeeklyReviewResult?
    public private(set) var errorMessage: String?

    private let coordinationService: any WeeklyReviewProviding

    public init(
        coordinationService: any WeeklyReviewProviding,
        athleteId: AthleteId,
        weekStart: LocalDate
    ) {
        self.coordinationService = coordinationService
        self.athleteId = athleteId
        self.weekStart = weekStart
    }

    public func load() {
        errorMessage = nil
        // Issue 3 fix: clear the previous week's result BEFORE
        // attempting the new load — otherwise a failed load after
        // switchToWeek() would leave the OLD week's result displayed
        // under the NEW week's heading, since `result` previously kept
        // its prior value on error.
        result = nil
        do {
            result = try coordinationService.weeklyReview(forAthlete: athleteId, weekStart: weekStart)
        } catch {
            errorMessage = "Could not load this week."
        }
    }

    /// Chronological, newest-first navigation: only ever moves
    /// backward into the past, or forward up to (never beyond) the
    /// current Vǫxtr week — Weekly History reconstructs weeks that
    /// have happened, it does not preview the future.
    public func switchToWeek(_ newWeekStart: LocalDate, calendar: Calendar = .current) {
        let currentWeekStart = TrainingPlanningCoordinationService.weekStart(calendar: calendar)
        guard newWeekStart <= currentWeekStart else { return }
        weekStart = newWeekStart
        load()
    }

    /// Every planned activity actually completed (a `LoggedActivity`
    /// references it) — reuses `PlannedActivityCompletion.isCompleted`
    /// directly, no re-derivation.
    public var completedFromPlanCount: Int {
        result?.plannedActivities.filter(\.isCompleted).count ?? 0
    }

    public var plannedCount: Int {
        result?.plannedActivities.count ?? 0
    }

    /// Logged activities with no `plannedActivityId` at all — genuinely
    /// unplanned, never a planned activity backfilled/inferred by
    /// title or date match.
    public var additionalLoggedActivities: [LoggedActivity] {
        result?.loggedActivities.filter { $0.plannedActivityId == nil } ?? []
    }

    public var additionalCount: Int { additionalLoggedActivities.count }

    /// Privacy: mirrors `FamilyHomeViewModel.loadFocusThisWeek()`'s own
    /// gate exactly — a reflection whose own `visibility` is
    /// `.privateToAthlete` never surfaces its text here either. Same
    /// existing visibility rule, not a new one invented for this
    /// screen.
    public var focusNextWeekIfPermitted: String? {
        guard let reflection = result?.weeklyReflection, reflection.visibility != .privateToAthlete else {
            return nil
        }
        return reflection.nextWeekConsideration
    }

    /// Final privacy gate for Weekly History's Reflection action.
    /// Reuses the SAME canonical `WeeklyReflection.visibility` check as
    /// `focusNextWeekIfPermitted`/`FamilyHomeViewModel.loadFocusThisWeek()`
    /// above — no parallel permission system invented for this screen.
    ///
    /// Critically distinguishes "no Reflection exists" from "a
    /// Reflection exists but this actor cannot see it" — both are
    /// knowable directly from `result.weeklyReflection` (present or
    /// nil) combined with its own `visibility` field, which the
    /// existing `WeeklyReviewCoordinationService` assembly already
    /// carries through unfiltered (it is a pure read-model composer,
    /// not a permission-enforcing layer — enforcement happens here,
    /// at the point of use, the same place `loadFocusThisWeek()`
    /// already enforces it). No architectural gap: the distinction is
    /// fully expressible today.
    public enum ReflectionAccessState {
        /// No Reflection exists for this athlete/week — Case A.
        case none
        /// A Reflection exists and is visible to the current actor —
        /// Case B. Carries the reflection itself for display/editing.
        case visible(WeeklyReflection)
        /// A Reflection exists but is `.privateToAthlete` — Case C.
        /// Never exposed as content, never offered for edit, and
        /// critically never treated as `.none` — offering "Add
        /// Reflection" here would risk creating a competing/duplicate
        /// Reflection for the same athlete/week that already has one.
        case hiddenForPrivacy
    }

    public var reflectionAccessState: ReflectionAccessState {
        guard let reflection = result?.weeklyReflection else { return .none }
        guard reflection.visibility != .privateToAthlete else { return .hiddenForPrivacy }
        return .visible(reflection)
    }
}
