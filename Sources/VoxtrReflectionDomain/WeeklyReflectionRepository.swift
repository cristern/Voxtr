import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// Sprint 5.0 scope only: insert and fetch `WeeklyReflection`. No
/// calculations, no trends, no UI — those are separate, later work.
/// `DailyStatus` and `MonthlyReflection` are untouched — nothing in
/// this story creates or persists them.
///
/// No `#Predicate` (established project lesson): every fetch here
/// fetches then filters in plain Swift instead.
///
/// No cross-domain SwiftData relationships and no cross-domain
/// imports — `athleteId` is a plain typed-ID-backed `UUID` field, the
/// same pattern every other repository in this project already uses.
/// This repository never queries Planning or Training.
@MainActor
public final class WeeklyReflectionRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Inserts a `WeeklyReflection`. `visibility` has no default,
    /// matching the entity's own initializer — the existing product
    /// decision that reflections require an explicit, caller-chosen
    /// `VisibilityPolicy` is preserved, not changed (same rule already
    /// established for `ActivityReflection`).
    public func insertWeeklyReflection(
        athleteId: AthleteId,
        weekStart: LocalDate,
        authorId: ActorId,
        overallSatisfaction: Int? = nil,
        loadFelt: Int? = nil,
        whatWorked: String? = nil,
        whatWasDifficult: String? = nil,
        learning: String? = nil,
        nextWeekConsideration: String? = nil,
        visibility: VisibilityPolicy
    ) throws -> WeeklyReflection {
        let reflection = WeeklyReflection(
            athleteId: athleteId,
            weekStart: weekStart,
            authorId: authorId,
            overallSatisfaction: overallSatisfaction,
            loadFelt: loadFelt,
            whatWorked: whatWorked,
            whatWasDifficult: whatWasDifficult,
            learning: learning,
            nextWeekConsideration: nextWeekConsideration,
            visibility: visibility
        )
        modelContext.insert(reflection)
        try modelContext.save()
        return reflection
    }

    public func fetchWeeklyReflection(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyReflection? {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<WeeklyReflection>())
        return all.first { $0.athleteId == rawAthleteId && $0.weekStart == weekStart }
    }

    /// Ordered deterministically by `weekStart`, then `id` as a stable
    /// tiebreaker — same pattern every other repository in this project
    /// already uses.
    public func fetchWeeklyReflections(forAthlete athleteId: AthleteId) throws -> [WeeklyReflection] {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<WeeklyReflection>())
        return all
            .filter { $0.athleteId == rawAthleteId }
            .sorted { lhs, rhs in
                if lhs.weekStart != rhs.weekStart {
                    return lhs.weekStart < rhs.weekStart
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// Sprint 5.2: updates an already-fetched `WeeklyReflection` in
    /// place — mirrors the mutation shape `PlanningRepository`'s
    /// `save()`-after-in-place-edit pattern already uses for
    /// `PlannedActivity`. `athleteId`/`weekStart`/`authorId` are not
    /// editable through this method — identity/attribution fields, same
    /// principle `PlanningService.editPlannedActivity` already applies
    /// to `id`/`weekPlanId`/`athleteId`/`createdAt`.
    public func updateWeeklyReflection(
        _ reflection: WeeklyReflection,
        overallSatisfaction: Int?,
        loadFelt: Int?,
        whatWorked: String?,
        whatWasDifficult: String?,
        learning: String?,
        nextWeekConsideration: String?
    ) throws -> WeeklyReflection {
        reflection.overallSatisfaction = overallSatisfaction
        reflection.loadFelt = loadFelt
        reflection.whatWorked = whatWorked
        reflection.whatWasDifficult = whatWasDifficult
        reflection.learning = learning
        reflection.nextWeekConsideration = nextWeekConsideration
        reflection.updatedAt = .now
        try modelContext.save()
        return reflection
    }
}
