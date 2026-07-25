import Foundation
import VoxtrCoreContracts

/// Sprint 6 (revised): the factual content of one weekly reflection,
/// as plain values — never the `WeeklyReflection` `@Model` itself.
/// Field-for-field mirror of what `WeeklyReflection` stores, minus its
/// identity/attribution/visibility fields, which future coaching logic
/// has no stated need for.
///
/// `Sendable`: every stored property is already a `Sendable` value type
/// (`Int?`, `String?`) and the whole type is immutable (`let` only) —
/// this conformance was simply missing, not something requiring a
/// workaround. Explicit conformance (not automatic inference) matters
/// here because this is a `public` type; Swift 6 doesn't infer
/// `Sendable` across a module boundary on its own.
public struct WeeklyReflectionSummary: Sendable {
    public let overallSatisfaction: Int?
    public let loadFelt: Int?
    public let whatWorked: String?
    public let whatWasDifficult: String?
    public let learning: String?
    public let nextWeekConsideration: String?

    public init(
        overallSatisfaction: Int?,
        loadFelt: Int?,
        whatWorked: String?,
        whatWasDifficult: String?,
        learning: String?,
        nextWeekConsideration: String?
    ) {
        self.overallSatisfaction = overallSatisfaction
        self.loadFelt = loadFelt
        self.whatWorked = whatWorked
        self.whatWasDifficult = whatWasDifficult
        self.learning = learning
        self.nextWeekConsideration = nextWeekConsideration
    }
}

/// Sprint 6 (revised): one parent-authored observation, as plain
/// values — never the `ParentObservation` `@Model` itself. Deliberately
/// minimal (date + text only) — nothing in the approved scope asks for
/// authorship or linkage detail here, and adding fields speculatively
/// is exactly the kind of unnecessary coupling this revision removes.
///
/// `Sendable`: `LocalDate` and `String` are both already `Sendable`,
/// and this type is fully immutable — same reasoning as
/// `WeeklyReflectionSummary` above.
public struct ParentObservationSummary: Sendable {
    public let localDate: LocalDate
    public let text: String

    public init(localDate: LocalDate, text: String) {
        self.localDate = localDate
        self.text = text
    }
}

/// Sprint 6 (revised): an immutable, in-memory-only, pure value-type
/// assembly of one athlete's weekly data for future coaching logic (and
/// eventually AI) to consume.
///
/// Every property here is a plain value type (`Int`, `String`,
/// `LocalDate`, `WeekPlanStatus`, or one of this file's own summary
/// structs) — there is no `@Model` reference anywhere in this type,
/// directly or nested. That is a hard requirement, not a style
/// preference: `@Model` instances are tied to the `ModelContext` they
/// were fetched from and are not safe to hand across an actor/thread
/// boundary (exactly the kind of boundary a future prompt-builder or
/// background coaching pass would be). This struct never touches
/// `ModelContext`, is never inserted anywhere, and is not part of
/// `AppSchema` — it is built fresh on every request from
/// already-persisted domain data and discarded after use.
///
/// Only `weekStart` and `previousWeekStart` describe the previous week
/// — no previous-week data is fetched or included. Fetching a full
/// previous week's data was removed after review: nothing in this
/// sprint's scope consumes it, and fetching it "for later" duplicated
/// exactly the pattern already flagged as this project's most common
/// mistake (`EventBus`, built and wired with zero real consumers). A
/// future trend-analysis story can add it once something actually needs
/// it.
///
/// `Sendable`: every stored property is a `Sendable` value type
/// (`AthleteId`, `LocalDate`, `WeekPlanStatus`, `Int`, plus the two
/// summary structs above, both `Sendable` for the same reason) — this
/// is the type that actually crosses `CoachingEngine`'s boundary (see
/// `CoachingEngine.analyse`), so it needs this conformance itself, not
/// just its members.
public struct WeeklyCoachingContext: Sendable {
    public let athleteId: AthleteId
    public let weekStart: LocalDate
    public let previousWeekStart: LocalDate

    /// `nil` when no `WeekPlan` exists yet for this week — an expected
    /// state, not an error. `WeekPlanStatus` is a plain `Codable` enum
    /// (`VoxtrCoreContracts`), not a `@Model` — reusing it directly adds
    /// no coupling beyond what every other package in this project
    /// already has.
    public let weekPlanStatus: WeekPlanStatus?

    // MARK: - Objective counts
    //
    // Plain counts — not scores, not percentages, not "on track"/
    // "behind" judgments. This sprint establishes the data model
    // coaching logic will later interpret; it does no interpretation
    // itself.

    public let plannedActivityCount: Int
    public let completedPlannedActivityCount: Int
    public let uncompletedPlannedActivityCount: Int
    public let unplannedLoggedActivityCount: Int
    public let totalLoggedActivityCount: Int

    public let weeklyReflection: WeeklyReflectionSummary?
    public let parentObservations: [ParentObservationSummary]

    public init(
        athleteId: AthleteId,
        weekStart: LocalDate,
        previousWeekStart: LocalDate,
        weekPlanStatus: WeekPlanStatus?,
        plannedActivityCount: Int,
        completedPlannedActivityCount: Int,
        uncompletedPlannedActivityCount: Int,
        unplannedLoggedActivityCount: Int,
        totalLoggedActivityCount: Int,
        weeklyReflection: WeeklyReflectionSummary?,
        parentObservations: [ParentObservationSummary]
    ) {
        self.athleteId = athleteId
        self.weekStart = weekStart
        self.previousWeekStart = previousWeekStart
        self.weekPlanStatus = weekPlanStatus
        self.plannedActivityCount = plannedActivityCount
        self.completedPlannedActivityCount = completedPlannedActivityCount
        self.uncompletedPlannedActivityCount = uncompletedPlannedActivityCount
        self.unplannedLoggedActivityCount = unplannedLoggedActivityCount
        self.totalLoggedActivityCount = totalLoggedActivityCount
        self.weeklyReflection = weeklyReflection
        self.parentObservations = parentObservations
    }
}
