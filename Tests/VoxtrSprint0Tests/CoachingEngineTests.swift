import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrCoachingDomain

/// A shared fixture-construction helper here is safe, unlike the
/// project-wide "no shared helper across @Test functions" lesson
/// established for `ModelContainer`/repository construction: that
/// lesson traced a real crash to SwiftData's interaction with shared
/// test setup specifically. `CoachingAnalysisInput` is a plain value
/// type with no SwiftData/`ModelContext` involvement anywhere in this
/// file, so that failure mode cannot occur here.
///
/// Sprint 14 (revised): this file used to construct `WeeklyCoachingContext`
/// (with `weeklyReflection`/`parentObservations` as full summary
/// values) — after the architecture review moved that type back to
/// `VoxtrAppShell` and introduced `CoachingAnalysisInput` as the
/// engine's actual, coaching-owned input, tests exercise domain rules
/// through `CoachingAnalysisInput` directly, never through
/// `WeeklyCoachingContext`. `hasWeeklyReflection`/`hasParentObservations`
/// replace the old `weeklyReflection: WeeklyReflectionSummary?`/
/// `parentObservations: [ParentObservationSummary]` parameters — the
/// engine only ever checked presence/absence, never the summaries'
/// own content, so no test coverage is lost by this simplification.
@Suite("CoachingEngine (Sprint 7)", .serialized)
struct CoachingEngineTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)

    private static func makeInput(
        plannedActivityCount: Int = 0,
        uncompletedPlannedActivityCount: Int = 0,
        hasWeeklyReflection: Bool = false,
        hasParentObservations: Bool = false
    ) -> CoachingAnalysisInput {
        CoachingAnalysisInput(
            athleteId: athleteId,
            weekStart: weekStart,
            plannedActivityCount: plannedActivityCount,
            uncompletedPlannedActivityCount: uncompletedPlannedActivityCount,
            hasWeeklyReflection: hasWeeklyReflection,
            hasParentObservations: hasParentObservations
        )
    }

    // MARK: - Every rule, individually

    @Test("allPlannedActivitiesCompleted fires when every planned activity is completed")
    func allPlannedActivitiesCompletedFires() {
        let input = Self.makeInput(plannedActivityCount: 3, uncompletedPlannedActivityCount: 0)
        let result = CoachingEngine().analyse(input)
        #expect(result.insights.contains(.allPlannedActivitiesCompleted))
        #expect(!result.insights.contains(.somePlannedActivitiesMissed))
    }

    @Test("somePlannedActivitiesMissed fires when at least one planned activity is uncompleted")
    func somePlannedActivitiesMissedFires() {
        let input = Self.makeInput(plannedActivityCount: 3, uncompletedPlannedActivityCount: 1)
        let result = CoachingEngine().analyse(input)
        #expect(result.insights.contains(.somePlannedActivitiesMissed))
        #expect(!result.insights.contains(.allPlannedActivitiesCompleted))
    }

    @Test("noWeeklyReflection fires when hasWeeklyReflection is false")
    func noWeeklyReflectionFires() {
        let input = Self.makeInput(hasWeeklyReflection: false)
        let result = CoachingEngine().analyse(input)
        #expect(result.insights.contains(.noWeeklyReflection))
        #expect(!result.insights.contains(.weeklyReflectionCompleted))
    }

    @Test("weeklyReflectionCompleted fires when hasWeeklyReflection is true")
    func weeklyReflectionCompletedFires() {
        let input = Self.makeInput(hasWeeklyReflection: true)
        let result = CoachingEngine().analyse(input)
        #expect(result.insights.contains(.weeklyReflectionCompleted))
        #expect(!result.insights.contains(.noWeeklyReflection))
    }

    @Test("noParentObservations fires when hasParentObservations is false")
    func noParentObservationsFires() {
        let input = Self.makeInput(hasParentObservations: false)
        let result = CoachingEngine().analyse(input)
        #expect(result.insights.contains(.noParentObservations))
        #expect(!result.insights.contains(.parentObservationsPresent))
    }

    @Test("parentObservationsPresent fires when hasParentObservations is true")
    func parentObservationsPresentFires() {
        let input = Self.makeInput(hasParentObservations: true)
        let result = CoachingEngine().analyse(input)
        #expect(result.insights.contains(.parentObservationsPresent))
        #expect(!result.insights.contains(.noParentObservations))
    }

    // MARK: - Edge cases

    @Test("Zero planned activities produces neither of the two completion-related insights")
    func zeroPlannedActivitiesSkipsCompletionRules() {
        let input = Self.makeInput(plannedActivityCount: 0, uncompletedPlannedActivityCount: 0)
        let result = CoachingEngine().analyse(input)
        #expect(!result.insights.contains(.allPlannedActivitiesCompleted))
        #expect(!result.insights.contains(.somePlannedActivitiesMissed))
    }

    // MARK: - No findings (from the completion/count rule group)

    @Test("An inactive week with a reflection and observations already recorded produces no completion-related findings — only the two unavoidable presence findings")
    func noFindingsFromCompletionRuleGroup() {
        let input = Self.makeInput(
            plannedActivityCount: 0,
            hasWeeklyReflection: true,
            hasParentObservations: true
        )
        let result = CoachingEngine().analyse(input)
        #expect(result.insights == [.weeklyReflectionCompleted, .parentObservationsPresent])
    }

    @Test("A fully empty input (nothing planned, no reflection, no observations) produces only the two unavoidable absence findings")
    func emptyInputProducesOnlyAbsenceFindings() {
        let input = Self.makeInput(
            plannedActivityCount: 0,
            uncompletedPlannedActivityCount: 0,
            hasWeeklyReflection: false,
            hasParentObservations: false
        )

        let result = CoachingEngine().analyse(input)

        #expect(result.insights == [.noWeeklyReflection, .noParentObservations])
    }

    // MARK: - Multiple simultaneous findings

    @Test("Multiple independent findings can co-occur in one result")
    func multipleSimultaneousFindings() {
        let input = Self.makeInput(
            plannedActivityCount: 5,
            uncompletedPlannedActivityCount: 0,
            hasWeeklyReflection: false,
            hasParentObservations: true
        )
        let result = CoachingEngine().analyse(input)
        #expect(result.insights.contains(.allPlannedActivitiesCompleted))
        #expect(result.insights.contains(.noWeeklyReflection))
        #expect(result.insights.contains(.parentObservationsPresent))
        #expect(result.insights.count == 3)
    }

    // MARK: - Rule ordering

    @Test("Insights are always returned in the same fixed evaluation order")
    func ruleOrderingIsFixed() {
        let input = Self.makeInput(
            plannedActivityCount: 4,
            uncompletedPlannedActivityCount: 0,
            hasWeeklyReflection: true,
            hasParentObservations: true
        )
        let result = CoachingEngine().analyse(input)
        #expect(result.insights == [
            .allPlannedActivitiesCompleted,
            .weeklyReflectionCompleted,
            .parentObservationsPresent,
        ])
    }

    // MARK: - Deterministic repeated execution

    @Test("Analysing the same input repeatedly always produces an identical result")
    func deterministicRepeatedExecution() {
        let input = Self.makeInput(
            plannedActivityCount: 3,
            uncompletedPlannedActivityCount: 2,
            hasWeeklyReflection: true,
            hasParentObservations: false
        )
        let engine = CoachingEngine()

        let first = engine.analyse(input)
        let second = engine.analyse(input)
        let third = engine.analyse(input)

        #expect(first == second)
        #expect(second == third)
    }

    @Test("The engine result carries the same athleteId and weekStart as the input")
    func resultCarriesAthleteAndWeekIdentity() {
        let input = Self.makeInput()
        let result = CoachingEngine().analyse(input)
        #expect(result.athleteId == input.athleteId)
        #expect(result.weekStart == input.weekStart)
    }
}
