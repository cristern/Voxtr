import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// S2.1 scope only: one use case — get-or-create a draft `WeekPlan` for
/// a given athlete and calendar week. No commit-week behavior, no
/// `PlannedActivity` editing, no UI. Lives in `VoxtrPlanningDomain`
/// itself (not `VoxtrAppShell`) since it only ever touches Planning's
/// own entity via `PlanningRepository` — no cross-domain concern here.
@MainActor
public final class PlanningService {
    private let repository: PlanningRepository

    public init(repository: PlanningRepository) {
        self.repository = repository
    }

    /// Returns the existing draft `WeekPlan` for this athlete/week if
    /// one already exists; otherwise creates one and returns it. Never
    /// creates a second `WeekPlan` for the same athlete/week — the
    /// fetch-then-insert-if-absent check below is this use case's only
    /// business rule, matching the approved scope exactly ("one plan
    /// per athlete/week"), not inventing anything further. Status stays
    /// at `WeekPlan`'s own default (`.draft`) and revision at its own
    /// default (`1`) — this method sets neither explicitly, so any
    /// future change to those defaults is the entity's decision, not
    /// duplicated here.
    public func getOrCreateWeekPlan(athleteId: AthleteId, weekStart: LocalDate) throws -> WeekPlan {
        if let existing = try repository.fetchWeekPlan(forAthlete: athleteId, weekStart: weekStart) {
            return existing
        }
        return try repository.insertWeekPlan(athleteId: athleteId, weekStart: weekStart)
    }
}
