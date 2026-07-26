import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrTrainingDomain

/// Sprint 13: unlike `HomeDashboardViewModel` (Sprint 12), which
/// exposes today's-training and coaching as two independent states
/// because they render as two independent sections, `DailyFocusViewModel`
/// exposes exactly ONE state — the whole point of this type is to
/// produce one composed card, not two separate pieces. Both underlying
/// loads still happen independently inside `load()` (a failure in one
/// must never prevent the other, per this sprint's explicit
/// requirement) — only the RESULT is unified.
///
/// `.loaded(nil)` means both underlying loads succeeded (or at least
/// one did) but nothing qualified for any priority level — "nothing
/// requiring attention," an intentional, valid outcome, not a failure.
/// `.failed` is reserved for the case where BOTH underlying loads
/// failed — the only case this sprint says should hide the card
/// entirely.
public enum DailyFocusLoadState {
    case loading
    case loaded(DailyFocusPresentation?)
    case failed
}

/// Sprint 13: composes `DailyFocusPresentation` from two already-existing
/// outputs — `TrainingPlanningCoordinationService.todaysPlannedActivitiesWithCompletion(forAthlete:)`
/// (Sprint 3.2) and `CoachingApplicationService.coachingPresentation(forAthlete:weekStart:)`
/// (Sprint 11). No repository, no `ModelContext`, no domain object
/// construction, no new coaching rule — every fact this type reads
/// (`isCompleted`, `action`) was already computed by something else;
/// this type only SELECTS among those already-computed facts using the
/// fixed priority order this sprint specifies, in the same way
/// `CoachingPresentationMapper`'s fixed section order is presentation
/// organization, not a new domain rule.
@MainActor
@Observable
public final class DailyFocusViewModel {
    public private(set) var loadState: DailyFocusLoadState = .loading

    public let athleteId: AthleteId
    public let weekStart: LocalDate

    /// Concrete, not protocol-injected — matches
    /// `HomeDashboardViewModel`'s (Sprint 12) precedent for this exact
    /// dependency, which itself matches `DailyTrainingViewModel`'s
    /// original precedent.
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    /// Protocol-injected — matches the established convention for this
    /// exact dependency since Sprint 11.
    private let coachingPresentationProvider: any CoachingPresentationProviding

    public init(
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        coachingPresentationProvider: any CoachingPresentationProviding,
        athleteId: AthleteId,
        weekStart: LocalDate
    ) {
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.coachingPresentationProvider = coachingPresentationProvider
        self.athleteId = athleteId
        self.weekStart = weekStart
    }

    /// Loads both underlying outputs independently — a thrown error
    /// from either becomes `nil` locally, not a shared early exit, so
    /// one failing can never prevent the other from being used. Only
    /// when BOTH are `nil` does the overall state become `.failed`.
    public func load() {
        loadState = .loading

        let todaysActivities: [PlannedActivityCompletion]?
        do {
            todaysActivities = try trainingPlanningCoordinationService.todaysPlannedActivitiesWithCompletion(forAthlete: athleteId)
        } catch {
            todaysActivities = nil
        }

        let coaching: CoachingPresentation?
        do {
            coaching = try coachingPresentationProvider.coachingPresentation(forAthlete: athleteId, weekStart: weekStart)
        } catch {
            coaching = nil
        }

        if todaysActivities == nil && coaching == nil {
            loadState = .failed
            return
        }

        loadState = .loaded(Self.composeFocus(todaysActivities: todaysActivities, coaching: coaching))
    }

    /// The fixed priority order this sprint specifies, applied to
    /// already-computed facts only:
    /// 1. Any incomplete planned activity today (`isCompleted == false`,
    ///    already derived by `TrainingPlanningCoordinationService` —
    ///    not recomputed here).
    /// 2. A coaching item whose `action` is not `.none` (already
    ///    assigned by `CoachingPresentationMapper` — not recomputed
    ///    here). Sections are walked in `CoachingPresentation`'s own
    ///    existing fixed order, so which actionable item wins (if more
    ///    than one exists) is itself deterministic without this
    ///    function inventing a new ranking.
    /// 3. Otherwise `nil` — nothing requiring attention.
    private static func composeFocus(
        todaysActivities: [PlannedActivityCompletion]?,
        coaching: CoachingPresentation?
    ) -> DailyFocusPresentation? {
        if let incomplete = todaysActivities?.first(where: { !$0.isCompleted }) {
            return DailyFocusPresentation(
                title: incomplete.plannedActivity.title,
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
