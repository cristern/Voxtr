import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrAppShell

@Suite("CoachingPresentationMapper (Sprint 8)", .serialized)
struct CoachingPresentationMapperTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)

    private static func makeResult(_ insights: [CoachingInsight]) -> CoachingResult {
        CoachingResult(athleteId: athleteId, weekStart: weekStart, insights: insights)
    }

    // MARK: - Every current CoachingResult finding type

    @Test("allPlannedActivitiesCompleted maps to a positive item in Planned Activities")
    func allPlannedActivitiesCompletedMapsCorrectly() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([.allPlannedActivitiesCompleted]))
        #expect(presentation.sections.count == 1)
        #expect(presentation.sections.first?.title == "Planned Activities")
        #expect(presentation.sections.first?.items.first?.insight == .allPlannedActivitiesCompleted)
        #expect(presentation.sections.first?.items.first?.emphasis == .positive)
    }

    @Test("somePlannedActivitiesMissed maps to an attention item in Planned Activities")
    func somePlannedActivitiesMissedMapsCorrectly() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([.somePlannedActivitiesMissed]))
        #expect(presentation.sections.first?.title == "Planned Activities")
        #expect(presentation.sections.first?.items.first?.insight == .somePlannedActivitiesMissed)
        #expect(presentation.sections.first?.items.first?.emphasis == .attention)
    }

    @Test("noWeeklyReflection maps to an attention item in Weekly Reflection")
    func noWeeklyReflectionMapsCorrectly() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([.noWeeklyReflection]))
        #expect(presentation.sections.first?.title == "Weekly Reflection")
        #expect(presentation.sections.first?.items.first?.insight == .noWeeklyReflection)
        #expect(presentation.sections.first?.items.first?.emphasis == .attention)
    }

    @Test("weeklyReflectionCompleted maps to a positive item in Weekly Reflection")
    func weeklyReflectionCompletedMapsCorrectly() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([.weeklyReflectionCompleted]))
        #expect(presentation.sections.first?.title == "Weekly Reflection")
        #expect(presentation.sections.first?.items.first?.insight == .weeklyReflectionCompleted)
        #expect(presentation.sections.first?.items.first?.emphasis == .positive)
    }

    @Test("noParentObservations maps to a neutral item in Parent Observations")
    func noParentObservationsMapsCorrectly() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([.noParentObservations]))
        #expect(presentation.sections.first?.title == "Parent Observations")
        #expect(presentation.sections.first?.items.first?.insight == .noParentObservations)
        #expect(presentation.sections.first?.items.first?.emphasis == .neutral)
    }

    @Test("parentObservationsPresent maps to a neutral item in Parent Observations")
    func parentObservationsPresentMapsCorrectly() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([.parentObservationsPresent]))
        #expect(presentation.sections.first?.title == "Parent Observations")
        #expect(presentation.sections.first?.items.first?.insight == .parentObservationsPresent)
        #expect(presentation.sections.first?.items.first?.emphasis == .neutral)
    }

    // MARK: - Multiple findings

    @Test("Multiple findings across all three categories map into three separate sections")
    func multipleFindingsProduceMultipleSections() {
        let result = Self.makeResult([
            .allPlannedActivitiesCompleted,
            .weeklyReflectionCompleted,
            .parentObservationsPresent,
        ])
        let presentation = CoachingPresentationMapper().map(result)

        #expect(presentation.sections.count == 3)
        #expect(presentation.sections.map(\.title) == ["Planned Activities", "Weekly Reflection", "Parent Observations"])
        #expect(presentation.sections.allSatisfy { $0.items.count == 1 })
    }

    // MARK: - Empty CoachingResult

    @Test("An empty CoachingResult maps to a valid, genuinely empty CoachingPresentation — no invented message")
    func emptyResultMapsToEmptyPresentation() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([]))

        #expect(presentation.athleteId == Self.athleteId)
        #expect(presentation.weekStart == Self.weekStart)
        #expect(presentation.sections.isEmpty)
    }

    // MARK: - Stable section and item ordering

    @Test("Section order is fixed regardless of the order insights appear in the input")
    func sectionOrderIsFixedRegardlessOfInputOrder() {
        // Deliberately supplied in an order that does NOT match the
        // fixed section order (Observations-related insight first).
        let result = Self.makeResult([
            .parentObservationsPresent,
            .allPlannedActivitiesCompleted,
            .noWeeklyReflection,
        ])
        let presentation = CoachingPresentationMapper().map(result)

        #expect(presentation.sections.map(\.title) == ["Planned Activities", "Weekly Reflection", "Parent Observations"])
    }

    // MARK: - Repeated mapping produces equal output

    @Test("Repeated mapping of the same CoachingResult always produces an equal CoachingPresentation")
    func repeatedMappingProducesEqualOutput() {
        let result = Self.makeResult([.somePlannedActivitiesMissed, .noWeeklyReflection, .noParentObservations])
        let mapper = CoachingPresentationMapper()

        let first = mapper.map(result)
        let second = mapper.map(result)
        let third = mapper.map(result)

        #expect(first == second)
        #expect(second == third)
    }

    // MARK: - No findings added or removed

    @Test("The total number of presentation items always equals the number of input insights")
    func itemCountMatchesInsightCount() {
        let allSixInsights: [CoachingInsight] = [
            .allPlannedActivitiesCompleted,
            .somePlannedActivitiesMissed,
            .noWeeklyReflection,
            .weeklyReflectionCompleted,
            .noParentObservations,
            .parentObservationsPresent,
        ]

        // Each of the six is tested individually, since
        // allPlannedActivitiesCompleted/somePlannedActivitiesMissed and
        // the reflection/observation pairs are mutually exclusive in
        // practice — this loop verifies the mapper's 1:1 behavior
        // holds for every single insight in isolation, not just the
        // subset CoachingEngine would ever actually produce together.
        for insight in allSixInsights {
            let presentation = CoachingPresentationMapper().map(Self.makeResult([insight]))
            let totalItems = presentation.sections.reduce(0) { $0 + $1.items.count }
            #expect(totalItems == 1)
        }

        let combined = Self.makeResult([.somePlannedActivitiesMissed, .noWeeklyReflection])
        let combinedPresentation = CoachingPresentationMapper().map(combined)
        let combinedTotalItems = combinedPresentation.sections.reduce(0) { $0 + $1.items.count }
        #expect(combinedTotalItems == combined.insights.count)
    }

    // MARK: - Equatable/Sendable usage

    @Test("Presentation types support equality comparison as expected for deterministic testing")
    func presentationTypesSupportEquatable() {
        let itemA = CoachingPresentationItem(insight: .allPlannedActivitiesCompleted, text: "Same text", emphasis: .positive, action: .none)
        let itemB = CoachingPresentationItem(insight: .allPlannedActivitiesCompleted, text: "Same text", emphasis: .positive, action: .none)
        let itemC = CoachingPresentationItem(insight: .somePlannedActivitiesMissed, text: "Different", emphasis: .attention, action: .none)

        #expect(itemA == itemB)
        #expect(itemA != itemC)

        let sectionA = CoachingPresentationSection(title: "Planned Activities", items: [itemA])
        let sectionB = CoachingPresentationSection(title: "Planned Activities", items: [itemB])
        #expect(sectionA == sectionB)
    }

    // MARK: - Sprint 10: action assignment

    @Test("noWeeklyReflection is assigned the startWeeklyReflection action")
    func noWeeklyReflectionAssignsStartWeeklyReflectionAction() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([.noWeeklyReflection]))
        #expect(presentation.sections.first?.items.first?.action == .startWeeklyReflection)
    }

    @Test("noParentObservations is assigned the addParentObservation action")
    func noParentObservationsAssignsAddParentObservationAction() {
        let presentation = CoachingPresentationMapper().map(Self.makeResult([.noParentObservations]))
        #expect(presentation.sections.first?.items.first?.action == .addParentObservation)
    }

    @Test("Every other insight is assigned no action — a valid, intentional outcome")
    func otherInsightsAssignNoAction() {
        let noActionInsights: [CoachingInsight] = [
            .allPlannedActivitiesCompleted,
            .somePlannedActivitiesMissed,
            .weeklyReflectionCompleted,
            .parentObservationsPresent,
        ]
        for insight in noActionInsights {
            let presentation = CoachingPresentationMapper().map(Self.makeResult([insight]))
            #expect(presentation.sections.first?.items.first?.action == .none)
        }
    }

    @Test("Action assignment is deterministic across repeated mapping of the same result")
    func actionAssignmentIsDeterministicAcrossRepeatedMapping() {
        let result = Self.makeResult([.noWeeklyReflection, .noParentObservations, .allPlannedActivitiesCompleted])
        let mapper = CoachingPresentationMapper()

        let first = mapper.map(result)
        let second = mapper.map(result)

        let firstActions = first.sections.flatMap { $0.items.map(\.action) }
        let secondActions = second.sections.flatMap { $0.items.map(\.action) }
        #expect(firstActions == secondActions)
        // Fixed section order is Planned Activities → Weekly Reflection →
        // Parent Observations, regardless of the input insight order.
        #expect(firstActions == [.none, .startWeeklyReflection, .addParentObservation])
    }
}
