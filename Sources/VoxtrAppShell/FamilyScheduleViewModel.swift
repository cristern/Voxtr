import Foundation
import VoxtrCoreContracts
import VoxtrCoreReferenceData
import VoxtrAthleteDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain

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

    /// Sport / Activity Identity domain foundation, Blocker B fix
    /// (review correction): routes through the one shared
    /// `ActivityLabelResolver` — see that type's own doc comment for
    /// the exact `name ?? Sport display name` contract. A prior version
    /// of this property fell back to `?? ""`, which review correctly
    /// rejected.
    public func primaryLabel(resolveSport: (SportId) -> Sport?) -> String {
        switch self {
        case .planned(let row):
            return ActivityLabelResolver.primaryLabel(
                name: row.plannedActivity.title,
                sportId: row.plannedActivity.sportId.map(SportId.init(rawValue:)),
                resolveSport: resolveSport
            )
        case .recurringSuggestion(_, _, _, let suggestion):
            return ActivityLabelResolver.primaryLabel(name: suggestion.title, sportId: suggestion.sportId, resolveSport: resolveSport)
        }
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
    public private(set) var dayGroups: [FamilyScheduleDayGroup] = []
    public private(set) var errorMessage: String?

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

    /// Sport / Activity Identity domain foundation, Blocker B fix:
    /// mirrors `resolveAthleteColor` immediately above — the same
    /// injected-closure shape for the same reason (a shared, cross-
    /// cutting reference-data concern this ViewModel doesn't own the
    /// source of truth for). Defaulted to `{ _ in nil }` so every
    /// pre-existing construction site keeps compiling; `primaryLabel(for:)`
    /// still resolves to `ActivityLabelResolver`'s own honest
    /// missing-reference fallback in that case, never a blank string.
    private let resolveSport: (SportId) -> Sport?

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
        resolveSport: @escaping (SportId) -> Sport? = { _ in nil }
    ) {
        self.provideActiveAthletes = provideActiveAthletes
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.planningService = planningService
        self.resolveAthleteColor = resolveAthleteColor
        self.resolveSport = resolveSport
    }

    /// The one function every Family Schedule row calls for an
    /// athlete's colour — mirrors `FamilyHomeViewModel.resolvedAthleteColor(for:)`'s
    /// own role on that screen, just backed by an injected resolver
    /// here instead of a locally-owned cache.
    public func resolvedAthleteColor(for athleteId: AthleteId) -> AthleteColor {
        resolveAthleteColor(athleteId)
    }

    /// The one function every Family Schedule row calls for its primary
    /// label — mirrors `resolvedAthleteColor(for:)` immediately above.
    public func primaryLabel(for row: FamilyScheduleRow) -> String {
        row.primaryLabel(resolveSport: resolveSport)
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
