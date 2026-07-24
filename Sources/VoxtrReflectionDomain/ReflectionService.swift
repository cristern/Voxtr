import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// S4.0 scope only: the domain-level use case for recording reflections
/// and parent observations. Lives in `VoxtrReflectionDomain` itself (not
/// `VoxtrAppShell`) since it only ever touches Reflection's own entities
/// via `ReflectionRepository` — same reasoning `PlanningService`/
/// `TrainingService` already established for their own domains.
///
/// Deliberately imports only `VoxtrCore` and `VoxtrCoreContracts` — NOT
/// `VoxtrTrainingDomain`. `LoggedActivityId` is a Core-level typed ID,
/// not a Training type, so linking a reflection to a logged activity by
/// ID never requires that import.
///
/// No visibility or sharing rules are added here beyond what
/// `ActivityReflection`/`ParentObservation`'s own `precondition`s
/// already enforce — the existing product decision that reflections
/// require an explicit, caller-chosen `VisibilityPolicy` (including
/// `.privateToAthlete`) is preserved exactly, not touched.
@MainActor
public final class ReflectionService {
    private let repository: ReflectionRepository

    public init(repository: ReflectionRepository) {
        self.repository = repository
    }

    public func recordActivityReflection(
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
        try repository.insertActivityReflection(
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
    }

    public func recordParentObservation(
        athleteId: AthleteId,
        authorId: ActorId,
        relatedLoggedActivityId: LoggedActivityId? = nil,
        localDate: LocalDate,
        text: String,
        visibility: VisibilityPolicy = .sharedWithGuardians
    ) throws -> ParentObservation {
        try repository.insertParentObservation(
            athleteId: athleteId,
            authorId: authorId,
            relatedLoggedActivityId: relatedLoggedActivityId,
            localDate: localDate,
            text: text,
            visibility: visibility
        )
    }

    public func fetchActivityReflections(forAthlete athleteId: AthleteId) throws -> [ActivityReflection] {
        try repository.fetchActivityReflections(forAthlete: athleteId)
    }

    public func fetchActivityReflections(forLoggedActivity loggedActivityId: LoggedActivityId) throws -> [ActivityReflection] {
        try repository.fetchActivityReflections(forLoggedActivity: loggedActivityId)
    }

    public func fetchParentObservations(forAthlete athleteId: AthleteId) throws -> [ParentObservation] {
        try repository.fetchParentObservations(forAthlete: athleteId)
    }
}
