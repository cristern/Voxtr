import Foundation
import Observation
import VoxtrCoreContracts
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// VX-023 (Sleep V1): the narrow read surface `HomeDashboardViewModel`
/// needs from `SleepCoordinationService` — protocol-injected for the
/// same testability reason `TodaysTrainingProviding`/
/// `CoachingPresentationProviding` already are on this exact type.
/// `SleepCoordinationService` conforms directly; nothing else needs to.
@MainActor
public protocol SleepStatusProviding {
    func isSleepTrackingEnabled(for athleteId: AthleteId) throws -> Bool
    func fetchDailyStatus(forAthlete athleteId: AthleteId, localDate: LocalDate) throws -> DailyStatus?
    /// VX-023: the range read `SleepHistoryViewModel` pages over.
    func fetchDailyStatuses(forAthlete athleteId: AthleteId, from: LocalDate, to: LocalDate) throws -> [DailyStatus]
    /// Athlete Home Sleep inline round: the one write capability this
    /// protocol now also exposes, mirroring
    /// `SleepCoordinationService.recordSleep`'s exact signature — the
    /// same canonical upsert path `SleepCaptureViewModel.save()` already
    /// uses, injected here so `HomeDashboardViewModel`'s own inline 1-5
    /// control can save through the SAME testable seam its reads
    /// already use, rather than taking a second, concrete dependency.
    /// No new persistence, no second Sleep write path.
    @discardableResult
    func recordSleep(
        athleteId: AthleteId, localDate: LocalDate, sleepQuality: Int,
        visibility: VisibilityPolicy, today: LocalDate
    ) throws -> DailyStatus
}

/// VX-023: the Athlete Home Sleep card's own load state. No `.disabled`
/// case doubling as an error state — tracking-disabled is a normal,
/// expected outcome ("Disabled != missing"), never treated as a failure.
/// `.loaded(sleepQuality: nil)` is "tracking on, nothing logged for
/// today yet"; `.loaded(sleepQuality: someValue)` is "tracking on,
/// today's Sleep already recorded." Both `.trackingDisabled` and
/// `.failed` mean the same thing to the view — render no card — kept as
/// distinct cases purely so tests can tell "disabled" and "could not
/// load" apart.
public enum SleepCardLoadState: Equatable {
    case loading
    case trackingDisabled
    case loaded(sleepQuality: Int?)
    case failed
}

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
public final class HomeDashboardViewModel: AthleteActivityChangeSubscriber, AthleteSleepChangeSubscriber {
    public private(set) var todaysTrainingState: TodaysTrainingLoadState = .loading
    public private(set) var todayActivityState: TodayActivityLoadState = .loading
    public private(set) var coachingSummaryState: CoachingPresentationLoadState = .loading
    /// VX-023: Athlete Home Sleep card state — see `SleepCardLoadState`'s
    /// own doc comment.
    public private(set) var sleepState: SleepCardLoadState = .loading
    /// Athlete Home Sleep inline round: surfaces a genuine
    /// `recordSleep(quality:)` save failure inline, next to the 1-5
    /// control — distinct from `sleepState`, which stays exactly as it
    /// was before the failed attempt (never forced to `.failed`, so the
    /// control itself never disappears out from under a person mid-tap).
    /// Cleared at the start of every `recordSleep(quality:)` call.
    public private(set) var sleepErrorMessage: String?

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
    /// Codemagic compile fix (review follow-up): ordinary `@MainActor`
    /// state — a strong reference to the ONE object whose own,
    /// non-actor-isolated `deinit` unsubscribes this instance from
    /// `activityChangeBroadcaster` when its subscription lifetime ends.
    /// See `ActivityChangeSubscription`'s own doc comment for exactly
    /// why this indirection exists: `HomeDashboardViewModel` itself
    /// cannot have a `deinit` that reads any of its OWN
    /// `@MainActor`-isolated stored properties (confirmed by Codemagic:
    /// `deinit` is `nonisolated`, and `nonisolated` code cannot read
    /// `@MainActor`-isolated state) — so it no longer has a `deinit` at
    /// all. Optional/`var`, not `let`: constructing the subscription
    /// requires calling `subscribe` with `self`, which Swift only
    /// allows once every OTHER stored property already has a value —
    /// including this one, so it starts `nil` and is set as the LAST
    /// statement in `init`, once that's true.
    private var activityChangeSubscription: ActivityChangeSubscription?
    /// VX-023: optional/defaulted `nil`, same reasoning as
    /// `todayActivityComposer` immediately above — "one dependency's
    /// absence never corrupts the rest of this ViewModel." Every
    /// pre-existing construction site (production and test) predates
    /// Sleep and doesn't need updating; `loadSleepState()` simply
    /// reports `.failed` if no provider was supplied.
    private let sleepStatusProvider: (any SleepStatusProviding)?
    /// Mirrors `activityChangeSubscription` above, for the separate
    /// `AthleteSleepChangeBroadcaster`. Optional because
    /// `sleepChangeBroadcaster` itself is optional below — no
    /// broadcaster supplied means no subscription is attempted at all.
    private var sleepChangeSubscription: SleepChangeSubscription?
    /// VX-023 (morning in-app prompt): the smallest local, in-memory
    /// presentation-dismissal state — see `dismissSleepPrompt`'s own doc
    /// comment for the exact semantics this implements.
    private var sleepPromptDismissedLocalDate: LocalDate?

    public init(
        trainingPlanningCoordinationService: any TodaysTrainingProviding,
        coachingPresentationProvider: any CoachingPresentationProviding,
        athleteId: AthleteId,
        athleteDisplayName: String = "",
        weekStart: LocalDate,
        todayActivityComposer: TodayActivityComposer? = nil,
        activityChangeBroadcaster: AthleteActivityChangeBroadcaster,
        sleepStatusProvider: (any SleepStatusProviding)? = nil,
        sleepChangeBroadcaster: AthleteSleepChangeBroadcaster? = nil
    ) {
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.coachingPresentationProvider = coachingPresentationProvider
        self.athleteId = athleteId
        self.athleteDisplayName = athleteDisplayName
        self.weekStart = weekStart
        self.todayActivityComposer = todayActivityComposer
        self.sleepStatusProvider = sleepStatusProvider
        self.activityChangeSubscription = nil
        self.sleepChangeSubscription = nil
        // Recurring reopen stale-Athlete-Home fix (architecture round):
        // subscribes to the SAME shared broadcaster
        // TrainingReflectionCoordinationService notifies after a
        // successful canonical mutation, regardless of which screen
        // performed it — Family Home's own rows, Family Schedule, Daily
        // Training (including nested under this very screen), or this
        // screen's own navigation. Must be the LAST statements in this
        // initializer (along with the Sleep subscribe immediately
        // below) — see `activityChangeSubscription`'s own doc comment
        // for why.
        let token = activityChangeBroadcaster.subscribe(athleteId: athleteId, self)
        self.activityChangeSubscription = ActivityChangeSubscription(
            athleteId: athleteId, token: token, broadcaster: activityChangeBroadcaster
        )
        // VX-023: same subscribe-then-wrap pattern as above, for the
        // separate Sleep broadcaster — only attempted if one was
        // actually supplied.
        if let sleepChangeBroadcaster {
            let sleepToken = sleepChangeBroadcaster.subscribe(athleteId: athleteId, self)
            self.sleepChangeSubscription = SleepChangeSubscription(
                athleteId: athleteId, token: sleepToken, broadcaster: sleepChangeBroadcaster
            )
        }
    }

    /// `AthleteActivityChangeSubscriber` conformance: reread canonical
    /// state through the exact same two calls this screen's own
    /// `onActivityLogged` wiring already makes — never a second,
    /// broadcaster-specific reload path. Coaching is deliberately not
    /// reloaded here either, matching every existing `onActivityLogged`
    /// closure in this codebase, none of which reload coaching.
    public func athleteActivityDidChange() {
        loadTodaysTraining()
        loadTodayActivityRows()
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

    /// `AthleteSleepChangeSubscriber` conformance: reread canonical
    /// Sleep state through the same `loadSleepState()` any other caller
    /// uses — never a second, broadcaster-specific reload path.
    public func athleteSleepDidChange() {
        loadSleepState()
    }

    /// VX-023: loads the Athlete Home Sleep card's state — tracking
    /// preference first, then (only if enabled) today's `DailyStatus`.
    /// `referenceDate`/`calendar` are injectable, matching this file's
    /// and package's established pattern (`FamilyHomeViewModel.nowNextState`,
    /// `TrainingPlanningCoordinationService.today`) for deterministic,
    /// `Date.now`-independent tests.
    public func loadSleepState(referenceDate: Date = .now, calendar: Calendar = .current) {
        guard let sleepStatusProvider else {
            sleepState = .failed
            return
        }
        sleepState = .loading
        do {
            guard try sleepStatusProvider.isSleepTrackingEnabled(for: athleteId) else {
                sleepState = .trackingDisabled
                return
            }
            let today = SleepCoordinationService.today(referenceDate: referenceDate, calendar: calendar)
            let status = try sleepStatusProvider.fetchDailyStatus(forAthlete: athleteId, localDate: today)
            sleepState = .loaded(sleepQuality: status?.sleepQuality)
        } catch {
            sleepState = .failed
        }
    }

    /// Athlete Home Sleep inline round: the canonical inline save path —
    /// each 1-5 tap on the Athlete Home Sleep control calls this
    /// directly, no intermediate form/Save button. Goes through the
    /// SAME `SleepStatusProviding.recordSleep` seam `loadSleepState()`
    /// already reads through (backed by
    /// `SleepCoordinationService.recordSleep` → the canonical
    /// `upsertSleepQuality` in production) — recording a value for a
    /// date that already has one UPDATES that same `DailyStatus`, never
    /// creates a duplicate (unchanged semantics, same call). Always
    /// records against TODAY specifically — this control has no notion
    /// of any other date, matching the approved target ("Sleep quality
    /// for TODAY... completed inline"); historical/backfill correction
    /// remains Sleep History's own separate, richer flow.
    ///
    /// On success, reloads `sleepState` from canonical truth via the
    /// existing `loadSleepState()` — no locally-assigned "optimistic"
    /// value is ever set here, so the displayed selection can never
    /// disagree with what was actually persisted. On failure,
    /// `sleepState` is left exactly as it was (never forced to
    /// `.failed`) and `sleepErrorMessage` reports why, mirroring
    /// `SleepCaptureViewModel.save()`'s own error mapping exactly — the
    /// same three cases, no new ones invented.
    public func recordSleep(quality: Int, referenceDate: Date = .now, calendar: Calendar = .current) {
        sleepErrorMessage = nil
        guard let sleepStatusProvider else {
            sleepErrorMessage = "Could not save Sleep. Please try again."
            return
        }
        let today = SleepCoordinationService.today(referenceDate: referenceDate, calendar: calendar)
        do {
            try sleepStatusProvider.recordSleep(
                athleteId: athleteId, localDate: today, sleepQuality: quality,
                visibility: .sharedWithGuardians, today: today
            )
            loadSleepState(referenceDate: referenceDate, calendar: calendar)
        } catch ReflectionServiceError.futureDateNotAllowed {
            sleepErrorMessage = "Sleep can't be logged for a future date."
        } catch ReflectionServiceError.invalidField(let message) {
            sleepErrorMessage = message
        } catch {
            sleepErrorMessage = "Could not save Sleep. Please try again."
        }
    }

    /// VX-023 (morning in-app prompt): "Sleep tracking ON; today Sleep
    /// missing; local time before 12:00" — all three checked here.
    /// Reads `sleepState` rather than re-fetching, so this can only ever
    /// report eligible once `loadSleepState()` has actually run and
    /// settled into `.loaded(sleepQuality: nil)`; `.trackingDisabled`/
    /// `.failed`/`.loading` are never eligible.
    public func isSleepPromptEligible(referenceDate: Date = .now, calendar: Calendar = .current) -> Bool {
        guard case .loaded(let sleepQuality) = sleepState, sleepQuality == nil else { return false }
        guard calendar.component(.hour, from: referenceDate) < 12 else { return false }
        let today = SleepCoordinationService.today(referenceDate: referenceDate, calendar: calendar)
        return sleepPromptDismissedLocalDate != today
    }

    /// VX-023: "once dismissed, do not re-nag during that same local
    /// morning/session/day" — the smallest local, in-memory presentation
    /// state that satisfies this: a single `LocalDate?` remembered only
    /// for this ViewModel instance's own lifetime (never persisted,
    /// never a new persistence domain). Recorded as the CURRENT day (per
    /// `referenceDate`), not literally "forever" — a later calendar day
    /// naturally makes `isSleepPromptEligible` re-eligible again on its
    /// own, since the comparison above is against that day's own
    /// `today`. Dismissing here never disables Sleep tracking itself —
    /// `sleepState`/`sleepStatusProvider` are completely untouched.
    public func dismissSleepPrompt(referenceDate: Date = .now, calendar: Calendar = .current) {
        sleepPromptDismissedLocalDate = SleepCoordinationService.today(referenceDate: referenceDate, calendar: calendar)
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
