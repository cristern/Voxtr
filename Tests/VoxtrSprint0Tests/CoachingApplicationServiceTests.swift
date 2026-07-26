import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCoachingDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain
import VoxtrReflectionDomain

// NOTE: like the other persistence-backed tests, these exercise @Model
// types and require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/repository construction — every test builds its own inline.

@Suite("CoachingApplicationService (Sprint 11)", .serialized)
struct CoachingApplicationServiceTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    /// Deterministic throwing double — a genuine technical failure.
    @MainActor
    private struct ThrowingCoachingContextProvider: WeeklyCoachingContextProviding {
        struct TestError: Error {}
        func weeklyCoachingContext(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyCoachingContext {
            throw TestError()
        }
    }

    /// A minimal, hand-built context — no persistence involved.
    @MainActor
    private struct StubCoachingContextProvider: WeeklyCoachingContextProviding {
        let context: WeeklyCoachingContext
        func weeklyCoachingContext(forAthlete athleteId: AthleteId, weekStart: LocalDate) throws -> WeeklyCoachingContext {
            context
        }
    }

    @Test("Existing weekly data flows through the complete deterministic pipeline end to end")
    @MainActor
    func completeDataFlowsThroughFullPipeline() throws {
        let container = try InMemoryPersistenceController(modelTypes: AppSchema.modelTypes).makeModelContainer()
        let planningRepository = PlanningRepository(modelContext: container.mainContext)
        let trainingRepository = TrainingRepository(modelContext: container.mainContext)
        let weeklyReflectionRepository = WeeklyReflectionRepository(modelContext: container.mainContext)
        let trainingPlanningCoordinationService = TrainingPlanningCoordinationService(
            planningRepository: planningRepository, trainingRepository: trainingRepository
        )
        let weeklyReviewCoordinationService = WeeklyReviewCoordinationService(
            planningRepository: planningRepository,
            trainingRepository: trainingRepository,
            weeklyReflectionRepository: weeklyReflectionRepository,
            trainingPlanningCoordinationService: trainingPlanningCoordinationService
        )
        let reflectionRepository = ReflectionRepository(modelContext: container.mainContext)
        let reflectionService = ReflectionService(repository: reflectionRepository)
        let coachingContextService = WeeklyCoachingContextService(
            weeklyReviewProvider: weeklyReviewCoordinationService,
            parentObservationProvider: reflectionService
        )
        let applicationService = CoachingApplicationService(coachingContextService: coachingContextService)
        let planning = PlanningService(repository: planningRepository)
        let training = TrainingService(repository: trainingRepository)
        let athleteId = AthleteId()

        let weekPlan = try planning.getOrCreateWeekPlan(athleteId: athleteId, weekStart: Self.weekStart)
        let plannedActivity = try planning.addPlannedActivity(
            toWeekPlan: weekPlan.weekPlanId, athleteId: athleteId, activityType: .individualTraining,
            title: "Endurance run", localDate: Self.weekStart, timeZoneId: Self.oslo
        )
        _ = try training.logActivity(
            athleteId: athleteId, plannedActivityId: plannedActivity.plannedActivityId,
            activityType: .individualTraining, title: "Endurance run",
            startedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .now
        )

        let presentation = try applicationService.coachingPresentation(forAthlete: athleteId, weekStart: Self.weekStart)

        let plannedSection = presentation.sections.first { $0.title == "Planned Activities" }
        #expect(plannedSection?.items.first?.insight == .allPlannedActivitiesCompleted)
    }

    @Test("A result with findings produces the expected presentation")
    @MainActor
    func findingsProduceExpectedPresentation() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: .draft, plannedActivityCount: 3, completedPlannedActivityCount: 1,
            uncompletedPlannedActivityCount: 2, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 1,
            weeklyReflection: nil, parentObservations: []
        )
        let applicationService = CoachingApplicationService(coachingContextService: StubCoachingContextProvider(context: context))

        let presentation = try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)

        #expect(presentation.sections.map(\.title) == ["Planned Activities", "Weekly Reflection", "Parent Observations"])
        #expect(presentation.sections[0].items.first?.insight == .somePlannedActivitiesMissed)
        #expect(presentation.sections[1].items.first?.insight == .noWeeklyReflection)
        #expect(presentation.sections[2].items.first?.insight == .noParentObservations)
    }

    @Test("A minimal context (nothing planned) produces a sparse, valid presentation — no invented success message")
    @MainActor
    func minimalContextProducesSparsePresentation() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: nil, plannedActivityCount: 0, completedPlannedActivityCount: 0,
            uncompletedPlannedActivityCount: 0, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 0,
            weeklyReflection: nil, parentObservations: []
        )
        let applicationService = CoachingApplicationService(coachingContextService: StubCoachingContextProvider(context: context))

        let presentation = try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)

        #expect(!presentation.sections.contains { $0.title == "Planned Activities" })
        let allText = presentation.sections.flatMap { $0.items.map(\.text) }
        #expect(!allText.contains { $0.lowercased().contains("everything looks good") })
    }

    @Test("Stable section ordering is preserved across repeated calls")
    @MainActor
    func stableOrderingPreservedAcrossRepeatedCalls() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: .committed, plannedActivityCount: 2, completedPlannedActivityCount: 2,
            uncompletedPlannedActivityCount: 0, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 2,
            weeklyReflection: WeeklyReflectionSummary(
                overallSatisfaction: 4, loadFelt: nil, whatWorked: nil,
                whatWasDifficult: nil, learning: nil, nextWeekConsideration: nil
            ),
            parentObservations: [ParentObservationSummary(localDate: Self.weekStart, text: "Note")]
        )
        let applicationService = CoachingApplicationService(coachingContextService: StubCoachingContextProvider(context: context))

        let first = try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)
        let second = try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)

        #expect(first.sections.map(\.title) == ["Planned Activities", "Weekly Reflection", "Parent Observations"])
        #expect(first.sections.map(\.title) == second.sections.map(\.title))
    }

    @Test("Repeated calls with equivalent input produce equal output — deterministic behaviour is preserved")
    @MainActor
    func repeatedCallsProduceEqualOutput() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: .draft, plannedActivityCount: 1, completedPlannedActivityCount: 0,
            uncompletedPlannedActivityCount: 1, unplannedLoggedActivityCount: 0, totalLoggedActivityCount: 0,
            weeklyReflection: nil, parentObservations: []
        )
        let applicationService = CoachingApplicationService(coachingContextService: StubCoachingContextProvider(context: context))

        let first = try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)
        let second = try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)

        #expect(first == second)
    }

    @Test("A genuine technical failure propagates from the service, never as a successful empty presentation")
    @MainActor
    func technicalFailurePropagates() throws {
        let applicationService = CoachingApplicationService(coachingContextService: ThrowingCoachingContextProvider())

        #expect(throws: ThrowingCoachingContextProvider.TestError.self) {
            try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)
        }
    }

    @Test("Extraction into CoachingApplicationService produces identical output to calling the three pipeline stages directly")
    @MainActor
    func extractionProducesIdenticalOutputToDirectPipelineCalls() throws {
        let context = WeeklyCoachingContext(
            athleteId: Self.athleteId, weekStart: Self.weekStart, previousWeekStart: Self.weekStart,
            weekPlanStatus: .draft, plannedActivityCount: 2, completedPlannedActivityCount: 1,
            uncompletedPlannedActivityCount: 1, unplannedLoggedActivityCount: 1, totalLoggedActivityCount: 2,
            weeklyReflection: nil,
            parentObservations: [ParentObservationSummary(localDate: Self.weekStart, text: "Note")]
        )
        let stubProvider = StubCoachingContextProvider(context: context)

        // The pre-Sprint-11 sequence, called directly — exactly what
        // WeeklyReviewViewModel.loadCoachingPresentation() used to do
        // itself before this sprint's extraction. Sprint 14 (revised):
        // now includes the explicit CoachingAnalysisInputMapper step
        // too, matching CoachingApplicationService's actual sequence.
        let directContext = try stubProvider.weeklyCoachingContext(forAthlete: Self.athleteId, weekStart: Self.weekStart)
        let directInput = CoachingAnalysisInputMapper().map(directContext)
        let directResult = CoachingEngine().analyse(directInput)
        let directPresentation = CoachingPresentationMapper().map(directResult)

        // The post-Sprint-11 path.
        let applicationService = CoachingApplicationService(coachingContextService: stubProvider)
        let extractedPresentation = try applicationService.coachingPresentation(forAthlete: Self.athleteId, weekStart: Self.weekStart)

        #expect(directPresentation == extractedPresentation)
    }
}
