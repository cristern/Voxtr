import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// S4.0 scope only: insert and fetch `ActivityReflection` and
/// `ParentObservation`. `DailyStatus`, `WeeklyReflection`,
/// `MonthlyReflection` are untouched — nothing in this story creates or
/// queries them.
///
/// No `#Predicate` (established project lesson): every fetch here
/// fetches then filters in plain Swift instead.
///
/// No cross-domain SwiftData relationships — `loggedActivityId` is a
/// plain typed-ID-backed `UUID` field (same pattern every other
/// repository already uses), not a `@Relationship` to Training's
/// entity. This repository never imports `VoxtrTrainingDomain` —
/// `LoggedActivityId` is a Core-level typed ID, not a Training type.
@MainActor
public final class ReflectionRepository {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Inserts an `ActivityReflection` linked to a `LoggedActivity` by
    /// typed ID. `visibility` has no default here, matching the
    /// entity's own initializer — the current product decision that the
    /// caller must always choose visibility explicitly (including
    /// `.privateToAthlete`) is preserved, not changed.
    public func insertActivityReflection(
        athleteId: AthleteId,
        loggedActivityId: LoggedActivityId,
        authorId: ActorId,
        visibility: VisibilityPolicy,
        bodyFeeling: Int? = nil,
        energy: Int? = nil,
        satisfaction: Int? = nil,
        perceivedExertion: Int? = nil,
        mostSatisfiedWith: String? = nil,
        learningNote: String? = nil,
        nextTimeNote: String? = nil
    ) throws -> ActivityReflection {
        let reflection = ActivityReflection(
            athleteId: athleteId,
            loggedActivityId: loggedActivityId,
            authorId: authorId,
            visibility: visibility,
            bodyFeeling: bodyFeeling,
            energy: energy,
            satisfaction: satisfaction,
            perceivedExertion: perceivedExertion,
            mostSatisfiedWith: mostSatisfiedWith,
            learningNote: learningNote,
            nextTimeNote: nextTimeNote
        )
        modelContext.insert(reflection)
        try modelContext.save()
        return reflection
    }

    /// Inserts a `ParentObservation`, linked to the athlete and
    /// optionally to a `LoggedActivity` by typed ID. `visibility`
    /// defaults to `.sharedWithGuardians`, matching the entity's own
    /// default — not a new rule.
    public func insertParentObservation(
        athleteId: AthleteId,
        authorId: ActorId,
        relatedLoggedActivityId: LoggedActivityId? = nil,
        localDate: LocalDate,
        text: String,
        visibility: VisibilityPolicy = .sharedWithGuardians
    ) throws -> ParentObservation {
        let observation = ParentObservation(
            athleteId: athleteId,
            authorId: authorId,
            relatedLoggedActivityId: relatedLoggedActivityId,
            localDate: localDate,
            text: text,
            visibility: visibility
        )
        modelContext.insert(observation)
        try modelContext.save()
        return observation
    }

    /// Ordered deterministically by `createdAt`, then `id` as a stable
    /// tiebreaker.
    public func fetchActivityReflections(forAthlete athleteId: AthleteId) throws -> [ActivityReflection] {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<ActivityReflection>())
        return all
            .filter { $0.athleteId == rawAthleteId }
            .sorted(by: Self.reflectionOrder)
    }

    /// Same ordering as above, scoped to one `LoggedActivity`.
    public func fetchActivityReflections(forLoggedActivity loggedActivityId: LoggedActivityId) throws -> [ActivityReflection] {
        let rawLoggedActivityId = loggedActivityId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<ActivityReflection>())
        return all
            .filter { $0.loggedActivityId == rawLoggedActivityId }
            .sorted(by: Self.reflectionOrder)
    }

    /// Ordered deterministically by `localDate`, then `id` — same
    /// pattern `PlanningRepository`/`TrainingRepository` already use.
    public func fetchParentObservations(forAthlete athleteId: AthleteId) throws -> [ParentObservation] {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<ParentObservation>())
        return all
            .filter { $0.athleteId == rawAthleteId }
            .sorted(by: Self.observationOrder)
    }

    private static func reflectionOrder(_ lhs: ActivityReflection, _ rhs: ActivityReflection) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func observationOrder(_ lhs: ParentObservation, _ rhs: ParentObservation) -> Bool {
        if lhs.localDate != rhs.localDate {
            return lhs.localDate < rhs.localDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
