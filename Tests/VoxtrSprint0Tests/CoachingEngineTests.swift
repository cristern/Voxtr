import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrAppShell

/// A shared fixture-construction helper here is safe, unlike the
/// project-wide "no shared helper across @Test functions" lesson
/// established for `ModelContainer`/repository construction: that
/// lesson traced a real crash to SwiftData's interaction with shared
/// test setup specifically. `WeeklyCoachingContext` is a plain value
/// type with no SwiftData/`ModelContext` involvement anywhere in this
/// file, so that failure mode cannot occur here.
@Suite("CoachingEngine (Sprint 7)", .serialized)
struct CoachingEngineTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)

    private static func makeContext(
        weekPlanStatus: WeekPlanStatus? = .committed,
        plannedActivityCount: Int = 0,
        completedPlannedActivityCount: Int = 0,
        uncompletedPlannedActivityCount: Int = 0,
        unplannedLoggedActivityCount: Int = 0,
        totalLoggedActivityCount: Int = 0,
        weeklyReflection: WeeklyReflectionSummary? = nil,
        parentObservations: [ParentObservationSummary] = []
    ) -> WeeklyCoachingContext {
        WeeklyCoachingContext(
            athleteId: athleteId,
            weekStart: weekStart,
            previousWeekStart: LocalDate(year: 2025, month: 12, day: 29),
            weekPlanStatus: weekPlanStatus,
            plannedActivityCount: plannedActivityCount,
            completedPlannedActivityCount: completedPlannedActivityCount,
            uncompletedPlannedActivityCount: uncompletedPlannedActivityCount,
            unplannedLoggedActivityCount: unplannedLoggedActivityCount,
            totalLoggedActivityCount: totalLoggedActivityCount,
            weeklyReflection: weeklyReflection,
            parentObservations: parentObservations
        )
    }

    private static let sampleReflection = WeeklyReflectionSummary(
        overallSatisfaction: 4, loadFelt: 3, whatWorked: "Consistency",
        whatWasDifficult: nil, learning: nil, nextWeekConsideration: nil
    )
    private static let sampleObservation = ParentObservationSummary(localDate: weekStart, text: "Looked strong.")

    // MARK: - Every rule, individually

    @Test("allPlannedActivitiesCompleted fires when every planned activity is completed")
    func allPlannedActivitiesCompletedFires() {
        let context = Self.makeContext(plannedActivityCount: 3, completedPlannedActivityCount: 3, uncompletedPlannedActivityCount: 0)
        let result = CoachingEngine().analyse(context)
        #expect(result.insights.contains(.allPlannedActivitiesCompleted))
        #expect(!result.insights.contains(.somePlannedActivitiesMissed))
    }

    @Test("somePlannedActivitiesMissed fires when at least one planned activity is uncompleted")
    func somePlannedActivitiesMissedFires() {
        let context = Self.makeContext(plannedActivityCount: 3, completedPlannedActivityCount: 2, uncompletedPlannedActivityCount: 1)
        let result = CoachingEngine().analyse(context)
        #expect(result.insights.contains(.somePlannedActivitiesMissed))
        #expect(!result.insights.contains(.allPlannedActivitiesCompleted))
    }

    @Test("noWeeklyReflection fires when weeklyReflection is nil")
    func noWeeklyReflectionFires() {
        let context = Self.makeContext(weeklyReflection: nil)
        let result = CoachingEngine().analyse(context)
        #expect(result.insights.contains(.noWeeklyReflection))
        #expect(!result.insights.contains(.weeklyReflectionCompleted))
    }

    @Test("weeklyReflectionCompleted fires when weeklyReflection is present")
    func weeklyReflectionCompletedFires() {
        let context = Self.makeContext(weeklyReflection: Self.sampleReflection)
        let result = CoachingEngine().analyse(context)
        #expect(result.insights.contains(.weeklyReflectionCompleted))
        #expect(!result.insights.contains(.noWeeklyReflection))
    }

    @Test("noParentObservations fires when parentObservations is empty")
    func noParentObservationsFires() {
        let context = Self.makeContext(parentObservations: [])
        let result = CoachingEngine().analyse(context)
        #expect(result.insights.contains(.noParentObservations))
        #expect(!result.insights.contains(.parentObservationsPresent))
    }

    @Test("parentObservationsPresent fires when at least one observation exists")
    func parentObservationsPresentFires() {
        let context = Self.makeContext(parentObservations: [Self.sampleObservation])
        let result = CoachingEngine().analyse(context)
        #expect(result.insights.contains(.parentObservationsPresent))
        #expect(!result.insights.contains(.noParentObservations))
    }

    // MARK: - Edge cases

    @Test("Zero planned activities produces neither of the two completion-related insights")
    func zeroPlannedActivitiesSkipsCompletionRules() {
        let context = Self.makeContext(plannedActivityCount: 0, completedPlannedActivityCount: 0, uncompletedPlannedActivityCount: 0)
        let result = CoachingEngine().analyse(context)
        #expect(!result.insights.contains(.allPlannedActivitiesCompleted))
        #expect(!result.insights.contains(.somePlannedActivitiesMissed))
    }

    // MARK: - No findings (from the completion/count rule group)

    @Test("An inactive week with a reflection and observations already recorded produces no completion-related findings — only the two unavoidable presence findings")
    func noFindingsFromCompletionRuleGroup() {
        let context = Self.makeContext(
            plannedActivityCount: 0,
            weeklyReflection: Self.sampleReflection,
            parentObservations: [Self.sampleObservation]
        )
        let result = CoachingEngine().analyse(context)
        #expect(result.insights == [.weeklyReflectionCompleted, .parentObservationsPresent])
    }

    @Test("A fully empty context (nothing planned, no reflection, no observations) produces only the two unavoidable absence findings")
    func emptyContextProducesOnlyAbsenceFindings() {
        let context = Self.makeContext(
            plannedActivityCount: 0,
            completedPlannedActivityCount: 0,
            uncompletedPlannedActivityCount: 0,
            unplannedLoggedActivityCount: 0,
            totalLoggedActivityCount: 0,
            weeklyReflection: nil,
            parentObservations: []
        )

        let result = CoachingEngine().analyse(context)

        #expect(result.insights == [.noWeeklyReflection, .noParentObservations])
    }

    // MARK: - Multiple simultaneous findings

    @Test("Multiple independent findings can co-occur in one result")
    func multipleSimultaneousFindings() {
        let context = Self.makeContext(
            plannedActivityCount: 5,
            completedPlannedActivityCount: 5,
            uncompletedPlannedActivityCount: 0,
            weeklyReflection: nil,
            parentObservations: [Self.sampleObservation]
        )
        let result = CoachingEngine().analyse(context)
        #expect(result.insights.contains(.allPlannedActivitiesCompleted))
        #expect(result.insights.contains(.noWeeklyReflection))
        #expect(result.insights.contains(.parentObservationsPresent))
        #expect(result.insights.count == 3)
    }

    // MARK: - Rule ordering

    @Test("Insights are always returned in the same fixed evaluation order")
    func ruleOrderingIsFixed() {
        let context = Self.makeContext(
            plannedActivityCount: 4,
            completedPlannedActivityCount: 4,
            uncompletedPlannedActivityCount: 0,
            weeklyReflection: Self.sampleReflection,
            parentObservations: [Self.sampleObservation]
        )
        let result = CoachingEngine().analyse(context)
        #expect(result.insights == [
            .allPlannedActivitiesCompleted,
            .weeklyReflectionCompleted,
            .parentObservationsPresent,
        ])
    }

    // MARK: - Deterministic repeated execution

    @Test("Analysing the same context repeatedly always produces an identical result")
    func deterministicRepeatedExecution() {
        let context = Self.makeContext(
            plannedActivityCount: 3,
            completedPlannedActivityCount: 1,
            uncompletedPlannedActivityCount: 2,
            weeklyReflection: Self.sampleReflection,
            parentObservations: []
        )
        let engine = CoachingEngine()

        let first = engine.analyse(context)
        let second = engine.analyse(context)
        let third = engine.analyse(context)

        #expect(first == second)
        #expect(second == third)
    }

    @Test("The engine result carries the same athleteId and weekStart as the input context")
    func resultCarriesAthleteAndWeekIdentity() {
        let context = Self.makeContext()
        let result = CoachingEngine().analyse(context)
        #expect(result.athleteId == context.athleteId)
        #expect(result.weekStart == context.weekStart)
    }
}
