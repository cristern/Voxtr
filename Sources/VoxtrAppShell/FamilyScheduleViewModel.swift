import Foundation
import VoxtrCoreContracts
import VoxtrAthleteDomain
import VoxtrTrainingDomain

/// Sprint 1 completion package, Part 5. One group of rows for a single
/// upcoming date — the presentation-level grouping Family Schedule
/// needs; not a new persisted concept, just a way to organize the same
/// `PlannedActivity` rows `FamilyHomeRow` already represents by date.
public struct FamilyScheduleDayGroup: Identifiable {
    public let id: String
    public let date: LocalDate
    public let rows: [FamilyHomeRow]
}

/// Sprint 1 completion package, Part 5: a forward-looking schedule
/// across every active athlete, grouped by date. Deliberately not a
/// calendar grid — a simple, deterministic day-by-day list, matching
/// "prefer a simple, maintainable day/date-based schedule... do not
/// introduce month-calendar complexity." Reuses
/// `TrainingPlanningCoordinationService`'s existing date-range query
/// (added for this same package) — no new persisted model, no
/// duplicated activities.
@MainActor
@Observable
public final class FamilyScheduleViewModel {
    public private(set) var dayGroups: [FamilyScheduleDayGroup] = []
    public private(set) var errorMessage: String?

    private let activeAthletes: [AthleteProfile]
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService

    /// How many upcoming days this first version shows — deliberately
    /// small and fixed rather than open-ended paging, matching "this is
    /// NOT intended to become a generic calendar replacement."
    private static let upcomingDayCount = 14

    public init(
        activeAthletes: [AthleteProfile],
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    ) {
        self.activeAthletes = activeAthletes
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
    }

    public func loadSchedule() {
        errorMessage = nil
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .day, value: 1, to: .now),
              let endDate = calendar.date(byAdding: .day, value: Self.upcomingDayCount, to: .now) else {
            dayGroups = []
            return
        }
        let start = Self.localDate(from: startDate, calendar: calendar)
        let end = Self.localDate(from: endDate, calendar: calendar)

        var merged: [FamilyHomeRow] = []
        var anyFailed = false
        for athlete in activeAthletes {
            do {
                let completions = try trainingPlanningCoordinationService.plannedActivitiesWithCompletion(
                    forAthlete: athlete.athleteId, from: start, through: end
                )
                merged.append(contentsOf: completions.map { completion in
                    FamilyHomeRow(
                        id: completion.plannedActivity.id.uuidString,
                        athleteId: athlete.athleteId,
                        athleteName: athlete.givenName,
                        plannedActivity: completion.plannedActivity,
                        isCompleted: completion.isCompleted
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
        let grouped = Dictionary(grouping: merged) { $0.plannedActivity.localDate }
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

    private static func timeSortKey(_ row: FamilyHomeRow) -> Int {
        guard let time = row.plannedActivity.startLocalTime else { return Int.max }
        return time.hour * 60 + time.minute
    }

    private static func localDate(from date: Date, calendar: Calendar) -> LocalDate {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }
}
