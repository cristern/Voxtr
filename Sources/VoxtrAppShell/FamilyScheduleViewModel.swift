import Foundation
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrCalendarPlanningDomain

/// Sprint 1.1, P1: one row in Family Schedule — either a real, planned
/// activity (opens the canonical Activity Detail) or a recurring
/// occurrence that has not yet been materialized into a real
/// `PlannedActivity` (see `PlanningService.deriveSuggestions(forAthlete:
/// from:through:)`'s own doc comment for exactly why this distinction
/// exists). A suggestion has no `PlannedActivityId` yet, so it cannot
/// open Activity Detail — "tapping an occurrence uses the canonical
/// Activity Detail path where the domain model supports it" is
/// satisfied by only offering that navigation for `.planned` rows.
public enum FamilyScheduleRow: Identifiable {
    case planned(FamilyHomeRow)
    case recurringSuggestion(id: String, athleteId: AthleteId, athleteName: String, suggestion: RecurringActivitySuggestion)

    public var id: String {
        switch self {
        case .planned(let row): return row.id
        case .recurringSuggestion(let id, _, _, _): return id
        }
    }

    public var athleteName: String {
        switch self {
        case .planned(let row): return row.athleteName
        case .recurringSuggestion(_, _, let athleteName, _): return athleteName
        }
    }

    /// Sport / Activity Identity domain foundation: resolves primary activity
    /// label following the canonical `Name ?? Sport` rule via `ActivityLabelResolver`.
    @MainActor
    public func primaryActivityLabel(resolver: ActivityLabelResolver = ActivityLabelResolver()) -> String {
        switch self {
        case .planned(let row): return resolver.primaryLabel(for: row.plannedActivity)
        case .recurringSuggestion(_, _, _, let suggestion): return resolver.primaryLabel(for: suggestion)
        }
    }

    @MainActor
    public var title: String {
        primaryActivityLabel()
    }

    public var startLocalTime: LocalTime? {
        switch self {
        case .planned(let row): return row.plannedActivity.startLocalTime
        case .recurringSuggestion(_, _, _, let suggestion): return suggestion.startLocalTime
        }
    }
}

/// Sprint 1 completion package, Part 5. One group of rows for a single
/// upcoming date — the presentation-level grouping Family Schedule
/// needs; not a new persisted concept, just a way to organize the same
/// `PlannedActivity`/`RecurringPlannedActivity` rows by date.
public struct FamilyScheduleDayGroup: Identifiable {
    public let id: String
    public let date: LocalDate
    public let rows: [FamilyScheduleRow]
}

/// Sprint 1 completion package, Part 5, extended in Sprint 1.1 P1 to
/// also include recurring activities: a forward-looking schedule
/// across every active athlete, grouped by date. Deliberately not a
/// calendar grid, per "prefer a simple, maintainable day/date-based
/// schedule... do not introduce month-calendar complexity." Merges
/// real `PlannedActivity` rows with unmaterialized recurring
/// occurrences in the same range — see `FamilyScheduleRow`'s own doc
/// comment for why these are distinct row kinds, not collapsed
/// together. Multiple recurring activities are never collapsed: each
/// occurrence (one per recurring definition per matching date) is its
/// own row, keyed by its own `externalSourceId`.
@MainActor
@Observable
public final class FamilyScheduleViewModel {
    /// Plan/Ahead root round: the smallest read-only summary Family
    /// Schedule needs to show its own calm, contextual "N calendar
    /// events to review" entry point (see `FamilyScheduleView`'s own
    /// doc comment) — computed ENTIRELY from the existing canonical
    /// `CalendarPlanningCoordinationService.fetchSources(forWorkspace:)`/
    /// `fetchReviewQueue(for:)` reads (the SAME calls
    /// `FamilyCalendarSourcesViewModel.refreshSources()` already makes
    /// for its own per-source review counts), never a second persisted
    /// count, shadow state, or heuristic. `actionableSources` carries
    /// only the `ExternalPlanningSource`s that actually have at least
    /// one pending item — used purely to route navigation (straight to
    /// that ONE source's own `CalendarImportReviewView` when there is
    /// exactly one, or to the existing `FamilyCalendarSourcesView` list
    /// when there is more than one); it is never itself business truth.
    public struct CalendarReviewPrompt {
        public let totalPendingCount: Int
        public let actionableSources: [ExternalPlanningSource]

        public init(totalPendingCount: Int, actionableSources: [ExternalPlanningSource]) {
            self.totalPendingCount = totalPendingCount
            self.actionableSources = actionableSources
        }

        /// Calm by Default: no callout at all when there is nothing to
        /// review — this is the default for every existing
        /// `FamilyScheduleViewModel` construction site that does not
        /// opt into the calendar-review feature.
        public static let none = CalendarReviewPrompt(totalPendingCount: 0, actionableSources: [])

        /// The ONE pure aggregation rule this feature uses — extracted
        /// here (rather than left inline in whichever SwiftUI View
        /// constructs the real `provideCalendarReviewPrompt` closure) so
        /// it is directly unit-testable without any SwiftUI view-body
        /// harness. `sources` is expected to already be scoped to ONE
        /// workspace and ALREADY excludes `.disconnected` sources — the
        /// exact contract `CalendarPlanningCoordinationService.fetchSources(forWorkspace:)`
        /// already guarantees at the canonical service boundary (it
        /// calls `fetchAllConnected(forWorkspace:)` internally); this
        /// function does not re-derive disconnected-source handling.
        ///
        /// Lead Review follow-up: `isEnabled` is checked HERE, directly,
        /// not only inferred from an absent/zero `reviewCounts` entry —
        /// defense in depth, so a disabled source can never become
        /// actionable even if the caller's `reviewCounts` is stale or
        /// malformed (e.g. still carries a positive count from before the
        /// source was disabled). `FamilyCalendarSourcesViewModel.refreshSources()`'s
        /// own `isEnabled` short-circuit (never fetching a disabled
        /// source's real count at all) remains the first line of
        /// defense; this is the second.
        public static func from(sources: [ExternalPlanningSource], reviewCounts: [ExternalPlanningSourceId: Int]) -> CalendarReviewPrompt {
            let actionable = sources.filter { source in
                source.isEnabled && (reviewCounts[source.externalPlanningSourceId] ?? 0) > 0
            }
            let total = actionable.reduce(0) { $0 + (reviewCounts[$1.externalPlanningSourceId] ?? 0) }
            return CalendarReviewPrompt(totalPendingCount: total, actionableSources: actionable)
        }
    }

    public private(set) var dayGroups: [FamilyScheduleDayGroup] = []
    public private(set) var errorMessage: String?
    /// Refreshed at the START of every `loadSchedule(referenceDate:calendar:)`
    /// call, from `provideCalendarReviewPrompt` below — never stored as
    /// a second, competing source of truth between loads, matching
    /// `provideActiveAthletes`'s own established freshness contract.
    public private(set) var calendarReviewPrompt = CalendarReviewPrompt.none

    /// Active-roster freshness fix (runtime/state audit): previously a
    /// frozen `let activeAthletes: [AthleteProfile]`, captured once at
    /// construction — correct only for the moment Family Schedule was
    /// pushed, and permanently stale for the rest of that screen
    /// instance's life if an athlete was archived or reactivated while
    /// it remained the visible/pushed content (e.g. a tab switch away
    /// and back with no pop). Replaced with an injected LIVE provider,
    /// the same dependency-injection shape `resolveAthleteColor` below
    /// already establishes for an analogous cross-cutting concern this
    /// ViewModel deliberately does not own the source of truth for.
    /// `loadSchedule(referenceDate:calendar:)` calls this fresh at the
    /// START of every load — never stored as a second, competing roster
    /// state — so each load always reflects the CURRENT canonical
    /// `AthleteProfile.isArchived` state, not a construction-time
    /// snapshot.
    private let provideActiveAthletes: () -> [AthleteProfile]
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let planningService: PlanningService
    /// Design Foundation extension round: Family Schedule is a
    /// shared/multi-athlete surface, so its rows need the same resolved
    /// Athlete Color Family Home already shows — but this ViewModel
    /// deliberately does not hold its own `AthleteRepository` or repeat
    /// `FamilyHomeViewModel.loadAthleteColors()`'s own cache/fetch
    /// logic. Family Schedule has two production entry points —
    /// `FamilyHomeContentView`'s "View upcoming schedule" destination
    /// (which injects the already-refreshed `FamilyHomeViewModel`'s own
    /// `resolvedAthleteColor(for:)`) and the Plan tab's
    /// `ParentPlanTabView` (which has no `FamilyHomeViewModel` in scope,
    /// so it injects its own small resolver backed by the SAME canonical
    /// `AthleteColor.resolved(forAthlete:using:)` helper Family Home
    /// itself now delegates to) — both resolve through that one shared
    /// implementation, never a second, locally-invented mapping.
    /// Defaulted to `AthleteColor.forAthleteId` (the stable,
    /// repository-free fallback) so every pre-existing test construction
    /// site — none of which supplies a resolver — keeps compiling and
    /// keeps its existing deterministic behaviour unchanged.
    private let resolveAthleteColor: (AthleteId) -> AthleteColor

    /// Plan/Ahead root round: same injected-closure shape as
    /// `resolveAthleteColor` above, for the same reason — this
    /// ViewModel deliberately does not own `CalendarPlanningCoordinationService`
    /// or `WorkspaceId` itself, since calendar source ownership is not
    /// this screen's own concern (see `ExternalPlanningSource`'s own
    /// doc comment: a source is family-owned, not schedule-owned).
    /// Defaulted to always return `.none` so every pre-existing
    /// `FamilyScheduleViewModel` construction site — none of which
    /// supplies this — keeps compiling and keeps showing no callout,
    /// unchanged.
    private let provideCalendarReviewPrompt: () -> CalendarReviewPrompt

    /// Fix: previously `tomorrow` through `+14 days` — omitted today
    /// entirely, and went twice as far ahead as the approved contract.
    /// This is a family logistics surface, not Weekly Planning (which
    /// intentionally keeps its own, separate Monday-Sunday model) —
    /// today through 7 calendar days ahead, so e.g. a Sunday view still
    /// shows the coming week rather than only the current calendar
    /// week's final day.
    private static let upcomingDayCount = 7

    public init(
        provideActiveAthletes: @escaping () -> [AthleteProfile],
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        planningService: PlanningService,
        resolveAthleteColor: @escaping (AthleteId) -> AthleteColor = AthleteColor.forAthleteId,
        provideCalendarReviewPrompt: @escaping () -> CalendarReviewPrompt = { .none }
    ) {
        self.provideActiveAthletes = provideActiveAthletes
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.planningService = planningService
        self.resolveAthleteColor = resolveAthleteColor
        self.provideCalendarReviewPrompt = provideCalendarReviewPrompt
    }

    /// The one function every Family Schedule row calls for an
    /// athlete's colour — mirrors `FamilyHomeViewModel.resolvedAthleteColor(for:)`'s
    /// own role on that screen, just backed by an injected resolver
    /// here instead of a locally-owned cache.
    public func resolvedAthleteColor(for athleteId: AthleteId) -> AthleteColor {
        resolveAthleteColor(athleteId)
    }

    public func loadSchedule() {
        loadSchedule(referenceDate: .now, calendar: .current)
    }

    /// Maintainability fix, same pattern as `FamilyHomeViewModel.nowNextState(referenceDate:calendar:)`:
    /// the underlying logic, with an injectable `referenceDate` — exists
    /// so tests can construct a genuinely deterministic scenario (e.g. a
    /// fixed Sunday) rather than depending on wall-clock `.now`, whose
    /// weekday varies by whenever the test happens to run. `loadSchedule()`
    /// above is the one public, unchanged API every existing caller
    /// already uses — this defaults to the exact same `.now`/`.current`
    /// it always used, so no existing behavior changes.
    func loadSchedule(referenceDate: Date, calendar: Calendar) {
        errorMessage = nil
        // Plan/Ahead root round: refreshed fresh at the START of every
        // load, exactly like `activeAthletes` below — never held as a
        // second, competing source of truth between loads.
        calendarReviewPrompt = provideCalendarReviewPrompt()
        // Active-roster freshness fix: obtained fresh at the START of
        // this load, from the live provider — never the construction-time
        // value this ViewModel no longer stores. Used consistently as a
        // local snapshot for the rest of THIS load only; never held as a
        // second, competing source of truth between loads.
        let activeAthletes = provideActiveAthletes()
        guard let endDate = calendar.date(byAdding: .day, value: Self.upcomingDayCount, to: referenceDate) else {
            dayGroups = []
            return
        }
        let start = Self.localDate(from: referenceDate, calendar: calendar)
        let end = Self.localDate(from: endDate, calendar: calendar)

        var merged: [FamilyScheduleRow] = []
        var anyFailed = false
        for athlete in activeAthletes {
            do {
                let completions = try trainingPlanningCoordinationService.plannedActivitiesWithCompletion(
                    forAthlete: athlete.athleteId, from: start, through: end
                )
                merged.append(contentsOf: completions.map { completion in
                    .planned(FamilyHomeRow(
                        id: completion.plannedActivity.id.uuidString,
                        athleteId: athlete.athleteId,
                        athleteName: athlete.givenName,
                        plannedActivity: completion.plannedActivity,
                        isCompleted: completion.isCompleted,
                        loggedActivity: completion.loggedActivity
                    ))
                })
            } catch {
                anyFailed = true
            }

            do {
                let suggestions = try planningService.deriveSuggestions(
                    forAthlete: athlete.athleteId, from: start, through: end
                )
                merged.append(contentsOf: suggestions.map { suggestion in
                    .recurringSuggestion(
                        id: suggestion.id,
                        athleteId: athlete.athleteId,
                        athleteName: athlete.givenName,
                        suggestion: suggestion
                    )
                })
            } catch {
                anyFailed = true
            }
        }

        // Group by date, then sort each day's rows chronologically by
        // start time (no-start-time rows sorted after timed ones —
        // deterministic, same convention as Family Home's own today
        // list), and sort the groups themselves by date.
        let grouped = Dictionary(grouping: merged) { row -> LocalDate in
            switch row {
            case .planned(let familyRow): return familyRow.plannedActivity.localDate
            case .recurringSuggestion(_, _, _, let suggestion): return suggestion.occurrenceDate
            }
        }
        dayGroups = grouped.keys.sorted().map { date in
            let rowsForDate = grouped[date] ?? []
            let sortedRows = rowsForDate.sorted { lhs, rhs in
                Self.timeSortKey(lhs) < Self.timeSortKey(rhs)
            }
            return FamilyScheduleDayGroup(id: date.isoString, date: date, rows: sortedRows)
        }

        if anyFailed && dayGroups.isEmpty {
            errorMessage = "Could not load the upcoming schedule."
        }
    }

    private static func timeSortKey(_ row: FamilyScheduleRow) -> Int {
        guard let time = row.startLocalTime else { return Int.max }
        return time.hour * 60 + time.minute
    }

    private static func localDate(from date: Date, calendar: Calendar) -> LocalDate {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }
}
