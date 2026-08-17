import Foundation
import VoxtrCoreContracts
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

    public var title: String {
        switch self {
        case .planned(let row): return row.plannedActivity.title
        case .recurringSuggestion(_, _, _, let suggestion): return suggestion.title
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

    private let activeAthletes: [AthleteProfile]
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let planningService: PlanningService

    /// Fix: previously `tomorrow` through `+14 days` — omitted today
    /// entirely, and went twice as far ahead as the approved contract.
    /// This is a family logistics surface, not Weekly Planning (which
    /// intentionally keeps its own, separate Monday-Sunday model) —
    /// today through 7 calendar days ahead, so e.g. a Sunday view still
    /// shows the coming week rather than only the current calendar
    /// week's final day.
    private static let upcomingDayCount = 7

    public init(
        activeAthletes: [AthleteProfile],
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        planningService: PlanningService
    ) {
        self.activeAthletes = activeAthletes
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.planningService = planningService
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
