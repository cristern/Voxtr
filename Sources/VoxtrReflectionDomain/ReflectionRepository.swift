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

    /// Planned/Logged Activity lifecycle consistency cleanup (Edit
    /// Logged Activity): looked up by the entity's own stable id, never
    /// by title/date.
    public func fetchActivityReflection(byId reflectionId: ReflectionId) throws -> ActivityReflection? {
        let rawId = reflectionId.rawValue
        return try modelContext.fetch(FetchDescriptor<ActivityReflection>()).first { $0.id == rawId }
    }

    /// Corrects the Form value (`bodyFeeling`) already recorded on an
    /// existing `ActivityReflection`. Mutates the SAME entity in place
    /// then saves — never delete+reinsert, preserving the entity's own
    /// stable id and every other field (energy/satisfaction/notes/
    /// visibility) untouched. `bodyFeeling: nil` clears the Form rating
    /// back to unset without deleting the reflection itself — other
    /// reflection content may still exist on it.
    public func updateActivityReflection(_ reflection: ActivityReflection, bodyFeeling: Int?) throws {
        reflection.bodyFeeling = bodyFeeling
        reflection.updatedAt = .now
        try modelContext.save()
    }

    /// Removes the exact reflection through Reflection's canonical
    /// repository. Used when its owning LoggedActivity is intentionally
    /// removed by the cross-domain reopen lifecycle command.
    public func deleteActivityReflection(_ reflection: ActivityReflection) throws {
        modelContext.delete(reflection)
        try modelContext.save()
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

    /// S4.2: same ordering as above, scoped to one `LoggedActivity`.
    /// Unlike `ActivityReflection` (S4.1: at most one per athlete +
    /// LoggedActivity), nothing limits how many `ParentObservation`s can
    /// reference the same `LoggedActivity` — a parent adding several
    /// notes over time about one session is expected, not a duplicate
    /// to reject, and nothing in this story's scope asked for such a
    /// restriction.
    public func fetchParentObservations(forLoggedActivity loggedActivityId: LoggedActivityId) throws -> [ParentObservation] {
        let rawLoggedActivityId = loggedActivityId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<ParentObservation>())
        return all
            .filter { $0.relatedLoggedActivityId == rawLoggedActivityId }
            .sorted(by: Self.observationOrder)
    }

    /// VX-023 (Sleep V1): the canonical "one `DailyStatus` per athlete +
    /// `LocalDate`" lookup — every DailyStatus create/update path below
    /// goes through this first. `nil` means no signal (Sleep or
    /// otherwise) has ever been recorded for this athlete on this date —
    /// not the same as a recorded-but-empty day.
    public func fetchDailyStatus(forAthlete athleteId: AthleteId, localDate: LocalDate) throws -> DailyStatus? {
        let rawAthleteId = athleteId.rawValue
        return try modelContext.fetch(FetchDescriptor<DailyStatus>())
            .first { $0.athleteId == rawAthleteId && $0.localDate == localDate }
    }

    /// VX-023: every `DailyStatus` row for one athlete whose `localDate`
    /// falls within `[from, to]` inclusive — the range-fetch History
    /// screens page over. Ordered newest-first (`localDate` descending,
    /// `id` as a stable tiebreaker) since Sleep History's own contract
    /// is "newest first." Dates in the requested range with no row at
    /// all are NOT represented here — callers that need explicit
    /// "not logged" rows (Sleep History) fill the gaps themselves from
    /// the requested date range, the same "fetch canonical rows, derive
    /// presentation gaps at the call site" separation `WeeklyHistoryListViewModel`
    /// already uses for missing weeks.
    public func fetchDailyStatuses(forAthlete athleteId: AthleteId, from: LocalDate, to: LocalDate) throws -> [DailyStatus] {
        let rawAthleteId = athleteId.rawValue
        let all = try modelContext.fetch(FetchDescriptor<DailyStatus>())
        return all
            .filter { $0.athleteId == rawAthleteId && $0.localDate >= from && $0.localDate <= to }
            .sorted(by: Self.dailyStatusOrder)
    }

    /// VX-023: the single canonical write path for Sleep — "if a
    /// `DailyStatus` for that athlete/date already exists for another
    /// wellbeing field, UPDATE the same `DailyStatus`; if Sleep is the
    /// first signal for that athlete/date, create it." Mutates the
    /// existing row's `sleepQuality` in place (preserving every other
    /// field — `sleepDurationMinutes`, `energy`, `generalForm`,
    /// `soreness`, `motivation`, `illnessFlag`, `note`, `visibility` —
    /// completely untouched) rather than delete+reinsert, exactly the
    /// same "mutate in place" discipline `updateActivityReflection`
    /// above already establishes. Never creates a second row for the
    /// same athlete/date — the `fetchDailyStatus` lookup above is always
    /// checked first.
    public func upsertSleepQuality(
        athleteId: AthleteId,
        localDate: LocalDate,
        sleepQuality: Int,
        visibility: VisibilityPolicy
    ) throws -> DailyStatus {
        if let existing = try fetchDailyStatus(forAthlete: athleteId, localDate: localDate) {
            existing.sleepQuality = sleepQuality
            existing.updatedAt = .now
            try modelContext.save()
            return existing
        }
        let status = DailyStatus(
            athleteId: athleteId,
            localDate: localDate,
            sleepQuality: sleepQuality,
            visibility: visibility
        )
        modelContext.insert(status)
        try modelContext.save()
        return status
    }

    private static func dailyStatusOrder(_ lhs: DailyStatus, _ rhs: DailyStatus) -> Bool {
        if lhs.localDate != rhs.localDate {
            return lhs.localDate > rhs.localDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
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
