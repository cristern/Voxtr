import Foundation
import VoxtrCore
import VoxtrCoreContracts

/// Sprint 5.0: thrown by `WeeklyReflectionService`.
public enum WeeklyReflectionServiceError: Error, Equatable {
    case weeklyReflectionAlreadyExists
    case invalidField(String)
}

/// Sprint 5.0 scope only: the domain-level use case for recording and
/// retrieving a weekly reflection. Lives in `VoxtrReflectionDomain`
/// itself (not `VoxtrAppShell`) since it only ever touches Reflection's
/// own entity via `WeeklyReflectionRepository` — same reasoning
/// `PlanningService`/`TrainingService`/`ReflectionService` already
/// established for their own domains. Never queries Planning or
/// Training directly, and never imports either package.
///
/// Naming: the domain entity is `WeeklyReflection` (v1.3 Section 10.3)
/// — this service uses that name throughout rather than introducing a
/// separate "WeeklyReview" concept the model doesn't have.
@MainActor
public final class WeeklyReflectionService {
    private let repository: WeeklyReflectionRepository

    public init(repository: WeeklyReflectionRepository) {
        self.repository = repository
    }

    /// Records a weekly reflection. Rejects a second reflection for the
    /// same athlete and week — the entity itself has no uniqueness
    /// constraint on this pair, but nothing in the domain model
    /// suggests more than one active weekly reflection per athlete per
    /// week is meaningful, and this mirrors the same one-per-pair rule
    /// already established for `ActivityReflection`
    /// (athlete + LoggedActivity) in S4.1.
    public func recordWeeklyReflection(
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
        guard try repository.fetchWeeklyReflection(forAthlete: athleteId, weekStart: weekStart) == nil else {
            throw WeeklyReflectionServiceError.weeklyReflectionAlreadyExists
        }
        try Self.validate(
            overallSatisfaction: overallSatisfaction,
            loadFelt: loadFelt,
            whatWorked: whatWorked,
            whatWasDifficult: whatWasDifficult,
            learning: learning,
            nextWeekConsideration: nextWeekConsideration
        )
        return try repository.insertWeeklyReflection(
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
    }

    public func fetchWeeklyReflection(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyReflection? {
        try repository.fetchWeeklyReflection(forAthlete: athleteId, weekStart: weekStart)
    }

    public func fetchWeeklyReflections(forAthlete athleteId: AthleteId) throws -> [WeeklyReflection] {
        try repository.fetchWeeklyReflections(forAthlete: athleteId)
    }

    /// Mirrors — does not add to — `WeeklyReflection`'s own
    /// `precondition`s (v1.3 Section 10.3: `overallSatisfaction`/
    /// `loadFelt` 1-5, free-text fields 0-1000 characters). The
    /// entity's initializer already enforces these, but only by
    /// crashing the process on violation; checking them here first is
    /// what lets this be a catchable error instead — same pattern
    /// `FamilyOnboardingValidator` and `PlanningService`'s private
    /// `validate()` already established.
    private static func validate(
        overallSatisfaction: Int?,
        loadFelt: Int?,
        whatWorked: String?,
        whatWasDifficult: String?,
        learning: String?,
        nextWeekConsideration: String?
    ) throws {
        for value in [overallSatisfaction, loadFelt] {
            if let value, !(1...5).contains(value) {
                throw WeeklyReflectionServiceError.invalidField("overallSatisfaction/loadFelt must be 1-5")
            }
        }
        for text in [whatWorked, whatWasDifficult, learning, nextWeekConsideration] {
            if let text, text.count > 1000 {
                throw WeeklyReflectionServiceError.invalidField("free-text fields must be 0-1000 characters")
            }
        }
    }
}
