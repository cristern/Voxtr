import Foundation
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

/// Sprint 1 (Daily Use Foundation), Part 1. One row in the family-wide
/// Today's Schedule — a `PlannedActivity` tagged with which athlete it
/// belongs to. Never carries a "selected athlete" of its own; each row
/// is self-contained, matching "no global selected athlete state."
public struct FamilyHomeRow: Identifiable {
    public let id: String
    public let athleteId: AthleteId
    public let athleteName: String
    public let plannedActivity: PlannedActivity
    public let isCompleted: Bool

    /// Recurring cancel/materialization fix: identifies a
    /// `PlannedActivity` that originated from a recurring definition —
    /// e.g. one materialized by "Log Activity" on a recurring
    /// occurrence but not yet logged (the exact state after the user
    /// cancels), which must still present as recurring through any
    /// fresh recomposition.
    ///
    /// Compares `externalSourceType` against `RecurringPlannedActivity`'s
    /// own constant — deliberately NOT `externalSourceId != nil`.
    /// Repository-wide inspection confirmed `externalSourceId`/
    /// `externalSourceType` are a GENERIC external-provenance pair (the
    /// `type` half exists precisely because more than one source kind is
    /// anticipated); recurring materialization merely happens to be the
    /// only producer today. Treating any non-nil `externalSourceId` as
    /// "recurring" would silently mislabel every future external source.
    ///
    /// Read directly from the persisted `PlannedActivity` on every
    /// access — never cached, so it cannot go stale across
    /// recomposition.
    public var isFromRecurring: Bool {
        plannedActivity.externalSourceType == RecurringPlannedActivity.externalSourceType
    }
}

/// Parent Home UX / Content Contract package: "Focus this week" — the
/// SAME persisted `nextWeekConsideration` value from the PRIOR week's
/// reflection, presented on Family Home under a new label. Never a
/// duplicate, Home-specific focus field — the prior reflection remains
/// the sole source of truth (this struct carries no ID of its own
/// distinct from the athlete/reflection it's drawn from).
///
/// Deliberately excludes any athlete with no relevant prior focus —
/// see `loadFocusThisWeek()`'s own `compactMap`: absence must show
/// nothing, not an empty/placeholder state. Also carries no
/// "incomplete" or "missing" notion at all — Focus ≠ Goal, and there
/// is no completion state to be missing.
public struct AthleteFocusThisWeek: Identifiable {
    public let id: String
    public let athleteId: AthleteId
    public let athleteName: String
    public let focus: String
}

/// Sprint 1 integration audit fix: `RestoredFamily.activeAthletes` is a
/// launch-time snapshot — it is never re-queried after app launch (see
/// `AthleteFamilyManagementViewModel`'s own established doc comment on
/// exactly this limitation, written when the multi-athlete foundation
/// was built, well before this sprint). Family Home was built directly
/// on top of that stale snapshot, with no refresh of its own — so an
/// athlete added, archived, or edited after launch silently never
/// appeared (or a stale one silently failed to resolve, e.g. the
/// reflection reminder's "Add reflection" link going dead once the
/// snapshot's athlete no longer matched anything meaningful). This is
/// the actual architectural gap behind those symptoms, not a collection
/// of unrelated bugs: `FamilyHomeViewModel` now owns a refreshable
/// `activeAthletes` list, re-fetched from `AthleteRepository` on every
/// appearance, and is the single source of truth `FamilyHomeContentView`
/// reads from for every athlete lookup — `family.activeAthletes` is no
/// longer read anywhere in that view.
@MainActor
@Observable
public final class FamilyHomeViewModel {
    public private(set) var activeAthletes: [AthleteProfile]
    /// Parent Home UX / Content Contract: derived from the PRIOR
    /// week's reflection only — never the current week's. See
    /// `AthleteFocusThisWeek`'s own doc comment.
    public private(set) var focusThisWeek: [AthleteFocusThisWeek] = []
    public private(set) var errorMessage: String?

    public private(set) var rows: [TodayActivityRow] = []
    public private(set) var tomorrowRows: [TodayActivityRow] = []
    private let workspaceId: WorkspaceId
    private let athleteRepository: AthleteRepository
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService
    private let todayActivityComposer: TodayActivityComposer

    public init(
        activeAthletes: [AthleteProfile],
        workspaceId: WorkspaceId,
        athleteRepository: AthleteRepository,
        planningService: PlanningService,
        trainingService: TrainingService,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReflectionService: WeeklyReflectionService
    ) {
        self.activeAthletes = activeAthletes
        self.workspaceId = workspaceId
        self.athleteRepository = athleteRepository
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
        self.todayActivityComposer = TodayActivityComposer(
            planningService: planningService,
            trainingService: trainingService,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
    }

    /// The single entry point the view calls on appear — refreshes the
    /// athlete roster first, then loads everything that depends on it,
    /// in that order, so today's schedule and the reflection reminder
    /// never operate against a stale roster.
    public func refresh() {
        refreshActiveAthletes()
        loadHome()
        loadTomorrow()
        loadFocusThisWeek()
    }

    /// Re-fetches from persistence — the same repository method and
    /// active-only filter `AthleteFamilyManagementViewModel.loadAthletes()`
    /// already established, kept deterministically ordered the same way
    /// (createdAt, then id) so this list's order never surprises a
    /// caller relying on "first active athlete."
    public func refreshActiveAthletes() {
        do {
            let fetched = try athleteRepository.fetchAthletes(forWorkspace: workspaceId)
            activeAthletes = fetched
                .filter { !$0.isArchived }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
        } catch {
            // Keep whatever roster was already known (the launch-time
            // snapshot, or a previous successful refresh) rather than
            // clearing it on a transient failure.
        }
    }

    /// Calls the already-existing, per-athlete
    /// `todaysPlannedActivitiesWithCompletion(forAthlete:)` once per
    /// active athlete and merges the results — no new persistence
    /// query, no schema change; this is a pure application-layer
    /// aggregation over an already-existing capability.
    public func loadHome() {
        errorMessage = nil
        var merged: [TodayActivityRow] = []
        var anyFailed = false
        for athlete in activeAthletes {
            do {
                let athleteRows = try todayActivityComposer.todayActivities(
                    forAthlete: athlete.athleteId, athleteName: athlete.givenName
                )
                merged.append(contentsOf: athleteRows)
            } catch {
                // One athlete's failure must never block the others —
                // same principle HomeDashboardViewModel's own two
                // independent load states already establish.
                anyFailed = true
            }
        }
        // Family Home presentation ordering (fix: this grouping was lost
        // when loadHome() moved from its own per-athlete fetch to
        // TodayActivityComposer, which only sorts chronologically — see
        // TodayActivityComposer.todayActivities(...)'s own doc comment).
        // Not-completed rows first (chronological), completed/logged
        // rows last (chronological) — the same pre-existing contract
        // FamilyHomeViewModel.sorted(_:) below still applies to
        // tomorrowRows. This is presentation ordering on top of the
        // composer's already-composed data, not a second aggregation —
        // the composer itself remains the single source of what rows
        // exist; only their order here is Family-Home-specific.
        let notCompleted = merged.filter { !$0.isCompletedOrLogged }.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        let completed = merged.filter { $0.isCompletedOrLogged }.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        rows = notCompleted + completed
        if anyFailed && rows.isEmpty {
            errorMessage = "Could not load today's activities."
        }
    }

    /// Sprint 1 completion package, Part 4: tomorrow's activities
    /// across every active athlete — same aggregation shape as
    /// `loadHome()`, over the generalized, date-parameterized
    /// coordination-service method rather than a new one hardcoded to
    /// "tomorrow." No new persisted model, no duplicated activities —
    /// this reads the same `PlannedActivity` rows `loadHome()` and
    /// every other surface already read.
    public func loadTomorrow() {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            tomorrowRows = []
            return
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
        let tomorrowDate = LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)

        var merged: [TodayActivityRow] = []
        for athlete in activeAthletes {
            let athleteRows = (try? todayActivityComposer.activities(
                forAthlete: athlete.athleteId, athleteName: athlete.givenName,
                on: tomorrowDate, includeUnplannedLogged: false
            )) ?? []
            merged.append(contentsOf: athleteRows)
        }
        // Same presentation ordering as loadHome() above — not-completed
        // first (chronological), completed/logged last (chronological).
        let notCompleted = merged.filter { !$0.isCompletedOrLogged }.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        let completed = merged.filter { $0.isCompletedOrLogged }.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey }
        tomorrowRows = notCompleted + completed
    }


    /// Parent Home UX / Content Contract: "Focus this week" — the SAME
    /// persisted `nextWeekConsideration` value from the PRIOR week's
    /// reflection (never the current week's, and never a duplicate,
    /// Home-specific field). `compactMap`, not `map`: an athlete with
    /// no prior reflection, or a prior reflection with no
    /// `nextWeekConsideration` text, is simply absent from the result —
    /// no "reflection incomplete"/"no focus entered" placeholder is
    /// ever constructed for them. Same per-athlete failure isolation
    /// as `loadHome()`/`loadTomorrow()` above.
    ///
    /// Privacy: excludes any reflection whose own `visibility` is
    /// `.privateToAthlete`. This is not a new restriction invented
    /// here — it's the conservative choice that avoids broadening
    /// access: this method displays the reflection's actual text
    /// content on Parent Home, which the reflection's own visibility
    /// setting must authorize. (This package's audit found the prior,
    /// now-removed reminder never rendered reflection text in its UI
    /// at all — only a bare "Recorded"/"not yet" status — so it never
    /// had to make this check; this method does, since it surfaces the
    /// content itself.) Long-term Reflection privacy architecture is
    /// explicitly out of scope here — this is the minimum conservative
    /// gate against the visibility rule that already exists today.
    public func loadFocusThisWeek() {
        let priorWeekStart = TrainingPlanningCoordinationService.weekStart().adding(days: -7)
        focusThisWeek = activeAthletes.compactMap { athlete in
            let reflection = (try? weeklyReflectionService.fetchWeeklyReflection(forAthlete: athlete.athleteId, weekStart: priorWeekStart)) ?? nil
            guard let reflection, reflection.visibility != .privateToAthlete else {
                return nil
            }
            guard let focus = reflection.nextWeekConsideration,
                  !focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AthleteFocusThisWeek(
                id: athlete.athleteId.rawValue.uuidString,
                athleteId: athlete.athleteId,
                athleteName: athlete.givenName,
                focus: focus
            )
        }
    }

    /// Parent Home UX / Content Contract, Now/Next: computed, not a
    /// separately loaded/cached state — derives entirely from `rows`/
    /// `tomorrowRows` above, the SAME canonical composed activities
    /// Today/Tomorrow already display. No parallel activity identity
    /// or lifecycle logic, no new query, no materialization: this is
    /// purely a different slice/ordering of data already loaded by
    /// `loadHome()`/`loadTomorrow()`. `@Observable` re-evaluates this
    /// automatically whenever those change.
    ///
    /// "Underway" (NOW) is `start <= current time < end` — genuinely
    /// in progress right now, not merely "started at some point,
    /// whenever that was." `end` is derived from each row's own
    /// `endLocalTimeSortKey` (start + duration, see that property's
    /// own doc comment) — not inferred from completion state alone: an
    /// activity that ended hours ago but hasn't been logged yet must
    /// not still occupy NOW.
    ///
    /// `endLocalTimeSortKey` is `nil` when duration is genuinely
    /// unknown (neither `PlannedActivity` nor `RecurringPlannedActivity`
    /// guarantees a duration) — such a row can NEVER be classified NOW,
    /// since Vǫxtr has no actual basis to claim it's still in progress.
    /// It also can't be NEXT once its start has passed (NEXT requires
    /// `start > now`). It simply falls out of Now/Next entirely once
    /// started with no known end — remaining visible in Today's own
    /// full list, just not occupying this slot; never a fabricated end
    /// time standing in for real information Vǫxtr doesn't have.
    /// NEXT/TOMORROW both take every row sharing the single earliest
    /// remaining start time — not one arbitrary winner — so genuinely
    /// simultaneous/closely-timed activities across different children
    /// are never hidden from
    /// each other.
    public var nowNextState: NowNextState {
        nowNextState(referenceDate: .now, calendar: .current)
    }

    /// Maintainability fix: the underlying logic, with an injectable
    /// `referenceDate`/`calendar` — exists so tests can construct a
    /// genuinely deterministic scenario (a fixed reference instant)
    /// rather than depending on wall-clock `.now` in a way that could
    /// theoretically cross a day boundary mid-test. `nowNextState`
    /// above is the one public, unchanged API every existing caller
    /// already uses — this defaults to the exact same `.now`/`.current`
    /// it always used, so no existing behavior changes.
    func nowNextState(referenceDate: Date, calendar: Calendar) -> NowNextState {
        let components = calendar.dateComponents([.hour, .minute], from: referenceDate)
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        let activeToday = rows.filter { !$0.isCompletedOrLogged && $0.startLocalTimeSortKey != Int.max }

        let underway = activeToday.filter { row in
            guard let end = row.endLocalTimeSortKey else { return false }
            return row.startLocalTimeSortKey <= nowMinutes && nowMinutes < end
        }
        if !underway.isEmpty {
            return .now(underway.sorted { $0.startLocalTimeSortKey < $1.startLocalTimeSortKey })
        }

        let upcomingToday = activeToday.filter { $0.startLocalTimeSortKey > nowMinutes }
        if let earliestKey = upcomingToday.map(\.startLocalTimeSortKey).min() {
            return .next(upcomingToday.filter { $0.startLocalTimeSortKey == earliestKey })
        }

        // Fix: NEXT must never fall forward into tomorrow — Tomorrow
        // already owns tomorrow's own preview (tomorrowSection), and
        // showing the same activity here too duplicated it on screen.
        // When nothing relevant remains today, the correct result is
        // .empty, not a synthetic "next (tomorrow)" fallback.
        return .empty
    }
}

/// Parent Home UX / Content Contract: the Now/Next surface's own
/// state — carries `TodayActivityRow`s directly (never a new wrapper
/// type), so the UI layer reuses the exact same row-rendering
/// component Today/Tomorrow already use. Visually repeating an
/// activity also present in Today is presentation of the SAME
/// activity identity, not duplicate domain data — no new `Identifiable`
/// conformance/ID is introduced here.
public enum NowNextState {
    case now([TodayActivityRow])
    case next([TodayActivityRow])
    case empty
}
