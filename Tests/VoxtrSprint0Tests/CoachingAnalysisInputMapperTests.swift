import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCoachingDomain

/// `CoachingAnalysisInputMapper` is a pure function over already-built
/// `WeeklyCoachingContext` values — no `@Model`/SwiftData involvement
/// anywhere in this file, so no container/repository setup is needed,
/// matching `CoachingEngineTests`'/`CoachingPresentationMapperTests`'
/// own pattern.

@Suite("CoachingAnalysisInputMapper (Sprint 14, revised)", .serialized)
struct CoachingAnalysisInputMapperTests {

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

    // MARK: - Carried-through fields

    @Test("athleteId is carried through unchanged")
    func athleteIdCarriedThrough() {
        let context = Self.makeContext()
        let input = CoachingAnalysisInputMapper().map(context)
        #expect(input.athleteId == context.athleteId)
    }

    @Test("weekStart is carried through unchanged")
    func weekStartCarriedThrough() {
        let context = Self.makeContext()
        let input = CoachingAnalysisInputMapper().map(context)
        #expect(input.weekStart == context.weekStart)
    }

    @Test("plannedActivityCount is carried through unchanged")
    func plannedActivityCountCarriedThrough() {
        let context = Self.makeContext(plannedActivityCount: 7)
        let input = CoachingAnalysisInputMapper().map(context)
        #expect(input.plannedActivityCount == 7)
    }

    @Test("uncompletedPlannedActivityCount is carried through unchanged")
    func uncompletedPlannedActivityCountCarriedThrough() {
        let context = Self.makeContext(uncompletedPlannedActivityCount: 3)
        let input = CoachingAnalysisInputMapper().map(context)
        #expect(input.uncompletedPlannedActivityCount == 3)
    }

    // MARK: - Collapsed-to-Bool fields

    @Test("hasWeeklyReflection is true when weeklyReflection is present")
    func hasWeeklyReflectionTrueWhenPresent() {
        let reflection = WeeklyReflectionSummary(
            overallSatisfaction: 4, loadFelt: 3, whatWorked: "Consistency",
            whatWasDifficult: nil, learning: nil, nextWeekConsideration: nil
        )
        let context = Self.makeContext(weeklyReflection: reflection)
        let input = CoachingAnalysisInputMapper().map(context)
        #expect(input.hasWeeklyReflection == true)
    }

    @Test("hasWeeklyReflection is false when weeklyReflection is nil")
    func hasWeeklyReflectionFalseWhenNil() {
        let context = Self.makeContext(weeklyReflection: nil)
        let input = CoachingAnalysisInputMapper().map(context)
        #expect(input.hasWeeklyReflection == false)
    }

    @Test("hasParentObservations is true when at least one observation is present")
    func hasParentObservationsTrueWhenNonEmpty() {
        let context = Self.makeContext(
            parentObservations: [ParentObservationSummary(localDate: Self.weekStart, text: "Note")]
        )
        let input = CoachingAnalysisInputMapper().map(context)
        #expect(input.hasParentObservations == true)
    }

    @Test("hasParentObservations is false when observations are empty")
    func hasParentObservationsFalseWhenEmpty() {
        let context = Self.makeContext(parentObservations: [])
        let input = CoachingAnalysisInputMapper().map(context)
        #expect(input.hasParentObservations == false)
    }

    // MARK: - Dropped fields have no effect on the mapped output

    @Test("Fields CoachingEngine never reads do not affect the mapped output")
    func droppedFieldsDoNotAffectOutput() {
        let baseline = CoachingAnalysisInputMapper().map(Self.makeContext(
            weekPlanStatus: .draft, plannedActivityCount: 2, completedPlannedActivityCount: 1,
            uncompletedPlannedActivityCount: 1, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 1
        ))
        let variedDroppedFields = CoachingAnalysisInputMapper().map(Self.makeContext(
            weekPlanStatus: .committed, plannedActivityCount: 2, completedPlannedActivityCount: 99,
            uncompletedPlannedActivityCount: 1, unplannedLoggedActivityCount: 42, totalLoggedActivityCount: 100
        ))

        // weekPlanStatus, completedPlannedActivityCount,
        // unplannedLoggedActivityCount, and totalLoggedActivityCount
        // all differ between the two contexts above; the mapped output
        // must be identical regardless, since CoachingAnalysisInput
        // doesn't carry any of them.
        #expect(baseline == variedDroppedFields)
    }

    // MARK: - Determinism

    @Test("Repeated mapping of the same context produces equal output")
    func repeatedMappingProducesEqualOutput() {
        let context = Self.makeContext(
            plannedActivityCount: 3, uncompletedPlannedActivityCount: 1,
            weeklyReflection: WeeklyReflectionSummary(
                overallSatisfaction: 4, loadFelt: nil, whatWorked: nil,
                whatWasDifficult: nil, learning: nil, nextWeekConsideration: nil
            ),
            parentObservations: [ParentObservationSummary(localDate: Self.weekStart, text: "Note")]
        )
        let mapper = CoachingAnalysisInputMapper()

        let first = mapper.map(context)
        let second = mapper.map(context)

        #expect(first == second)
    }
}
