import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts

/// S4.1: thrown by `ReflectionService.recordActivityReflection` when
/// one already exists for the same athlete and `LoggedActivity`.
///
/// VX-022 (Session Form): `.invalidField` is thrown when a numeric
/// field would violate `ActivityReflection`'s own `precondition`s
/// (bodyFeeling/energy/satisfaction 1-5, perceivedExertion 1-10) —
/// checked here first so out-of-range input is a catchable error
/// instead of a process crash, the same pattern
/// `WeeklyReflectionServiceError.invalidField` already established for
/// `WeeklyReflection`'s own equivalent fields.
public enum ReflectionServiceError: Error, Equatable {
    case activityReflectionAlreadyExists
    case invalidField(String)
    /// Planned/Logged Activity lifecycle consistency cleanup: thrown by
    /// `updateActivityReflection` when no `ActivityReflection` exists
    /// for the given id, or exists but belongs to a different athlete —
    /// athlete isolation, never inferred from title/date.
    case activityReflectionNotFound
    /// VX-023 (Sleep V1): thrown by `recordSleep` when `localDate` is
    /// after the caller-supplied `today` — "future `LocalDate` must be
    /// rejected." Historical dates (including today itself) are always
    /// allowed.
    case futureDateNotAllowed
}

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
        // S4.1: reject a second reflection for the same athlete and
        // LoggedActivity — checked before any insert is attempted.
        // Checking both fields (not just loggedActivityId alone) is a
        // literal, defensive match to "the same athlete and
        // LoggedActivity," even though a LoggedActivity already belongs
        // to exactly one athlete in practice.
        let existing = try repository.fetchActivityReflections(forLoggedActivity: loggedActivityId)
        guard !existing.contains(where: { $0.athleteId == athleteId.rawValue }) else {
            throw ReflectionServiceError.activityReflectionAlreadyExists
        }
        try Self.validate(bodyFeeling: bodyFeeling, energy: energy, satisfaction: satisfaction, perceivedExertion: perceivedExertion)
        return try repository.insertActivityReflection(
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

    /// S4.1: convenience for the common case — after this story's
    /// duplicate-reflection rule, there's at most one reflection per
    /// `LoggedActivity`, so callers that only care about "the"
    /// reflection (not a list) don't need to unwrap an array
    /// themselves. Not a new query capability — reuses the existing
    /// deterministically-ordered fetch above and takes its first
    /// result.
    public func fetchActivityReflection(forLoggedActivity loggedActivityId: LoggedActivityId) throws -> ActivityReflection? {
        try repository.fetchActivityReflections(forLoggedActivity: loggedActivityId).first
    }

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity -> RPE + Form): corrects the Form value
    /// (`bodyFeeling`) already recorded on an existing
    /// `ActivityReflection`. Athlete-scoped, same isolation guarantee
    /// every other athlete-scoped method here already provides. Never
    /// creates an `ActivityReflection` — `recordActivityReflection`
    /// remains the only way one comes into existence; a legacy logged
    /// activity with no reflection yet is the caller's job to detect
    /// (via `fetchActivityReflection(forLoggedActivity:)`) and route to
    /// `recordActivityReflection` instead, never fabricated here.
    @discardableResult
    public func updateActivityReflection(
        _ reflectionId: ReflectionId,
        athleteId: AthleteId,
        bodyFeeling: Int?
    ) throws -> ActivityReflection {
        guard let reflection = try repository.fetchActivityReflection(byId: reflectionId),
              reflection.athleteId == athleteId.rawValue else {
            throw ReflectionServiceError.activityReflectionNotFound
        }
        if let bodyFeeling, !(1...5).contains(bodyFeeling) {
            throw ReflectionServiceError.invalidField("bodyFeeling must be 1-5")
        }
        try repository.updateActivityReflection(reflection, bodyFeeling: bodyFeeling)
        return reflection
    }

    public func deleteActivityReflection(
        _ reflectionId: ReflectionId,
        athleteId: AthleteId
    ) throws {
        guard let reflection = try repository.fetchActivityReflection(byId: reflectionId),
              reflection.athleteId == athleteId.rawValue else {
            throw ReflectionServiceError.activityReflectionNotFound
        }
        try repository.deleteActivityReflection(reflection)
    }

    public func stageDeleteActivityReflection(
        _ reflectionId: ReflectionId,
        athleteId: AthleteId
    ) throws {
        guard let reflection = try repository.fetchActivityReflection(byId: reflectionId),
              reflection.athleteId == athleteId.rawValue else {
            throw ReflectionServiceError.activityReflectionNotFound
        }
        repository.stageDeleteActivityReflection(reflection)
    }

    public func uses(modelContext: ModelContext) -> Bool {
        repository.uses(modelContext: modelContext)
    }

    public func fetchParentObservations(forAthlete athleteId: AthleteId) throws -> [ParentObservation] {
        try repository.fetchParentObservations(forAthlete: athleteId)
    }

    /// VX-023 (Sleep V1): the canonical Sleep write path — "if a
    /// `DailyStatus` for that athlete/date already exists for another
    /// wellbeing field, UPDATE the same `DailyStatus`; if Sleep is the
    /// first signal for that athlete/date, create it through this
    /// Reflection-domain path" (`ReflectionRepository.upsertSleepQuality`
    /// implements the actual update-vs-create branch). `sleepQuality`
    /// 1-5 is checked here first so an out-of-range value (0, 6, ...) is
    /// a catchable error rather than `DailyStatus.init`'s own
    /// `precondition` crash — same reasoning `validate(bodyFeeling:...)`
    /// already established below for `ActivityReflection`.
    ///
    /// `today` is an injected `LocalDate`, not computed here — this
    /// domain package has no `Calendar`/`Date`-to-`LocalDate` resolution
    /// of its own (that lives in `VoxtrAppShell`, e.g.
    /// `TrainingPlanningCoordinationService.today(referenceDate:calendar:)`).
    /// Callers (`SleepCoordinationService`) resolve "today" once via
    /// that existing mechanism and pass it down, keeping this method
    /// fully deterministic for tests with no `Date.now` dependency.
    ///
    /// `visibility` defaults to `.sharedWithGuardians` — the same
    /// family-first V1 default already established in this exact
    /// package (`insertParentObservation`) and in
    /// `TrainingReflectionCoordinationService.logActivity`'s
    /// `sessionFormVisibility` — `DailyStatus.init` itself has no
    /// default, so this is where that product default is applied.
    public func recordSleep(
        athleteId: AthleteId,
        localDate: LocalDate,
        sleepQuality: Int,
        visibility: VisibilityPolicy = .sharedWithGuardians,
        today: LocalDate
    ) throws -> DailyStatus {
        guard (1...5).contains(sleepQuality) else {
            throw ReflectionServiceError.invalidField("sleepQuality must be 1-5")
        }
        guard localDate <= today else {
            throw ReflectionServiceError.futureDateNotAllowed
        }
        return try repository.upsertSleepQuality(
            athleteId: athleteId,
            localDate: localDate,
            sleepQuality: sleepQuality,
            visibility: visibility
        )
    }

    /// VX-023: the canonical single-date Sleep read — `nil` when no
    /// `DailyStatus` (Sleep or otherwise) exists yet for this athlete on
    /// this date, distinct from a row that exists but has
    /// `sleepQuality == nil` (a wellbeing entry that never recorded
    /// Sleep). Both cases display as "not logged" in Sleep UI, but this
    /// method itself makes no such presentation decision.
    public func fetchDailyStatus(forAthlete athleteId: AthleteId, localDate: LocalDate) throws -> DailyStatus? {
        try repository.fetchDailyStatus(forAthlete: athleteId, localDate: localDate)
    }

    /// VX-023: the canonical range read Sleep History pages over —
    /// newest-first, inclusive of both endpoints. See
    /// `ReflectionRepository.fetchDailyStatuses(forAthlete:from:to:)`'s
    /// own doc comment for why missing dates are NOT synthesized here.
    public func fetchDailyStatuses(forAthlete athleteId: AthleteId, from: LocalDate, to: LocalDate) throws -> [DailyStatus] {
        try repository.fetchDailyStatuses(forAthlete: athleteId, from: from, to: to)
    }

    /// S4.2: fetch observations for one LoggedActivity.
    public func fetchParentObservations(forLoggedActivity loggedActivityId: LoggedActivityId) throws -> [ParentObservation] {
        try repository.fetchParentObservations(forLoggedActivity: loggedActivityId)
    }

    /// Mirrors — does not add to — `ActivityReflection`'s own
    /// `precondition`s (bodyFeeling/energy/satisfaction 1-5,
    /// perceivedExertion 1-10). The entity's initializer already
    /// enforces these, but only by crashing the process on violation;
    /// checking them here first is what lets this be a catchable error
    /// instead — same pattern `WeeklyReflectionService.validate`
    /// already established for `WeeklyReflection`'s equivalent fields.
    private static func validate(bodyFeeling: Int?, energy: Int?, satisfaction: Int?, perceivedExertion: Int?) throws {
        for value in [bodyFeeling, energy, satisfaction] {
            if let value, !(1...5).contains(value) {
                throw ReflectionServiceError.invalidField("bodyFeeling/energy/satisfaction must be 1-5")
            }
        }
        if let perceivedExertion, !(1...10).contains(perceivedExertion) {
            throw ReflectionServiceError.invalidField("perceivedExertion must be 1-10")
        }
    }
}
