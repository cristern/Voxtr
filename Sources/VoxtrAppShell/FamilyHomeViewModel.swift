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

/// Sprint 1 (Vǫxtr Parent continuation), Part 3: one reflection
/// reminder per active athlete, each carrying its own explicit
/// `athleteId` — replaces the previous single "first active athlete's
/// reflection" reminder, which relied on array ordering rather than
/// identity. With multiple athletes, a parent must be able to tell
/// which athlete each reminder is about, and navigate to that specific
/// athlete's reflection, not whichever athlete happened to be first.
public struct AthleteReflectionReminder: Identifiable {
    public let id: String
    public let athleteId: AthleteId
    public let athleteName: String
    public let reflectionExists: Bool
    public let whatWentWell: String?
    public let whatCouldImprove: String?
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
    public private(set) var rows: [FamilyHomeRow] = []
    public private(set) var reflectionReminders: [AthleteReflectionReminder] = []
    public private(set) var errorMessage: String?

    public private(set) var tomorrowRows: [FamilyHomeRow] = []
    private let athleteRepository: AthleteRepository
    private let trainingPlanningCoordinationService: TrainingPlanningCoordinationService
    private let weeklyReflectionService: WeeklyReflectionService

    public init(
        activeAthletes: [AthleteProfile],
        workspaceId: WorkspaceId,
        athleteRepository: AthleteRepository,
        trainingPlanningCoordinationService: TrainingPlanningCoordinationService,
        weeklyReflectionService: WeeklyReflectionService
    ) {
        self.activeAthletes = activeAthletes
        self.workspaceId = workspaceId
        self.athleteRepository = athleteRepository
        self.trainingPlanningCoordinationService = trainingPlanningCoordinationService
        self.weeklyReflectionService = weeklyReflectionService
    }

    /// The single entry point the view calls on appear — refreshes the
    /// athlete roster first, then loads everything that depends on it,
    /// in that order, so today's schedule and the reflection reminder
    /// never operate against a stale roster.
    public func refresh() {
        refreshActiveAthletes()
        loadHome()
        loadTomorrow()
        loadReflectionReminders()
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

        var merged: [FamilyHomeRow] = []
        for athlete in activeAthletes {
            let completions = (try? trainingPlanningCoordinationService.plannedActivitiesWithCompletion(
                forAthlete: athlete.athleteId, on: tomorrowDate
            )) ?? []
            merged.append(contentsOf: completions.map { completion in
                FamilyHomeRow(
                    id: completion.plannedActivity.id.uuidString,
                    athleteId: athlete.athleteId,
                    athleteName: athlete.givenName,
                    plannedActivity: completion.plannedActivity,
                    isCompleted: completion.isCompleted
                )
            })
        }
        tomorrowRows = Self.sorted(merged)
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

    /// Sprint 1 (Vǫxtr Parent continuation), Part 3: one reminder per
    /// active athlete — never just `activeAthletes.first`. A failure
    /// fetching one athlete's reflection doesn't block the others,
    /// same independence principle `loadHome()` above already
    /// establishes.
    public func loadReflectionReminders() {
        let weekStart = TrainingPlanningCoordinationService.weekStart()
        reflectionReminders = activeAthletes.compactMap { athlete in
            let reflection = try? weeklyReflectionService.fetchWeeklyReflection(forAthlete: athlete.athleteId, weekStart: weekStart)
            let resolved = (reflection ?? nil)
            return AthleteReflectionReminder(
                id: athlete.athleteId.rawValue.uuidString,
                athleteId: athlete.athleteId,
                athleteName: athlete.givenName,
                reflectionExists: resolved != nil,
                whatWentWell: resolved?.whatWorked,
                whatCouldImprove: resolved?.whatWasDifficult
            )
        }
    }
}
