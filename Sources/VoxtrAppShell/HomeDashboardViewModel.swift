import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrTrainingDomain

/// Sprint 12: mirrors `WeeklyReviewLoadState`/`CoachingPresentationLoadState`'s
/// exact shape — per this sprint's explicit instruction to follow
/// `WeeklyReviewViewModel`'s established pattern, not invent a
/// different one. No separate "empty" case, for the same reason those
/// two have none: an empty `[PlannedActivityCompletion]` array already
/// says "nothing planned today" on its own; the view reads that
/// directly.
public enum TodaysTrainingLoadState {
    case loading
    case loaded([PlannedActivityCompletion])
    case failed
}

/// Sprint 1.2B: the comprehensive "today" read model — reuses
/// `TodayActivityComposer`/`TodayActivityRow` (already established for
/// Family Home) rather than a second, screen-specific aggregation.
/// Additive alongside `TodaysTrainingLoadState` above, not a
/// replacement — `dailyFocusState` below still depends on that
/// original, narrower `[PlannedActivityCompletion]` shape, and Daily
/// Focus is a retained product concept out of this package's scope.
public enum TodayActivityLoadState {
    case loading
    case loaded([TodayActivityRow])
    case failed
}

/// Sprint 13 (architecture correction): moved here from the now-removed
/// `DailyFocusViewModel` — this is where the state is actually derived
/// now, so this is where the type belongs. Same shape as
/// `CoachingPresentationLoadState`: `.loaded(nil)` is "nothing
/// qualified, an intentional valid outcome," `.failed` is reserved for
/// "both underlying sources failed, hide the card."
public enum DailyFocusLoadState {
    case loading
    case loaded(DailyFocusPresentation?)
    case failed
}

/// Sprint 12: backs `HomeDashboardView`. Two independent load states —
/// today's training and the coaching summary — for the same reason
/// `WeeklyReviewViewModel` keeps its own two independent: a failure in
/// one must never block the other from loading or force it into
/// `.failed` too.
///
/// Reuses `CoachingPresentationLoadState` (defined alongside
/// `WeeklyReviewViewModel`) directly for the coaching summary, rather
/// than declaring a second, structurally-identical enum — that would
/// be exactly the "duplicate presentation model" this sprint asks to
/// avoid.
///
/// Nothing here recomputes anything. `todaysTraining` comes from
/// `TrainingPlanningCoordinationService.todaysPlannedActivitiesWithCompletion(forAthlete:)`
/// (already existed since Sprint 3.2 — completion state is derived
/// there, not here). `coachingSummary` comes from
/// `CoachingApplicationService.coachingPresentation(forAthlete:weekStart:)`
/// (Sprint 11) exactly as implemented — this type never touches
/// `WeeklyCoachingContext`, `CoachingEngine`, or
/// `CoachingPresentationMapper` directly, and never imports SwiftData
/// or a repository.
///
/// Sprint 13 (architecture correction): this is now the SINGLE owner of
/// dashboard data loading. `dailyFocusState` below is a *computed*
/// property derived from `todaysTrainingState`/`coachingSummaryState` —
/// not a third stored, independently-loaded piece of state. Nothing
/// calls `TodaysTrainingProviding`/`CoachingPresentationProviding` a
/// second time for Daily Focus; `loadTodaysTraining()`/
/// `loadCoachingSummary()` remain the only two loading entry points
/// this type has ever had.
@MainActor
@Observable
public final class HomeDashboardViewModel {
    public private(set) var todaysTrainingState: TodaysTrainingLoadState = .loading
    public private(set) var todayActivityState: TodayActivityLoadState = .loading
    public private(set) var coachingSummaryState: CoachingPresentationLoadState = .loading

    public let athleteId: AthleteId
    public let weekStart: LocalDate
    private let athleteDisplayName: String
    /// Sprint 13 (architecture correction): now protocol-injected —
    /// `HomeDashboardViewModel`'s own tests need deterministic
    /// call-count and independent-failure control over this dependency,
    /// which the concrete type didn't allow. `DailyTrainingViewModel`
    /// still takes the concrete type directly, unchanged — it has no
    /// such need, so it wasn't touched.
    private let trainingPlanningCoordinationService: any TodaysTrainingProviding
    /// Protocol-injected — matches the established convention for this
    /// exact dependency since Sprint 11.
    private let coachingPresentationProvider: any CoachingPresentationProviding
    /// Sprint 1.2B: injected by the caller (which already holds
    /// `planningService`/`trainingService`/the concrete coordination
    /// service) rather than this ViewModel taking those three
    /// dependencies directly just to build one internally. Optional,
    /// defaulted to `nil`, so the many existing construction sites that
    /// predate this feature don't all need updating — `loadTodayActivityRows()`
    /// simply reports `.failed` if no composer was supplied, the same
    /// "one dependency's absence never corrupts the rest of this
    /// ViewModel" principle this type's own two independent load
    /// states already establish.
    private let todayActivityComposer: TodayActivityComposer?

    public init(
        trainingPlanningCoordinationService: any TodaysTrainingProviding,
        coachingPresentationProvider: any CoachingPresentationProviding,
        athleteId: AthleteId,
        athleteDisplayName: String = "",
        weekStart: LocalDate,
        todayActivityComposer: TodayActivityComposer? = nil
    ) {
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.coachingPresentationProvider = coachingPresentationProvider
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.weekStart = weekStart
        self.todayActivityComposer = todayActivityComposer
    }

    public func loadTodayActivityRows() {
        homeDashboardDebugLog("loadTodayActivityRows START instance=\(ObjectIdentifier(self)) athleteId=\(athleteId.rawValue.uuidString)")
        todayActivityState = .loading
        guard let todayActivityComposer else {
            todayActivityState = .failed
            return
        }
        do {
            let rows = try todayActivityComposer.todayActivities(forAthlete: athleteId, athleteName: athleteDisplayName)
            todayActivityState = .loaded(rows)
            let summary = rows.map { row -> String in
                if case .planned(let familyHomeRow) = row {
                    return "\(familyHomeRow.id)=\(String(describing: familyHomeRow.outcomeStatus))"
                }
                return row.id
            }.joined(separator: ", ")
            homeDashboardDebugLog("loadTodayActivityRows DONE instance=\(ObjectIdentifier(self)) rows=[\(summary)]")
        } catch {
            todayActivityState = .failed
        }
    }

    public func loadTodaysTraining() {
        todaysTrainingState = .loading
        do {
            let activities = try trainingPlanningCoordinationService.todaysPlannedActivitiesWithCompletion(forAthlete: athleteId)
            todaysTrainingState = .loaded(activities)
        } catch {
            todaysTrainingState = .failed
        }
    }

    /// Pure delegation — the same pipeline call
    /// `WeeklyReviewViewModel.loadCoachingPresentation()` already makes,
    /// with no transformation. There is exactly one place in this
    /// codebase that performs the coaching orchestration
    /// (`CoachingApplicationService`); this method is not a second one.
    public func loadCoachingSummary() {
        coachingSummaryState = .loading
        do {
            let presentation = try coachingPresentationProvider.coachingPresentation(forAthlete: athleteId, weekStart: weekStart)
            coachingSummaryState = .loaded(presentation)
        } catch {
            coachingSummaryState = .failed
        }
    }

    /// Sprint 13 (architecture correction): Daily Focus, derived purely
    /// from `todaysTrainingState`/`coachingSummaryState` — no service
    /// call happens here, ever. Being a computed property (not a
    /// stored one updated imperatively) means it always reflects
    /// whatever the two source states currently are, with nothing to
    /// keep in sync by hand and no possibility of a stale copy.
    ///
    /// - `.loading` while EITHER source is still `.loading` — composing
    ///   from a source that hasn't settled yet isn't meaningful.
    /// - `.failed` only when BOTH sources are `.failed` — hides the
    ///   card entirely.
    /// - `.loaded(...)` otherwise, composed from whichever source(s)
    ///   actually succeeded — a single source's failure is passed to
    ///   `DailyFocusComposer` as `nil` for that source only, never as a
    ///   reason to fail the whole composition.
    public var dailyFocusState: DailyFocusLoadState {
        switch (todaysTrainingState, coachingSummaryState) {
        case (.loading, _), (_, .loading):
            return .loading
        case (.failed, .failed):
            return .failed
        case (.loaded(let activities), .failed):
            return .loaded(DailyFocusComposer().compose(todaysActivities: activities, coaching: nil))
        case (.failed, .loaded(let coaching)):
            return .loaded(DailyFocusComposer().compose(todaysActivities: nil, coaching: coaching))
        case (.loaded(let activities), .loaded(let coaching)):
            return .loaded(DailyFocusComposer().compose(todaysActivities: activities, coaching: coaching))
        }
    }
}
