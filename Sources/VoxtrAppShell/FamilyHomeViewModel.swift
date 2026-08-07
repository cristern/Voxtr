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
}

/// The bottom-of-Home reflection reminder (Part 5) — deliberately shows
/// one athlete's reflection, not every athlete's. With Home now
/// family-first and no global "selected athlete," there is no existing
/// concept of which athlete a reminder like this should represent;
/// showing the first active athlete's (the same deterministic
/// ordering `FamilyRestorationService` already establishes) is a
/// disclosed simplification, not a hidden assumption — a future work
/// package may want this per-athlete or rotating.
public enum ReflectionReminderState {
    case loading
    case recorded(athleteName: String, whatWentWell: String?, whatCouldImprove: String?)
    case none(athleteName: String)
    case unavailable
}

@MainActor
@Observable
public final class FamilyHomeViewModel {
    public private(set) var rows: [FamilyHomeRow] = []
    public private(set) var reflectionState: ReflectionReminderState = .loading
    public private(set) var errorMessage: String?

    private let activeAthletes: [AthleteProfile]
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService

    public init(
        activeAthletes: [AthleteProfile],
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReflectionService: WeeklyReflectionService
    ) {
        self.activeAthletes = activeAthletes
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
    }

    /// Calls the already-existing, per-athlete
    /// `todaysPlannedActivitiesWithCompletion(forAthlete:)` once per
    /// active athlete and merges the results — no new persistence
    /// query, no schema change; this is a pure application-layer
    /// aggregation over an already-existing capability.
    public func loadHome() {
        errorMessage = nil
        var merged: [FamilyHomeRow] = []
        var anyFailed = false
        for athlete in activeAthletes {
            do {
                let completions = try trainingPlanningCoordinationService.todaysPlannedActivitiesWithCompletion(forAthlete: athlete.athleteId)
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
                // One athlete's failure must never block the others —
                // same principle HomeDashboardViewModel's own two
                // independent load states already establish.
                anyFailed = true
            }
        }
        rows = Self.sorted(merged)
        if anyFailed && rows.isEmpty {
            errorMessage = "Could not load today's activities."
        }
    }

    /// Not completed first (sorted chronologically by start time, with
    /// no-start-time activities — e.g. "Strength · Ready to log" —
    /// sorted after timed ones within that group), then completed
    /// activities after, also chronological.
    private static func sorted(_ rows: [FamilyHomeRow]) -> [FamilyHomeRow] {
        func timeSortKey(_ row: FamilyHomeRow) -> Int {
            guard let time = row.plannedActivity.startLocalTime else { return Int.max }
            return time.hour * 60 + time.minute
        }
        let notCompleted = rows.filter { !$0.isCompleted }.sorted { timeSortKey($0) < timeSortKey($1) }
        let completed = rows.filter { $0.isCompleted }.sorted { timeSortKey($0) < timeSortKey($1) }
        return notCompleted + completed
    }

    public func loadReflectionReminder() {
        guard let athlete = activeAthletes.first else {
            reflectionState = .unavailable
            return
        }
        do {
            let weekStart = TrainingPlanningCoordinationService.weekStart()
            if let reflection = try weeklyReflectionService.fetchWeeklyReflection(forAthlete: athlete.athleteId, weekStart: weekStart) {
                reflectionState = .recorded(
                    athleteName: athlete.givenName,
                    whatWentWell: reflection.whatWorked,
                    whatCouldImprove: reflection.whatWasDifficult
                )
            } else {
                reflectionState = .none(athleteName: athlete.givenName)
            }
        } catch {
            reflectionState = .unavailable
        }
    }
}
